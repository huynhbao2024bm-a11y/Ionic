import 'dart:convert';

import 'package:ionic_server/src/http/request_body.dart';
import 'package:ionic_server/src/modules/auth/auth_routes.dart';
import 'package:ionic_server/src/modules/auth/auth_service.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/profiles/profiles_service.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

Handler createProfilesRoutes(DatabaseService database) {
  final auth = AuthService(database);
  final profiles = ProfilesService(database);
  final router = Router()
    ..patch('/me', (Request request) => _updateMe(request, auth, profiles))
    ..get('/search', (Request request) => _search(request, auth, profiles))
    ..get(
      '/following',
      (Request request) => _following(request, auth, profiles),
    )
    ..get('/blocked', (Request request) => _blocked(request, auth, profiles))
    ..get('/muted', (Request request) => _muted(request, auth, profiles))
    ..post(
      '/<handle>/follow',
      (Request request, String handle) =>
          _change(request, handle, auth, profiles, profiles.follow),
    )
    ..delete(
      '/<handle>/follow',
      (Request request, String handle) => _change(
        request,
        handle,
        auth,
        profiles,
        profiles.unfollow,
        statusCode: 200,
      ),
    )
    ..post(
      '/<handle>/block',
      (Request request, String handle) =>
          _change(request, handle, auth, profiles, profiles.block),
    )
    ..delete(
      '/<handle>/block',
      (Request request, String handle) => _change(
        request,
        handle,
        auth,
        profiles,
        profiles.unblock,
        statusCode: 200,
      ),
    )
    ..post(
      '/<handle>/mute',
      (Request request, String handle) =>
          _change(request, handle, auth, profiles, profiles.mute),
    )
    ..delete(
      '/<handle>/mute',
      (Request request, String handle) => _change(
        request,
        handle,
        auth,
        profiles,
        profiles.unmute,
        statusCode: 200,
      ),
    )
    ..get(
      '/<handle>',
      (Request request, String handle) =>
          _profile(request, handle, auth, profiles),
    );
  return router.call;
}

Future<Response> _updateMe(
  Request request,
  AuthService auth,
  ProfilesService profiles,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  final profile = await profiles.updateMe(
    user.id,
    await readJsonObject(request),
  );
  return _json(200, {
    'user': {
      'id': user.id,
      'handle': user.handle,
      'displayName': profile['displayName'],
    },
    'profile': profile,
  });
}

Future<Response> _search(
  Request request,
  AuthService auth,
  ProfilesService profiles,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  return _json(
    200,
    await profiles.search(user.id, request.url.queryParameters['q']),
  );
}

Future<Response> _following(
  Request request,
  AuthService auth,
  ProfilesService profiles,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  return _json(200, await profiles.listFollowing(user.id));
}

Future<Response> _blocked(
  Request request,
  AuthService auth,
  ProfilesService profiles,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  return _json(200, await profiles.listBlocked(user.id));
}

Future<Response> _muted(
  Request request,
  AuthService auth,
  ProfilesService profiles,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  return _json(200, await profiles.listMuted(user.id));
}

Future<Response> _profile(
  Request request,
  String handle,
  AuthService auth,
  ProfilesService profiles,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  return _json(200, await profiles.getProfile(user.id, handle));
}

typedef _ProfileChange = Future<Map<String, String>> Function(
  String viewerId,
  String handle,
);

Future<Response> _change(
  Request request,
  String handle,
  AuthService auth,
  ProfilesService profiles,
  _ProfileChange operation, {
  int statusCode = 201,
}) async {
  final user = await requireAuthenticatedUser(request, auth);
  return _json(statusCode, await operation(user.id, handle));
}

Response _json(int statusCode, Object value) => Response(
  statusCode,
  body: jsonEncode(value),
  headers: const {'content-type': 'application/json; charset=utf-8'},
);
