import 'dart:io';

import '../database/database_service.dart';
import 'attachment_storage.dart';

/// Durable local-storage deletion queue. Only server-generated UUID keys are
/// resolved under the configured roots. Failed files stay queued for retry.
class MediaCleanupService {
  MediaCleanupService(this.database);
  final DatabaseService database;

  Future<void> drainBestEffort() async {
    try {
      await drain();
    } catch (_) {
      /* Durable jobs remain for retry. */
    }
  }

  Future<int> drain() async => database.transaction((tx) async {
    final jobs = await tx.execute(
      '''SELECT storage_kind, storage_key FROM media_deletion_job
      ORDER BY created_at LIMIT 100 FOR UPDATE SKIP LOCKED''',
    );
    var removed = 0;
    for (final job in jobs) {
      final kind = '${job[0]}';
      final key = '${job[1]}';
      if (!RegExp(r'^[a-f0-9-]{36}$').hasMatch(key)) continue;
      final root = Directory(
        kind == 'attachment'
            ? Platform.environment['IONIC_ATTACHMENT_DIR'] ??
                  '.data/attachments'
            : Platform.environment['IONIC_MEDIA_DIR'] ?? '.data/media',
      ).absolute.path;
      try {
        if (kind == 'attachment') {
          await AttachmentStorage.fromEnvironment().delete(key);
        } else {
          for (final suffix in ['', '.part']) {
            final file = File('$root${Platform.pathSeparator}$key$suffix');
            if (await file.exists()) await file.delete();
          }
        }
        await tx.execute(
          r'DELETE FROM media_deletion_job WHERE storage_kind = $1 AND storage_key = $2',
          parameters: [kind, key],
        );
        removed++;
      } catch (_) {
        /* Keep the durable job for a later storage retry. */
      }
    }
    return removed;
  });

  Future<void> expireStaging() async {
    await database.query('''DELETE FROM media_asset WHERE id IN(
      SELECT a.id FROM media_asset a WHERE a.created_at<now()-interval '24 hours'
        AND NOT EXISTS(SELECT 1 FROM content_attachment c WHERE c.media_asset_id=a.id)
      ORDER BY a.created_at LIMIT 100 FOR UPDATE SKIP LOCKED)''');
  }
}
