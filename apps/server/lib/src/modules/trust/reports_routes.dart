import 'dart:convert';

import 'package:ionic_server/src/http/request_body.dart';
import 'package:ionic_server/src/modules/auth/auth_routes.dart';
import 'package:ionic_server/src/modules/auth/auth_service.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/trust/reports_service.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

Handler createReportsRoutes(DatabaseService database) {
  final auth = AuthService(database);
  final reports = ReportsService(database);
  final router = Router()
    ..post('/', (Request request) async {
      final user = await requireAuthenticatedUser(request, auth);
      final report = await reports.create(
        user.id,
        await readJsonObject(request),
      );
      return Response(
        201,
        body: jsonEncode(report),
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    });
  return router.call;
}
