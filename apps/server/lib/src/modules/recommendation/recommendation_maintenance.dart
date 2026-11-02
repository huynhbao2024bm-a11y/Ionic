import 'dart:async';
import 'dart:io';

import '../database/database_service.dart';
import 'adaptive_feedback.dart';
import '../media/media_cleanup_service.dart';
import '../trust/moderation_service.dart';
import '../health/preview_heartbeat.dart';

/// Model-independent minute sweep. Logical expiry is enforced by reads even
/// when maintenance is delayed; larger queues can use the same bounded CLI.
class RecommendationMaintenance {
  RecommendationMaintenance(this.database);
  final DatabaseService database;
  Timer? _timer;
  Future<void>? _running;
  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => sweep());
    sweep();
  }

  Future<void> sweep() async {
    if (_running != null) return;
    final work = _sweep();
    _running = work;
    try {
      await work;
    } finally {
      _running = null;
    }
  }

  Future<void> _sweep() async {
    try {
      if (await database.checkReadiness() != DatabaseReadiness.ready) return;
      await AdaptiveFeedbackService(database).cleanupExpired();
      await ModerationService(database).cleanupExpired();
      await PreviewHeartbeatService(database).expire();
      final media = MediaCleanupService(database);
      await media.expireStaging();
      await media.drainBestEffort();
    } catch (error) {
      stderr.writeln(
        'Recommendation expiry cleanup failed: ${error.runtimeType}',
      );
    }
  }

  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    await _running;
  }
}
