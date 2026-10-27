import 'dart:convert';
import 'dart:io';

import 'package:ionic_server/src/http/api_exception.dart';
import 'package:ionic_server/src/modules/auth/auth_routes.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/health/health_routes.dart';
import 'package:ionic_server/src/modules/messages/messages_routes.dart';
import 'package:ionic_server/src/modules/media/media_routes.dart';
import 'package:ionic_server/src/modules/posts/posts_routes.dart';
import 'package:ionic_server/src/modules/profiles/profiles_routes.dart';
import 'package:ionic_server/src/modules/recommendation/recommendation_routes.dart';
import 'package:ionic_server/src/modules/trust/reports_routes.dart';
import 'package:ionic_server/src/modules/videos/videos_routes.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

Handler createApp({
  required DatabaseService database,
  required Set<String> allowedOrigins,
}) {
  final api = Router()
    ..mount('/health', createHealthRoutes(database))
    ..mount('/auth', createAuthRoutes(database))
    ..mount('/feed', createRecommendationRoutes(database))
    ..mount('/posts', createPostsRoutes(database))
    ..mount('/media', createMediaRoutes(database))
    ..mount('/profiles', createProfilesRoutes(database))
    ..mount('/messages', createMessagesRoutes(database))
    ..mount('/reports', createReportsRoutes(database));
  if (Platform.environment['FEATURE_VIDEO_ENABLED'] == 'true') {
    api.mount('/videos', createVideosRoutes(database));
  }
  final router = Router()
    ..mount('/api/v1/', api.call)
    ..all('/<ignored|.*>', _notFound);

  return const Pipeline()
      .addMiddleware(_errorBoundary())
      .addMiddleware(_originAndCors(allowedOrigins))
      .addHandler(router.call);
}

Middleware _errorBoundary() =>
    (Handler inner) => (Request request) async {
      try {
        return await inner(request);
      } on ApiException catch (error) {
        return apiErrorResponse(error);
      } catch (error) {
        stderr.writeln('Unhandled API error: ${error.runtimeType}');
        return _jsonResponse(500, const {
          'statusCode': 500,
          'error': 'Internal Server Error',
          'message': 'Request failed.',
        });
      }
    };

Middleware _originAndCors(Set<String> allowedOrigins) =>
    (Handler inner) => (Request request) async {
      final origin = request.headers['origin'];
      final isWrite = !const {
        'GET',
        'HEAD',
        'OPTIONS',
      }.contains(request.method.toUpperCase());
      if (origin != null && isWrite && !allowedOrigins.contains(origin)) {
        return _jsonResponse(403, const {
          'statusCode': 403,
          'error': 'Forbidden',
          'message': 'Origin is not allowed.',
        });
      }

      if (request.method == 'OPTIONS') {
        return Response(204, headers: _corsHeaders(origin, allowedOrigins));
      }

      final response = await inner(request);
      return response.change(
        headers: {...response.headers, ..._corsHeaders(origin, allowedOrigins)},
      );
    };

Map<String, String> _corsHeaders(String? origin, Set<String> allowedOrigins) {
  if (origin == null || !allowedOrigins.contains(origin)) return const {};
  return {
    'access-control-allow-origin': origin,
    'access-control-allow-credentials': 'true',
    'access-control-allow-methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
    'access-control-allow-headers':
        'Content-Type, X-CSRF-Token, X-Ionic-Caption, X-Ionic-Media-Type',
    'vary': 'Origin',
  };
}

Response _jsonResponse(int statusCode, Object body) => Response(
  statusCode,
  body: jsonEncode(body),
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Response _notFound(Request request) => _jsonResponse(404, const {
  'statusCode': 404,
  'error': 'Not Found',
  'message': 'Route not found.',
});
