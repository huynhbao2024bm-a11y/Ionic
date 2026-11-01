import 'package:postgres/postgres.dart';

import '../database/database_service.dart';

/// All preference writers take this lock; reset never replays domain actions.
Future<void> lockPreference(TxSession tx, String userId) async {
  await tx.execute(
    r'INSERT INTO user_recommendation_setting(user_id) VALUES ($1) ON CONFLICT DO NOTHING',
    parameters: [userId],
  );
  await tx.execute(
    r'SELECT user_id FROM user_recommendation_setting WHERE user_id = $1 FOR UPDATE',
    parameters: [userId],
  );
}

class PreferenceEvidenceService {
  /// Refresh only after invalidation/expiry. Must precede a fresh feed clock.
  Future<bool> refresh(
    DatabaseService database,
    String userId,
    double halfLifeMs,
  ) async {
    final needed = await database.query(_needsRefresh, parameters: [userId]);
    if (needed.isEmpty || needed.first.first != true) return false;
    return database.transaction((tx) async {
      await lockPreference(tx, userId);
      final again = await tx.execute(_needsRefresh, parameters: [userId]);
      if (again.first.first != true) return false;
      await rebuild(tx, userId, halfLifeMs);
      return true;
    });
  }

  static const _needsRefresh = r'''SELECT
    EXISTS (SELECT 1 FROM user_recommendation_setting WHERE user_id=$1 AND evidence_dirty)
    OR EXISTS (SELECT 1 FROM user_preference_baseline WHERE user_id=$1 AND expires_at<=now())
    OR EXISTS (SELECT 1 FROM user_preference_evidence e JOIN content c ON c.id=e.content_id
      WHERE e.user_id=$1 AND (e.expires_at<=now() OR e.source_updated_at<>c.updated_at
        OR c.deleted_at IS NOT NULL OR c.status<>'published' OR c.visibility<>'public'))''';

  /// Contributions are bounded, reversible and decayed independently. Confidence
  /// is the strongest remaining source, never an invented action-count probability.
  Future<void> rebuild(TxSession tx, String userId, double halfLifeMs) async {
    await tx.execute(
      r'''DELETE FROM user_preference_evidence e USING content c
      WHERE e.content_id=c.id AND e.user_id=$1 AND (e.expires_at<=now()
        OR e.source_updated_at<>c.updated_at OR c.deleted_at IS NOT NULL
        OR c.status<>'published' OR c.visibility<>'public')''',
      parameters: [userId],
    );
    await tx.execute(
      r'DELETE FROM user_preference_baseline WHERE user_id=$1 AND expires_at<=now()',
      parameters: [userId],
    );
    // Bound whole actions, not individual labels in a snapshot.
    await tx.execute(
      r'''WITH keep AS (SELECT content_id, kind, max(occurred_at) AS at
        FROM user_preference_evidence WHERE user_id=$1 GROUP BY content_id,kind
        ORDER BY at DESC,content_id,kind LIMIT 512)
      DELETE FROM user_preference_evidence e WHERE e.user_id=$1 AND NOT EXISTS
        (SELECT 1 FROM keep k WHERE k.content_id=e.content_id AND k.kind=e.kind)''',
      parameters: [userId],
    );
    await tx.execute(
      r'DELETE FROM user_preference_feature WHERE user_id=$1',
      parameters: [userId],
    );
    await tx.execute(
      r'''WITH sources AS (
        SELECT taxonomy_version,dimension,label_id,score::double precision AS score,
          confidence::double precision AS confidence,source_summary,updated_at AS at,expires_at
        FROM user_preference_baseline WHERE user_id=$1
        UNION ALL
        SELECT taxonomy_version,dimension,label_id,contribution::double precision,
          confidence::double precision,ARRAY[kind],occurred_at,expires_at
        FROM user_preference_evidence WHERE user_id=$1
      ), decayed AS (
        SELECT *,power(2::double precision,
          -greatest(0,extract(epoch FROM (now()-at))*1000)/$2::double precision) AS decay FROM sources
      ), totals AS (
        SELECT taxonomy_version,dimension,label_id,greatest(-1,least(1,sum(score*decay))) AS score,
          max(confidence*decay) AS confidence,max(expires_at) AS expires_at
        FROM decayed GROUP BY taxonomy_version,dimension,label_id
      )
      INSERT INTO user_preference_feature
        (user_id,taxonomy_version,dimension,label_id,score,confidence,source_summary,updated_at,expires_at)
      SELECT $1,t.taxonomy_version,t.dimension,t.label_id,t.score,t.confidence,
        ARRAY(SELECT DISTINCT unnest(d.source_summary) FROM decayed d
          WHERE d.taxonomy_version=t.taxonomy_version AND d.dimension=t.dimension AND d.label_id=t.label_id),
        now(),t.expires_at FROM totals t''',
      parameters: [userId, halfLifeMs],
    );
    await tx.execute(
      r'UPDATE user_recommendation_setting SET evidence_dirty=false,updated_at=now() WHERE user_id=$1',
      parameters: [userId],
    );
  }
}
