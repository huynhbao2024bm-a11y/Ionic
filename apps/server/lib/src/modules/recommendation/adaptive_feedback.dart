import 'dart:convert';
import 'dart:math' as math;

import 'package:postgres/postgres.dart';

import '../../http/api_exception.dart';
import '../database/database_service.dart';
import 'adaptive_policy.dart';
import 'preference_evidence.dart';
import 'semantic_config.dart';

String recommendationUuid() {
  final random = math.Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final h = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

class AdaptiveContext {
  const AdaptiveContext({
    required this.sequence,
    required this.paused,
    required this.interest,
    required this.topicInterest,
    required this.lastTopicSequence,
  });
  final int sequence;
  final bool paused;
  final InterestEstimate interest;
  final Map<String, InterestEstimate> topicInterest;
  final Map<String, int> lastTopicSequence;
}

class AdaptiveFeedbackService {
  AdaptiveFeedbackService(this.database);
  final DatabaseService database;

  Future<AdaptiveContext> loadContext(TxSession tx, String userId) async {
    final modelVersion = SemanticConfig().enabled ? semanticModelVersion : '';
    final setting = await tx.execute(
      r'SELECT learning_paused,delivery_sequence FROM user_recommendation_setting WHERE user_id=$1',
      parameters: [userId],
    );
    final rows = await tx.execute(
      r'''SELECT DISTINCT ON(s.content_id) s.content_id,s.topic_ids,s.reward,s.updated_at,
      EXISTS(SELECT 1 FROM user_preference_evidence e WHERE e.user_id=$1 AND e.content_id=c.id AND e.source_updated_at=c.updated_at AND e.expires_at>now()) AS positive,
      EXISTS(SELECT 1 FROM feed_content_hide h WHERE h.user_id=$1 AND h.content_id=c.id) OR
      EXISTS(SELECT 1 FROM recommendation_item_feedback f WHERE f.user_id=$1 AND f.content_id=c.id AND f.source_updated_at=c.updated_at AND f.preference='less') AS negative,
      EXISTS(SELECT 1 FROM content_semantic_feature v WHERE v.content_id=c.id AND v.source_updated_at=c.updated_at AND v.model_version=$2) AS has_semantic
      FROM recommendation_attention_summary s JOIN content c ON c.id=s.content_id AND c.updated_at=s.source_updated_at
      JOIN app_user u ON u.id=c.author_id AND u.state='active' JOIN user_profile p ON p.user_id=u.id
      WHERE s.user_id=$1 AND s.expires_at>now() AND c.author_id<>$1 AND c.kind='text' AND c.visibility='public' AND c.status='published' AND c.deleted_at IS NULL
        AND (p.visibility='public' OR EXISTS(SELECT 1 FROM account_follow f WHERE f.follower_id=$1 AND f.followed_id=u.id))
        AND NOT EXISTS(SELECT 1 FROM account_block b WHERE (b.blocker_id=$1 AND b.blocked_id=u.id) OR (b.blocker_id=u.id AND b.blocked_id=$1))
        AND NOT EXISTS(SELECT 1 FROM account_mute m WHERE m.muter_id=$1 AND m.muted_id=u.id)
      ORDER BY s.content_id,s.updated_at DESC LIMIT 512''',
      parameters: [userId, modelVersion],
    );
    final totals = <String, List<double>>{}, last = <String, int>{};
    var evidence = 0.0, reward = 0.0;
    final representedPositive = rows
        .where(
          (row) =>
              row.toColumnMap()['has_semantic'] == true &&
              (row.toColumnMap()['reward'] as num) >= .65,
        )
        .length;
    for (final row in rows) {
      final r = row.toColumnMap();
      final age = math.max(
        0,
        DateTime.now().difference(r['updated_at'] as DateTime).inMilliseconds,
      );
      final decay = math.pow(2, -age / (7 * 86400000)).toDouble();
      final outcome = r['negative'] == true
          ? 0.0
          : r['positive'] == true
          ? 0.95
          : (r['reward'] as num).toDouble();
      if ((r['topic_ids'] as List).isNotEmpty ||
          (r['has_semantic'] == true && representedPositive >= 2)) {
        evidence += decay;
        reward += outcome * decay;
      }
      for (final topic in (r['topic_ids'] as List).cast<String>()) {
        final t = totals.putIfAbsent(topic, () => [0, 0]);
        t[0] += decay;
        t[1] += outcome * decay;
      }
    }
    final explicit = await tx.execute(
      r'''SELECT count(DISTINCT e.content_id)::int FROM user_preference_evidence e
      JOIN content c ON c.id=e.content_id AND c.updated_at=e.source_updated_at
      JOIN app_user u ON u.id=c.author_id AND u.state='active' JOIN user_profile p ON p.user_id=u.id
      WHERE e.user_id=$1 AND e.expires_at>now() AND c.deleted_at IS NULL AND c.status='published' AND c.kind='text' AND c.visibility='public' AND c.author_id<>$1
        AND (p.visibility='public' OR EXISTS(SELECT 1 FROM account_follow f WHERE f.follower_id=$1 AND f.followed_id=u.id))
        AND NOT EXISTS(SELECT 1 FROM account_block b WHERE (b.blocker_id=$1 AND b.blocked_id=u.id) OR (b.blocker_id=u.id AND b.blocked_id=$1))
        AND NOT EXISTS(SELECT 1 FROM account_mute m WHERE m.muter_id=$1 AND m.muted_id=u.id)
        AND NOT EXISTS(SELECT 1 FROM feed_content_hide h WHERE h.user_id=$1 AND h.content_id=c.id)
        AND (e.dimension IN ('topic','context') OR EXISTS(SELECT 1 FROM content_semantic_feature v WHERE v.content_id=c.id AND v.source_updated_at=c.updated_at AND v.model_version=$2)) ''',
      parameters: [userId, modelVersion],
    );
    final accepted = (explicit.first.first as int).clamp(0, 32).toDouble();
    evidence += accepted;
    reward += accepted * .9;
    final issued = await tx.execute(
      r'''SELECT topic_ids,delivery_sequence FROM recommendation_delivery_receipt
      WHERE user_id=$1 AND issued_at>now()-interval '24 hours' AND expires_at>now()
      ORDER BY delivery_sequence DESC LIMIT 2000''',
      parameters: [userId],
    );
    for (final row in issued) {
      for (final topic in (row[0] as List).cast<String>()) {
        last.putIfAbsent(topic, () => (row[1] as num).toInt());
      }
    }
    return AdaptiveContext(
      sequence: (setting.first[1] as num).toInt(),
      paused: setting.first[0] == true,
      interest: InterestEstimate(evidence: evidence, rewardTotal: reward),
      topicInterest: {
        for (final e in totals.entries)
          e.key: InterestEstimate(
            evidence: e.value[0],
            rewardTotal: e.value[1],
          ),
      },
      lastTopicSequence: last,
    );
  }

  Future<Map<String, Object?>> record(
    String userId,
    Map<String, Object?> input,
  ) async {
    if (input.length != 1 || input['items'] is! List) {
      throw const ApiException(400, 'Attention batch is invalid.');
    }
    final items = input['items'] as List;
    if (items.isEmpty || items.length > 20) {
      throw const ApiException(400, 'Attention batch must contain 1–20 items.');
    }
    final parsed = <Map<String, String>>[];
    for (final value in items) {
      if (value is! Map ||
          value.length != 2 ||
          value['receiptId'] is! String ||
          !RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ).hasMatch(value['receiptId'] as String) ||
          !AttentionBand.values.any((b) => b.name == value['band'])) {
        throw const ApiException(400, 'Attention item is invalid.');
      }
      parsed.add({
        'id': value['receiptId'] as String,
        'band': value['band'] as String,
      });
    }
    return database.transaction((tx) async {
      await lockPreference(tx, userId);
      final setting = await tx.execute(
        r'SELECT learning_paused FROM user_recommendation_setting WHERE user_id=$1',
        parameters: [userId],
      );
      if (setting.first.first == true) {
        return {'status': 'paused', 'accepted': 0};
      }
      var accepted = 0;
      final changed = <String>{};
      // Stable locking order; duplicate receipt updates are monotonic/idempotent.
      parsed.sort((a, b) => a['id']!.compareTo(b['id']!));
      for (final item in parsed) {
        final rows = await tx.execute(
          r'''SELECT r.*,c.author_id FROM recommendation_delivery_receipt r
          JOIN content c ON c.id=r.content_id AND c.updated_at=r.source_updated_at
          JOIN app_user u ON u.id=c.author_id AND u.state='active' JOIN user_profile p ON p.user_id=u.id
          WHERE r.id=$1 AND r.user_id=$2 AND r.measurement_enabled AND r.expires_at>now() AND c.kind='text' AND c.visibility='public'
            AND c.status='published' AND c.deleted_at IS NULL AND c.author_id<>$2
            AND (p.visibility='public' OR EXISTS(SELECT 1 FROM account_follow f WHERE f.follower_id=$2 AND f.followed_id=u.id))
            AND NOT EXISTS(SELECT 1 FROM account_block b WHERE (b.blocker_id=$2 AND b.blocked_id=u.id) OR (b.blocker_id=u.id AND b.blocked_id=$2))
            AND NOT EXISTS(SELECT 1 FROM account_mute m WHERE m.muter_id=$2 AND m.muted_id=u.id)
            AND NOT EXISTS(SELECT 1 FROM feed_content_hide h WHERE h.user_id=$2 AND h.content_id=c.id)
          FOR UPDATE OF r''',
          parameters: [item['id'], userId],
        );
        if (rows.isEmpty) {
          continue; // No access/expired/self: no evidence, no details.
        }
        final r = rows.first.toColumnMap();
        final band = AttentionBand.values.byName(item['band']!);
        if ((r['attention_band'] as int) >= band.index) continue;
        if (DateTime.now()
                    .difference(r['issued_at'] as DateTime)
                    .inMilliseconds +
                250 <
            attentionLowerBoundMs[band]!) {
          continue;
        }
        await tx.execute(
          r'UPDATE recommendation_delivery_receipt SET attention_band=$2,observed_at=now() WHERE id=$1',
          parameters: [item['id'], band.index],
        );
        final reward = attentionReward(
          band,
          textCharacters: r['text_characters'] as int,
          hasMedia: r['has_media'] == true,
        );
        await tx.execute(
          r'''INSERT INTO recommendation_attention_summary
          (user_id,content_id,summary_day,source_updated_at,topic_ids,reward,random_reward,last_sequence)
          VALUES($1,$2,(now() AT TIME ZONE 'UTC')::date,$3,$4,$5,$6,$7)
          ON CONFLICT(user_id,content_id,summary_day) DO UPDATE SET
            source_updated_at=EXCLUDED.source_updated_at,topic_ids=EXCLUDED.topic_ids,
            reward=CASE WHEN recommendation_attention_summary.source_updated_at=EXCLUDED.source_updated_at THEN greatest(recommendation_attention_summary.reward,EXCLUDED.reward) ELSE EXCLUDED.reward END,
            random_reward=CASE WHEN recommendation_attention_summary.source_updated_at=EXCLUDED.source_updated_at THEN greatest(recommendation_attention_summary.random_reward,EXCLUDED.random_reward) ELSE EXCLUDED.random_reward END,
            last_sequence=greatest(recommendation_attention_summary.last_sequence,EXCLUDED.last_sequence),
            updated_at=now(),expires_at=now()+interval '30 days' ''',
          parameters: [
            userId,
            r['content_id'],
            r['source_updated_at'],
            r['topic_ids'],
            reward,
            r['is_random'] == true ? reward : null,
            r['delivery_sequence'],
          ],
        );
        changed.add('${r['content_id']}');
        accepted++;
      }
      if (changed.isNotEmpty) {
        await tx.execute(
          r'UPDATE recommendation_post_distribution SET dirty=true WHERE content_id=ANY($1::uuid[])',
          parameters: [changed.toList()..sort()],
        );
      }
      await pruneViewer(tx, userId);
      return {'status': 'recorded', 'accepted': accepted};
    });
  }

  Future<void> pruneViewer(TxSession tx, String userId) async {
    await tx.execute(
      r'''DELETE FROM recommendation_feed_plan WHERE user_id=$1 AND
      (expires_at<=now() OR id NOT IN(SELECT id FROM recommendation_feed_plan WHERE user_id=$1 ORDER BY created_at DESC,id LIMIT 4))''',
      parameters: [userId],
    );
    await tx.execute(
      r'''DELETE FROM recommendation_delivery_receipt WHERE user_id=$1 AND
      (expires_at<=now() OR id NOT IN(SELECT id FROM recommendation_delivery_receipt WHERE user_id=$1 ORDER BY issued_at DESC,id LIMIT 2000))''',
      parameters: [userId],
    );
    await tx.execute(
      r'''DELETE FROM recommendation_attention_summary WHERE user_id=$1 AND
      (expires_at<=now() OR (content_id,summary_day) NOT IN(SELECT content_id,summary_day FROM recommendation_attention_summary
        WHERE user_id=$1 ORDER BY updated_at DESC,content_id,summary_day LIMIT 512))''',
      parameters: [userId],
    );
  }

  Future<int> cleanupExpired() async {
    var removed = 0;
    for (final table in [
      'recommendation_feed_plan',
      'recommendation_delivery_receipt',
      'recommendation_attention_summary',
      'recommendation_audience_grant',
    ]) {
      final result = await database.query(
        'DELETE FROM $table WHERE ctid IN (SELECT ctid FROM $table WHERE expires_at<=now() ORDER BY expires_at LIMIT 2000) RETURNING 1',
      );
      removed += result.length;
    }
    return removed;
  }

  Future<Set<String>> reserveAudience(
    TxSession tx,
    String userId,
    List<String> ids,
    AdaptivePolicy policy,
  ) async {
    if (ids.isEmpty) return {};
    final sorted = ids.toSet().toList()..sort();
    final now = DateTime.now().toUtc(),
        windowMs = policy.audienceWindowMinutes * 60000;
    final start = DateTime.fromMillisecondsSinceEpoch(
      now.millisecondsSinceEpoch ~/ windowMs * windowMs,
      isUtc: true,
    );
    await tx.execute(
      r'''INSERT INTO recommendation_post_distribution(content_id,source_updated_at,window_start,allowance)
      SELECT id,updated_at,$2,$3 FROM content WHERE id=ANY($1::uuid[]) ON CONFLICT DO NOTHING''',
      parameters: [sorted, start, policy.audienceBase],
    );
    final locked = await tx.execute(
      r'''SELECT content_id,window_start,issued_unique FROM recommendation_post_distribution
      WHERE content_id=ANY($1::uuid[]) ORDER BY content_id FOR UPDATE''',
      parameters: [sorted],
    );
    final quality = await tx.execute(
      r'''WITH unique_readers AS (
      SELECT s.content_id,s.user_id,max(CASE
        WHEN EXISTS(SELECT 1 FROM feed_content_hide h WHERE h.user_id=s.user_id AND h.content_id=s.content_id)
          OR EXISTS(SELECT 1 FROM recommendation_item_feedback f WHERE f.user_id=s.user_id AND f.content_id=s.content_id AND f.source_updated_at=s.source_updated_at AND f.preference='less') THEN 0
        WHEN EXISTS(SELECT 1 FROM user_preference_evidence e WHERE e.user_id=s.user_id AND e.content_id=s.content_id AND e.source_updated_at=s.source_updated_at AND e.expires_at>now()) THEN .95
        ELSE s.random_reward END) AS reward,min(s.expires_at) AS expires
      FROM recommendation_attention_summary s JOIN content c ON c.id=s.content_id AND c.updated_at=s.source_updated_at
      JOIN app_user u ON u.id=s.user_id AND u.state='active'
      WHERE s.content_id=ANY($1::uuid[]) AND s.user_id<>c.author_id AND s.random_reward IS NOT NULL AND s.expires_at>now()
      GROUP BY s.content_id,s.user_id
    ) SELECT content_id,count(*)::int,sum(reward)::double precision,min(expires) FROM unique_readers GROUP BY content_id''',
      parameters: [sorted],
    );
    final estimates = {
      for (final r in quality)
        '${r[0]}': InterestEstimate(
          evidence: (r[1] as num).toDouble(),
          rewardTotal: (r[2] as num).toDouble(),
        ),
    };
    final expiry = {for (final r in quality) '${r[0]}': r[3] as DateTime};
    final own = (await tx.execute(
      r'SELECT id FROM content WHERE id=ANY($1::uuid[]) AND author_id=$2',
      parameters: [sorted, userId],
    )).map((r) => '${r.first}').toSet();
    final existing = await tx.execute(
      r'SELECT content_id FROM recommendation_audience_grant WHERE content_id=ANY($1::uuid[]) AND user_id=$2 AND window_start=$3 AND expires_at>now()',
      parameters: [sorted, userId, start],
    );
    final granted = existing.map((r) => '${r.first}').toSet(),
        allowed = <String>{},
        updates = <Map<String, Object?>>[];
    for (final r in locked) {
      final contentId = '${r[0]}';
      final decision = audienceDecision(
        estimates[contentId] ??
            const InterestEstimate(evidence: 0, rewardTotal: 0),
        policy,
      );
      final used = r[1] == start ? (r[2] as int) : 0;
      if (own.contains(contentId) ||
          used < decision.allowance ||
          granted.contains(contentId)) {
        allowed.add(contentId);
      }
      final windowEnd = start.add(
            Duration(minutes: policy.audienceWindowMinutes),
          ),
          sourceExpiry = expiry[contentId];
      updates.add({
        'id': contentId,
        'allowance': decision.allowance,
        'used': used,
        'score': decision.mean,
        'confidence': decision.confidence,
        'expires':
            (sourceExpiry != null && sourceExpiry.isBefore(windowEnd)
                    ? sourceExpiry
                    : windowEnd)
                .toIso8601String(),
      });
    }
    await tx.execute(
      r'''UPDATE recommendation_post_distribution d SET window_start=$2,allowance=x.allowance,issued_unique=x.used,
      score=x.score,confidence=x.confidence,dirty=false,valid_until=x.expires,source_updated_at=c.updated_at
      FROM jsonb_to_recordset($1::jsonb) AS x(id uuid,allowance int,used int,score real,confidence real,expires timestamptz),content c
      WHERE d.content_id=x.id AND c.id=d.content_id''',
      parameters: [jsonEncode(updates), start],
    );
    final inserted = await tx.execute(
      r'''INSERT INTO recommendation_audience_grant(content_id,user_id,window_start,expires_at)
      SELECT id,$2,$3,$4 FROM content WHERE id=ANY($1::uuid[])
      ON CONFLICT DO NOTHING RETURNING content_id''',
      parameters: [
        allowed.where((id) => !own.contains(id)).toList(),
        userId,
        start,
        start.add(Duration(minutes: policy.audienceWindowMinutes)),
      ],
    );
    if (inserted.isNotEmpty) {
      await tx.execute(
        r'UPDATE recommendation_post_distribution SET issued_unique=issued_unique+1 WHERE content_id=ANY($1::uuid[])',
        parameters: [inserted.map((r) => '${r.first}').toList()],
      );
    }
    return sorted.where((id) => !allowed.contains(id)).toSet();
  }
}
