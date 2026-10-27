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
    ..get('/public', (Request request) => _public(request, posts))
    ..get('/mine', (Request request) => _mine(request, auth, posts))
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
    );
  return router.call;
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
  headers: const {'content-type': 'application/json; charset=utf-8'},
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
  final user = await requireAuthenticatedUser(request, auth);
  return _json(
    200,
    await posts.listReplies(
      user.id,
      contentId,
      _limit(request),
      request.url.queryParameters['cursor'],
    ),
  );
}
