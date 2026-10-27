import 'dart:io';

import 'types.dart';

const _defaultWeights = {
  'topic': 1.0,
  'format': 1.0,
  'language': 1.0,
  'context': 1.0,
  'social': 1.0,
  'freshness': 1.0,
  'quality': 0.0,
  'exploration': 1.0,
  'negativePreference': 1.0,
  'repetition': 1.0,
};

const _taxonomyV1AdjacentLabels = <String, List<String>>{
  'topic.design': ['topic.product', 'topic.creativity'],
  'topic.software': ['topic.product', 'topic.learning'],
  'topic.product': ['topic.design', 'topic.software'],
  'topic.writing': ['topic.learning', 'topic.creativity'],
  'topic.learning': ['topic.software', 'topic.writing', 'topic.creativity'],
  'topic.creativity': ['topic.design', 'topic.writing', 'topic.learning'],
};

RankerConfig buildRankerConfig(
  double nowMs, {
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  double read(String name, double fallback) {
    final envName =
        'RECOMMENDATION_WEIGHT_${name.replaceAllMapped(RegExp(r'[A-Z]'), (match) => '_${match[0]}').toUpperCase()}';
    final raw = env[envName]?.trim();
    if (raw == null || raw.isEmpty) return fallback;
    final value = double.tryParse(raw);
    if (value == null || !value.isFinite || value < 0) {
      throw FormatException('$envName must be a finite non-negative number.');
    }
    return value;
  }

  double readPositive(String key, double fallback) {
    final raw = env[key]?.trim();
    if (raw == null || raw.isEmpty) return fallback;
    final value = double.tryParse(raw);
    if (value == null || !value.isFinite || value <= 0) {
      throw FormatException('$key must be a finite positive number.');
    }
    return value;
  }

  double readUnit(String key, double fallback) {
    final value = readPositive(key, fallback);
    if (value > 1) throw FormatException('$key must be between 0 and 1.');
    return value;
  }

  int readInteger(String key, int fallback) {
    final raw = env[key]?.trim();
    if (raw == null || raw.isEmpty) return fallback;
    final value = int.tryParse(raw);
    if (value == null || value < 1) {
      throw FormatException('$key must be a positive integer.');
    }
    return value;
  }

  final weights = RankerWeights(
    topic: read('topic', _defaultWeights['topic']!),
    format: read('format', _defaultWeights['format']!),
    language: read('language', _defaultWeights['language']!),
    context: read('context', _defaultWeights['context']!),
    social: read('social', _defaultWeights['social']!),
    freshness: read('freshness', _defaultWeights['freshness']!),
    quality: read('quality', _defaultWeights['quality']!),
    exploration: read('exploration', _defaultWeights['exploration']!),
    negativePreference: read(
      'negativePreference',
      _defaultWeights['negativePreference']!,
    ),
    repetition: read('repetition', _defaultWeights['repetition']!),
  );
  final taxonomyVersion =
      env['RECOMMENDATION_TAXONOMY_VERSION']?.trim().isNotEmpty == true
      ? env['RECOMMENDATION_TAXONOMY_VERSION']!.trim()
      : 'ionic-taxonomy-v1';

  return RankerConfig(
    rankerVersion:
        env['RECOMMENDATION_RANKER_VERSION']?.trim().isNotEmpty == true
        ? env['RECOMMENDATION_RANKER_VERSION']!.trim()
        : 'ionic-deterministic-v1',
    taxonomyVersion: taxonomyVersion,
    nowMs: nowMs,
    weights: weights,
    freshnessHalfLifeMs: readPositive(
      'RECOMMENDATION_FRESHNESS_HALF_LIFE_MS',
      86400000,
    ),
    preferenceHalfLifeMs: readPositive(
      'RECOMMENDATION_PREFERENCE_HALF_LIFE_MS',
      1209600000,
    ),
    recentExposureWindowMs: readPositive(
      'RECOMMENDATION_RECENT_EXPOSURE_WINDOW_MS',
      604800000,
    ),
    minimumPreferenceConfidence: readUnit(
      'RECOMMENDATION_MIN_PREFERENCE_CONFIDENCE',
      0.55,
    ),
    strongMatchThreshold: readUnit(
      'RECOMMENDATION_STRONG_MATCH_THRESHOLD',
      0.18,
    ),
    maxPerCreator: readInteger('RECOMMENDATION_MAX_PER_CREATOR', 3),
    maxPerTopic: readInteger('RECOMMENDATION_MAX_PER_TOPIC', 4),
    maxConsecutiveTopic: readInteger('RECOMMENDATION_MAX_CONSECUTIVE_TOPIC', 2),
    adjacentLabels: taxonomyVersion == 'ionic-taxonomy-v1'
        ? _taxonomyV1AdjacentLabels
        : const {},
  );
}

int readCandidateLimit({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final raw = env['RECOMMENDATION_CANDIDATE_LIMIT']?.trim();
  final limit = raw == null || raw.isEmpty ? 500 : int.tryParse(raw);
  if (limit == null || limit < 1) {
    throw const FormatException(
      'RECOMMENDATION_CANDIDATE_LIMIT must be a positive integer.',
    );
  }
  if (limit > 5000) {
    throw const FormatException(
      'RECOMMENDATION_CANDIDATE_LIMIT cannot exceed 5000.',
    );
  }
  return limit;
}
