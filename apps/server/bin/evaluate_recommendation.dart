import 'dart:convert';
import 'dart:io';

import 'package:ionic_server/src/modules/recommendation/content_labeler.dart';
import 'package:ionic_server/src/modules/recommendation/evaluation.dart';
import 'package:ionic_server/src/modules/recommendation/ranker.dart';
import 'package:ionic_server/src/modules/recommendation/ranker_config.dart';
import 'package:ionic_server/src/modules/recommendation/text_label_rules.dart';
import 'package:ionic_server/src/modules/recommendation/types.dart';

const _hourMs = 60 * 60 * 1000.0;
const _dayMs = 24 * _hourMs;

Map<String, dynamic> _map(Object? value, String name) {
  if (value is! Map) throw FormatException('$name must be an object.');
  return Map<String, dynamic>.from(value);
}

List<Map<String, dynamic>> _objects(Object? value, String name) {
  if (value == null) return const [];
  if (value is! List) throw FormatException('$name must be a list.');
  return value.map((item) => _map(item, name)).toList(growable: false);
}

List<String> _strings(Object? value, String name) {
  if (value == null) return const [];
  if (value is! List || value.any((item) => item is! String)) {
    throw FormatException('$name must contain strings.');
  }
  return List<String>.from(value);
}

double _number(Map<String, dynamic> value, String key, [double? fallback]) {
  final raw = value[key];
  if (raw == null && fallback != null) return fallback;
  if (raw is! num || !raw.toDouble().isFinite) {
    throw FormatException('$key must be a finite number.');
  }
  return raw.toDouble();
}

LabelDimension _dimension(Map<String, dynamic> value) =>
    LabelDimension.values.byName(value['dimension'] as String);

TaxonomyLabelRef _labelRef(
  Map<String, dynamic> value,
  String taxonomyVersion,
) => TaxonomyLabelRef(
  taxonomyVersion: taxonomyVersion,
  dimension: _dimension(value),
  labelId: value['labelId'] as String,
);

ViewerProfile _profile(
  Map<String, dynamic> raw,
  String taxonomyVersion,
  double nowMs,
) {
  final explicit = _objects(raw['explicitInterests'], 'explicitInterests')
      .map(
        (value) => ExplicitInterest(
          taxonomyVersion: taxonomyVersion,
          dimension: _dimension(value),
          labelId: value['labelId'] as String,
        ),
      )
      .toList(growable: false);
  final preferences = _objects(raw['preferences'], 'preferences')
      .map(
        (value) => PreferenceFeature(
          taxonomyVersion: taxonomyVersion,
          dimension: _dimension(value),
          labelId: value['labelId'] as String,
          sourceSummary: _strings(
            value['sourceSummary'],
            'sourceSummary',
          ).map(PreferenceSignalKind.values.byName).toList(growable: false),
          score: _number(value, 'score'),
          confidence: _number(value, 'confidence'),
          updatedAtMs: nowMs - _number(value, 'updatedHoursAgo', 0) * _hourMs,
          expiresAtMs: nowMs + _number(value, 'expiresInDays', 30) * _dayMs,
        ),
      )
      .toList(growable: false);
  final hiddenLabels = _objects(
    raw['hiddenLabels'],
    'hiddenLabels',
  ).map((value) => _labelRef(value, taxonomyVersion)).toList(growable: false);
  final lessLikeLabels = _objects(
    raw['lessLikeLabels'],
    'lessLikeLabels',
  ).map((value) => _labelRef(value, taxonomyVersion)).toList(growable: false);
  final exposures = _objects(raw['recentExposures'], 'recentExposures')
      .map(
        (value) => ExposureRecord(
          contentId: value['contentId'] as String,
          creatorId: value['creatorId'] as String,
          taxonomyVersion: taxonomyVersion,
          topicLabelIds: _strings(value['topicLabelIds'], 'topicLabelIds'),
          exposedAtMs: nowMs - _number(value, 'hoursAgo', 0) * _hourMs,
        ),
      )
      .toList(growable: false);

  return ViewerProfile(
    explicitInterests: explicit,
    preferences: preferences,
    followingCreatorIds: _strings(
      raw['followingCreatorIds'],
      'followingCreatorIds',
    ),
    blockedCreatorIds: _strings(raw['blockedCreatorIds'], 'blockedCreatorIds'),
    mutedCreatorIds: _strings(raw['mutedCreatorIds'], 'mutedCreatorIds'),
    hiddenContentIds: _strings(raw['hiddenContentIds'], 'hiddenContentIds'),
    hiddenLabels: hiddenLabels,
    lessLikeLabels: lessLikeLabels,
    recentExposures: exposures,
  );
}

Map<String, String> _rankerEnvironment(Map<String, dynamic> raw) {
  const environmentKeys = {
    'maxPerCreator': 'RECOMMENDATION_MAX_PER_CREATOR',
    'maxPerTopic': 'RECOMMENDATION_MAX_PER_TOPIC',
    'maxConsecutiveTopic': 'RECOMMENDATION_MAX_CONSECUTIVE_TOPIC',
  };
  final environment = <String, String>{};
  for (final entry in environmentKeys.entries) {
    final value = raw[entry.key];
    if (value != null) {
      environment[entry.value] = value.toString();
    }
  }
  return environment;
}

