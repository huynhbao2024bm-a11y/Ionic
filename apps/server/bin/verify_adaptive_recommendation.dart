import 'dart:convert';
import 'dart:io';

import 'package:ionic_server/src/http/api_exception.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/recommendation/adaptive_feedback.dart';
import 'package:ionic_server/src/modules/recommendation/adaptive_policy.dart';
import 'package:ionic_server/src/modules/recommendation/preference_evidence.dart';
import 'package:ionic_server/src/modules/recommendation/recommendation_service.dart';
import 'package:ionic_server/src/modules/posts/posts_service.dart';

String id(int n) => 'd0000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

Future<void> main() async {
  final url = Platform.environment['DATABASE_URL'];
  if (url == null ||
      !Uri.parse(url).pathSegments.last
          .startsWith('ionic_recommendation_verify_') ||
      Platform.environment['RECOMMENDATION_ADAPTIVE_ENABLED'] != 'true') {
    throw StateError('Use dedicated empty DB and enable adaptive mode.');
  }
  final db = DatabaseService.fromEnvironment(), viewer = id(1);
  final feed = RecommendationService(db),
      feedback = AdaptiveFeedbackService(db),
      posts = PostsService(db);
  final users = [for (var i = 1; i <= 30; i++) id(i)];
  var seeded = false, checks = 0;
  void check(bool value, String label) {
    if (!value) throw StateError(label);
    checks++;
  }

  List<Map<String, dynamic>> items(Map<String, Object?> page) =>
      (page['items'] as List)
          .map((p) => Map<String, dynamic>.from(p as Map))
          .toList();
  Future<Map<String, Object?>> observe(
    String user,
    String receipt,
    String band,
  ) => feed.recordAttention(user, {
    'items': [
      {'receiptId': receipt, 'band': band},
    ],
  });
  Future<int> count(String table) async =>
      (await db.query(
            'SELECT count(*) FROM $table WHERE user_id=\$1',
            parameters: [viewer],
          )).first.first
          as int;
  try {
    check(
      (await db.query('SELECT count(*) FROM app_user')).first.first == 0,
      'Dedicated DB empty',
    );
    await db.transaction((tx) async {
      for (var i = 0; i < users.length; i++) {
        await tx.execute(
          r'''INSERT INTO app_user(id,handle,handle_normalized,password_salt,password_hash)
          VALUES($1,$2,$2,decode(repeat('00',16),'hex'),decode(repeat('00',64),'hex'))''',
          parameters: [users[i], 'v8_fixture_${i.toString().padLeft(3, '0')}'],
        );
        await tx.execute(
          r'INSERT INTO user_profile(user_id,display_name) VALUES($1,$2)',
          parameters: [users[i], 'Synthetic $i'],
        );
      }
      for (var i = 0; i < 160; i++) {
        await tx.execute(
          r"INSERT INTO content(id,author_id,body,created_at) VALUES($1,$2,$3,now()-interval '1 hour')",
          parameters: [id(1000 + i), users[1 + i % 12], 'Synthetic text $i'],
        );
        await tx.execute(
          r'''INSERT INTO content_label(content_id,taxonomy_version,dimension,label_id,confidence,source)
          VALUES($1,'ionic-taxonomy-v1','format','format.text',1,'rule'),($1,'ionic-taxonomy-v1','topic',$2,.8,'rule')''',
          parameters: [
            id(1000 + i),
            [
              'topic.pets',
              'topic.design',
              'topic.science',
              'topic.books',
              'topic.food',
              'topic.music',
              'topic.travel',
              'topic.learning',
              'topic.sports',
              'topic.crafts',
            ][i % 10],
          ],
        );
      }
    });
    seeded = true;
    final first = await feed.forYou(viewer, 10, null), one = items(first);
    check(
      one.length == 10 && one.every((p) => p['receiptId'] is String),
      'Issued receipts for signed-in eligible non-author items',
    );
    check(
      await count('recommendation_delivery_receipt') == 10 &&
          await count('recommendation_attention_summary') == 0,
      'Delivery alone never becomes reading',
    );
    final receipt = one.first['receiptId'] as String,
        postId = one.first['id'] as String;
    check(
      (await observe(viewer, receipt, 'long'))['accepted'] == 0,
      'Wall clock prevents immediate inflated dwell',
    );
    await db.query(
      r"UPDATE recommendation_delivery_receipt SET issued_at=now()-interval '1 minute',expires_at=now()+interval '6 days' WHERE id=$1",
      parameters: [receipt],
    );
    check(
      (await observe(users[20], receipt, 'long'))['accepted'] == 0,
      'Receipt owner enforcement',
    );
    check(
      (await observe(viewer, receipt, 'long'))['accepted'] == 1,
      'Qualified coarse attention accepted',
    );
    check(
      (await observe(viewer, receipt, 'long'))['accepted'] == 0,
      'Retry idempotent',
    );
    check(
      (await observe(viewer, receipt, 'short'))['accepted'] == 0,
      'Cannot downgrade monotonic summary',
    );
    check(
      await count('recommendation_attention_summary') == 1,
      'One derived daily contribution',
    );
    final cursor = first['nextCursor'] as String;
    final second = await feed.forYou(viewer, 10, cursor),
        secondAgain = await feed.forYou(viewer, 10, cursor);
    check(
      jsonEncode(second) == jsonEncode(secondAgain),
      'Append retries stable despite accepted feedback',
    );
    check(
      !items(second).any((p) => one.any((a) => a['id'] == p['id'])),
      'Adaptive append never reissues earlier plan IDs',
    );
    final edited = items(second).last;
    await db.query(
      r'UPDATE content SET updated_at=clock_timestamp() WHERE id=$1',
      parameters: [edited['id']],
    );
    try {
      await feed.forYou(viewer, 10, cursor);
      throw StateError('Expected cached-page rejection');
    } on ApiException catch (e) {
      check(
        e.code == 'FEED_CURSOR_STALE',
        'Cached page reauthorized after source edit',
      );
    }
    final receiptIds = items(second).map((p) => p['receiptId']).toList();
    final flags = await db.query(
      r'SELECT count(*)::int,count(*) FILTER(WHERE is_random)::int FROM recommendation_delivery_receipt WHERE id=ANY($1::uuid[])',
      parameters: [receiptIds],
    );
    check(
      (flags.first[1] as int) * 100 >= (flags.first[0] as int) * 40,
      'Adaptive page retains random floor',
    );
    final fresh = await feed.forYou(viewer, 10, null);
    check(
      await count('recommendation_feed_plan') <= 4,
      'Feed plan cap holds immediately after issuing a page',
    );
    check(
      !items(fresh).any((p) => p['id'] == postId),
      'Qualified seen item suppressed across refresh',
    );
    final context = await db.transaction((tx) async {
      await lockPreference(tx, viewer);
      return feedback.loadContext(tx, viewer);
    });
    check(
      context.topicInterest.isNotEmpty && context.interest.evidence > 0,
      'Reader pacing receives accepted evidence',
    );
    await posts.setSaved(viewer, postId, true);
    await db.query(
      r'INSERT INTO account_mute(muter_id,muted_id) VALUES($1,$2)',
      parameters: [viewer, one.first['authorId']],
    );
    final mutedContext = await db.transaction((tx) async {
      await lockPreference(tx, viewer);
      return feedback.loadContext(tx, viewer);
    });
    check(
      mutedContext.topicInterest.isEmpty && mutedContext.interest.evidence == 0,
      'Muted sources do not inflate pacing or exploration confidence',
    );
    await db.query(
      r'DELETE FROM account_mute WHERE muter_id=$1',
      parameters: [viewer],
    );
    await posts.setSaved(viewer, postId, false);
    await feed.updateSettings(viewer, {'paused': true});
    check(
      (await observe(
            viewer,
            items(second).first['receiptId'] as String,
            'read',
          ))['status'] ==
          'paused',
      'Pause blocks ingestion',
    );
    final paused = await feed.forYou(viewer, 10, null);
    check(
      items(paused).every((p) => !p.containsKey('receiptId')),
      'Pause omits collection tokens',
    );
    await feed.updateSettings(viewer, {'paused': false});
    check(
      (await observe(viewer, receipt, 'long'))['accepted'] == 0,
      'Resume never replays old paused/inactivated receipt',
    );
    final own = await feed.forYou(users[1], 10, null);
    check(
      items(own)
          .where((p) => p['authorId'] == users[1])
          .every((p) => !p.containsKey('receiptId')),
      'Self-reading never creates item evaluation tokens',
    );
    final nextReceipt = items(fresh).first['receiptId'] as String,
        nextPost = items(fresh).first['id'] as String;
    await db.query(
      r'UPDATE content SET updated_at=clock_timestamp() WHERE id=$1',
      parameters: [nextPost],
    );
    check(
      (await observe(viewer, nextReceipt, 'long'))['accepted'] == 0,
      'Source edits invalidate attention binding',
    );
    final live = await feed.forYou(viewer, 10, null),
        liveItem = items(live).first,
        liveReceipt = items(live).first['receiptId'] as String;
    await db.query(
      r'INSERT INTO account_block(blocker_id,blocked_id) VALUES($1,$2)',
      parameters: [liveItem['authorId'], viewer],
    );
    check(
      (await observe(viewer, liveReceipt, 'read'))['accepted'] == 0,
      'Reverse block stops evidence',
    );
    await db.query(
      r'DELETE FROM account_block WHERE blocked_id=$1',
      parameters: [viewer],
    );
    await posts.setSaved(viewer, postId, true);
    await feed.reset(viewer);
    for (final table in [
      'recommendation_delivery_receipt',
      'recommendation_attention_summary',
      'recommendation_feed_plan',
      'recommendation_audience_grant',
    ]) {
      check(await count(table) == 0, 'Reset clears $table');
    }
    check(
      (await db.query(
            r'SELECT count(*) FROM content_bookmark WHERE user_id=$1',
            parameters: [viewer],
          )).first.first ==
          1,
      'Reset retains authoritative saved item',
    );
    // Exercise strict unique-audience allocation under concurrent attempts.
    final target = id(1159);
    await db.query(
      r'DELETE FROM recommendation_audience_grant WHERE content_id=$1',
      parameters: [target],
    );
    await db.query(
      r'DELETE FROM recommendation_post_distribution WHERE content_id=$1',
      parameters: [target],
    );
    const tiny = AdaptivePolicy(
      audienceBase: 3,
      audienceMinimum: 1,
      audienceMaximum: 12,
    );
    final attempts = await Future.wait([
      for (var i = 20; i < 28; i++)
        db.transaction((tx) async {
          await lockPreference(tx, users[i]);
          return feedback.reserveAudience(tx, users[i], [target], tiny);
        }),
    ]);
    check(
      attempts.where((e) => e.isEmpty).length == 3,
      'Concurrent audience reservations respect exact allowance',
    );
    check(
      (await db.query(
            r'SELECT issued_unique FROM recommendation_post_distribution WHERE content_id=$1',
            parameters: [target],
          )).first.first ==
          3,
      'Audience counter equals distinct grants',
    );
    final owner = await db.query(
      r'SELECT author_id FROM content WHERE id=$1',
      parameters: [target],
    );
    await db.transaction((tx) async {
      await lockPreference(tx, '${owner.first.first}');
      await feedback.reserveAudience(tx, '${owner.first.first}', [
        target,
      ], tiny);
    });
    check(
      (await db.query(
            r'SELECT issued_unique FROM recommendation_post_distribution WHERE content_id=$1',
            parameters: [target],
          )).first.first ==
          3,
      'Author does not consume audience grants',
    );
    // Derived source provenance permits source deletion to withdraw evidence.
    final measured = await feed.forYou(viewer, 10, null),
        // Do not randomly delete the independent audience fixture used below.
        m = items(measured).firstWhere((item) => item['id'] != id(1158));
    await db.query(
      r"UPDATE recommendation_delivery_receipt SET issued_at=now()-interval '1 minute',expires_at=now()+interval '6 days' WHERE id=$1",
      parameters: [m['receiptId']],
    );
    await observe(viewer, m['receiptId'] as String, 'read');
    await db.query(r'DELETE FROM content WHERE id=$1', parameters: [m['id']]);
    check(
      (await db.query(
            r'SELECT count(*) FROM recommendation_attention_summary WHERE content_id=$1',
            parameters: [m['id']],
          )).first.first ==
          0,
      'Content deletion cascades derived reader evidence',
    );
    try {
      await feed.recordAttention(viewer, {
        'items': [
          {'receiptId': '------------------------------------', 'band': 'long'},
        ],
      });
      throw StateError('Expected malformed rejection');
    } on ApiException catch (e) {
      check(e.statusCode == 400, 'Malformed receipt rejected at boundary');
    }
    // Real owned receipts from independent synthetic readers affect the next
    // audience allowance, rather than only testing the pure formula.
    final strongPost = id(1158), weakPost = id(5000);
    await db.query(
      r"UPDATE content SET status='removed' WHERE id<>$1",
      parameters: [strongPost],
    );
    await db.query(
      r'UPDATE recommendation_post_distribution SET dirty=true WHERE content_id=$1',
      parameters: [strongPost],
    );
    for (var i = 15; i < 23; i++) {
      final p = await feed.forYou(users[i], 1, null), item = items(p).single;
      await db.query(
        r"UPDATE recommendation_delivery_receipt SET issued_at=now()-interval '1 minute',expires_at=now()+interval '6 days' WHERE id=$1",
        parameters: [item['receiptId']],
      );
      await observe(users[i], item['receiptId'] as String, 'long');
    }
    await feed.forYou(users[29], 1, null);
    final expanded =
        (await db.query(
              r'SELECT allowance FROM recommendation_post_distribution WHERE content_id=$1',
              parameters: [strongPost],
            )).first.first
            as int;
    check(
      expanded > const AdaptivePolicy().audienceBase,
      'Independent random-reader evidence expands actual post allowance',
    );
    await db.query(
      r"UPDATE content SET status='removed' WHERE id=$1",
      parameters: [strongPost],
    );
    await db.query(
      r"INSERT INTO content(id,author_id,body) VALUES($1,$2,'Weak sample')",
      parameters: [weakPost, users[1]],
    );
    await db.query(
      r"INSERT INTO content_label(content_id,taxonomy_version,dimension,label_id,confidence,source) VALUES($1,'ionic-taxonomy-v1','format','format.text',1,'rule')",
      parameters: [weakPost],
    );
    for (var i = 15; i < 23; i++) {
      final p = await feed.forYou(users[i], 1, null), item = items(p).single;
      await db.query(
        r"UPDATE recommendation_delivery_receipt SET issued_at=now()-interval '1 minute',expires_at=now()+interval '6 days' WHERE id=$1",
        parameters: [item['receiptId']],
      );
      await observe(users[i], item['receiptId'] as String, 'peek');
    }
    await feed.forYou(users[29], 1, null);
    final reduced =
        (await db.query(
              r'SELECT allowance FROM recommendation_post_distribution WHERE content_id=$1',
              parameters: [weakPost],
            )).first.first
            as int;
    check(
      reduced < const AdaptivePolicy().audienceBase &&
          reduced >= const AdaptivePolicy().audienceMinimum,
      'Repeated brief outcomes reduce actual allowance without permanent ban',
    );
    // Retention cleanup uses real constrained rows, not just deleted fixtures.
    await db.query(
      r'''INSERT INTO recommendation_feed_plan(id,user_id,page_size,seed,created_at,expires_at)
      VALUES($1,$2,20,repeat('0',32),now()-interval '2 days',now()-interval '1 day')''',
      parameters: [id(6000), viewer],
    );
    await db.query(
      r'''INSERT INTO recommendation_delivery_receipt
      (id,user_id,content_id,source_updated_at,delivery_sequence,text_characters,has_media,is_random,measurement_enabled,issued_at,expires_at)
      SELECT $1,$2,id,updated_at,1,12,false,true,false,now()-interval '8 days',now()-interval '1 day' FROM content WHERE id=$3''',
      parameters: [id(6001), viewer, weakPost],
    );
    await db.query(
      r'''INSERT INTO recommendation_attention_summary(user_id,content_id,summary_day,source_updated_at,reward,last_sequence,updated_at,expires_at)
      SELECT $1,id,(now()-interval '31 days')::date,updated_at,.5,1,now()-interval '31 days',now()-interval '1 day' FROM content WHERE id=$2''',
      parameters: [viewer, weakPost],
    );
    check(
      await feedback.cleanupExpired() >= 3,
      'Physical cleanup enforces raw/derived/plan expiry',
    );
    check(
      (await db.query(
            r'SELECT count(*) FROM recommendation_delivery_receipt WHERE id=$1',
            parameters: [id(6001)],
          )).first.first ==
          0,
      'Expired detail removed',
    );
    // Enforce bounded storage even if a client repeatedly refreshes/reports.
    await db.query(
      r'''INSERT INTO recommendation_delivery_receipt
      (id,user_id,content_id,source_updated_at,delivery_sequence,text_characters,has_media,is_random,measurement_enabled)
      SELECT gen_random_uuid(),$1,c.id,c.updated_at,g,12,false,true,true
      FROM content c CROSS JOIN generate_series(1,2005) g WHERE c.id=$2''',
      parameters: [viewer, weakPost],
    );
    await db.query(
      r'''INSERT INTO recommendation_attention_summary
      (user_id,content_id,summary_day,source_updated_at,reward,last_sequence)
      SELECT $1,c.id,current_date-g,c.updated_at,.5,g FROM content c CROSS JOIN generate_series(1,600) g WHERE c.id=$2
      ON CONFLICT DO NOTHING''',
      parameters: [viewer, weakPost],
    );
    await db.transaction((tx) async {
      await lockPreference(tx, viewer);
      await feedback.pruneViewer(tx, viewer);
    });
    check(
      await count('recommendation_delivery_receipt') == 2000,
      'Detail cap removes oldest rows',
    );
    check(
      await count('recommendation_attention_summary') == 512,
      'Derived cap removes oldest contributions',
    );
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'checks': checks,
        'kind': 'Isolated synthetic adaptive policy mechanics; no human relevance claim',
        'firstPageRandom': flags.first[1],
        'firstPageSize': flags.first[0],
        'readerDerivedTopics': context.topicInterest.length,
        'concurrentAudienceAllowance': 3,
        'strongActualAudienceAllowance': expanded,
        'weakActualAudienceAllowance': reduced,
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
