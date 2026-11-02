import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Opt-in live journey. Creates non-discoverable synthetic accounts, follows
/// before making both profiles private, then publishes only inside that cohort.
/// Passwords/cookies stay in RAM; finally deletes only the accounts it creates.
Future<void> main(List<String> args) async {
  if (args.length != 2 ||
      args[1] != '--allow-live-preview' ||
      args[0] != 'https://ionic-api.onrender.com/api/v1') {
    throw ArgumentError(
      'Explicitly select the intended isolated live preview.',
    );
  }
  final base = args[0],
      client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  final actors =
      <({String handle, String password, String cookie, String id})>[];
  var checks = 0;
  final mediaIds = <String>[];
  final deletedActors = <String>{};
  void check(bool value, String label) {
    if (!value) throw StateError(label);
    checks++;
  }

  Future<
    ({
      int status,
      Map<String, String> headers,
      Uint8List bytes,
      List<Cookie> cookies,
    })
  >
  request(
    String method,
    String path, {
    String? cookie,
    Object? body,
    Uint8List? bytes,
    String? mediaType,
  }) async {
    final r = await client
        .openUrl(method, Uri.parse('$base/$path'))
        .timeout(const Duration(seconds: 30));
    if (cookie != null) r.headers.set('cookie', cookie);
    if (bytes != null) {
      r.headers.set('content-type', 'application/octet-stream');
      r.headers.set('x-ionic-media-type', mediaType!);
      r.contentLength = bytes.length;
      r.add(bytes);
    } else if (body != null) {
      final encoded = utf8.encode(jsonEncode(body));
      r.headers.set('content-type', 'application/json');
      r.contentLength = encoded.length;
      r.add(encoded);
    }
    final response = await r.close().timeout(const Duration(seconds: 90));
    final data = BytesBuilder();
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      if (data.length + chunk.length > 10 * 1024 * 1024) {
        throw StateError('Unexpected response size');
      }
      data.add(chunk);
    }
    final headers = <String, String>{};
    response.headers.forEach(
      (name, values) => headers[name] = values.join(','),
    );
    return (
      status: response.statusCode,
      headers: headers,
      bytes: data.takeBytes(),
      cookies: response.cookies,
    );
  }

  Future<Map<String, dynamic>> json(
    String method,
    String path, {
    String? cookie,
    Object? body,
    int expected = 200,
  }) async {
    final r = await request(method, path, cookie: cookie, body: body);
    if (r.status != expected) {
      throw StateError('$method $path returned ${r.status}');
    }
    return jsonDecode(utf8.decode(r.bytes)) as Map<String, dynamic>;
  }

  Future<void> cleanup() async {
    for (final actor in actors.reversed) {
      if (deletedActors.contains(actor.id)) continue;
      final r = await request(
        'POST',
        'auth/delete-account',
        cookie: actor.cookie,
        body: {'currentPassword': actor.password, 'confirmation': 'DELETE'},
      );
      if (r.status != 200) {
        throw StateError(
          'Synthetic account cleanup failed for ${actor.handle}',
        );
      }
      deletedActors.add(actor.id);
    }
  }

  try {
    check(
      (await json('GET', 'health/ready'))['status'] == 'ready',
      'Live readiness includes database',
    );
    for (var i = 0; i < 2; i++) {
      final handle = 'ionic_check_${_randomHex(4)}123',
          password = 'Aa1!${_randomHex(24)}';
      final r = await request(
        'POST',
        'auth/register',
        body: {
          'handle': handle,
          'displayName': 'Kiểm tra triển khai',
          'password': password,
        },
      );
      check(r.status == 201, 'Live registration succeeds');
      final cookie = r.cookies.firstWhere((c) => c.name == 'ionic_session');
      check(
        cookie.httpOnly && cookie.secure,
        'Production cookie is secure and HttpOnly',
      );
      final id = '${(jsonDecode(utf8.decode(r.bytes)) as Map)['user']['id']}';
      actors.add((
        handle: handle,
        password: password,
        cookie: 'ionic_session=${cookie.value}',
        id: id,
      ));
      await json(
        'PATCH',
        'auth/settings',
        cookie: actors.last.cookie,
        body: {'discoverable': false},
      );
    }
    final a = actors[0], b = actors[1];
    await json(
      'POST',
      'profiles/${a.handle}/follow',
      cookie: b.cookie,
      body: {},
      expected: 201,
    );
    await json(
      'POST',
      'profiles/${b.handle}/follow',
      cookie: a.cookie,
      body: {},
      expected: 201,
    );
    for (final actor in actors) {
      await json(
        'PATCH',
        'auth/settings',
        cookie: actor.cookie,
        body: {'visibility': 'private'},
      );
    }
    final image = Uint8List.fromList(
      img.encodeJpg(img.Image(width: 8, height: 8), quality: 85),
    );
    Future<String> uploadAvatar() async {
      final r = await request(
        'POST',
        'media/upload',
        cookie: a.cookie,
        bytes: image,
        mediaType: 'image',
      );
      check(r.status == 201, 'Live avatar staging');
      final id = (jsonDecode(utf8.decode(r.bytes)) as Map)['id'].toString();
      mediaIds.add(id);
      return id;
    }

    for (final handle in ['ADMIN123', 'no_digits']) {
      check(
        (await request(
              'POST',
              'auth/register',
              body: {
                'handle': handle,
                'displayName': 'Invalid registration',
                'password': 'fictional-password-123',
              },
            )).status ==
            400,
        'Live reserved/digit handle policy',
      );
    }
    final avatar = await uploadAvatar();
    check(
      (await request(
            'PUT',
            'profiles/me/avatar',
            cookie: b.cookie,
            body: {'mediaId': avatar},
          )).status ==
          400,
      'Cross-account avatar assignment denied',
    );
    await json(
      'PUT',
      'profiles/me/avatar',
      cookie: a.cookie,
      body: {'mediaId': avatar},
    );
    check(
      (await json(
            'GET',
            'auth/me',
            cookie: a.cookie,
          ))['user']['avatarMediaId'] ==
          avatar,
      'Live avatar persists',
    );
    check(
      (await request('GET', 'media/$avatar/file', cookie: b.cookie)).status ==
          200,
      'Follower reads cloud avatar',
    );
    check(
      (await request('GET', 'media/$avatar/file')).status == 404,
      'Guest private-avatar denial',
    );
    final replacement = await uploadAvatar();
    await json(
      'PUT',
      'profiles/me/avatar',
      cookie: a.cookie,
      body: {'mediaId': replacement},
    );
    check(
      (await request('GET', 'media/$avatar/file', cookie: a.cookie)).status ==
          404,
      'Replaced avatar inaccessible',
    );
    await json(
      'PUT',
      'profiles/me/avatar',
      cookie: a.cookie,
      body: {'mediaId': null},
    );
    check(
      (await request(
            'GET',
            'media/$replacement/file',
            cookie: a.cookie,
          )).status ==
          404,
      'Removed avatar inaccessible',
    );
    final uploaded = await request(
      'POST',
      'media/upload',
      cookie: a.cookie,
      bytes: image,
      mediaType: 'image',
    );
    check(uploaded.status == 201, 'Real private cloud image upload');
    final imageMeta = jsonDecode(utf8.decode(uploaded.bytes)) as Map;
    final imageId = '${imageMeta['id']}';
    mediaIds.add(imageId);
    check(
      (await request('GET', 'media/$imageId/file', cookie: a.cookie)).status ==
          404,
      'Unpublished cloud media stays private',
    );
    final publish = {
      'body': 'Bài kiểm tra riêng tư về mèo và ảnh.',
      'attachmentIds': [imageId],
      'clientPublishId': _uuid(),
    };
    final post = await json(
      'POST',
      'posts/',
      cookie: a.cookie,
      body: publish,
      expected: 201,
    );
    final postId = '${post['id']}';
    check(
      postId ==
          (await json(
            'POST',
            'posts/',
            cookie: a.cookie,
            body: publish,
            expected: 201,
          ))['id'],
      'Live publication retry creates no duplicate',
    );
    final file = await request('GET', 'media/$imageId/file', cookie: b.cookie);
    check(
      file.status == 200 && img.decodeJpg(file.bytes)?.width == 8,
      'Authorized follower reads actual stored image',
    );
    check(
      file.headers['cache-control']!.contains('no-store'),
      'Private image response is not cached',
    );
    check(
      (await request('GET', 'media/$imageId/file')).status == 404,
      'Guest cannot retrieve private-profile cloud image',
    );
    final feed = await json('GET', 'feed/for-you?limit=20', cookie: b.cookie);
    check(
      (feed['items'] as List).any((p) => (p as Map)['id'] == postId),
      'Live structured adaptive feed returns eligible followed private content',
    );
    check(
      (feed['items'] as List).every(
        (p) => !(p as Map).keys.any(
          (k) => ['labels', 'isRandom', 'score', 'features'].contains(k),
        ),
      ),
      'Live feed keeps ranking details internal',
    );
    final voice = await request(
      'POST',
      'media/upload',
      cookie: b.cookie,
      bytes: _wave(),
      mediaType: 'audio',
    );
    check(voice.status == 201, 'Real private cloud voice upload');
    final voiceId = '${(jsonDecode(utf8.decode(voice.bytes)) as Map)['id']}';
    mediaIds.add(voiceId);
    final reply = await json(
      'POST',
      'posts/$postId/replies',
      cookie: b.cookie,
      body: {
        'body': 'Bình luận kiểm tra riêng tư.',
        'attachmentIds': [voiceId],
        'clientPublishId': _uuid(),
      },
      expected: 201,
    );
    check(reply['id'] is String, 'Voice reply persists');
    final replies = await json(
      'GET',
      'posts/$postId/replies?limit=20',
      cookie: a.cookie,
    );
    check(
      (replies['items'] as List).any(
        (r) =>
            (r as Map)['id'] == reply['id'] &&
            (r['attachments'] as List).isNotEmpty,
      ),
      'Comment list contains persisted voice reply',
    );
    final voiceRead = await request(
      'GET',
      'media/$voiceId/file',
      cookie: a.cookie,
    );
    check(
      voiceRead.status == 200 && voiceRead.bytes.length == 32044,
      'Actual stored voice bytes are readable by authorized parent owner',
    );
    check(
      (await request('GET', 'media/$voiceId/file')).status == 404,
      'Guest voice access denied',
    );
    final c = await json(
      'POST',
      'messages/conversations',
      cookie: a.cookie,
      body: {'handle': b.handle},
      expected: 201,
    );
    final conversationId = '${(c['conversation'] as Map)['id']}',
        messageId = _uuid();
    final message = await json(
      'POST',
      'messages/conversations/$conversationId',
      cookie: a.cookie,
      body: {
        'body': 'Tin nhắn kiểm tra riêng tư.',
        'clientMessageId': messageId,
      },
      expected: 201,
    );
    check(message['id'] == messageId, 'Live private send persists');
    final history = await json(
      'GET',
      'messages/conversations/$conversationId',
      cookie: b.cookie,
    );
    check(
      (history['items'] as List).any((m) => (m as Map)['id'] == messageId),
      'Recipient reads real persisted history',
    );
    await json(
      'POST',
      'messages/conversations/$conversationId/read',
      cookie: b.cookie,
      body: {'lastMessageId': messageId},
    );
    check(
      (await json(
            'GET',
            'messages/conversations/$conversationId',
            cookie: a.cookie,
          ))['partnerReadMessageId'] ==
          messageId,
      'Live read receipt persists',
    );
    await json(
      'PATCH',
      'feed/settings',
      cookie: b.cookie,
      body: {'paused': true},
    );
    check(
      (await json('GET', 'feed/settings', cookie: b.cookie))['paused'] == true,
      'Live pause persists',
    );
    await json('POST', 'feed/reset', cookie: b.cookie, body: {}, expected: 201);
    await json(
      'PATCH',
      'feed/settings',
      cookie: b.cookie,
      body: {'paused': false},
    );
    check(
      (await json('GET', 'auth/me', cookie: a.cookie))['user']['id'] == a.id,
      'Live session restoration endpoint',
    );
    final followers = await json(
      'GET',
      'profiles/${a.handle}/followers',
      cookie: a.cookie,
    );
    check(
      (followers['items'] as List).any((i) => (i as Map)['handle'] == b.handle),
      'Live follower list',
    );
    final following = await json(
      'GET',
      'profiles/${b.handle}/following',
      cookie: b.cookie,
    );
    check(
      (following['items'] as List).any((i) => (i as Map)['handle'] == a.handle),
      'Live following list',
    );
    await json('DELETE', 'profiles/me/followers/${b.handle}', cookie: a.cookie);
    check(
      (await request(
            'GET',
            'profiles/${a.handle}/followers',
            cookie: b.cookie,
          )).status ==
          404,
      'Removing follower revokes private graph access',
    );
    await cleanup();
    check(
      (await request('GET', 'auth/me', cookie: a.cookie)).status == 401,
      'Deleted account session no longer works',
    );
    check(
      (await request('GET', 'media/$imageId/file', cookie: b.cookie)).status ==
          404,
      'Deleted parent revokes cloud media access',
    );
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'checks': checks,
        'api': base,
        'syntheticAccountIds': actors.map((a) => a.id).toList(),
        'mediaIds': mediaIds,
        'privateCohort': true,
        'cleanupViaAuthorizedApi': true,
        'scope': 'Real Render + Supabase HTTP journeys; synthetic media/private accounts, not native UI or microphone quality.',
      }),
    );
    actors.clear();
  } finally {
    try {
      if (actors.isNotEmpty) await cleanup();
    } finally {
      client.close(force: true);
    }
  }
}

String _randomHex(int n) => List.generate(
  n,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();
String _uuid() {
  final h = _randomHex(16);
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-4${h.substring(13, 16)}-8${h.substring(17, 20)}-${h.substring(20)}';
}

Uint8List _wave() {
  final b = Uint8List(32044), d = ByteData.sublistView(b);
  b.setRange(0, 4, ascii.encode('RIFF'));
  d.setUint32(4, 32036, Endian.little);
  b.setRange(8, 12, ascii.encode('WAVE'));
  b.setRange(12, 16, ascii.encode('fmt '));
  d.setUint32(16, 16, Endian.little);
  d.setUint16(20, 1, Endian.little);
  d.setUint16(22, 1, Endian.little);
  d.setUint32(24, 16000, Endian.little);
  d.setUint32(28, 32000, Endian.little);
  d.setUint16(32, 2, Endian.little);
  d.setUint16(34, 16, Endian.little);
  b.setRange(36, 40, ascii.encode('data'));
  d.setUint32(40, 32000, Endian.little);
  return b;
}
