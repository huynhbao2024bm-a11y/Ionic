import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:ionic_server/src/http/api_exception.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/posts/posts_service.dart';
import 'package:ionic_server/src/modules/profiles/profiles_service.dart';
import 'package:ionic_server/src/modules/messages/messages_service.dart';
import 'package:ionic_server/src/modules/auth/auth_service.dart';
import 'package:ionic_server/src/modules/media/attachment_storage.dart';
import 'package:ionic_server/src/modules/media/media_service.dart';
import 'package:ionic_server/src/modules/media/media_cleanup_service.dart';
import 'package:ionic_server/src/modules/trust/reports_service.dart';
import 'package:ionic_server/src/modules/trust/moderation_service.dart';
import 'package:ionic_server/src/modules/trust/text_policy.dart';
import 'package:ionic_server/src/modules/health/preview_heartbeat.dart';
import 'package:postgres/postgres.dart';

String id(int n) => 'd0000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

class MemoryStorage implements AttachmentStorage {
  final items = <String, Uint8List>{};
  @override
  Future<void> write(String key, Uint8List bytes, String mimeType) async {
    items[key] = bytes;
  }

  @override
  Future<Stream<List<int>>> read(String key, int expectedBytes) async =>
      Stream.value(items[key]!);
  @override
  Future<void> delete(String key) async {
    items.remove(key);
  }

  @override
  Future<void> verifyConfiguration() async {}
}

