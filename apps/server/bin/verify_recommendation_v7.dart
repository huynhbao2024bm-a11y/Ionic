import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:ionic_server/src/app.dart';

import 'package:ionic_server/src/http/api_exception.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/recommendation/candidate_retrieval.dart';
import 'package:ionic_server/src/modules/recommendation/feed_distribution.dart';
import 'package:ionic_server/src/modules/recommendation/ranker.dart';
import 'package:ionic_server/src/modules/recommendation/ranker_config.dart';
import 'package:ionic_server/src/modules/recommendation/recommendation_service.dart';
import 'package:ionic_server/src/modules/recommendation/types.dart';

String id(int n) => 'c0000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

Future<void> main() async {
  final url = Platform.environment['DATABASE_URL'];
  if (url == null ||
      !Uri.parse(url).pathSegments.last
          .startsWith('ionic_recommendation_verify_')) {
    throw StateError('Use a dedicated empty recommendation verification DB.');
  }
  final db = DatabaseService.fromEnvironment();
  final service = RecommendationService(db);
  final users = [for (var i = 1; i <= 14; i++) id(i)],
      viewer = id(1),
      followed = id(2);
  var seeded = false, checks = 0;
  void check(bool value, String name) {
    if (!value) throw StateError(name);
    checks++;
  }

  List<String> ids(Map<String, Object?> page) =>
      (page['items'] as List).map((p) => '${(p as Map)['id']}').toList();
  Map<String, dynamic> cursor(String value) =>
      jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(value))))
          as Map<String, dynamic>;
  Future<List<Map<String, dynamic>>> retrieve(
    String seed, {
    int limit = 500,
    int? clock,
  }) async {
    final config = buildRankerConfig(
      (clock ?? DateTime.now().millisecondsSinceEpoch).toDouble(),
    );
    return (await db.query(
      candidateRetrievalSql,
      parameters: candidateRetrievalParameters(
        viewerId: viewer,
        config: config,
        candidateLimit: limit,
        randomSeed: seed,
      ),
    )).map((r) => r.toColumnMap()).toList();
  }

  List<String> randomIds(List<Map<String, dynamic>> rows) {
    final unique = <String, int>{
      for (final r in rows)
        if (r['random_position'] != null)
          '${r['id']}': (r['random_position'] as num).toInt(),
    };
    return (unique.keys.toList()
      ..sort((a, b) => unique[a]!.compareTo(unique[b]!)));
  }

  Future<void> stale(
    String input, {
    int limit = 20,
    String expected = 'FEED_CURSOR_STALE',
  }) async {
    try {
      await service.forYou(viewer, limit, input);
      throw StateError('Expected cursor rejection');
    } on ApiException catch (e) {
      check(e.code == expected, 'Typed cursor rejection');
    }
  }

  try {
    check(
      (await db.query('SELECT count(*) FROM app_user')).first.first == 0,
      'Verification DB empty',
    );
    await db.transaction((tx) async {
      for (var i = 0; i < users.length; i++) {
        await tx.execute(
          r'''INSERT INTO app_user(id,handle,handle_normalized,password_salt,password_hash)
          VALUES($1,$2,$2,decode(repeat('00',16),'hex'),decode(repeat('00',64),'hex'))''',
          parameters: [users[i], 'v7_fixture_$i'],
        );
        await tx.execute(
          r'INSERT INTO user_profile(user_id,display_name,visibility) VALUES($1,$2,$3)',
          parameters: [
            users[i],
            'Synthetic $i',
            i == 13 ? 'private' : 'public',
          ],
        );
      }
      await tx.execute(
        r'INSERT INTO account_follow(follower_id,followed_id) VALUES($1,$2)',
        parameters: [viewer, followed],
      );
      for (var i = 0; i < 218; i++) {
        final author = i < 120
            ? followed
            : i < 208
            ? users[2 + (i - 120) % 11]
            : users.last;
        await tx.execute(
          r"INSERT INTO content(id,author_id,body,created_at) VALUES($1,$2,$3,now()-interval '1 hour')",
          parameters: [id(1000 + i), author, 'Synthetic fixture $i'],
        );
        await tx.execute(
          r'''INSERT INTO content_label(content_id,taxonomy_version,dimension,label_id,confidence,source)
          VALUES($1,'ionic-taxonomy-v1','format','format.text',1,'rule')''',
          parameters: [id(1000 + i)],
        );
      }
    });
    seeded = true;
    final first = await service.forYou(viewer, 20, null);
    final firstCursor = first['nextCursor'] as String, c = cursor(firstCursor);
    check(
      c['v'] == 2 && c['pageSize'] == 20 && (c['seed'] as String).length == 32,
      'Versioned nonce/page cursor',
    );
    final rows = await retrieve(c['seed'] as String, clock: c['asOfMs'] as int);
    final config = buildRankerConfig((c['asOfMs'] as int).toDouble());
    final unique = <String, Map<String, dynamic>>{
      for (final r in rows) '${r['id']}': r,
    };
    final candidates = unique.entries
        .map(
          (e) => FeedCandidate(
            id: e.key,
            creatorId: '${e.value['author_id']}',
            kind: ContentKind.text,
            publishedAtMs: (e.value['created_at'] as DateTime)
                .millisecondsSinceEpoch
                .toDouble(),
            labels: [
              ContentLabel(
                taxonomyVersion: config.taxonomyVersion,
                dimension: LabelDimension.format,
                labelId: 'format.text',
                confidence: 1,
                source: LabelSource.rule,
              ),
            ],
            eligible: true,
            visibleToViewer: true,
          ),
        )
        .toList();
    final profile = ViewerProfile(
      explicitInterests: const [],
      preferences: const [],
      followingCreatorIds: [followed],
      blockedCreatorIds: const [],
      mutedCreatorIds: const [],
      hiddenContentIds: const [],
      hiddenLabels: const [],
      lessLikeLabels: const [],
      recentExposures: const [],
    );
    final scored = rankCandidates(
      candidates,
      profile,
      config,
      candidates.length,
      diversify: false,
      deduplicateGroups: false,
    );
    final expected = mixFeedSnapshot(
      ranked: scored,
      randomOrderedIds: randomIds(rows),
      pageSize: 20,
      config: config,
    );
    check(
      jsonEncode(ids(first)) ==
          jsonEncode(
            expected.entries.take(20).map((e) => e.item.candidate.id).toList(),
          ),
      'Real service matches independent seeded SQL/mixer reconstruction',
    );
    check(
      expected.entries.take(20).where((e) => e.isRandom).length >= 8,
      'At least eight actual random draws',
    );
    check(
      (first['items'] as List)
              .where((p) => (p as Map)['authorId'] == followed)
              .length <=
          3,
      'Followed author capped on actual first page',
    );
    check(
      (first['items'] as List).every(
        (p) => !(p as Map).keys.any(
          [
            'random',
            'isRandom',
            'random_position',
            'score',
            'labels',
            'reasonCode',
          ].contains,
        ),
      ),
      'No lane/ranking data in response',
    );
    final next = await service.forYou(viewer, 20, firstCursor),
        again = await service.forYou(viewer, 20, firstCursor);
    check(
      jsonEncode(ids(next)) == jsonEncode(ids(again)),
      'Same cursor stable',
    );
    check(!ids(next).any(ids(first).contains), 'No cross-page duplicate');
    check(
      jsonEncode(ids(next)) ==
          jsonEncode(
            expected.entries
                .skip(20)
                .take(20)
                .map((e) => e.item.candidate.id)
                .toList(),
          ),
      'Second page preserves seeded mixed order',
    );
    final seen = <String>{...ids(first), ...ids(next)};
    var continuation = next['nextCursor'] as String?, pageCount = 2;
    final allocations = <Map<String, Object?>>[];
    while (continuation != null) {
      final page = await service.forYou(viewer, 20, continuation),
          pageIds = ids(page);
      check(!pageIds.any(seen.contains), 'All appended pages unique');
      final expectedPage = expected.entries
          .skip(pageCount * 20)
          .take(20)
          .toList();
      check(
        jsonEncode(pageIds) ==
            jsonEncode(expectedPage.map((e) => e.item.candidate.id).toList()),
        'Every page matches frozen distribution',
      );
      final randomCount = expectedPage.where((e) => e.isRandom).length;
      check(
        randomCount >=
            const FeedDistributionPolicy().randomSlots(pageIds.length),
        'Every page including final tail meets 40%',
      );
      allocations.add({'returned': pageIds.length, 'random': randomCount});
      seen.addAll(pageIds);
      pageCount++;
      continuation = page['nextCursor'] as String?;
    }
    check(
      seen.length == 208,
      'Authorized catalogue served once; private author excluded',
    );
    final refresh = await service.forYou(viewer, 20, null),
        refreshCursor = cursor(refresh['nextCursor'] as String);
    check(
      refreshCursor['seed'] != c['seed'] &&
          jsonEncode(ids(refresh)) != jsonEncode(ids(first)),
      'Refresh regenerates random draw',
    );
    await stale(firstCursor, limit: 7);
    final legacy = base64Url
        .encode(
          utf8.encode(
            jsonEncode({
              'asOfMs': c['asOfMs'],
              'afterId': c['afterId'],
              'snapshotKey': c['snapshotKey'],
            }),
          ),
        )
        .replaceAll('=', '');
    await stale(legacy);
    final changed = {...c, 'seed': '11111111111111111111111111111111'};
    await stale(
      base64Url.encode(utf8.encode(jsonEncode(changed))).replaceAll('=', ''),
    );
    const seed = '22222222222222222222222222222222';
    final before = randomIds(await retrieve(seed));
    await db.query(
      r"INSERT INTO user_preference_control(user_id,taxonomy_version,dimension,label_id,control) VALUES($1,'ionic-taxonomy-v1','topic','topic.design','more')",
      parameters: [viewer],
    );
    check(
      jsonEncode(before) == jsonEncode(randomIds(await retrieve(seed))),
      'Positive interest does not change random draw',
    );
    final controlled = id(1120);
    await db.query(
      r"INSERT INTO content_label(content_id,taxonomy_version,dimension,label_id,confidence,source) VALUES($1,'ionic-taxonomy-v1','topic','topic.sports',1,'rule')",
      parameters: [controlled],
    );
    await db.query(
      r"INSERT INTO user_preference_control(user_id,taxonomy_version,dimension,label_id,control) VALUES($1,'ionic-taxonomy-v1','topic','topic.sports','less')",
      parameters: [viewer],
    );
    check(
      randomIds(await retrieve(seed)).last == controlled,
      'Explicit topic less deferred behind alternatives',
    );
    await service.hide(viewer, id(1121));
    await db.query(
      r'INSERT INTO account_mute(muter_id,muted_id) VALUES($1,$2)',
      parameters: [viewer, users[3]],
    );
    await db.query(
      r'INSERT INTO account_block(blocker_id,blocked_id) VALUES($1,$2)',
      parameters: [users[4], viewer],
    );
    final filtered = await retrieve(seed);
    check(
      filtered.every(
        (r) =>
            r['id'] != id(1121) &&
            r['author_id'] != users[3] &&
            r['author_id'] != users[4] &&
            r['author_id'] != users.last,
      ),
      'Both candidate lanes retain hide/mute/reverse-block/private gates',
    );
    final small = await retrieve(seed, limit: 12);
    final randomAuthors = small
        .where((r) => r['random_position'] != null)
        .map((r) => r['author_id'])
        .toSet();
    check(
      randomAuthors.length >= 9,
      'Random pool resists prolific followed author',
    );
    const testToken = 'synthetic-v7-session-only-0000000000000000000';
    await db.query(
      r"INSERT INTO user_session(token_hash,user_id,expires_at) VALUES($1,$2,now()+interval '1 hour')",
      parameters: [sha256.convert(utf8.encode(testToken)).toString(), viewer],
    );
    final app = createApp(database: db, allowedOrigins: {'http://localhost'});
    final response = await app(
      Request(
        'GET',
        Uri.parse('http://localhost/api/v1/feed/for-you?limit=20'),
        headers: {'cookie': 'ionic_session=$testToken'},
      ),
    );
    check(
      response.statusCode == 200 &&
          response.headers['cache-control'] == 'no-store',
      'Authenticated feed HTTP response never cached',
    );
    final body =
        jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    check(
      (body['items'] as List).every((p) => !(p as Map).containsKey('isRandom')),
      'HTTP response keeps attribution internal',
    );
    final unsigned = await app(
      Request('GET', Uri.parse('http://localhost/api/v1/feed/for-you')),
    );
    check(unsigned.statusCode == 401, 'Random feed remains session-authorized');
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'rankerVersion': config.rankerVersion,
        'checks': checks,
        'pages': pageCount,
        'servedDistinct': seen.length,
        'minimumRandomShare': .4,
        'appendedPageAllocations': allocations,
        'source': 'Synthetic isolated PostgreSQL mechanics; no real-user relevance claim',
      }),
    );
  } finally {
    if (seeded) {
      await db.query(
        r'DELETE FROM app_user WHERE id=ANY($1::uuid[])',
        parameters: [users],
      );
    }
    await db.close();
  }
}
