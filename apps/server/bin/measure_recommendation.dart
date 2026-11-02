import 'dart:convert';
import 'dart:io';

import 'package:ionic_server/src/http/api_exception.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/posts/posts_service.dart';
import 'package:ionic_server/src/modules/recommendation/candidate_retrieval.dart';
import 'package:ionic_server/src/modules/recommendation/content_labeler.dart';
import 'package:ionic_server/src/modules/recommendation/ranker_config.dart';
import 'package:ionic_server/src/modules/recommendation/recommendation_service.dart';
import 'package:ionic_server/src/modules/recommendation/text_label_rules.dart';
import 'package:ionic_server/src/modules/recommendation/types.dart';
import 'package:ionic_server/src/modules/recommendation/semantic_worker.dart';
import 'package:ionic_server/src/modules/recommendation/adaptive_policy.dart';

/// Deterministic synthetic corpus and real serving SQL. No human relevance claim.
Future<void> main(List<String> args) async {
  final url = Platform.environment['DATABASE_URL'];
  if (url == null ||
      !Uri.parse(url).pathSegments.last
          .startsWith('ionic_recommendation_verify_')) {
    throw StateError(
      'Use an empty dedicated ionic_recommendation_verify_* database.',
    );
  }
  final db = DatabaseService.fromEnvironment();
  final adaptive =
      Platform.environment['RECOMMENDATION_ADAPTIVE_ENABLED'] == 'true';
  final now = DateTime.utc(2026, 11, 1);
  final config = buildRankerConfig(now.millisecondsSinceEpoch.toDouble());
  final authors = [for (var i = 1; i <= 49; i++) _id(i)];
  final viewer = authors.first;
  var checks = 0;
  void check(bool value, String name) {
    if (!value) throw StateError(name);
    checks++;
  }

  final output = <String, Object?>{};
  var seeded = false;
  LocalTextEmbedder? model;
  try {
    check(
      (await db.query('SELECT count(*) FROM app_user')).first.first == 0,
      'Dedicated database must be empty',
    );
    check(
      await db.checkReadiness() == DatabaseReadiness.ready,
      'Migrations ready',
    );
    await db.transaction((tx) async {
      for (var i = 0; i < authors.length; i++) {
        await tx.execute(
          r'''INSERT INTO app_user(id, handle, handle_normalized, password_salt, password_hash)
          VALUES ($1, $2, $2, decode(repeat('00', 16), 'hex'), decode(repeat('00', 64), 'hex'))''',
          parameters: [authors[i], 'fictional_${i.toString().padLeft(3, '0')}'],
        );
        await tx.execute(
          r'INSERT INTO user_profile(user_id, display_name) VALUES ($1, $2)',
          parameters: [authors[i], 'Fictional $i'],
        );
      }
    });
    seeded = true;
    final posts = <Map<String, Object?>>[], labels = <Map<String, Object?>>[];
    final direct = <String>[], adjacent = <String>[];
    const neutral = [
      'Lập trình phần mềm',
      'Học tập kiến thức',
      'Writing storytelling',
      'Quan sát thiên văn sao chổi',
    ];
    for (var i = 0; i < 6012; i++) {
      final isDirect = i < 4, isAdjacent = i >= 4 && i < 12;
      final text = isDirect
          ? 'Thiết kế giao diện $i'
          : isAdjacent
          ? (i.isEven ? 'Sản phẩm roadmap $i' : 'Sáng tạo ý tưởng $i')
          : '${neutral[i % neutral.length]} $i';
      final id = _id(10000 + i);
      if (isDirect) direct.add(id);
      if (isAdjacent) adjacent.add(id);
      posts.add({
        'id': id,
        'author_id': authors[1 + i % 48],
        'body': text,
        'created_at': now
            .subtract(
              isDirect
                  ? Duration(days: 20, minutes: i)
                  : isAdjacent
                  ? Duration(days: 19, minutes: i)
                  : Duration(minutes: i + 1),
            )
            .toIso8601String(),
      });
      for (final label in labelContent(
        LabelContentInput(
          taxonomyVersion: config.taxonomyVersion,
          kind: ContentKind.text,
          text: text,
          formatLabelIds: const {ContentKind.text: 'format.text'},
          // Freeze stored fixture labels so classifier-vocabulary expansion cannot
          // change row counts between the before/after query measurements.
          keywordRules: textLabelRules
              .where(
                (r) => const [
                  'topic.design',
                  'topic.software',
                  'topic.product',
                  'topic.writing',
                  'topic.learning',
                  'topic.creativity',
                  'context.howto',
                  'language.vi',
                ].contains(r.labelId),
              )
              .toList(),
        ),
      )) {
        labels.add({
          'content_id': id,
          'taxonomy_version': label.taxonomyVersion,
          'dimension': label.dimension.name,
          'label_id': label.labelId,
          'confidence': label.confidence,
          'source': label.source.name,
        });
      }
    }
    await db.transaction((tx) async {
      await tx.execute(
        r'''INSERT INTO content(id, author_id, body, created_at)
        SELECT id, author_id, body, created_at FROM jsonb_to_recordset($1::jsonb)
        AS x(id uuid, author_id uuid, body text, created_at timestamptz)''',
        parameters: [jsonEncode(posts)],
      );
      await tx.execute(
        r'''INSERT INTO content_label(content_id, taxonomy_version, dimension, label_id, confidence, source)
        SELECT content_id, taxonomy_version, dimension, label_id, confidence, source FROM jsonb_to_recordset($1::jsonb)
        AS x(content_id uuid, taxonomy_version text, dimension text, label_id text, confidence real, source text)''',
        parameters: [jsonEncode(labels)],
      );
      for (final label in [
        ('topic', 'topic.design'),
        ('format', 'format.text'),
      ]) {
        await tx.execute(
          r'''INSERT INTO user_preference_control(user_id, taxonomy_version, dimension, label_id, control)
          VALUES ($1, $2, $3, $4, 'more')''',
          parameters: [viewer, config.taxonomyVersion, label.$1, label.$2],
        );
      }
    });
    for (final table in [
      'app_user',
      'user_profile',
      'content',
      'content_label',
      'user_preference_control',
    ]) {
      await db.query('ANALYZE $table');
    }
    if (args.contains('--semantic-load')) {
      model = await LocalTextEmbedder.start();
      final worker = SemanticWorker(db, model);
      var embedded = 0;
      final watch = Stopwatch()..start();
      while (true) {
        final n = await worker.runBatch();
        if (n == 0) break;
        embedded += n;
      }
      watch.stop();
      for (final seed in [direct.first, adjacent.first]) {
        await db.query(
          r'''INSERT INTO recommendation_item_feedback(user_id,content_id,preference,source_updated_at,updated_at)
          SELECT $1,id,'more',updated_at,$3 FROM content WHERE id=$2''',
          parameters: [viewer, seed, now.subtract(const Duration(minutes: 1))],
        );
      }
      output['semanticLoad'] = {
        'actuallyEmbeddedPosts': embedded,
        'workerElapsedMs': watch.elapsedMilliseconds,
        'positiveSeedCount': 2,
        'scope': 'All 6012 fixture bodies embedded with the real model; not human relevance evidence.',
      };
    }
    final smallParameters = candidateRetrievalParameters(
      viewerId: viewer,
      config: config,
      candidateLimit: 24,
    );
    final small = await db.query(
      candidateRetrievalSql,
      parameters: smallParameters,
    );
    final found = small.map((r) => '${r.toColumnMap()['id']}').toSet();
    double coverage(List<String> expected) =>
        expected.where(found.contains).length / expected.length;
    output.addAll({
      'corpusVersion': 'ionic-retrieval-corpus-v1',
      'source': 'synthetic structural fixtures, not human relevance judgments',
      'rankerVersion': config.rankerVersion,
      'postCount': posts.length,
      'labelCount': labels.length,
      'retrievalLimit': 24,
      'retrievedDistinct': found.length,
      'directCandidateCoverage': coverage(direct),
      'adjacentCandidateCoverage': coverage(adjacent),
      'directExpectedCount': direct.length,
      'adjacentExpectedCount': adjacent.length,
    });
    if (!args.contains('--baseline')) {
      check(
        coverage(direct) == 1,
        'Older direct matches must survive generic format labels',
      );
      check(
        coverage(adjacent) == 1,
        'Explicit positive topic must retrieve older adjacent topics',
      );
    }
    final params = candidateRetrievalParameters(
      viewerId: viewer,
      config: config,
      candidateLimit: 500,
      audienceWindowStart: adaptive ? _audienceWindow() : null,
    );
    output['adaptiveMode'] = adaptive;
    final samples = <double>[];
    for (var i = 0; i < 14; i++) {
      final watch = Stopwatch()..start();
      await db.query(candidateRetrievalSql, parameters: params);
      watch.stop();
      if (i >= 2) samples.add(watch.elapsedMicroseconds / 1000);
    }
    samples.sort();
    final plan = await db.query(
      'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) $candidateRetrievalSql',
      parameters: params,
    );
    final rawPlan = plan.first.first;
    final parsedPlan = rawPlan is String ? jsonDecode(rawPlan) : rawPlan;
    final planEntry = (parsedPlan as List).first as Map;
    output['servingQuery'] = {
      'candidateLimit': 500,
      'warmups': 2,
      'samples': samples.length,
      'p50Ms': samples[samples.length ~/ 2],
      'p95Ms': samples[(samples.length * .95).ceil() - 1],
      'postgresPlanningMs': planEntry['Planning Time'],
      'postgresExecutionMs': planEntry['Execution Time'],
      'explain': parsedPlan,
    };
    if (args.contains('--semantic-load')) {
      final service = RecommendationService(db);
      final elapsed = <double>[];
      for (var i = 0; i < 10; i++) {
        final watch = Stopwatch()..start();
        await service.forYou(viewer, 20, null);
        watch.stop();
        if (i >= 2) elapsed.add(watch.elapsedMicroseconds / 1000);
      }
      elapsed.sort();
      output['semanticFeedService'] = {
        'positiveSeedCount': 2,
        'samples': 8,
        'warmups': 2,
        'p50Ms': elapsed[elapsed.length ~/ 2],
        'p95Ms': elapsed.last,
        'scope': 'Full service with two active semantic seeds, excluding HTTP/device network.',
      };
      // Exercise the maximum seed budget, including explicit negatives.
      await db.query(
        r'DELETE FROM recommendation_item_feedback WHERE user_id=$1',
        parameters: [viewer],
      );
      for (var i = 0; i < 24; i++) {
        await db.query(
          r'''INSERT INTO recommendation_item_feedback(user_id,content_id,preference,source_updated_at,updated_at)
          SELECT $1,id,$4,updated_at,$3 FROM content WHERE id=$2''',
          parameters: [
            viewer,
            _id(10000 + i),
            now.subtract(const Duration(minutes: 1)),
            i < 12 ? 'more' : 'less',
          ],
        );
      }
      final maximum = <double>[];
      for (var i = 0; i < 14; i++) {
        final watch = Stopwatch()..start();
        await db.query(candidateRetrievalSql, parameters: params);
        watch.stop();
        if (i >= 2) maximum.add(watch.elapsedMicroseconds / 1000);
      }
      maximum.sort();
      final maximumPlan = await db.query(
        'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) $candidateRetrievalSql',
        parameters: params,
      );
      final maximumRaw = maximumPlan.first.first;
      output['maximumSeedQuery'] = {
        'seedCount': 24,
        'positive': 12,
        'negative': 12,
        'samples': 12,
        'warmups': 2,
        'p50Ms': maximum[maximum.length ~/ 2],
        'p95Ms': maximum.last,
        'explain': maximumRaw is String ? jsonDecode(maximumRaw) : maximumRaw,
      };
    }
    if (!args.contains('--baseline')) {
      final service = RecommendationService(db);
      final page = await service.forYou(viewer, 2, null);
      final firstItems = page['items'] as List;
      check(
        firstItems.length == 2 &&
            firstItems.map((p) => (p as Map)['id']).toSet().length == 2,
        'Mixed real feed returns distinct eligible items',
      );
      check(
        firstItems.every(
          (p) => !(p as Map).keys.any(
            ['labels', 'score', 'reasonCode', 'rankerVersion'].contains,
          ),
        ),
        'No ranking internals in feed response',
      );
      final firstCursor = page['nextCursor'] as String;
      final next = await service.forYou(viewer, 2, firstCursor);
      check(
        !(next['items'] as List).any(
          (p) => firstItems.any((f) => (f as Map)['id'] == (p as Map)['id']),
        ),
        'Stable cursor does not repeat content',
      );
      await service.hide(viewer, '${(firstItems.first as Map)['id']}');
      var staleRejected = false;
      try {
        final replay = await service.forYou(viewer, 2, firstCursor);
        if (adaptive) {
          staleRejected =
              jsonEncode(
                (replay['items'] as List).map((p) => (p as Map)['id']).toList(),
              ) ==
              jsonEncode(
                (next['items'] as List).map((p) => (p as Map)['id']).toList(),
              );
        }
      } on ApiException catch (error) {
        staleRejected = error.code == 'FEED_CURSOR_STALE';
      }
      check(
        staleRejected,
        adaptive
            ? 'Issued page remains stable after a different page changes'
            : 'Stale snapshot rejected with stable code',
      );
      await service.unhide(viewer, '${(firstItems.first as Map)['id']}');
      final blockedAuthor = authors[1];
      await db.query(
        r'INSERT INTO account_block(blocker_id, blocked_id) VALUES ($1, $2)',
        parameters: [blockedAuthor, viewer],
      );
      final blockedPool = await db.query(
        candidateRetrievalSql,
        parameters: params,
      );
      check(
        blockedPool.every(
          (r) => '${r.toColumnMap()['author_id']}' != blockedAuthor,
        ),
        'Reverse block excludes candidates',
      );
      await db.query(
        r'DELETE FROM account_block WHERE blocker_id = $1',
        parameters: [blockedAuthor],
      );
      await db.query(
        r'INSERT INTO account_mute(muter_id, muted_id) VALUES ($1, $2)',
        parameters: [viewer, blockedAuthor],
      );
      final mutedPool = await db.query(
        candidateRetrievalSql,
        parameters: params,
      );
      check(
        mutedPool.every(
          (r) => '${r.toColumnMap()['author_id']}' != blockedAuthor,
        ),
        'Mute excludes candidates',
      );
      await db.query(
        r'DELETE FROM account_mute WHERE muter_id = $1',
        parameters: [viewer],
      );
      final postsService = PostsService(db);
      final beforeLike = await service.forYou(viewer, 2, null);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await postsService.setLike(viewer, direct.last, true);
      var updatedProfileRejected = false;
      try {
        final after = await service.forYou(
          viewer,
          2,
          beforeLike['nextCursor'] as String,
        );
        if (adaptive) {
          updatedProfileRejected = (after['items'] as List).isNotEmpty;
        }
      } on ApiException catch (error) {
        updatedProfileRejected = error.code == 'FEED_CURSOR_STALE';
      }
      check(
        updatedProfileRejected,
        adaptive
            ? 'Next unissued page adapts without invalidating earlier pages'
            : 'Learned feature update invalidates older clock without ranker 500',
      );
      check(
        ((await service.forYou(viewer, 2, null))['items'] as List).isNotEmpty,
        'Fresh page succeeds after learned update',
      );
      await service.reset(viewer);
      await service.updateSettings(viewer, {'paused': true});
      await postsService.setLike(viewer, direct.first, true);
      check(
        (await db.query(
              r'SELECT count(*) FROM user_preference_feature WHERE user_id = $1',
              parameters: [viewer],
            )).first.first ==
            0,
        'Pause prevents learned writes',
      );
      await service.updateSettings(viewer, {'paused': false});
      await postsService.setSaved(viewer, direct.first, true);
      final learnedRows = await db.query(
        r'SELECT dimension, label_id, score FROM user_preference_feature WHERE user_id = $1 ORDER BY dimension, label_id',
        parameters: [viewer],
      );
      await postsService.setSaved(viewer, direct.first, true);
      final retriedRows = await db.query(
        r'SELECT dimension, label_id, score FROM user_preference_feature WHERE user_id = $1 ORDER BY dimension, label_id',
        parameters: [viewer],
      );
      check(
        learnedRows.isNotEmpty &&
            jsonEncode(learnedRows.map((r) => r.toColumnMap()).toList()) ==
                jsonEncode(retriedRows.map((r) => r.toColumnMap()).toList()),
        'Idempotent save does not learn twice',
      );
      await service.reset(viewer);
      check(
        (await service.settings(viewer))['paused'] == false,
        'Reset restores learning',
      );
      check(
        (await db.query(
              r'SELECT count(*) FROM user_preference_control WHERE user_id = $1',
              parameters: [viewer],
            )).first.first ==
            0,
        'Reset clears controls',
      );
      check(
        (await db.query(
              r'SELECT count(*) FROM user_preference_feature WHERE user_id = $1',
              parameters: [viewer],
            )).first.first ==
            0,
        'Reset clears learned features',
      );
      check(
        (await db.query(
              r'SELECT count(*) FROM content_bookmark WHERE user_id = $1',
              parameters: [viewer],
            )).first.first ==
            1,
        'Reset preserves authoritative save',
      );
      final serviceSamples = <double>[];
      for (var i = 0; i < 10; i++) {
        final watch = Stopwatch()..start();
        await service.forYou(viewer, 20, null);
        watch.stop();
        if (i >= 2) serviceSamples.add(watch.elapsedMicroseconds / 1000);
      }
      serviceSamples.sort();
      output['feedService'] = {
        'semanticSeedCount': 0,
        'samples': serviceSamples.length,
        'warmups': 2,
        'pageSize': 20,
        'p50Ms': serviceSamples[serviceSamples.length ~/ 2],
        'p95Ms': serviceSamples.last,
        'scope': 'Service including profile reads, retrieval, ranking and attachment metadata; excludes HTTP/device network.',
      };
      if (adaptive) {
        final measured = await service.forYou(viewer, 20, null);
        final observed = (measured['items'] as List)
            .cast<Map<String, dynamic>>();
        final receiptIds = observed
            .map((p) => p['receiptId'] as String)
            .toList();
        // Isolated fixture clock adjustment, never performed on application data.
        await db.query(
          r"UPDATE recommendation_delivery_receipt SET issued_at=now()-interval '1 minute',expires_at=now()+interval '6 days' WHERE id=ANY($1::uuid[])",
          parameters: [receiptIds],
        );
        final accepted = await service.recordAttention(viewer, {
          'items': [
            for (var i = 0; i < receiptIds.length; i++)
              {
                'receiptId': receiptIds[i],
                'band': i % 3 == 0 ? 'peek' : 'long',
              },
          ],
        });
        check(
          accepted['accepted'] == 20,
          'Mature context accepts twenty owned coarse observations',
        );
        final measurements = <String, List<double>>{
          'fresh': [],
          'append': [],
          'cachedRetry': [],
        };
        for (var i = 0; i < 10; i++) {
          var watch = Stopwatch()..start();
          final fresh = await service.forYou(viewer, 20, null);
          watch.stop();
          if (i >= 2) {
            measurements['fresh']!.add(watch.elapsedMicroseconds / 1000);
          }
          watch = Stopwatch()..start();
          final append = await service.forYou(
            viewer,
            20,
            fresh['nextCursor'] as String,
          );
          watch.stop();
          if (i >= 2) {
            measurements['append']!.add(watch.elapsedMicroseconds / 1000);
          }
          watch = Stopwatch()..start();
          final retry = await service.forYou(
            viewer,
            20,
            fresh['nextCursor'] as String,
          );
          watch.stop();
          if (i >= 2) {
            measurements['cachedRetry']!.add(watch.elapsedMicroseconds / 1000);
          }
          check(
            jsonEncode(
                  (append['items'] as List)
                      .map((p) => (p as Map)['id'])
                      .toList(),
                ) ==
                jsonEncode(
                  (retry['items'] as List)
                      .map((p) => (p as Map)['id'])
                      .toList(),
                ),
            'Mature append retry preserves order',
          );
        }
        output['observedContextService'] = {
          'qualifiedSourcePosts': 20,
          'warmups': 2,
          'samplesPerPath': 8,
          'scope': 'Same 6012-body corpus; synthetic owned bands, full service excluding HTTP/network/device frames.',
          for (final e in measurements.entries) e.key: (_percentiles(e.value)),
        };
      }
      output['functionalAssertions'] = checks;
    }
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(output));
  } finally {
    await model?.close();
    if (seeded) {
      await db.query(
        r'DELETE FROM app_user WHERE id = ANY($1::uuid[])',
        parameters: [authors],
      );
    }
    await db.close();
  }
}

Map<String, double> _percentiles(List<double> values) {
  values.sort();
  return {'p50Ms': values[values.length ~/ 2], 'p95Ms': values.last};
}

String _id(int value) =>
    'a0000000-0000-4000-8000-${value.toString().padLeft(12, '0')}';

DateTime _audienceWindow() {
  final ms = AdaptivePolicy.fromEnvironment().audienceWindowMinutes * 60000;
  return DateTime.fromMillisecondsSinceEpoch(
    DateTime.now().millisecondsSinceEpoch ~/ ms * ms,
    isUtc: true,
  );
}