Future<void> main() async {
  final url = Platform.environment['DATABASE_URL'];
  if (url == null ||
      !Uri.parse(url).pathSegments.last.startsWith('ionic_core_verify_')) {
    throw StateError('Use the dedicated verification DB only.');
  }
  final db = DatabaseService.fromEnvironment(),
      a = id(1),
      b = id(2),
      m = id(3),
      outside = id(4);
  final users = [a, b, m, outside],
      posts = PostsService(db),
      profiles = ProfilesService(db),
      reports = ReportsService(db),
      moderation = ModerationService(db);
  final media = MediaService(db, storage: MemoryStorage());
  var checks = 0, seeded = false;
  void check(bool v, String label) {
    if (!v) throw StateError(label);
    checks++;
  }

  Future<void> denied(
    Future<Object?> Function() run,
    int status,
    String label,
  ) async {
    try {
      await run();
      throw StateError('Unexpected success: $label');
    } on ApiException catch (e) {
      check(e.statusCode == status, label);
    }
  }

  List<Map<String, dynamic>> items(Map<String, Object?> page) =>
      (page['items'] as List)
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();
  try {
    await MediaCleanupService(db).drainBestEffort();
    check(
      (await db.query(
        r'SELECT id FROM app_user WHERE id=ANY($1::uuid[])',
        parameters: [users],
      )).isEmpty,
      'fixture namespace unused',
    );
    for (var n = 1; n <= 4; n++) {
      await db.query(
        r"""INSERT INTO app_user(id,handle,handle_normalized,password_salt,password_hash)
        VALUES($1,$2,$2,decode(repeat('00',16),'hex'),decode(repeat('00',64),'hex'))""",
        parameters: [id(n), 'review_test123$n'],
      );
      seeded = true;
      await db.query(
        r"INSERT INTO user_profile(user_id,display_name) VALUES($1,'Synthetic reviewer verification')",
        parameters: [id(n)],
      );
    }
    for (final value in [
      'https://example.com',
      'WWW.Example.org',
      't.me/user',
      'example.vn',
      'https://localhost:4000',
      '１２７．０．０．１',
      'exa\u200bmple.com',
      '[mở](https://example.com)',
      'user@example.com',
      '例子。中国',
      'ftp://host/file',
    ]) {
      try {
        requireLinkFree(value);
        throw StateError('Link escaped policy');
      } on ApiException catch (e) {
        check(e.code == 'LINK_NOT_ALLOWED', 'recognizable link rejected');
      }
    }
    for (final value in [
      'Mèo đang ngủ. Hôm nay rất đẹp!',
      'Phiên bản 1.2 đã ra mắt',
      '3.14 là xấp xỉ pi',
      '@someone123',
      'C++ và Dart',
      'https là giao thức',
    ]) {
      requireLinkFree(value);
      check(true, 'ordinary Vietnamese and technical text allowed');
    }
    await denied(
      () => posts.create(a, {'body': 'https://example.com'}),
      400,
      'post link server rejection',
    );
    await denied(
      () => profiles.updateMe(a, {'displayName': 'example.com', 'bio': ''}),
      400,
      'name link server rejection',
    );
    await denied(
      () => profiles.updateMe(a, {'displayName': 'Name', 'bio': 't.me/abc'}),
      400,
      'bio link server rejection',
    );
    await denied(
      () => AuthService(db).register({
        'handle': 'new_link123',
        'displayName': 'example.com',
        'password': 'SafeSynthetic123!',
      }),
      400,
      'signup name link rejection',
    );
    final bytes = img.encodeJpg(img.Image(width: 8, height: 8));
    Future<String> upload() async =>
        ' ${(await media.upload(a, Stream.value(bytes), {'x-ionic-media-type': 'image', 'content-length': '${bytes.length}'}))['id']}'
            .trim();
    final asset = await upload(), unreportedAsset = await upload();
    final post = await posts.create(a, {
          'body': 'Private synthetic original',
          'attachmentIds': [asset],
        }),
        postId = post['id'] as String;
    final second = await posts.create(a, {
          'body': 'Unreported private original',
          'attachmentIds': [unreportedAsset],
        }),
        secondId = second['id'] as String;
    await profiles.follow(b, 'review_test1231');
    await db.query(
      r"UPDATE user_profile SET visibility='private' WHERE user_id=$1",
      parameters: [a],
    );
    check(
      items(await posts.readVisible(null, [postId])).isEmpty,
      'guest private detail denied',
    );
    check(
      items(await posts.readVisible(a, [postId])).length == 1,
      'owner private detail',
    );
    check(
      items(await posts.readVisible(b, [postId])).length == 1,
      'follower private detail',
    );
    await denied(
      () => posts.readVisible(b, List.filled(51, postId)),
      400,
      'sync bounded',
    );
    await denied(
      () => posts.readVisible(b, ['invalid']),
      400,
      'sync UUID validation',
    );
    await denied(
      () => posts.editOwn(b, postId, {'body': 'Unauthorized change'}),
      404,
      'other-account edit denied',
    );
    await posts.deleteOwn(b, postId);
    check(
      items(await posts.readVisible(a, [postId])).length == 1,
      'other-account delete changes nothing',
    );
    await posts.editOwn(a, postId, {'body': 'Edited by author'});
    check(
      items(await posts.readVisible(b, [postId])).single['body'] ==
          'Edited by author',
      'detail and batch see persisted edit',
    );
    await denied(
      () => posts.editOwn(a, postId, {'body': 'link example.com'}),
      400,
      'edit link rejection',
    );
    await denied(
      () => posts.addReply(b, postId, {'body': 't.me/abc'}),
      400,
      'reply link rejection',
    );
    final reply = await posts.addReply(a, postId, {'body': 'Reported reply'}),
        replyId = reply['id'] as String;
    final anotherReply = await posts.addReply(b, postId, {
          'body': 'Follower reply',
        }),
        anotherId = anotherReply['id'] as String;
    check(
      items(await posts.listReplies(b, postId, 50, null, ids: [replyId]))
              .single['id'] ==
          replyId,
      'reply batch exact IDs',
    );
    await denied(
      () => reports.create(a, {'contentId': postId, 'reason': 'spam'}),
      404,
      'no self report',
    );
    await denied(
      () => reports.create(outside, {'contentId': postId, 'reason': 'spam'}),
      404,
      'private report ACL',
    );
    await denied(
      () => reports.create(b, {
        'contentId': postId,
        'reason': 'spam',
        'details': 'example.com',
      }),
      400,
      'report text links rejected',
    );
    check(
      !await moderation.isReviewer(m),
      'handle or identity does not imply reviewer',
    );
    await denied(
      () => moderation.queue(m, null),
      403,
      'queue requires independent permission',
    );
    await db.query(
      r'INSERT INTO moderation_reviewer(user_id) VALUES($1)',
      parameters: [m],
    );
    check(await moderation.isReviewer(m), 'operator provisioned membership');
    await denied(
      () => media.read(m, asset),
      404,
      'reviewer cannot browse unreported private media',
    );
    final report = await reports.create(b, {
          'contentId': postId,
          'reason': 'spam',
        }),
        reportId = report['id'] as String;
    check(
      (await reports.create(b, {
            'contentId': postId,
            'reason': 'spam',
          }))['id'] ==
          reportId,
      'report retry deduplicated',
    );
    check(
      (await media.read(m, asset)).byteSize > 0,
      'reviewer reads exact reported media',
    );
    await denied(
      () => media.read(outside, asset),
      404,
      'normal user denied reported private media',
    );
    await denied(
      () => media.read(m, unreportedAsset),
      404,
      'reviewer unrelated private media denied',
    );
    check(
      items(await posts.readVisible(m, [postId, secondId])).isEmpty,
      'reviewer cannot browse private profiles',
    );
    final replyReport = await reports.create(b, {
      'contentId': postId,
      'replyId': replyId,
      'reason': 'harassment',
    });
    check(
      replyReport['id'] != reportId,
      'post and reply reports independently persisted',
    );
    await reports.create(a, {
      'contentId': postId,
      'replyId': anotherId,
      'reason': 'other',
    });
    check(
      items(await moderation.queue(m, null)).length == 3,
      'queue includes exact reported targets',
    );
    await denied(
      () => moderation.resolve(outside, reportId, {
        'action': 'remove',
        'reason': 'No permission',
      }),
      403,
      'unprivileged takedown denied',
    );
    await denied(
      () => moderation.resolve(m, reportId, {'action': 'remove', 'reason': ''}),
      400,
      'decision requires reason',
    );
    await denied(
      () => moderation.resolve(m, reportId, {
        'action': 'remove',
        'reason': 'example.com',
      }),
      400,
      'decision link rejected',
    );
    await moderation.resolve(m, replyReport['id'] as String, {
      'action': 'remove',
      'reason': 'Verified synthetic violation',
    });
    check(
      !items(await posts.listReplies(b, postId, 50, null))
          .any((r) => r['id'] == replyId),
      'removed reply gone from scroll and sync',
    );
    check(
      items(await posts.readVisible(b, [postId])).single['replyCount'] == 1,
      'reply count synchronized after moderation',
    );
    await moderation.resolve(m, reportId, {
      'action': 'remove',
      'reason': 'Verified synthetic violation',
    });
    await moderation.resolve(m, reportId, {
      'action': 'remove',
      'reason': 'Retry',
    });
    check(
      items(await posts.readVisible(b, [postId])).isEmpty,
      'removed post denied detail and sync',
    );
    await denied(
      () => posts.listReplies(b, postId, 20, null),
      404,
      'removed parent denies comments',
    );
    await denied(
      () => media.read(m, asset),
      404,
      'takedown revokes attachment even for reviewer',
    );
    check(
      (await db.query(
            r'SELECT count(*) FROM moderation_audit WHERE content_id=$1',
            parameters: [postId],
          )).first.first ==
          2,
      'retry adds no duplicate moderation audit',
    );
    final c = await MessagesService(db)
        .startConversation(b, {'handle': 'review_test1234'});
    await denied(
      () => MessagesService(db).sendMessage(
        b,
        (c['conversation'] as Map)['id'] as String,
        {'body': 'example.com'},
      ),
      400,
      'message link rejected',
    );
    // Public guest reading and controls refresh.
    await db.query(
      r"UPDATE user_profile SET visibility='public' WHERE user_id=$1",
      parameters: [a],
    );
    check(
      items(await posts.readVisible(null, [secondId])).length == 1,
      'guest public detail',
    );
    check(
      items(await posts.listReplies(null, secondId, 20, null)).isEmpty,
      'guest public comments',
    );
    await profiles.mute(b, 'review_test1231');
    check(
      items(await posts.readVisible(b, [secondId], feedControls: true)).isEmpty,
      'feed sync honors mute',
    );
    check(
      items(await posts.readVisible(b, [secondId])).length == 1,
      'direct read separate from mute',
    );
    await profiles.block(b, 'review_test1231');
    check(
      items(await posts.readVisible(b, [secondId])).isEmpty,
      'block revokes detail',
    );
    await db.query(
      r"UPDATE moderation_audit SET created_at=now()-interval '31 days' WHERE content_id=$1",
      parameters: [postId],
    );
    await moderation.cleanupExpired();
    check(
      (await db.query(
            r'SELECT count(*) FROM moderation_audit WHERE content_id=$1',
            parameters: [postId],
          )).first.first ==
          0,
      'audit bounded retention',
    );
    await posts.deleteOwn(a, secondId);
    check(
      items(await posts.readVisible(a, [secondId])).isEmpty,
      'owner deletion persisted',
    );
    final heartbeat = PreviewHeartbeatService(db);
    check(
      (await db.query(
            "SELECT owner_id FROM reserved_handle WHERE handle='admin'",
          )).first.first ==
          null,
      'test reservation has no existing owner',
    );
    await db.query(
      "UPDATE reserved_handle SET owner_id=\$1 WHERE handle='admin'",
      parameters: [a],
    );
    await db.query(
      r'UPDATE preview_heartbeat_account SET user_id=$1 WHERE slot=1',
      parameters: [a],
    );
    check(
      (await heartbeat.claim(a))['enabled'] == true,
      'fixed owner heartbeat allowed',
    );
    final candidates = [b, m, outside];
    final claims = await Future.wait(candidates.map((u) => heartbeat.claim(u)));
    check(
      claims.where((r) => r['enabled'] == true).length == 1,
      'concurrent secondary claims allocate exactly one slot',
    );
    final winner = claims.indexWhere((r) => r['enabled'] == true),
        winnerId = candidates[winner],
        token = claims[winner]['leaseToken'] as String;
    await heartbeat.ping(a);
    await heartbeat.ping(winnerId, leaseToken: token);
    check(true, 'owner and one leased sender work without synthetic events');
    await denied(
      () => heartbeat.ping(candidates[(winner + 1) % 3]),
      403,
      'third account cannot heartbeat',
    );
    await denied(
      () => heartbeat.ping(winnerId, leaseToken: 'forged'),
      403,
      'lease token required',
    );
    check(
      (await heartbeat.claim(winnerId))['enabled'] == false,
      'another device cannot steal active same-account lease',
    );
    final renewed = await heartbeat.claim(winnerId, previousToken: token);
    check(renewed['enabled'] == true, 'matching instance can renew lease');
    final nextToken = renewed['leaseToken'] as String;
    await denied(
      () => heartbeat.ping(winnerId, leaseToken: token),
      403,
      'rotated token revoked',
    );
    await heartbeat.release(candidates[(winner + 1) % 3], nextToken);
    check(
      await heartbeat.allowed(winnerId),
      'unrelated account cannot release lease',
    );
    await heartbeat.release(winnerId, nextToken);
    check(
      !await heartbeat.allowed(winnerId),
      'normal close releases secondary slot',
    );
    final later = await heartbeat.claim(candidates[(winner + 1) % 3]);
    check(later['enabled'] == true, 'next active opener receives vacant slot');
    await db.query(
      "UPDATE preview_heartbeat_account SET lease_expires_at=now()-interval '1 minute' WHERE slot=2",
    );
    check(
      (await heartbeat.claim(winnerId))['enabled'] == true,
      'powered-off stale lease expires',
    );
    try {
      await db.query('INSERT INTO preview_heartbeat_account(slot) VALUES(3)');
      throw StateError('Third slot admitted');
    } on ServerException catch (e) {
      check(e.code == '23514', 'database forbids a third slot');
    }
    check(
      (await db.query(
            r'SELECT count(*) FROM recommendation_delivery_receipt WHERE user_id=ANY($1::uuid[])',
            parameters: [users],
          )).first.first ==
          0,
      'heartbeats create no recommendation receipts',
    );

    final image = img.encodeJpg(img.Image(width: 8, height: 8));
    for (final budget in [
      (account: 1, total: 700 * 1024 * 1024),
      (account: 64 * 1024 * 1024, total: 1),
    ]) {
      await denied(
        () =>
            MediaService(
              db,
              storage: MemoryStorage(),
              accountBudgetBytes: budget.account,
              totalBudgetBytes: budget.total,
            ).upload(a, Stream.value(image), {
              'x-ionic-media-type': 'image',
              'content-length': '${image.length}',
            }),
        413,
        'storage budget blocks before object upload',
      );
    }
    // Real queue pagination, dismissal and logical expiry under independent permission.
    for (var n = 100; n < 131; n++) {
      await db.query(
        r"INSERT INTO content(id,author_id,body) VALUES($1,$2,$3)",
        parameters: [id(n), a, 'Synthetic queue $n'],
      );
      await reports.create(outside, {'contentId': id(n), 'reason': 'other'});
    }
    final firstQueue = await moderation.queue(m, null),
        secondQueue = await moderation.queue(
          m,
          firstQueue['nextCursor'] as String,
        );
    check(
      items(firstQueue).length == 30 && items(secondQueue).length == 1,
      'review queue paginates thirty and one',
    );
    check(
      {
            ...items(firstQueue).map((r) => r['id']),
            ...items(secondQueue).map((r) => r['id']),
          }.length ==
          31,
      'review cursor has no duplicate targets',
    );
    await denied(
      () => moderation.queue(m, 'bad_cursor'),
      400,
      'review cursor validation',
    );
    final selected = items(firstQueue).first;
    await moderation.resolve(m, selected['id'] as String, {
      'action': 'dismiss',
      'reason': 'No violation in synthetic fixture',
    });
    check(
      items(await posts.readVisible(outside, [selected['contentId']])).length ==
          1,
      'dismiss does not remove content',
    );
    final expiring = items(firstQueue)[1];
    await db.query(
      r"UPDATE content_report SET created_at=now()-interval '31 days' WHERE id=$1",
      parameters: [expiring['id']],
    );
    final freshReport = await reports.create(outside, {
      'contentId': expiring['contentId'],
      'reason': 'other',
    });
    check(
      freshReport['id'] != expiring['id'],
      'expired report does not prevent new reporting',
    );
    await db.query(
      r'DELETE FROM moderation_reviewer WHERE user_id=$1',
      parameters: [m],
    );
    await denied(
      () => moderation.queue(m, null),
      403,
      'revoked reviewer permission effective immediately',
    );
    stdout.writeln(
      jsonEncode({
        'checks': checks,
        'scope': 'Isolated PostgreSQL policy/authorization/sync/moderation; synthetic image store, not live media or native UI.',
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
