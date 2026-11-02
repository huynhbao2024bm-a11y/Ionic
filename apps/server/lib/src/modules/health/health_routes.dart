import 'dart:convert';

import 'package:ionic_server/src/modules/database/database_service.dart';

import '../auth/auth_service.dart';
import '../auth/auth_routes.dart';
import 'preview_heartbeat.dart';
import '../../http/request_body.dart';
import '../../http/api_exception.dart';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

Handler createHealthRoutes(DatabaseService database) {
  final auth = AuthService(database),
      heartbeat = PreviewHeartbeatService(database);
  final router = Router()
    ..get(
      '/heartbeat-permission',
      (Request request) async => _json(200, {
        'enabled': await heartbeat.allowed(
          (await requireAuthenticatedUser(request, auth)).id,
        ),
        'intervalSeconds': 600,
      }),
    )
    ..post('/heartbeat-lease', (Request request) async {
      final user = await requireAuthenticatedUser(request, auth),
          token = await _leaseToken(request);
      return _json(200, await heartbeat.claim(user.id, previousToken: token));
    })
    ..post('/heartbeat', (Request request) async {
      final user = await requireAuthenticatedUser(request, auth);
      await heartbeat.ping(user.id, leaseToken: await _leaseToken(request));
      return _json(200, {'status': 'ok'});
    })
    ..post('/heartbeat-release', (Request request) async {
      final user = await requireAuthenticatedUser(request, auth);
      await heartbeat.release(user.id, await _leaseToken(request));
      return _json(200, {'status': 'released'});
    })
    ..get('/live', _liveness)
    ..get('/ready', (Request request) => _readiness(database));
  return router.call;
}

Future<String?> _leaseToken(Request request) async {
  final input = await readJsonObject(request), token = input['leaseToken'];
  if (input.keys.any((k) => k != 'leaseToken') ||
      (token != null && (token is! String || token.length > 64))) {
    throw const ApiException(400, 'Heartbeat lease is invalid.');
  }
  return token as String?;
}

Response _liveness(Request request) => _json(200, const {'status': 'ok'});

Future<Response> _readiness(DatabaseService database) async {
  final readiness = await database.checkReadiness();
  final isReady = readiness == DatabaseReadiness.ready;
  return _json(isReady ? 200 : 503, {
    'status': isReady ? 'ready' : 'not_ready',
    'dependencies': {'database': _readinessLabel(readiness)},
  });
}

String _readinessLabel(DatabaseReadiness readiness) => switch (readiness) {
  DatabaseReadiness.ready => 'ready',
  DatabaseReadiness.unconfigured => 'unconfigured',
  DatabaseReadiness.unavailable => 'unavailable',
  DatabaseReadiness.schemaPending => 'schema_pending',
};

Response _json(int statusCode, Object body) => Response(
  statusCode,
  body: jsonEncode(body),
  headers: const {'content-type': 'application/json; charset=utf-8'},
);