FeedCandidate _candidate(
  Map<String, dynamic> raw,
  String taxonomyVersion,
  double nowMs,
) {
  final text = raw['text'];
  if (text is! String || text.trim().isEmpty) {
    throw const FormatException('Every candidate requires non-empty text.');
  }
  final labels = labelContent(
    LabelContentInput(
      taxonomyVersion: taxonomyVersion,
      kind: ContentKind.text,
      text: text,
      formatLabelIds: const {ContentKind.text: 'format.text'},
      keywordRules: textLabelRules,
      declaredLanguageLabelId: 'language.vi',
    ),
  );
  return FeedCandidate(
    id: raw['id'] as String,
    creatorId: raw['creatorId'] as String,
    kind: ContentKind.text,
    publishedAtMs: nowMs - _number(raw, 'ageHours') * _hourMs,
    labels: labels,
    eligible: true,
    visibleToViewer: true,
    duplicateGroupId: raw['duplicateGroupId'] as String?,
  );
}

double? _mean(Iterable<double?> values) {
  final present = values.whereType<double>().toList(growable: false);
  if (present.isEmpty) return null;
  return present.reduce((left, right) => left + right) / present.length;
}

Future<void> main(List<String> args) async {
  final path = args.isEmpty ? 'data/recommendation/judgments-v1.json' : args[0];
  final file = File(path);
  if (!await file.exists()) {
    throw FileSystemException('Dataset not found', path);
  }
  final dataset = _map(jsonDecode(await file.readAsString()), 'dataset');
  if (dataset['formatVersion'] != 1) {
    throw const FormatException('Unsupported recommendation dataset version.');
  }
  final taxonomyVersion = dataset['taxonomyVersion'] as String;
  final nowMs = DateTime.parse(dataset['asOfUtc'] as String)
      .toUtc()
      .millisecondsSinceEpoch
      .toDouble();
  final scenarios = _objects(dataset['scenarios'], 'scenarios');
  if (scenarios.isEmpty) {
    throw const FormatException('The dataset must contain scenarios.');
  }

  final output = <Map<String, dynamic>>[];
  for (final scenario in scenarios) {
    final candidates = _objects(scenario['candidates'], 'candidates');
    final candidateIds = <String>{};
    final grades = <String, int>{};
    final rankableCandidates = <FeedCandidate>[];
    for (final raw in candidates) {
      final id = raw['id'] as String;
      if (!candidateIds.add(id)) {
        throw FormatException('Duplicate candidate ID "$id".');
      }
      final grade = raw['grade'];
      if (grade is! int || grade < 0 || grade > 3) {
        throw FormatException('Candidate "$id" needs a relevance grade 0..3.');
      }
      grades[id] = grade;
      rankableCandidates.add(_candidate(raw, taxonomyVersion, nowMs));
    }

    final config = buildRankerConfig(
      nowMs,
      environment: {
        ...Platform.environment,
        ..._rankerEnvironment(
          _map(scenario['rankerConfig'] ?? const {}, 'rankerConfig'),
        ),
      },
    );
    final limit = scenario['limit'] as int;
    final ranked = rankCandidates(
      rankableCandidates,
      _profile(
        _map(scenario['profile'] ?? const {}, 'profile'),
        taxonomyVersion,
        nowMs,
      ),
      config,
      limit,
    );
    final metrics = evaluateRanking(
      RankingEvaluationInput(
        ranked: ranked,
        relevanceByContentId: grades,
        limit: limit,
        relevantAtOrAbove: dataset['relevantAtOrAbove'] as int,
      ),
    );
    output.add({
      'id': scenario['id'],
      'description': scenario['description'],
      'candidateCount': candidates.length,
      'returnedCount': ranked.length,
      'limit': limit,
      'topContentIds': ranked
          .take(limit)
          .map((item) => item.candidate.id)
          .toList(growable: false),
      'topTiers': ranked
          .take(limit)
          .map((item) => item.tier.name)
          .toList(growable: false),
      'metrics': {
        'precisionAtK': metrics.precisionAtK,
        'recallAtK': metrics.recallAtK,
        'ndcgAtK': metrics.ndcgAtK,
        'creatorCoverage': metrics.creatorCoverage,
        'topicCoverage': metrics.topicCoverage,
        'repeatedCreatorItemRate': metrics.repeatedCreatorItemRate,
        'repeatedTopicItemRate': metrics.repeatedTopicItemRate,
      },
    });
  }

  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'datasetId': dataset['datasetId'],
      'taxonomyVersion': taxonomyVersion,
      'rankerVersion': buildRankerConfig(nowMs).rankerVersion,
      'judgmentSource': _map(
        dataset['judgmentProtocol'],
        'judgmentProtocol',
      )['source'],
      'scenarioCount': output.length,
      'macroMean': {
        'precisionAtK': _mean(
          output.map((item) => item['metrics']['precisionAtK'] as double?),
        ),
        'recallAtK': _mean(
          output.map((item) => item['metrics']['recallAtK'] as double?),
        ),
        'ndcgAtK': _mean(
          output.map((item) => item['metrics']['ndcgAtK'] as double?),
        ),
      },
      'scenarios': output,
    }),
  );
}
