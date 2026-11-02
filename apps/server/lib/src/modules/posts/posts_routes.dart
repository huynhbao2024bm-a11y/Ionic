import 'dart:convert';

import 'package:ionic_server/src/http/api_exception.dart';
import 'package:ionic_server/src/http/request_body.dart';
import 'package:ionic_server/src/modules/auth/auth_routes.dart';
import 'package:ionic_server/src/modules/auth/auth_service.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/posts/posts_service.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

Handler createPostsRoutes(DatabaseService database) {
  final auth = AuthService(database);
  final posts = PostsService(database);
  final router = Router()
    ..post('/', (Request request) => _create(request, auth, posts))
    ..post('/<contentId>/replies/sync', (
      Request request,
      String contentId,
    ) async {
      final input = await readJsonObject(request), ids = input['ids'];
      final uuid = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        caseSensitive: false,
      );
      if (input.keys.any((k) => !['ids', 'threaded'].contains(k)) ||
          (input.containsKey('threaded') && input['threaded'] is! bool) ||
          ids is! List ||
          ids.isEmpty ||
          ids.length > 50 ||
          ids.any((i) => i is! String || !uuid.hasMatch(i))) {
        throw const ApiException(400, 'Expected one to fifty reply IDs.');
      }
      return _json(
        200,
        await posts.listReplies(
          await _optionalViewer(request, auth),
          contentId,
          50,
          null,
          ids: ids.cast<String>(),
          threaded: input['threaded'] == true,
        ),
      );
    })
    ..post('/sync', (Request request) async {
      final input = await readJsonObject(request);
      if (input.length != 1 || !input.containsKey('ids')) {
        throw const ApiException(400, 'Expected post IDs.');
      }
      return _json(
        200,
        await posts.readVisible(
          await _optionalViewer(request, auth),
          input['ids'],
          feedControls: true,
        ),
      );
    })
    ..get('/public', (Request request) => _public(request, posts))
    ..get('/mine', (Request request) => _mine(request, auth, posts))
    ..get(
      '/saved',
      (Request request) async => _json(
        200,
        await posts.listSaved(
          (await requireAuthenticatedUser(request, auth)).id,
          _limit(request),
          request.url.queryParameters['cursor'],
        ),
      ),
    )
    ..patch(
      '/<contentId>',
      (Request request, String contentId) async => _json(
        200,
        await posts.editOwn(
          (await requireAuthenticatedUser(request, auth)).id,
          contentId,
          await readJsonObject(request),
        ),
      ),
    )
    ..delete(
      '/<contentId>',
      (Request request, String contentId) async => _json(
        200,
        await posts.deleteOwn(
          (await requireAuthenticatedUser(request, auth)).id,
          contentId,
        ),
      ),
    )
    ..get('/following', (Request request) => _following(request, auth, posts))
    ..get('/search', (Request request) => _search(request, auth, posts))
    ..get(
      '/author/<handle>',
      (Request request, String handle) => _author(request, handle, auth, posts),
    )
    ..post(
      '/<contentId>/like',
      (Request request, String contentId) =>
          _like(request, contentId, true, auth, posts),
    )
    ..delete(
      '/<contentId>/like',
      (Request request, String contentId) =>
          _like(request, contentId, false, auth, posts),
    )
    ..post(
      '/<contentId>/save',
      (Request request, String contentId) =>
          _save(request, contentId, true, auth, posts),
    )
    ..delete(
      '/<contentId>/save',
      (Request request, String contentId) =>
          _save(request, contentId, false, auth, posts),
    )
    ..post(
      '/<contentId>/replies',
      (Request request, String contentId) =>
          _addReply(request, contentId, auth, posts),
    )
    ..get(
      '/<contentId>/replies',
      (Request request, String contentId) =>
          _replies(request, contentId, auth, posts),
    )
    ..post(
      '/<contentId>/replies/<replyId>/like',
      (Request request, String contentId, String replyId) async => _json(
        201,
        await posts.setReplyLike(
          (await requireAuthenticatedUser(request, auth)).id,
          contentId,
          replyId,
          true,
        ),
      ),
    )
    ..delete(
      '/<contentId>/replies/<replyId>/like',
      (Request request, String contentId, String replyId) async => _json(
        200,
        await posts.setReplyLike(
          (await requireAuthenticatedUser(request, auth)).id,
          contentId,
          replyId,
          false,
        ),
      ),
    )
    ..delete(
      '/<contentId>/replies/<replyId>',
      (Request request, String contentId, String replyId) async => _json(
        200,
        await posts.deleteReply(
          (await requireAuthenticatedUser(request, auth)).id,
          contentId,
          replyId,
        ),
      ),
    )
    ..get('/<contentId>', (Request request, String contentId) async {
      final page = await posts.readVisible(
        await _optionalViewer(request, auth),
        [contentId],
      );
      final items = page['items'] as List;
      if (items.isEmpty) throw const ApiException(404, 'Post was not found.');
      return _json(200, items.first as Object);
    });
  return router.call;
}

