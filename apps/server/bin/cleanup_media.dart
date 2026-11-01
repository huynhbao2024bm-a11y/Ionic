import 'dart:io';

import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/media/media_cleanup_service.dart';

Future<void> main() async {
  final database = DatabaseService.fromEnvironment();
  try {
    final removed = await MediaCleanupService(database).drain();
    stdout.writeln('Completed $removed queued media deletions.');
  } finally {
    await database.close();
  }
}
