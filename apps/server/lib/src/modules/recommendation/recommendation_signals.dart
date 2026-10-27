import 'dart:io';

import 'package:ionic_server/src/modules/recommendation/preference_profile.dart';
import 'package:ionic_server/src/modules/recommendation/ranker_config.dart';
import 'package:ionic_server/src/modules/recommendation/types.dart';
import 'package:postgres/postgres.dart';

const _defaultSignalWeights = <PreferenceSignalKind, double>{
  PreferenceSignalKind.like: 0.18,
  PreferenceSignalKind.unlike: -0.12,
  PreferenceSignalKind.save: 0.24,
  PreferenceSignalKind.unsave: -0.16,
  PreferenceSignalKind.follow: 0.25,
  PreferenceSignalKind.unfollow: -0.2,
  PreferenceSignalKind.comment: 0,
  PreferenceSignalKind.share: 0,
  PreferenceSignalKind.active_view: 0.05,
  PreferenceSignalKind.skip: -0.03,
  PreferenceSignalKind.more_like_this: 0.35,
  PreferenceSignalKind.less_like_this: -0.35,
  PreferenceSignalKind.hide: -0.2,
};

Map<PreferenceSignalKind, double> configuredSignalWeights({
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  return {
    for (final entry in _defaultSignalWeights.entries)
      entry.key: _readWeight(env, entry.key, entry.value),
  };
}

double _readWeight(
  Map<String, String> environment,
  PreferenceSignalKind kind,
  double fallback,
) {
  final key =
      'RECOMMENDATION_SIGNAL_WEIGHT_${kind.name.replaceAllMapped(RegExp(r'[A-Z]'), (match) => '_${match[0]}').toUpperCase()}';
  final raw = environment[key]?.trim();
  if (raw == null || raw.isEmpty) return fallback;
  final value = double.tryParse(raw);
  if (value == null || !value.isFinite || value < -1 || value > 1) {
    throw FormatException('$key must be between -1 and 1.');
  }
  return value;
}

PreferenceUpdatePolicy _updatePolicy(
  double nowMs, {
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  final config = buildRankerConfig(nowMs, environment: env);
  final rawExpiry = env['RECOMMENDATION_PREFERENCE_EXPIRY_MS']?.trim();
  final expiryAfterMs = rawExpiry == null || rawExpiry.isEmpty
      ? 5184000000.0
      : double.tryParse(rawExpiry);
  if (expiryAfterMs == null || !expiryAfterMs.isFinite || expiryAfterMs <= 0) {
    throw const FormatException(
      'RECOMMENDATION_PREFERENCE_EXPIRY_MS must be a finite positive number.',
    );
  }
  return PreferenceUpdatePolicy(
    nowMs: nowMs,
    halfLifeMs: config.preferenceHalfLifeMs,
    expiryAfterMs: expiryAfterMs,
    maxAbsoluteScore: 1,
    signalWeights: configuredSignalWeights(environment: env),
  );
}

class RecommendationSignalsService {
  /// Caller must persist the authoritative action first, in this same transaction.
  Future<void> recordContentAction({
    required TxSession transaction,
    required String userId,
    required String contentId,
    required String actionId,
    required PreferenceSignalKind kind,
    double? nowMs,
  }) async {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch.toDouble();
    final policy = _updatePolicy(now);
    if (policy.signalWeights[kind] == 0) return;

    await transaction.execute(
      r'INSERT INTO user_recommendation_setting(user_id, learning_paused) VALUES ($1, false) '
      'ON CONFLICT (user_id) DO NOTHING',
      parameters: [userId],
    );
    final setting = await transaction.execute(
      r'SELECT learning_paused FROM user_recommendation_setting WHERE user_id = $1 FOR UPDATE',
      parameters: [userId],
    );
    if (setting.isNotEmpty && setting.first.first == true) return;

    final taxonomyVersion =
        Platform.environment['RECOMMENDATION_TAXONOMY_VERSION']
                ?.trim()
                .isNotEmpty ==
            true
        ? Platform.environment['RECOMMENDATION_TAXONOMY_VERSION']!.trim()
        : 'ionic-taxonomy-v1';
    final labels = await transaction.execute(
      r'''SELECT dimension, label_id, confidence FROM content_label
          WHERE content_id = $1 AND taxonomy_version = $2 AND status = 'active'
          ORDER BY dimension, label_id''',
      parameters: [contentId, taxonomyVersion],
    );
    for (final row in labels) {
      final values = row.toColumnMap();
      final dimension = LabelDimension.values.byName('${values['dimension']}');
      final labelId = '${values['label_id']}';
      final confidence = (values['confidence'] as num).toDouble();
      final idempotencyKey =
          '$actionId:${kind.name}:${dimension.name}:$labelId';
      final existingResult = await transaction.execute(
        r'''SELECT score, confidence, source_summary, updated_at, expires_at
            FROM user_preference_feature
            WHERE user_id = $1 AND taxonomy_version = $2 AND dimension = $3 AND label_id = $4''',
        parameters: [userId, taxonomyVersion, dimension.name, labelId],
      );
      final existingFeatures = existingResult.map((featureRow) {
        final feature = featureRow.toColumnMap();
        final sources = feature['source_summary'];
        if (sources is! List) {
          throw StateError(
            'Stored preference feature has an invalid source summary.',
          );
        }
        return PreferenceFeature(
          taxonomyVersion: taxonomyVersion,
          dimension: dimension,
          labelId: labelId,
          sourceSummary: sources
              .map((source) => PreferenceSignalKind.values.byName('$source'))
              .toList(),
          score: (feature['score'] as num).toDouble(),
          confidence: (feature['confidence'] as num).toDouble(),
          updatedAtMs: (feature['updated_at'] as DateTime)
              .millisecondsSinceEpoch
              .toDouble(),
          expiresAtMs: (feature['expires_at'] as DateTime)
              .millisecondsSinceEpoch
              .toDouble(),
        );
      }).toList();
      final signal = PreferenceSignal(
        idempotencyKey: idempotencyKey,
        taxonomyVersion: taxonomyVersion,
        dimension: dimension,
        labelId: labelId,
        kind: kind,
        confidence: confidence,
        occurredAtMs: now,
      );
      final updated = applyPreferenceSignals(
        existingFeatures,
        [signal],
        const [],
        policy,
      ).features.firstOrNull;
      if (updated == null) continue;

      await transaction.execute(
        r'''INSERT INTO user_preference_feature
             (user_id, taxonomy_version, dimension, label_id, score, confidence, source_summary, updated_at, expires_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, to_timestamp($8 / 1000.0), to_timestamp($9 / 1000.0))
           ON CONFLICT (user_id, taxonomy_version, dimension, label_id)
           DO UPDATE SET score = EXCLUDED.score, confidence = EXCLUDED.confidence,
             source_summary = EXCLUDED.source_summary, updated_at = EXCLUDED.updated_at,
             expires_at = EXCLUDED.expires_at''',
        parameters: [
          userId,
          updated.taxonomyVersion,
          updated.dimension.name,
          updated.labelId,
          updated.score,
          updated.confidence,
          updated.sourceSummary.map((source) => source.name).toList(),
          updated.updatedAtMs,
          updated.expiresAtMs,
        ],
      );
    }
  }
}
