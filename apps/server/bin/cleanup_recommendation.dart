import 'dart:io';

import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/recommendation/preference_evidence.dart';
import 'package:ionic_server/src/modules/recommendation/ranker_config.dart';
import 'package:ionic_server/src/modules/recommendation/adaptive_feedback.dart';

/// Bounded, model-independent maintenance; schedule before a public release.
Future<void> main() async {
  final db = DatabaseService.fromEnvironment();
  try {
    final users = await db.query('''SELECT user_id FROM (
      SELECT user_id FROM user_recommendation_setting WHERE evidence_dirty
      UNION SELECT user_id FROM user_preference_evidence WHERE expires_at<=now()
      UNION SELECT user_id FROM user_preference_baseline WHERE expires_at<=now()
    ) due ORDER BY user_id LIMIT 100''');
    var count = 0;
    final halfLife = buildRankerConfig(
      DateTime.now().millisecondsSinceEpoch.toDouble(),
    ).preferenceHalfLifeMs;
    for (final user in users) {
      if (await PreferenceEvidenceService().refresh(
        db,
        '${user.first}',
        halfLife,
      )) {
        count++;
      }
    }
    stdout.writeln(
      'Refreshed $count preference profiles; rerun if 100 were returned.',
    );
    stdout.writeln(
      'Removed ${await AdaptiveFeedbackService(db).cleanupExpired()} expired adaptive records; rerun when a table returns its 2000-row cap.',
    );
  } finally {
    await db.close();
  }
}
