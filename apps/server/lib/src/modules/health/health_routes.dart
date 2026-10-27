import 'dart:convert';

import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

Handler createHealthRoutes(DatabaseService database) {
  final router = Router()
    ..get('/live', _liveness)
    ..get('/ready', (Request request) => _readiness(database));
  return router.call;
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
