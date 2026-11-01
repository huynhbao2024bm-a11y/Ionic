import 'dart:io';

import 'package:ionic_server/src/app.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:ionic_server/src/modules/recommendation/recommendation_maintenance.dart';

Future<void> main() async {
  final port = _readPort(Platform.environment['PORT']);
  final isProduction = Platform.environment['APP_ENV'] == 'production';
  final host =
      Platform.environment['HOST'] ?? (isProduction ? '0.0.0.0' : '127.0.0.1');
  final allowedOrigins =
      (Platform.environment['WEB_ORIGINS'] ?? 'http://127.0.0.1:4200')
          .split(',')
          .map((origin) => origin.trim())
          .where((origin) => origin.isNotEmpty)
          .toSet();
  final database = DatabaseService.fromEnvironment();
  final maintenance = RecommendationMaintenance(database)..start();

  final server = await shelf_io.serve(
    createApp(database: database, allowedOrigins: allowedOrigins),
    host,
    port,
  );
  server.autoCompress = true;
  stdout.writeln(
    'Ionic Dart API listening on http://${server.address.host}:${server.port}',
  );

  var stopping = false;
  Future<void> shutdown() async {
    if (stopping) return;
    stopping = true;
    await server.close();
    await maintenance.close();
    await database.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen((_) => shutdown());
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) => shutdown());
  }
}

int _readPort(String? value) {
  final port = value == null ? 3001 : int.tryParse(value);
  if (port == null || port < 1 || port > 65535) {
    throw StateError('PORT must be an integer between 1 and 65535.');
  }
  return port;
}
