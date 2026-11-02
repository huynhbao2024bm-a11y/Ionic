import 'dart:convert';
import 'dart:io';

import 'package:ionic_server/src/http/api_exception.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/posts/posts_service.dart';
import 'package:ionic_server/src/modules/recommendation/candidate_retrieval.dart';
import 'package:ionic_server/src/modules/recommendation/ranker_config.dart';
import 'package:ionic_server/src/modules/recommendation/recommendation_service.dart';
import 'package:ionic_server/src/modules/recommendation/recommendation_signals.dart';
import 'package:ionic_server/src/modules/recommendation/types.dart';
import 'package:ionic_server/src/modules/recommendation/semantic_config.dart';
import 'package:ionic_server/src/modules/recommendation/semantic_worker.dart';
import 'package:ionic_server/src/modules/recommendation/text_duplicates.dart';

String id(int n) => 'b0000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

Future<void> main() async {
  final url = Platform.environment['DATABASE_URL'];
  if (url == null ||
      !Uri.parse(url).pathSegments.last
          .startsWith('ionic_recommendation_verify_') ||
      !SemanticConfig().enabled) {
    throw StateError(
      'Use an empty dedicated recommendation verification database and enable semantics.',
    );
  }
  final db = DatabaseService.fromEnvironment();
  final feed = RecommendationService(db), posts = PostsService(db);
  final viewer = id(1), author = id(2), other = id(3), privateAuthor = id(4);
  final authors = [viewer, author, other, privateAuthor];
  final cases =
      (jsonDecode(
            await File('data/recommendation/semantic-challenge-v1.json')
                .readAsString(),
          ) as Map)['cases']
          as List;
  var checks = 0, seeded = false;
  LocalTextEmbedder? model;
  final observations = <Map<String, Object?>>[];
  void check(bool value, String name) {
    if (!value) throw StateError(name);
    checks++;
  }

  Future<int> count(String table) async =>
      (await db.query(
            'SELECT count(*) FROM $table WHERE user_id=\$1',
            parameters: [viewer],
          )).first.first
          as int;
  Future<double> score() async =>
      ((await db.query(
                r'SELECT coalesce(sum(score),0)::double precision FROM user_preference_feature WHERE user_id=$1',
                parameters: [viewer],
              )).first.first
              as num)
          .toDouble();
  Future<List<Map<String, dynamic>>> retrieve() async {
    final config = buildRankerConfig(
      DateTime.now().millisecondsSinceEpoch.toDouble(),
    );
    return (await db.query(
      candidateRetrievalSql,
      parameters: candidateRetrievalParameters(
        viewerId: viewer,
        config: config,
        candidateLimit: 500,
      ),
    )).map((r) => r.toColumnMap()).toList();
  }

  try {
    check(
      (await db.query('SELECT count(*) FROM app_user')).first.first == 0,
      'Verification database empty',
    );
    await db.transaction((tx) async {
      for (var i = 0; i < authors.length; i++) {
        await tx.execute(
          r'''INSERT INTO app_user(id,handle,handle_normalized,password_salt,password_hash)
          VALUES($1,$2,$2,decode(repeat('00',16),'hex'),decode(repeat('00',64),'hex'))''',
          parameters: [
            authors[i],
            'v6_fixture_${i.toString().padLeft(3, '0')}',
          ],
        );
        await tx.execute(
          r'INSERT INTO user_profile(user_id,display_name,visibility) VALUES($1,$2,$3)',
          parameters: [
            authors[i],
            'Synthetic $i',
            i == 3 ? 'private' : 'public',
          ],
        );
      }
      for (var i = 0; i < cases.length; i++) {
        final c = cases[i] as Map;
        for (var j = 0; j < 3; j++) {
          final body = c[['seed', 'related', 'unrelated'][j]];
          await tx.execute(
            r"INSERT INTO content(id,author_id,body,created_at) VALUES($1,$2,$3,now()-interval '1 minute')",
            parameters: [id(100 + i * 3 + j), j == 0 ? author : other, body],
          );
          // Freeze a generic label to isolate actual semantics from keyword rules.
          await tx.execute(
            r'''INSERT INTO content_label(content_id,taxonomy_version,dimension,label_id,confidence,source)
            VALUES($1,'ionic-taxonomy-v1','format','format.text',1,'rule')''',
            parameters: [id(100 + i * 3 + j)],
          );
        }
      }
      await tx.execute(
        r"INSERT INTO content(id,author_id,body) VALUES($1,$2,'Private account fixture')",
        parameters: [id(999), privateAuthor],
      );
    });
    seeded = true;
    model = await LocalTextEmbedder.start();
    final worker = SemanticWorker(db, model);
    var embedded = 0;
    while (true) {
      final n = await worker.runBatch();
      if (n == 0) break;
      embedded += n;
    }
    check(embedded == 36, 'Only 36 public text fixtures embedded');
    check(
      (await db.query(
            r'SELECT count(*) FROM content_semantic_feature WHERE content_id=$1',
            parameters: [id(999)],
          )).first.first ==
          0,
      'Private account never embedded',
    );
    check(await worker.runBatch() == 0, 'Worker idempotent');
    var admitted = 0;
    for (var i = 0; i < cases.length; i++) {
      await feed.reset(viewer);
      final seed = id(100 + i * 3),
          related = id(101 + i * 3),
          unrelated = id(102 + i * 3);
      await posts.setLike(viewer, seed, true);
      final rows = await retrieve();
      double similarity(String key) =>
          (rows.firstWhere((r) => r['id'] == key)['semantic_positive'] as num)
              .toDouble();
      final positive = similarity(related), negative = similarity(unrelated);
      check(
        positive > negative,
        'Real semantic ordering ${(cases[i] as Map)['id']}',
      );
      if (positive >= SemanticConfig().minimumSimilarity) admitted++;
      observations.add({
        'id': (cases[i] as Map)['id'],
        'relatedCosine': positive,
        'unrelatedCosine': negative,
      });
      await posts.setLike(viewer, seed, false);
    }
    final first = id(100);
    await posts.setLike(viewer, first, true);
    final once = await score(),
        onceCount = await count('user_preference_evidence');
    await posts.setLike(viewer, first, true);
    check(
      await count('user_preference_evidence') == onceCount,
      'Like retry idempotent',
    );
    for (var i = 0; i < 8; i++) {
      await posts.setLike(viewer, first, false);
      await posts.setLike(viewer, first, true);
    }
    check(
      (await score() - once).abs() < .0001,
      'Repeated toggles cannot amplify',
    );
    await posts.setSaved(viewer, first, true);
    check(await score() > once, 'Independent save contributes');
    await feed.updateSettings(viewer, {'paused': true});
    await posts.setSaved(viewer, first, false);
    check(
      (await score() - once).abs() < .0001,
      'Unsave withdraws while paused',
    );
    await posts.setLike(viewer, id(103), true);
    check(
      await count('user_preference_evidence') == onceCount,
      'Paused like persists without learning',
    );
    await feed.updateSettings(viewer, {'paused': false});
    await feed.setPreference(viewer, first, {'preference': 'less'});
    final negativeRows = await retrieve();
    check(
      negativeRows.every((r) => r['semantic_positive'] == null),
      'Item less overrides its positive evidence',
    );
    check(
      negativeRows.any((r) => r['semantic_negative'] != null),
      'Negative example available',
    );
    await feed.setPreference(viewer, first, {'preference': 'none'});
    check(
      await count('recommendation_item_feedback') == 0,
      'Item feedback removable',
    );
    await feed.reset(viewer);
    check(
      await count('user_preference_evidence') == 0 &&
          await count('user_preference_feature') == 0 &&
          await count('user_preference_baseline') == 0,
      'Reset clears all learned layers',
    );
    check(
      (await db.query(
            r'SELECT count(*) FROM content_reaction WHERE user_id=$1',
            parameters: [viewer],
          )).first.first ==
          2,
      'Reset preserves domain reactions',
    );
    check(
      (await retrieve()).every((r) => r['semantic_positive'] == null),
      'Reset does not replay retained reactions',
    );
    await posts.setLike(viewer, first, false);
    await posts.setLike(viewer, first, true);
    final page = await feed.forYou(viewer, 1, null);
    check(
      !(jsonEncode(page).contains('semantic_') ||
          jsonEncode(page).contains('reasonCode')),
      'No internal features exposed',
    );
    await db.query(
      r"UPDATE content SET body=body || ' changed',updated_at=clock_timestamp() WHERE id=$1",
      parameters: [first],
    );
    check(
      (await retrieve()).every((r) => r['semantic_positive'] == null),
      'Stale edited seed vector ignored',
    );
    try {
      await feed.forYou(viewer, 1, page['nextCursor'] as String?);
      throw StateError('Expected stale');
    } on ApiException catch (e) {
      check(e.code == 'FEED_CURSOR_STALE', 'Evidence edit invalidates cursor');
    }
    check(
      await count('user_preference_evidence') == 0,
      'Changed source withdraws old learned labels',
    );
    check(await worker.runBatch() == 1, 'Edit re-embedded once');
    await posts.setSaved(viewer, first, true);
    await db.query(
      r'INSERT INTO account_block(blocker_id,blocked_id) VALUES($1,$2)',
      parameters: [author, viewer],
    );
    final blocked = await retrieve();
    check(
      blocked.every(
        (r) => r['author_id'] != author && r['semantic_positive'] == null,
      ),
      'Reverse block gates candidates and semantic seeds',
    );
    await db.query(
      r'DELETE FROM account_block WHERE blocker_id=$1',
      parameters: [author],
    );
    await db.query(
      r"UPDATE user_profile SET visibility='private' WHERE user_id=$1",
      parameters: [author],
    );
    check(
      (await retrieve()).every((r) => r['semantic_positive'] == null),
      'Private seed immediately unavailable before cleanup',
    );
    await worker.runBatch();
    check(
      (await db.query(
            r'SELECT count(*) FROM content_semantic_feature s JOIN content c ON c.id=s.content_id WHERE c.author_id=$1',
            parameters: [author],
          )).first.first ==
          0,
      'Worker purges restricted content vectors',
    );
    await db.query(r'DELETE FROM content WHERE id=$1', parameters: [first]);
    await feed.forYou(viewer, 20, null);
    check(
      await count('user_preference_feature') == 0,
      'Content deletion removes cached influence',
    );
    await db.query(
      r"UPDATE user_profile SET visibility='public' WHERE user_id=$1",
      parameters: [author],
    );
    await feed.reset(viewer);
    await db.query(
      r'''INSERT INTO user_preference_baseline
      (user_id,taxonomy_version,dimension,label_id,score,confidence,source_summary,updated_at,expires_at)
      VALUES($1,'ionic-taxonomy-v1','format','format.text',.5,1,ARRAY['like'],now(),now()+interval '1 day')''',
      parameters: [viewer],
    );
    final later = id(106);
    await posts.setLike(viewer, later, true);
    check(await score() > .5, 'Legacy baseline retained with new evidence');
    await posts.setLike(viewer, later, false);
    check((await score() - .5).abs() < .0001, 'Undo preserves legacy baseline');
    await db.query(
      r"UPDATE user_preference_baseline SET updated_at=now()-interval '2 days',expires_at=now()-interval '1 day' WHERE user_id=$1",
      parameters: [viewer],
    );
    await feed.forYou(viewer, 20, null);
    check(
      await count('user_preference_baseline') == 0 && await score() == 0,
      'Expired baseline withdrawn',
    );
    await db.query(
      r'''INSERT INTO content(id,author_id,body)
      SELECT ('b0000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,$1,'Bounded synthetic evidence fixture'
      FROM generate_series(2000,2513) n''',
      parameters: [other],
    );
    await db.query(
      r'''INSERT INTO user_preference_evidence
      (user_id,content_id,kind,taxonomy_version,dimension,label_id,contribution,confidence,source_updated_at,occurred_at,expires_at)
      SELECT $1,c.id,'like','ionic-taxonomy-v1',x.dimension,x.label,.18,1,c.updated_at,
        now()-interval '1 hour',now()+interval '1 day'
      FROM content c CROSS JOIN (VALUES('format','format.text'),('topic','topic.design')) x(dimension,label)
      WHERE c.author_id=$2 AND c.body='Bounded synthetic evidence fixture' ''',
      parameters: [viewer, other],
    );
    await posts.setSaved(viewer, later, true);
    check(
      (await db.query(
            r'SELECT count(DISTINCT (content_id,kind)) FROM user_preference_evidence WHERE user_id=$1',
            parameters: [viewer],
          )).first.first ==
          512,
      '512 whole-action cap',
    );
    check(
      (await db.query(
            r'''SELECT count(*) FROM (SELECT content_id,count(*) n FROM user_preference_evidence
      WHERE user_id=$1 AND content_id<>$2 GROUP BY content_id HAVING count(*)<>2) partial''',
            parameters: [viewer, later],
          )).first.first ==
          0,
      'Cap never splits label snapshots',
    );
    await db.query(
      r"UPDATE user_preference_evidence SET occurred_at=now()-interval '61 days',expires_at=now()-interval '1 day' WHERE user_id=$1",
      parameters: [viewer],
    );
    await feed.forYou(viewer, 20, null);
    check(
      await count('user_preference_evidence') == 0 && await score() == 0,
      'Expired evidence physically purged on access',
    );
    await feed.reset(viewer);
    await posts.setSaved(viewer, id(109), true);
    await db.query(
      r"UPDATE content_semantic_feature SET model_version='wrong-version' WHERE content_id=$1",
      parameters: [id(109)],
    );
    check(
      (await retrieve()).every((r) => r['semantic_positive'] == null),
      'Wrong model version never mixed',
    );
    await worker.runBatch();
    final config = buildRankerConfig(
      DateTime.now().millisecondsSinceEpoch.toDouble(),
    );
    final disabled = candidateRetrievalParameters(
      viewerId: viewer,
      config: config,
      candidateLimit: 500,
    );
    disabled[7] = '';
    check(
      (await db.query(
        candidateRetrievalSql,
        parameters: disabled,
      )).every((r) => r.toColumnMap()['semantic_positive'] == null),
      'Semantic disable returns structured fallback',
    );
    await model.close();
    model = null;
    check(
      ((await feed.forYou(viewer, 20, null))['items'] as List).isNotEmpty,
      'Feed independent of stopped model process',
    );
    await db.query('DELETE FROM content_semantic_feature');
    check(
      ((await feed.forYou(viewer, 20, null))['items'] as List).isNotEmpty,
      'Missing vectors preserve feed',
    );
    await feed.reset(viewer);
    final preserved = id(112);
    await posts.setLike(viewer, preserved, true);
    await db.transaction(
      (tx) => RecommendationSignalsService().recordContentAction(
        transaction: tx,
        userId: viewer,
        contentId: preserved,
        actionId: 'synthetic-legacy-policy',
        kind: PreferenceSignalKind.active_view,
      ),
    );
    check(await score() > .18, 'Legacy policy and reversible evidence coexist');
    await posts.setLike(viewer, preserved, false);
    check(
      (await score() - .05).abs() < .0001,
      'Text undo preserves separate legacy policy contribution',
    );
    final groups = textDuplicateGroups({
      'a': 'Một câu chuyện về hành trình vượt qua rừng núi để ngắm bình minh.',
      'b': 'Một câu chuyện về hành trình vượt qua rừng núi để ngắm bình minh!',
      'c': 'Một hướng dẫn làm bánh mì với bột nước muối và men tại nhà.',
      'd': 'ma má mà mạ mã mả ma má mà mạ mã mả',
    });
    check(
      groups['a'] == groups['b'] && groups['a'] != groups['c'],
      'Conservative clone grouping',
    );
    check(groups['d'] != groups['a'], 'Vietnamese diacritics preserved');
    final samples = <double>[];
    for (var i = 0; i < 12; i++) {
      final watch = Stopwatch()..start();
      await feed.forYou(viewer, 20, null);
      watch.stop();
      if (i >= 2) samples.add(watch.elapsedMicroseconds / 1000);
    }
    samples.sort();
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'version': buildRankerConfig(
          DateTime.now().millisecondsSinceEpoch.toDouble(),
        ).rankerVersion,
        'checks': checks,
        'source':
            'AI-authored synthetic mechanics, not human relevance judgments',
        'model': semanticModelVersion,
        'semanticContrasts': observations,
        'relatedAboveProvisionalThreshold': admitted,
        'embeddedPosts': embedded,
        'smallFixtureServiceMedianMs': samples[samples.length ~/ 2],
        'smallFixtureServiceP95Ms': samples.last,
      }),
    );
  } finally {
    await model?.close();
    if (seeded) {
      await db.query(
        r'DELETE FROM app_user WHERE id=ANY($1::uuid[])',
        parameters: [authors],
      );
    }
    await db.close();
  }
}
