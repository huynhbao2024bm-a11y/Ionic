import 'dart:convert';

import 'package:ionic_server/src/http/request_body.dart';
import 'package:ionic_server/src/modules/auth/auth_routes.dart';
import 'package:ionic_server/src/modules/auth/auth_service.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/trust/reports_service.dart';
import 'package:ionic_server/src/modules/trust/moderation_service.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

Handler createReportsRoutes(DatabaseService database) {
  final auth = AuthService(database);
  final reports = ReportsService(database);
  final moderation = ModerationService(database);
  final router = Router()
    ..get(
      '/reviewer',
      (Request request) async => _json(200, {
        'enabled': await moderation.isReviewer(
          (await requireAuthenticatedUser(request, auth)).id,
        ),
      }),
    )
    ..get(
      '/queue',
      (Request request) async => _json(
        200,
        await moderation.queue(
          (await requireAuthenticatedUser(request, auth)).id,
          request.url.queryParameters['cursor'],
        ),
      ),
    )
    ..post('/<reportId>/resolve', (Request request, String reportId) async {
      await moderation.resolve(
        (await requireAuthenticatedUser(request, auth)).id,
        reportId,
        await readJsonObject(request),
      );
      return _json(200, {'status': 'resolved'});
    })
    ..post('/', (Request request) async {
      final user = await requireAuthenticatedUser(request, auth);
      final report = await reports.create(
        user.id,
        await readJsonObject(request),
      );
      return Response(
        201,
        body: jsonEncode(report),
        headers: const {
          'content-type': 'application/json; charset=utf-8',
          'cache-control': 'no-store',
        },
      );
    });
  return router.call;
}

Response _json(int status, Object body) => Response(
  status,
  body: jsonEncode(body),
  headers: const {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  },
);
