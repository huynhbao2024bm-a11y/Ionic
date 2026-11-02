import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:ionic_server/src/app.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/media/media_cleanup_service.dart';
import 'package:ionic_server/src/modules/auth/handle_policy.dart';
import 'package:shelf/shelf.dart';

Future<void> main() async {
  final url = Platform.environment['DATABASE_URL'];
  if (url == null ||
      !Uri.parse(url).pathSegments.last.startsWith('ionic_core_verify_')) {
    throw StateError('Use isolated verification DB.');
  }
  final db = DatabaseService.fromEnvironment();
  final app = createApp(database: db, allowedOrigins: {});
  final accounts = <String>[];
  var checks = 0;
  void check(bool value, String label) {
    if (!value) throw StateError(label);
    checks++;
  }

  Future<({Object? json, Uint8List bytes})> call(
    String method,
    String path, {
    String? cookie,
    Object? body,
    Uint8List? bytes,
    int status = 200,
  }) async {
    final r = await app(
      Request(
        method,
        Uri.parse('http://localhost/api/v1$path'),
        headers: {
          'cookie': ?cookie,
          'content-type': bytes == null
              ? 'application/json'
              : 'application/octet-stream',
          if (bytes != null) 'x-ionic-media-type': 'image',
        },
        body: bytes ?? (body == null ? null : jsonEncode(body)),
      ),
    );
    final data = Uint8List.fromList(await r.read().expand((b) => b).toList());
    check(
      r.statusCode == status,
      '$method $path expected $status got ${r.statusCode}',
    );
    return (
      json: r.headers['content-type']?.contains('application/json') == true
          ? jsonDecode(utf8.decode(data))
          : null,
      bytes: data,
    );
  }

  Future<({String id, String handle, String cookie})> actor(
    String suffix,
  ) async {
    final handle =
        'av_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${suffix}123';
    final r = await app(
      Request(
        'POST',
        Uri.parse('http://localhost/api/v1/auth/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'handle': handle,
          'displayName': 'Fictional avatar',
          'password': 'fictional-password-123',
        }),
      ),
    );
    check(r.statusCode == 201, 'register');
    final user = (jsonDecode(await r.readAsString()) as Map)['user'] as Map;
    final id = user['id'] as String;
    accounts.add(id);
    return (
      id: id,
      handle: handle,
      cookie: r.headers['set-cookie']!.split(';').first,
    );
  }

  final jpeg = Uint8List.fromList(
    img.encodeJpg(img.Image(width: 64, height: 64)),
  );
  Future<String> upload(String cookie) async =>
      ((await call(
                'POST',
                '/media/upload',
                cookie: cookie,
                bytes: jpeg,
                status: 201,
              )).json
              as Map)['id']
          as String;
  try {
    for (final name in [
      'admin',
      'ADMIN123',
      'aadmin999',
      'super_admin123',
      'plain',
      'a12',
      '１２３abc',
    ]) {
      check(
        registrationHandleError(name.toLowerCase()) != null,
        'reject $name',
      );
      await call(
        'POST',
        '/auth/register',
        body: {
          'handle': name,
          'displayName': 'Fictional',
          'password': 'fictional-password-123',
        },
        status: 400,
      );
    }
    for (final name in ['abc123', '1a2b3', '123', 'member_001']) {
      check(registrationHandleError(name) == null, 'allow $name');
    }
    final a = await actor('a'), b = await actor('b');
    await call(
      'POST',
      '/profiles/${a.handle}/follow',
      cookie: b.cookie,
      body: {},
      status: 201,
    );
    final followers =
        (await call(
              'GET',
              '/profiles/${a.handle}/followers',
              cookie: a.cookie,
            )).json
            as Map;
    check(
      (followers['items'] as List).any((i) => (i as Map)['handle'] == b.handle),
      'owner sees followers',
    );
    final following =
        (await call(
              'GET',
              '/profiles/${b.handle}/following',
              cookie: b.cookie,
            )).json
            as Map;
    check(
      (following['items'] as List).any((i) => (i as Map)['handle'] == a.handle),
      'viewer sees following',
    );
    await call(
      'GET',
      '/profiles/${a.handle}/followers?cursor=bad',
      cookie: a.cookie,
      status: 400,
    );
    await call('GET', '/profiles/${a.handle}/followers', status: 401);
    await call(
      'DELETE',
      '/profiles/me/followers/${b.handle}',
      cookie: a.cookie,
    );
    final removed =
        (await call(
              'GET',
              '/profiles/${b.handle}/following',
              cookie: b.cookie,
            )).json
            as Map;
    check(
      (removed['items'] as List).isEmpty,
      'removing follower removes only reverse edge',
    );
    final graphIds = <String>[];
    await db.transaction((tx) async {
      for (var i = 0; i < 32; i++) {
        final handle = 'graph_${i.toString().padLeft(3, '0')}';
        final r = await tx.execute(
          r"INSERT INTO app_user(id,handle,handle_normalized,password_salt,password_hash) VALUES(gen_random_uuid(),$1,$1,decode(repeat('00',16),'hex'),decode(repeat('00',64),'hex')) RETURNING id",
          parameters: [handle],
        );
        final id = r.first.first.toString();
        graphIds.add(id);
        accounts.add(id);
        await tx.execute(
          r'INSERT INTO user_profile(user_id,display_name,visibility) VALUES($1,$2,$3)',
          parameters: [
            id,
            'Fictional connection',
            i == 0 ? 'private' : 'public',
          ],
        );
        await tx.execute(
          r'INSERT INTO account_follow(follower_id,followed_id) VALUES($1,$2)',
          parameters: [id, a.id],
        );
      }
    });
    final page1 =
        (await call(
              'GET',
              '/profiles/${a.handle}/followers',
              cookie: a.cookie,
            )).json
            as Map;
    check(
      (page1['items'] as List).length == 30 && page1['nextCursor'] is String,
      'bounded graph page with cursor',
    );
    final cursor = Uri.encodeQueryComponent(page1['nextCursor'] as String);
    final page2 =
        (await call(
              'GET',
              '/profiles/${a.handle}/followers?cursor=$cursor',
              cookie: a.cookie,
            )).json
            as Map;
    check(
      (page2['items'] as List).length == 2 && page2['nextCursor'] == null,
      'graph last page',
    );
    final names = [
      ...(page1['items'] as List),
      ...(page2['items'] as List),
    ].map((i) => (i as Map)['handle']).toSet();
    check(names.length == 32, 'no repeated connection at equal timestamps');
    await call(
      'GET',
      '/profiles/${a.handle}/following?cursor=$cursor',
      cookie: a.cookie,
      status: 400,
    );
    final publicPage =
        (await call(
              'GET',
              '/profiles/${a.handle}/followers',
              cookie: b.cookie,
            )).json
            as Map;
    final publicPage2 =
        (await call(
              'GET',
              '/profiles/${a.handle}/followers?cursor=${Uri.encodeQueryComponent(publicPage['nextCursor'] as String)}',
              cookie: b.cookie,
            )).json
            as Map;
    check(
      [
            ...(publicPage['items'] as List),
            ...(publicPage2['items'] as List),
          ].length ==
          31,
      'other viewers cannot inspect private member identities',
    );
    await db.query(
      r'DELETE FROM app_user WHERE id=ANY($1::uuid[])',
      parameters: [graphIds],
    );
    final first = await upload(a.cookie);
    await call(
      'PUT',
      '/profiles/me/avatar',
      body: {'mediaId': first},
      status: 401,
    );
    await call(
      'PUT',
      '/profiles/me/avatar',
      cookie: b.cookie,
      body: {'mediaId': first},
      status: 400,
    );
    await call('GET', '/media/$first/file', cookie: a.cookie, status: 404);
    await call(
      'PUT',
      '/profiles/me/avatar',
      cookie: a.cookie,
      body: {'mediaId': first},
    );
    await call(
      'PUT',
      '/profiles/me/avatar',
      cookie: a.cookie,
      body: {'mediaId': first},
    );
    final me = (await call('GET', '/auth/me', cookie: a.cookie)).json as Map;
    check(
      (me['user'] as Map)['avatarMediaId'] == first,
      'session avatar persists',
    );
    final profile =
        (await call('GET', '/profiles/${a.handle}', cookie: b.cookie)).json
            as Map;
    check(
      (profile['profile'] as Map)['avatarMediaId'] == first,
      'profile avatar persists',
    );
    check(
      (await call('GET', '/media/$first/file')).bytes.isNotEmpty,
      'public profile avatar readable',
    );
    await call(
      'POST',
      '/posts',
      cookie: a.cookie,
      body: {
        'body': 'No media reuse',
        'attachmentIds': [first],
      },
      status: 400,
    );
    await call(
      'PATCH',
      '/auth/settings',
      cookie: a.cookie,
      body: {'visibility': 'private'},
    );
    await call('GET', '/media/$first/file', status: 404);
    await call('GET', '/media/$first/file', cookie: b.cookie, status: 404);
    await call(
      'GET',
      '/profiles/${a.handle}/followers',
      cookie: b.cookie,
      status: 404,
    );
    await call('GET', '/media/$first/file', cookie: a.cookie);
    await db.query(
      r"UPDATE media_asset SET created_at=now()-interval '2 days' WHERE id=$1",
      parameters: [first],
    );
    await MediaCleanupService(db).expireStaging();
    await call('GET', '/media/$first/file', cookie: a.cookie);
    final second = await upload(a.cookie);
    await call('GET', '/media/$first/file', cookie: a.cookie);
    await call(
      'PUT',
      '/profiles/me/avatar',
      cookie: a.cookie,
      body: {'mediaId': second},
    );
    await call('GET', '/media/$first/file', cookie: a.cookie, status: 404);
    await call('GET', '/media/$second/file', cookie: a.cookie);
    await call(
      'PATCH',
      '/auth/settings',
      cookie: a.cookie,
      body: {'visibility': 'public'},
    );
    await call(
      'POST',
      '/profiles/${b.handle}/block',
      cookie: a.cookie,
      body: {},
      status: 201,
    );
    await call('GET', '/media/$second/file', cookie: b.cookie, status: 404);
    await call(
      'PUT',
      '/profiles/me/avatar',
      cookie: a.cookie,
      body: {'mediaId': null},
    );
    await call('GET', '/media/$second/file', cookie: a.cookie, status: 404);
    // Direct database writes cannot bypass the reserved/digit rule.
    for (final handle in ['admin', 'bad_admin123', 'ab12']) {
      var denied = false;
      try {
        await db.query(
          r'UPDATE app_user SET handle=$2,handle_normalized=$2 WHERE id=$1',
          parameters: [b.id, handle],
        );
      } catch (_) {
        denied = true;
      }
      check(denied, 'DB rejects $handle');
    }
    final unchanged = await db.query(
      r'SELECT handle FROM app_user WHERE id=$1',
      parameters: [b.id],
    );
    check(unchanged.first.first == b.handle, 'failed rename keeps account');
    final last = await upload(a.cookie);
    await call(
      'PUT',
      '/profiles/me/avatar',
      cookie: a.cookie,
      body: {'mediaId': last},
    );
    await db.query(r'DELETE FROM app_user WHERE id=$1', parameters: [a.id]);
    await call('GET', '/media/$last/file', status: 404);
    stdout.writeln('Profile/handle verification passed: $checks checks.');
  } finally {
    if (accounts.isNotEmpty) {
      await db.query(
        r'DELETE FROM app_user WHERE id=ANY($1::uuid[])',
        parameters: [accounts],
      );
    }
    await MediaCleanupService(db).drainBestEffort();
    await db.close();
  }
}
