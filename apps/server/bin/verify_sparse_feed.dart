import 'dart:convert';
import 'dart:io';

import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/posts/posts_service.dart';
import 'package:ionic_server/src/modules/profiles/profiles_service.dart';
import 'package:ionic_server/src/modules/recommendation/recommendation_service.dart';

String id(int n) => 'e0000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';
Future<void> main() async {
  final url = Platform.environment['DATABASE_URL'];
  if (url == null ||
      !Uri.parse(url).pathSegments.last
          .startsWith('ionic_recommendation_verify_') ||
      Platform.environment['RECOMMENDATION_ADAPTIVE_ENABLED'] != 'true') {
    throw StateError('Use a dedicated empty adaptive verification DB.');
  }
  final db = DatabaseService.fromEnvironment();
  // One pool per runner; use the same application database for all modules.
  final serving = RecommendationService(db),
      posts = PostsService(db),
      profiles = ProfilesService(db),
      users = [id(1), id(2), id(3)];
  var checks = 0, seeded = false;
  void check(bool value, String label) {
    if (!value) throw StateError(label);
    checks++;
  }

  List<Map<String, dynamic>> items(Map<String, Object?> page) =>
      (page['items'] as List)
          .map((i) => Map<String, dynamic>.from(i as Map))
          .toList();
  Future<void> observe(List<Map<String, dynamic>> page) async {
    for (final item in page.where((i) => i['authorId'] != users[0])) {
      await db.query(
        r"UPDATE recommendation_delivery_receipt SET issued_at=now()-interval '2 minutes', expires_at=now()+interval '6 days' WHERE id=$1",
        parameters: [item['receiptId']],
      );
      await serving.recordAttention(users[0], {
        'items': [
          {'receiptId': item['receiptId'], 'band': 'long'},
        ],
      });
    }
  }

  Future<void> quota(List<Map<String, dynamic>> page) async {
    final receipt = page.firstWhere(
      (i) => i['receiptId'] is String,
    )['receiptId'];
    final rows = await db.query(
      r'''SELECT count(*) FILTER(WHERE is_random) FROM recommendation_delivery_receipt
          WHERE plan_id=(SELECT plan_id FROM recommendation_delivery_receipt WHERE id=$1)
            AND content_id=ANY($2::uuid[])''',
      parameters: [receipt, page.map((i) => i['id'] as String).toList()],
    );
    check(
      (rows.first.first as int) >= (page.length * .4).ceil(),
      'random floor applies to resurfaced pages',
    );
  }

  try {
    check(
      (await db.query('SELECT count(*) FROM app_user')).first.first == 0,
      'isolated DB is empty',
    );
    await db.transaction((tx) async {
      for (var i = 0; i < users.length; i++) {
        await tx.execute(
          r"INSERT INTO app_user(id,handle,handle_normalized,password_salt,password_hash) VALUES($1,$2,$2,decode(repeat('00',16),'hex'),decode(repeat('00',64),'hex'))",
          parameters: [users[i], 'sparse_${i.toString().padLeft(3, '0')}'],
        );
        await tx.execute(
          r'INSERT INTO user_profile(user_id,display_name) VALUES($1,$2)',
          parameters: [users[i], 'Fictional reader $i'],
        );
      }
    });
    seeded = true;
    const bodies = [
      'Mèo ngủ trên ghế',
      'Bữa cơm nấu xong',
      'Chuyến đi biển xanh',
      'Tranh màu buổi tối',
      'Tiếng đàn ngày mưa',
      'Đọc sách sáng nay',
      'Bóng đá cuối tuần',
      'Trồng cây trên sân',
      'Ảnh phố lúc chiều',
      'Bánh mì vừa nướng',
      'Phần mềm vẽ hình',
      'Học tiếng Nhật mới',
      'Chạy bộ ven sông',
      'Cà phê rất thơm',
      'Tập yoga ngoài trời',
    ];
    final otherIds = <String>[];
    for (var i = 0; i < 6; i++) {
      final result = await posts.create(i < 3 ? users[0] : users[1], {
        'body': bodies[i],
      });
      if (i >= 3) otherIds.add(result['id'] as String);
    }
    final baseline = items(await serving.forYou(users[0], 20, null));
    check(baseline.length == 6, 'six real posts, no invented fill');
    await observe(baseline);
    final repeated = items(await serving.forYou(users[0], 20, null));
    check(
      repeated.length == 6 &&
          repeated.where((i) => i['authorId'] != users[0]).length == 3,
      'watched others resurface instead of only self posts',
    );
    await quota(repeated);
    await db.query(
      r"UPDATE content SET created_at=now()-interval '1 year' WHERE id=ANY($1::uuid[])",
      parameters: [otherIds],
    );
    check(
      items(await serving.forYou(users[0], 20, null)).length == 6,
      'old age does not empty a sparse feed',
    );
    for (var i = 6; i < bodies.length; i++) {
      final p = await posts.create(users[1], {'body': bodies[i]});
      otherIds.add(p['id'] as String);
    }
    final unseen = items(await serving.forYou(users[0], 20, null));
    check(
      unseen.length >= 10 &&
          !unseen.any((i) => otherIds.take(3).contains(i['id'])),
      'unseen supply wins when sufficient',
    );
    await observe(unseen);
    final full = items(await serving.forYou(users[0], 20, null));
    check(
      full.length == 15 && full.map((i) => i['id']).toSet().length == 15,
      'minimum ten with enough distinct eligible posts',
    );
    await quota(full);
    final first = await serving.forYou(users[0], 10, null),
        firstItems = items(first);
    check(
      firstItems.length == 10 && first['nextCursor'] is String,
      'first ten-item page',
    );
    final last = items(
      await serving.forYou(users[0], 10, first['nextCursor'] as String),
    );
    check(
      last.length == 5 &&
          [...firstItems, ...last].map((i) => i['id']).toSet().length == 15,
      'no duplicate IDs across pages in one plan',
    );
    final cached = items(
      await serving.forYou(users[0], 10, first['nextCursor'] as String),
    );
    check(
      jsonEncode(cached.map((i) => i['id']).toList()) ==
          jsonEncode(last.map((i) => i['id']).toList()),
      'cursor retry order remains stable',
    );
    await serving.hide(users[0], otherIds.first);
    await profiles.mute(users[0], 'sparse_001');
    await posts.create(users[2], {'body': 'Ảnh chim bên hồ'});
    await profiles.block(users[0], 'sparse_002');
    final controlled = items(await serving.forYou(users[0], 20, null));
    check(
      controlled.length == 3 &&
          controlled.every((i) => i['authorId'] == users[0]),
      'minimum never bypasses mute/block/hide',
    );
    await profiles.unmute(users[0], 'sparse_001');
    final restored = items(await serving.forYou(users[0], 20, null));
    check(
      restored.length >= 10 &&
          !restored.any(
            (i) => i['id'] == otherIds.first || i['authorId'] == users[2],
          ),
      'unmute restores supply while hide/block stay hard',
    );
    await db.query(
      r"UPDATE user_profile SET visibility='private' WHERE user_id=$1",
      parameters: [users[1]],
    );
    check(
      items(await serving.forYou(users[0], 20, null))
          .every((i) => i['authorId'] == users[0]),
      'resurfacing never bypasses profile privacy',
    );
    await db.query(
      r"UPDATE user_profile SET visibility='private' WHERE user_id=$1",
      parameters: [users[0]],
    );
    check(
      items(await serving.forYou(users[0], 20, null)).length == 3,
      'private-profile owner retains own posts',
    );
    check(
      !items(await serving.forYou(users[1], 20, null))
          .any((i) => i['authorId'] == users[0]),
      'own-private exception never grants access to another viewer',
    );
    stdout.writeln(
      jsonEncode({
        'checks': checks,
        'smallCatalogue': 6,
        'largerCatalogue': 15,
        'kind': 'Isolated sparse-feed mechanics, not human relevance.',
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
