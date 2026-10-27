import 'dart:convert';

import 'package:ionic_server/src/http/api_exception.dart';
import 'package:ionic_server/src/http/request_body.dart';
import 'package:ionic_server/src/modules/auth/auth_routes.dart';
import 'package:ionic_server/src/modules/auth/auth_service.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/recommendation/recommendation_service.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

Handler createRecommendationRoutes(DatabaseService database) {
  final auth = AuthService(database);
  final recommendation = RecommendationService(database);
  final router = Router()
    ..get(
      '/for-you',
      (Request request) => _forYou(request, auth, recommendation),
    )
    ..get(
      '/settings',
      (Request request) => _settings(request, auth, recommendation),
    )
    ..patch(
      '/settings',
      (Request request) => _updateSettings(request, auth, recommendation),
    )
    ..post('/reset', (Request request) => _reset(request, auth, recommendation))
    ..post(
      '/<contentId>/preference',
      (Request request, String contentId) =>
          _setPreference(request, contentId, auth, recommendation),
    )
    ..post(
      '/<contentId>/hide',
      (Request request, String contentId) =>
          _hide(request, contentId, auth, recommendation),
    )
    ..post(
      '/<contentId>/video-signal',
      (Request request, String contentId) =>
          _recordVideoSignal(request, contentId, auth, recommendation),
    );
  return router.call;
}

Future<Response> _forYou(
  Request request,
  AuthService auth,
  RecommendationService recommendation,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  final rawLimit = request.url.queryParameters['limit'];
  final limit = rawLimit == null ? 20 : int.tryParse(rawLimit);
  if (limit == null || limit < 1 || limit > 50) {
    throw const ApiException(400, 'Limit must be an integer between 1 and 50.');
  }
  final value = await recommendation.forYou(
    user.id,
    limit,
    request.url.queryParameters['cursor'],
  );
  return _json(200, value);
}

Future<Response> _settings(
  Request request,
  AuthService auth,
  RecommendationService recommendation,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  return _json(200, await recommendation.settings(user.id));
}

Future<Response> _updateSettings(
  Request request,
  AuthService auth,
  RecommendationService recommendation,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  return _json(
    200,
    await recommendation.updateSettings(user.id, await readJsonObject(request)),
  );
}

Future<Response> _reset(
  Request request,
  AuthService auth,
  RecommendationService recommendation,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  return _json(201, await recommendation.reset(user.id));
}

Future<Response> _setPreference(
  Request request,
  String contentId,
  AuthService auth,
  RecommendationService recommendation,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  return _json(
    201,
    await recommendation.setPreference(
      user.id,
      contentId,
      await readJsonObject(request),
    ),
  );
}

Future<Response> _hide(
  Request request,
  String contentId,
  AuthService auth,
  RecommendationService recommendation,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  return _json(201, await recommendation.hide(user.id, contentId));
}

Future<Response> _recordVideoSignal(
  Request request,
  String contentId,
  AuthService auth,
  RecommendationService recommendation,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  return _json(
    201,
    await recommendation.recordVideoSignal(
      user.id,
      contentId,
      await readJsonObject(request),
    ),
  );
}

Response _json(int statusCode, Object value) => Response(
  statusCode,
  body: jsonEncode(value),
  headers: const {'content-type': 'application/json; charset=utf-8'},
);
