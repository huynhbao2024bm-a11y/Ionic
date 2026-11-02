import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:ionic_server/src/app.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/media/media_cleanup_service.dart';
import 'package:shelf/shelf.dart';

/// Integration verification with fictional users, real routes and PostgreSQL.
/// Refuses normal databases. Run migrations against this dedicated DB first.
Future<void> main() async {
  final url = Platform.environment['DATABASE_URL'];
  if (url == null ||
      !Uri.parse(url).pathSegments.last.startsWith('ionic_core_verify_')) {
    throw StateError('Use a dedicated ionic_core_verify_* database.');
  }
  final db = DatabaseService.fromEnvironment();
  final app = createApp(database: db, allowedOrigins: {});
  final accounts = <String>[];
  var checks = 0;
  void check(bool value, String name) {
    if (!value) throw StateError(name);
    checks++;
  }

  Future<({Map<String, dynamic> json, Uint8List bytes, String? cookie})> call(
    String method,
    String path, {
    String? cookie,
    Object? body,
    Uint8List? bytes,
    Map<String, String> headers = const {},
    int status = 200,
  }) async {
    final response = await app(
      Request(
        method,
        Uri.parse('http://localhost/api/v1$path'),
        headers: {
          'cookie': ?cookie,
          'content-type': bytes == null
              ? 'application/json'
              : 'application/octet-stream',
          ...headers,
        },
        body: bytes ?? (body == null ? null : jsonEncode(body)),
      ),
    );
    final data = Uint8List.fromList(
      await response.read().expand((b) => b).toList(),
    );
    check(
      response.statusCode == status,
      '$method $path: expected $status, received ${response.statusCode}',
    );
    Map<String, dynamic> json = {};
    if (response.headers['content-type']?.contains('application/json') ==
        true) {
      json = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
    }
    return (
      json: json,
      bytes: data,
      cookie: response.headers['set-cookie']?.split(';').first,
    );
  }

  Future<({String id, String handle, String cookie})> register(
    String suffix,
  ) async {
    final handle =
        'verify_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${suffix}123';
    final r = await call(
      'POST',
      '/auth/register',
      status: 201,
      body: {
        'handle': handle,
        'displayName': 'Fictional $suffix',
        'password': 'fictional-password-123',
      },
    );
    final id = '${(r.json['user'] as Map)['id']}';
    accounts.add(id);
    return (id: id, handle: handle, cookie: r.cookie!);
  }

  String uuid(int n) =>
      '12345678-1234-4234-8234-${n.toString().padLeft(12, '0')}';
  try {
    check(
      await db.checkReadiness() == DatabaseReadiness.ready,
      'Database migrations ready',
    );
    final a = await register('a'),
        b = await register('b'),
        c = await register('c');
    final a2 = await call(
      'POST',
      '/auth/login',
      status: 201,
      body: {'handle': a.handle, 'password': 'fictional-password-123'},
    );
    final sessions =
        (await call('GET', '/auth/sessions', cookie: a.cookie)).json['items']
            as List;
    check(
      sessions.length == 2 &&
          sessions.where((s) => s['current'] == true).length == 1,
      'Session IDs and current flag',
    );
    check(
      !jsonEncode(sessions).contains('token_hash'),
      'Session tokens never exported',
    );
    final other = sessions.firstWhere((s) => s['current'] == false);
    await call('DELETE', '/auth/sessions/${other['id']}', cookie: b.cookie);
    await call('GET', '/auth/me', cookie: a2.cookie);
    await call('DELETE', '/auth/sessions/${other['id']}', cookie: a.cookie);
    await call('GET', '/auth/me', cookie: a2.cookie, status: 401);
    await call(
      'POST',
      '/auth/password',
      cookie: a.cookie,
      status: 403,
      body: {
        'currentPassword': 'incorrect-password',
        'newPassword': 'changed-password-123',
      },
    );
    await call(
      'POST',
      '/auth/password',
      cookie: a.cookie,
      body: {
        'currentPassword': 'fictional-password-123',
        'newPassword': 'changed-password-123',
      },
    );
    await call('GET', '/auth/me', cookie: a.cookie);
    await call(
      'POST',
      '/auth/login',
      status: 401,
      body: {'handle': a.handle, 'password': 'fictional-password-123'},
    );
    final code = (await call(
      'POST',
      '/auth/recovery-code',
      cookie: a.cookie,
      status: 201,
      body: {'currentPassword': 'changed-password-123'},
    )).json['recoveryCode'];
    await call(
      'POST',
      '/auth/recover',
      status: 403,
      body: {
        'handle': a.handle,
        'recoveryCode': 'A' * 43,
        'newPassword': 'recovered-password-123',
      },
    );
    await call(
      'POST',
      '/auth/recover',
      body: {
        'handle': a.handle,
        'recoveryCode': code,
        'newPassword': 'recovered-password-123',
      },
    );
    await call(
      'POST',
      '/auth/recover',
      status: 403,
      body: {
        'handle': a.handle,
        'recoveryCode': code,
        'newPassword': 'recovered-password-123',
      },
    );
    await call('GET', '/auth/me', cookie: a.cookie, status: 401);
    final login = await call(
      'POST',
      '/auth/login',
      status: 201,
      body: {'handle': a.handle, 'password': 'recovered-password-123'},
    );
    final ac = login.cookie!;
    await call(
      'PATCH',
      '/auth/settings',
      cookie: ac,
      status: 400,
      body: {'discoverable': 'false'},
    );
    await call('DELETE', '/auth/sessions/${'z' * 36}', cookie: ac, status: 400);
    await call('GET', '/messages/conversations', status: 401);

    await call(
      'PATCH',
      '/auth/settings',
      cookie: b.cookie,
      body: {'messagePermission': 'nobody'},
    );
    await call(
      'POST',
      '/messages/conversations',
      cookie: ac,
      status: 403,
      body: {'handle': b.handle},
    );
    await call(
      'PATCH',
      '/auth/settings',
      cookie: b.cookie,
      body: {'messagePermission': 'following'},
    );
    await call(
      'POST',
      '/messages/conversations',
      cookie: ac,
      status: 403,
      body: {'handle': b.handle},
    );
    await call(
      'POST',
      '/profiles/${a.handle}/follow',
      cookie: b.cookie,
      status: 201,
      body: {},
    );
    final conv =
        (await call(
              'POST',
              '/messages/conversations',
              cookie: ac,
              status: 201,
              body: {'handle': b.handle},
            )).json['conversation']
            as Map;
    final conversationId = '${conv['id']}';
    final retry = {'body': 'Fictional message', 'clientMessageId': uuid(1)};
    await call(
      'POST',
      '/messages/conversations/$conversationId',
      cookie: ac,
      status: 201,
      body: retry,
    );
    await call(
      'POST',
      '/messages/conversations/$conversationId',
      cookie: ac,
      status: 201,
      body: retry,
    );
    await call(
      'POST',
      '/messages/conversations/$conversationId',
      cookie: ac,
      status: 403,
      body: {'body': 'Changed body', 'clientMessageId': uuid(1)},
    );
    final messages =
        (await call(
              'GET',
              '/messages/conversations/$conversationId',
              cookie: b.cookie,
            )).json['items']
            as List;
    check(messages.length == 1, 'Message retry does not duplicate');
    await call(
      'GET',
      '/messages/conversations/$conversationId',
      cookie: c.cookie,
      status: 404,
    );
    final unread =
        (await call(
              'GET',
              '/messages/conversations',
              cookie: b.cookie,
            )).json['items']
            as List;
    check(unread.first['unreadCount'] == 1, 'Unread count');
    await call(
      'POST',
      '/messages/conversations/$conversationId/read',
      cookie: b.cookie,
      body: {'lastMessageId': uuid(1)},
    );
    final read = await call(
      'GET',
      '/messages/conversations/$conversationId',
      cookie: ac,
    );
    check(
      read.json['partnerReadMessageId'] == uuid(1),
      'Read receipt bound to visible message',
    );
    await call(
      'PATCH',
      '/auth/settings',
      cookie: b.cookie,
      body: {'messagePermission': 'nobody'},
    );
    await call(
      'POST',
      '/messages/conversations/$conversationId',
      cookie: ac,
      status: 403,
      body: {'body': 'Denied', 'clientMessageId': uuid(2)},
    );
    await call(
      'PATCH',
      '/auth/settings',
      cookie: b.cookie,
      body: {'messagePermission': 'everyone'},
    );
    for (var i = 2; i <= 53; i++) {
      await call(
        'POST',
        '/messages/conversations/$conversationId',
        cookie: ac,
        status: 201,
        body: {'body': 'History $i', 'clientMessageId': uuid(i)},
      );
    }
    final latest = await call(
      'GET',
      '/messages/conversations/$conversationId?limit=50',
      cookie: b.cookie,
    );
    final older = await call(
      'GET',
      '/messages/conversations/$conversationId?limit=50&cursor=${latest.json['nextCursor']}',
      cookie: b.cookie,
    );
    check(
      (latest.json['items'] as List).length == 50 &&
          (older.json['items'] as List).length == 3,
      'Message cursor covers history',
    );
    await call(
      'POST',
      '/profiles/${a.handle}/block',
      cookie: b.cookie,
      status: 201,
      body: {},
    );
    await call(
      'GET',
      '/messages/conversations/$conversationId',
      cookie: ac,
      status: 404,
    );
    await call(
      'POST',
      '/messages/conversations/$conversationId',
      cookie: ac,
      status: 403,
      body: {'body': 'Blocked', 'clientMessageId': uuid(54)},
    );
    await call('DELETE', '/profiles/${a.handle}/block', cookie: b.cookie);

    final image = img.Image(width: 32, height: 24);
    image.exif.imageIfd['Make'] = 'FICTIONAL PRIVATE CAMERA';
    image.exif.gpsIfd[1] = 'N';
    final jpeg = Uint8List.fromList(img.encodeJpg(image));
    check(!img.decodeJpg(jpeg)!.exif.isEmpty, 'Image fixture contains EXIF');
    final upload = await call(
      'POST',
      '/media/upload',
      cookie: ac,
      status: 201,
      bytes: jpeg,
      headers: {'x-ionic-media-type': 'image'},
    );
    final assetId = '${upload.json['id']}';
    await call('GET', '/media/$assetId/file', cookie: ac, status: 404);
    await call(
      'POST',
      '/posts/',
      cookie: b.cookie,
      status: 400,
      body: {
        'body': 'Cannot steal attachment',
        'attachmentIds': [assetId],
      },
    );
    final postBody = {
      'body': 'Fictional image post',
      'attachmentIds': [assetId],
      'clientPublishId': uuid(100),
    };
    final post = await call(
      'POST',
      '/posts/',
      cookie: ac,
      status: 201,
      body: postBody,
    );
    await call('POST', '/posts/', cookie: ac, status: 201, body: postBody);
    await call(
      'POST',
      '/posts/',
      cookie: ac,
      status: 409,
      body: {...postBody, 'body': 'Different body'},
    );
    final postId = '${post.json['id']}';
    final rendered = await call('GET', '/media/$assetId/file');
    check(
      img.decodeJpg(rendered.bytes)!.exif.isEmpty,
      'Server removes EXIF/GPS',
    );
    check(
      (await db.query(
            r'SELECT count(*) FROM content WHERE id = $1',
            parameters: [postId],
          )).first.first ==
          1,
      'Post retry persists once',
    );
    final wave = _wave();
    await call(
      'POST',
      '/media/upload',
      cookie: ac,
      status: 400,
      bytes: Uint8List.fromList([1, 2, 3]),
      headers: {'x-ionic-media-type': 'image'},
    );
    final invalidWave = Uint8List.fromList(wave)..[22] = 2;
    await call(
      'POST',
      '/media/upload',
      cookie: ac,
      status: 400,
      bytes: invalidWave,
      headers: {'x-ionic-media-type': 'audio'},
    );
    final voice = await call(
      'POST',
      '/media/upload',
      cookie: b.cookie,
      status: 201,
      bytes: wave,
      headers: {'x-ionic-media-type': 'audio'},
    );
    final voiceId = '${voice.json['id']}';
    final reply = {
      'body': 'Fictional voice reply',
      'attachmentIds': [voiceId],
      'clientPublishId': uuid(101),
    };
    final r1 = await call(
      'POST',
      '/posts/$postId/replies',
      cookie: b.cookie,
      status: 201,
      body: reply,
    );
    final r2 = await call(
      'POST',
      '/posts/$postId/replies',
      cookie: b.cookie,
      status: 201,
      body: reply,
    );
    check(
      r1.json['id'] == r2.json['id'] && r2.json['authorHandle'] == b.handle,
      'Reply retry returns same authorized reply',
    );
    await Future.wait(
      List.generate(
        6,
        (_) => call('GET', '/posts/$postId/replies', cookie: ac),
      ),
    ).timeout(const Duration(seconds: 10));
    await call('GET', '/media/$voiceId/file', cookie: c.cookie);
    await call(
      'POST',
      '/profiles/${b.handle}/block',
      cookie: c.cookie,
      status: 201,
      body: {},
    );
    await call('GET', '/media/$voiceId/file', cookie: c.cookie, status: 404);
    check(
      ((await call(
                'GET',
                '/posts/$postId/replies',
                cookie: c.cookie,
              )).json['items']
              as List)
          .isEmpty,
      'Blocked reply author excluded',
    );
    await call(
      'PATCH',
      '/posts/$postId',
      cookie: b.cookie,
      status: 404,
      body: {'body': 'Not owner'},
    );
    await call(
      'PATCH',
      '/posts/$postId',
      cookie: ac,
      body: {'body': 'Edited fictional post'},
    );
    await call(
      'POST',
      '/posts/$postId/save',
      cookie: b.cookie,
      status: 201,
      body: {},
    );
    check(
      ((await call('GET', '/posts/saved', cookie: b.cookie)).json['items']
                  as List)
              .length ==
          1,
      'Saved posts activity',
    );
    await call(
      'POST',
      '/feed/$postId/hide',
      cookie: b.cookie,
      status: 201,
      body: {},
    );
    check(
      ((await call('GET', '/feed/hidden', cookie: b.cookie)).json['items']
                  as List)
              .length ==
          1,
      'Hidden posts management',
    );
    await call('DELETE', '/feed/$postId/hide', cookie: b.cookie);
    await call(
      'PATCH',
      '/auth/settings',
      cookie: ac,
      body: {'visibility': 'private', 'discoverable': false},
    );
    await call('GET', '/media/$assetId/file', cookie: c.cookie, status: 404);
    await call('GET', '/media/$assetId/file', status: 404);
    final found =
        (await call(
              'GET',
              '/profiles/search?q=${a.handle}',
              cookie: c.cookie,
            )).json['items']
            as List;
    check(found.isEmpty, 'Discoverability enforced');
    await call(
      'PATCH',
      '/auth/settings',
      cookie: ac,
      body: {'visibility': 'public'},
    );
    final exported = await call('GET', '/auth/export', cookie: ac);
    check(
      (exported.json['sentMessages'] as List).length == 53,
      'Account export includes authored messages',
    );
    check(
      !jsonEncode(exported.json).contains('password_hash') &&
          !jsonEncode(exported.json).contains('code_hash'),
      'Account export excludes secrets',
    );
    await call('DELETE', '/posts/$postId', cookie: ac);
    await call('GET', '/media/$assetId/file', cookie: ac, status: 404);
    await call('GET', '/media/$voiceId/file', cookie: b.cookie, status: 404);
    check(
      (await db.query('SELECT count(*) FROM media_deletion_job')).first.first ==
          0,
      'Post deletion drains media jobs',
    );
    final pending = await call(
      'POST',
      '/media/upload',
      cookie: ac,
      status: 201,
      bytes: jpeg,
      headers: {'x-ionic-media-type': 'image'},
    );
    check(pending.json['id'] != null, 'Account deletion includes staged files');
    await call(
      'POST',
      '/auth/delete-account',
      cookie: ac,
      status: 403,
      body: {'currentPassword': 'wrong-password', 'confirmation': 'DELETE'},
    );
    await call(
      'POST',
      '/auth/delete-account',
      cookie: ac,
      body: {
        'currentPassword': 'recovered-password-123',
        'confirmation': 'DELETE',
      },
    );
    await call('GET', '/auth/me', cookie: ac, status: 401);
    check(
      (await db.query(
            r'SELECT count(*) FROM direct_conversation WHERE id = $1',
            parameters: [conversationId],
          )).first.first ==
          0,
      'Deletion removes conversation history',
    );
    await call('POST', '/auth/logout-all', cookie: b.cookie, body: {});
    await call('GET', '/auth/me', cookie: b.cookie, status: 401);
    stdout.writeln(
      'PASS: $checks account/media/message checks against isolated PostgreSQL.',
    );
  } finally {
    for (final id in accounts) {
      await db.query(r'DELETE FROM app_user WHERE id = $1', parameters: [id]);
    }
    await MediaCleanupService(db).drain();
    await db.close();
  }
}

Uint8List _wave() {
  final bytes = Uint8List(32044), data = ByteData(32044);
  void text(int start, String s) =>
      bytes.setRange(start, start + s.length, s.codeUnits);
  text(0, 'RIFF');
  text(8, 'WAVE');
  text(12, 'fmt ');
  text(36, 'data');
  data.setUint32(4, bytes.length - 8, Endian.little);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  data.setUint32(40, 32000, Endian.little);
  for (final range in [(4, 8), (16, 36), (40, 44)]) {
    bytes.setRange(
      range.$1,
      range.$2,
      data.buffer.asUint8List(range.$1, range.$2 - range.$1),
    );
  }
  return bytes;
}
