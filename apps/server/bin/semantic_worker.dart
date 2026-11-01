import 'dart:async';
import 'dart:io';

import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/recommendation/semantic_worker.dart';

Future<void> main(List<String> args) async {
  if (args.any((a) => a != '--watch')) {
    throw ArgumentError('Only --watch is supported.');
  }
  final db = DatabaseService.fromEnvironment();
  LocalTextEmbedder? embedder;
  var stopping = false;
  final signals = <StreamSubscription<ProcessSignal>>[];
  for (final signal in [
    ProcessSignal.sigint,
    if (!Platform.isWindows) ProcessSignal.sigterm,
  ]) {
    signals.add(
      signal.watch().listen((_) {
        stopping = true;
      }),
    );
  }
  try {
    embedder = await LocalTextEmbedder.start();
    final worker = SemanticWorker(db, embedder);
    do {
      final count = await worker.runBatch();
      if (count > 0) stdout.writeln('Embedded $count public posts.');
      if (!args.contains('--watch')) break;
      if (count == 0) await Future<void>.delayed(const Duration(seconds: 5));
    } while (!stopping);
  } finally {
    for (final signal in signals) {
      await signal.cancel();
    }
    await embedder?.close();
    await db.close();
  }
}