Future<String?> _optionalViewer(Request request, AuthService auth) async {
  final token = readSessionToken(request.headers['cookie']);
  return token == null ? null : (await auth.authenticate(token)).id;
}

Future<Response> _public(Request request, PostsService posts) async => _json(
  200,
  await posts.listPublic(
    _limit(request),
    request.url.queryParameters['cursor'],
  ),
);

int _limit(Request request) {
  final raw = request.url.queryParameters['limit'];
  final value = raw == null ? 20 : int.tryParse(raw);
  if (value == null || value < 1 || value > 50) {
    throw const ApiException(400, 'Limit must be an integer between 1 and 50.');
  }
  return value;
}

Response _json(int statusCode, Object value) => Response(
  statusCode,
  body: jsonEncode(value),
  headers: const {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  },
);

Future<Response> _create(
  Request request,
  AuthService auth,
  PostsService posts,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  return _json(201, await posts.create(user.id, await readJsonObject(request)));
}

Future<Response> _mine(
  Request request,
  AuthService auth,
  PostsService posts,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  return _json(
    200,
    await posts.listMine(
      user.id,
      _limit(request),
      request.url.queryParameters['cursor'],
    ),
  );
}

Future<Response> _following(
  Request request,
  AuthService auth,
  PostsService posts,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  return _json(
    200,
    await posts.listFollowing(
      user.id,
      _limit(request),
      request.url.queryParameters['cursor'],
    ),
  );
}

Future<Response> _search(
  Request request,
  AuthService auth,
  PostsService posts,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  return _json(
    200,
    await posts.search(
      user.id,
      request.url.queryParameters['q'],
      _limit(request),
      request.url.queryParameters['cursor'],
    ),
  );
}

Future<Response> _author(
  Request request,
  String handle,
  AuthService auth,
  PostsService posts,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  return _json(
    200,
    await posts.listAuthor(
      user.id,
      handle,
      _limit(request),
      request.url.queryParameters['cursor'],
    ),
  );
}

Future<Response> _like(
  Request request,
  String contentId,
  bool liked,
  AuthService auth,
  PostsService posts,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  return _json(
    liked ? 201 : 200,
    await posts.setLike(user.id, contentId, liked),
  );
}

Future<Response> _save(
  Request request,
  String contentId,
  bool saved,
  AuthService auth,
  PostsService posts,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  return _json(
    saved ? 201 : 200,
    await posts.setSaved(user.id, contentId, saved),
  );
}

Future<Response> _addReply(
  Request request,
  String contentId,
  AuthService auth,
  PostsService posts,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  return _json(
    201,
    await posts.addReply(user.id, contentId, await readJsonObject(request)),
  );
}

Future<Response> _replies(
  Request request,
  String contentId,
  AuthService auth,
  PostsService posts,
) async {
  final viewerId = await _optionalViewer(request, auth);
  final threaded = request.url.queryParameters['threaded'];
  if (threaded != null && threaded != 'true' && threaded != 'false') {
    throw const ApiException(400, 'Threaded flag is invalid.');
  }
  return _json(
    200,
    await posts.listReplies(
      viewerId,
      contentId,
      _limit(request),
      request.url.queryParameters['cursor'],
      threaded: threaded == 'true',
      thread: request.url.queryParameters['thread'],
    ),
  );
}
