import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:ionic_server/src/app.dart';
import 'package:ionic_server/src/http/api_exception.dart';
import 'package:ionic_server/src/modules/auth/auth_service.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/media/media_cleanup_service.dart';
import 'package:ionic_server/src/modules/posts/posts_service.dart';
import 'package:ionic_server/src/modules/profiles/profiles_service.dart';
import 'package:shelf/shelf.dart';

Future<void> main() async {
  final url = Platform.environment['DATABASE_URL'];
  if (url == null ||
      !Uri.parse(url).pathSegments.last.startsWith('ionic_core_verify_')) {
    throw StateError('Use isolated verification DB.');
  }
  final db = DatabaseService.fromEnvironment();
  // Use one managed pool for fixture lifetime, including authentication.
  final identity = AuthService(db),
      posts = PostsService(db),
      profiles = ProfilesService(db),
      app = createApp(database: db, allowedOrigins: {});
  final users = <String>[];
  var checks = 0;
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

  Future<AuthResult> actor(String suffix) async {
    final r = await identity.register({
      'handle':
          'ct-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${suffix}123',
      'displayName': 'Người kiểm thử',
      'password': 'fixture-password-123',
    });
    users.add(r.user.id);
    return r;
  }

  Future<Map<String, dynamic>> call(
    String method,
    String path, {
    AuthResult? actor,
    Object? body,
    int status = 200,
    Uint8List? bytes,
  }) async {
    final r = await app(
      Request(
        method,
        Uri.parse('http://localhost/api/v1$path'),
        headers: {
          if (actor != null)
            'cookie': sessionCookie(actor.token).split(';').first,
          'content-type': bytes == null
              ? 'application/json'
              : 'application/octet-stream',
          if (bytes != null) 'x-ionic-media-type': 'image',
        },
        body: bytes ?? (body == null ? null : jsonEncode(body)),
      ),
    );
    final raw = await r.readAsString();
    check(
      r.statusCode == status,
      '$method $path expected $status got ${r.statusCode}: $raw',
    );
    return raw.isEmpty ? {} : jsonDecode(raw) as Map<String, dynamic>;
  }

  List<Map<String, dynamic>> items(Map<String, dynamic> page) =>
      (page['items'] as List).cast<Map<String, dynamic>>();
  try {
    for (final handle in [
      'có123',
      'co.123',
      'co+123',
      'co 123',
      'co@123',
      '１２３abc',
      'admin-123',
      'a12',
    ]) {
      await denied(
        () => identity.register({
          'handle': handle,
          'displayName': 'Test',
          'password': 'fixture-password-123',
        }),
        400,
        'invalid handle $handle',
      );
    }
    final owner = await actor('a'),
        reader = await actor('b'),
        other = await actor('c');
    check(
      (await identity.login({
            'handle': reader.user.handle,
            'password': 'fixture-password-123',
          })).user.id ==
          reader.user.id,
      'hyphen login',
    );
    check(
      ((await profiles.getProfile(reader.user.id, owner.user.handle))['profile']
              as Map<String, dynamic>)['handle'] ==
          owner.user.handle,
      'hyphen profile lookup',
    );
    final p =
        (await posts.create(owner.user.id, {
              'body': 'Bài kiểm thử bình luận',
            }))['id']
            as String;
    final p2 =
        (await posts.create(other.user.id, {'body': 'Bài khác'}))['id']
            as String;
    final root = await posts.addReply(reader.user.id, p, {
          'body': 'Bình luận gốc',
        }),
        rid = root['id'] as String;
    final child = await posts.addReply(other.user.id, p, {
          'body': 'Trả lời thứ nhất',
          'parentReplyId': rid,
        }),
        cid = child['id'] as String;
    final nested = await posts.addReply(reader.user.id, p, {
          'body': 'Trả lời tiếp',
          'parentReplyId': cid,
        }),
        nid = nested['id'] as String;
    check(
      nested['threadRootId'] == rid && nested['parentReplyId'] == cid,
      'flat bounded thread preserves immediate parent',
    );
    check(
      items(await posts.listReplies(null, p, 20, null)).length == 3,
      'legacy flat comments preserved',
    );
    final roots = items(
      await posts.listReplies(reader.user.id, p, 20, null, threaded: true),
    );
    check(
      roots.length == 1 &&
          roots.single['threadCount'] == 2 &&
          roots.single['canDelete'] == true,
      'thread roots and own delete permission',
    );
    final page = await posts.listReplies(
      reader.user.id,
      p,
      1,
      null,
      threaded: true,
      thread: rid,
    );
    check(
      items(page).length == 1 && page['nextCursor'] != null,
      'thread page bounded',
    );
    check(
      items(
            await posts.listReplies(
              reader.user.id,
              p,
              1,
              page['nextCursor'] as String,
              threaded: true,
              thread: rid,
            ),
          ).single['id'] !=
          items(page).single['id'],
      'thread cursor no duplicate',
    );
    await denied(
      () => posts.addReply(reader.user.id, p2, {
        'body': 'Cross post',
        'parentReplyId': rid,
      }),
      404,
      'parent same post',
    );
    await denied(
      () => posts.addReply(reader.user.id, p, {
        'body': 'Bad UUID',
        'parentReplyId': 'invalid',
      }),
      400,
      'parent UUID',
    );
    final retry = await posts.addReply(reader.user.id, p, {
      'body': 'Trả lời tiếp',
      'parentReplyId': cid,
      'clientPublishId': nid,
    });
    check(retry['id'] == nid, 'same parent retry idempotent');
    await denied(
      () => posts.addReply(reader.user.id, p, {
        'body': 'Trả lời tiếp',
        'parentReplyId': rid,
        'clientPublishId': nid,
      }),
      409,
      'retry parent bound',
    );
    final before = await db.query(
      r'SELECT count(*) FROM user_preference_evidence WHERE user_id=$1',
      parameters: [reader.user.id],
    );
    await Future.wait(
      List.generate(5, (_) => posts.setReplyLike(reader.user.id, p, cid, true)),
    );
    var heart = items(
      await posts.listReplies(reader.user.id, p, 20, null, ids: [cid]),
    ).single;
    check(
      heart['likeCount'] == 1 && heart['liked'] == true,
      'concurrent heart idempotent',
    );
    check(
      (await posts.setReplyLike(reader.user.id, p, cid, false))['likeCount'] ==
          0,
      'unheart',
    );
    check(
      (await posts.setReplyLike(reader.user.id, p, cid, false))['likeCount'] ==
          0,
      'repeat unheart',
    );
    check(
      (await db.query(
            r'SELECT count(*) FROM user_preference_evidence WHERE user_id=$1',
            parameters: [reader.user.id],
          )).first.first ==
          before.first.first,
      'comment hearts create no ranking evidence',
    );
    await denied(
      () => posts.setReplyLike(reader.user.id, p2, cid, true),
      404,
      'heart same post',
    );
    await call('POST', '/posts/$p/replies/$cid/like', status: 401, body: {});
    await call(
      'POST',
      '/posts/$p/replies/$cid/like',
      actor: reader,
      status: 201,
      body: {},
    );
    await call('DELETE', '/posts/$p/replies/$cid/like', actor: reader);
    await call(
      'POST',
      '/posts/$p/replies/sync',
      actor: reader,
      body: {
        'ids': [rid],
        'threaded': 'true',
      },
      status: 400,
    );
    await call('GET', '/posts/$p/replies?threaded=bad', status: 400);
    await call('GET', '/posts/$p/replies?threaded=true&thread=$rid');
    await denied(
      () => posts.deleteReply(other.user.id, p, rid),
      404,
      'unrelated cannot delete',
    );
    await profiles.block(reader.user.id, other.user.handle);
    await denied(
      () => posts.setReplyLike(reader.user.id, p, cid, true),
      404,
      'heart blocked author',
    );
    await denied(
      () => posts.addReply(reader.user.id, p, {
        'body': 'Blocked reply',
        'parentReplyId': cid,
      }),
      404,
      'reply blocked author',
    );
    check(
      items(
        await posts.listReplies(
          other.user.id,
          p,
          20,
          null,
          threaded: true,
          thread: null,
        ),
      ).isEmpty,
      'blocked root hides thread',
    );
    await profiles.unblock(reader.user.id, other.user.handle);
    final image = Uint8List.fromList(
      img.encodeJpg(img.Image(width: 32, height: 32)),
    );
    final media =
        (await call(
              'POST',
              '/media/upload',
              actor: reader,
              status: 201,
              bytes: image,
            ))['id']
            as String;
    final mediaReply = await posts.addReply(reader.user.id, p, {
      'body': 'Ảnh đính kèm',
      'attachmentIds': [media],
    });
    await call('DELETE', '/posts/$p/replies/${mediaReply['id']}', actor: owner);
    check(
      (await db.query(
        r'SELECT id FROM media_asset WHERE id=$1',
        parameters: [media],
      )).isEmpty,
      'post owner deletion revokes media immediately',
    );
    await call('GET', '/media/$media', actor: reader, status: 404);
    await posts.deleteReply(owner.user.id, p, rid);
    final tombstone = items(
      await posts.listReplies(other.user.id, p, 20, null, threaded: true),
    ).single;
    check(
      tombstone['removed'] == true &&
          tombstone['threadCount'] == 2 &&
          tombstone['authorId'] == '' &&
          tombstone['authorHandle'] == '' &&
          tombstone['body'] != 'Bình luận gốc',
      'removed root redacted with children retained',
    );
    await denied(
      () => posts.addReply(other.user.id, p, {
        'body': 'Removed parent',
        'parentReplyId': rid,
      }),
      404,
      'cannot reply directly to removed root',
    );
    await denied(
      () => posts.setReplyLike(other.user.id, p, rid, true),
      404,
      'cannot heart removed root',
    );
    final after = await posts.addReply(owner.user.id, p, {
      'body': 'Tiếp tục luồng',
      'parentReplyId': cid,
    });
    check(after['threadRootId'] == rid, 'existing children remain replyable');
    await denied(
      () => posts.addReply(reader.user.id, p, {
        'body': 'Bình luận gốc',
        'clientPublishId': rid,
      }),
      409,
      'removed publication cannot be recreated',
    );
    await posts.deleteReply(other.user.id, p, cid);
    check(
      items(await posts.listReplies(reader.user.id, p, 20, null, ids: [nid]))
              .single['inReplyToHandle'] ==
          null,
      'removed parent identity not exposed',
    );
    final exported = await identity.exportAccount(reader.user.id);
    check(
      exported.containsKey('commentHearts') &&
          (exported['replies'] as List).any(
            (r) => (r as Map<String, dynamic>).containsKey('parent_reply_id'),
          ),
      'account export includes new domain state',
    );
    await profiles.block(owner.user.id, reader.user.handle);
    await posts.deleteReply(reader.user.id, p, nid);
    check(true, 'author can delete own reply after post owner block');
    await posts.deleteReply(owner.user.id, p, after['id'] as String);
    check(
      items(await posts.listReplies(other.user.id, p, 20, null, threaded: true))
          .isEmpty,
      'no empty tombstone after all replies removed',
    );
    stdout.writeln(
      jsonEncode({
        'checks': checks,
        'scope': 'Isolated SQL/API comments, ownership, media, retry and ASCII handles; not live cloud or native UI.',
      }),
    );
  } finally {
    await db.query(
      r'DELETE FROM app_user WHERE id=ANY($1::uuid[])',
      parameters: [users],
    );
    await MediaCleanupService(db).drainBestEffort();
    await db.close();
  }
}
