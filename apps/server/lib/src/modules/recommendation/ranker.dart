import 'dart:math' as math;

import 'types.dart';

const _tierOrder = <RelevanceTier, int>{
  RelevanceTier.direct: 0,
  RelevanceTier.strong: 1,
  RelevanceTier.adjacent: 2,
  RelevanceTier.fresh: 3,
};

const _labelDimensions = LabelDimension.values;
const _preferenceSignalKinds = PreferenceSignalKind.values;

double _clamp01(double value) => math.min(1, math.max(0, value));

String _labelKey(
  String taxonomyVersion,
  LabelDimension dimension,
  String labelId,
) => '$taxonomyVersion\u0000${dimension.name}\u0000$labelId';

bool _labelIsControlled(ContentLabel label, Set<String> controlKeys) =>
    controlKeys.contains(
      _labelKey(label.taxonomyVersion, label.dimension, label.labelId),
    );

void _validateConfig(RankerConfig config, int limit) {
  if (config.rankerVersion.trim().isEmpty ||
      config.taxonomyVersion.trim().isEmpty) {
    throw ArgumentError('Ranker and taxonomy versions are required.');
  }
  if (!config.nowMs.isFinite) {
    throw RangeError('Ranker time must be finite.');
  }
  if (!config.freshnessHalfLifeMs.isFinite ||
      config.freshnessHalfLifeMs <= 0 ||
      !config.preferenceHalfLifeMs.isFinite ||
      config.preferenceHalfLifeMs <= 0 ||
      !config.recentExposureWindowMs.isFinite ||
      config.recentExposureWindowMs < 0) {
    throw RangeError('Ranker time windows must be finite and valid.');
  }
  if (!config.minimumPreferenceConfidence.isFinite ||
      !config.strongMatchThreshold.isFinite ||
      config.minimumPreferenceConfidence < 0 ||
      config.minimumPreferenceConfidence > 1 ||
      config.strongMatchThreshold <= 0 ||
      config.strongMatchThreshold > 1) {
    throw RangeError(
      'Ranker confidence and match thresholds must be between 0 and 1.',
    );
  }
  if (limit < 0 ||
      config.maxPerCreator < 1 ||
      config.maxPerTopic < 1 ||
      config.maxConsecutiveTopic < 1) {
    throw RangeError(
      'Feed limit and diversity caps must be positive integers.',
    );
  }

  final weights = config.weights.entries;
  var nonPenaltyWeightTotal = 0.0;
  for (final (name, weight) in weights) {
    if (!weight.isFinite || weight < 0) {
      throw RangeError('Ranker weights must be finite and non-negative.');
    }
    if (name != 'repetition' && name != 'negativePreference') {
      nonPenaltyWeightTotal += weight;
    }
  }
  if (!nonPenaltyWeightTotal.isFinite || nonPenaltyWeightTotal <= 0) {
    throw RangeError(
      'At least one positive ranking weight must be greater than zero.',
    );
  }
}

class _PreparedProfile {
  const _PreparedProfile({
    required this.explicitInterestKeys,
    required this.preferencesByKey,
    required this.positivePreferenceLabelIds,
    required this.followingCreatorIds,
    required this.blockedCreatorIds,
    required this.mutedCreatorIds,
    required this.hiddenContentIds,
    required this.hiddenLabelKeys,
    required this.lessLikeLabelKeys,
    required this.recentExposureContentIds,
    required this.recentExposureCount,
    required this.recentTopicExposureCount,
    required this.recentCreatorCounts,
    required this.recentLabelCounts,
  });

  final Set<String> explicitInterestKeys;
  final Map<String, PreferenceFeature> preferencesByKey;
  final List<String> positivePreferenceLabelIds;
  final Set<String> followingCreatorIds;
  final Set<String> blockedCreatorIds;
  final Set<String> mutedCreatorIds;
  final Set<String> hiddenContentIds;
  final Set<String> hiddenLabelKeys;
  final Set<String> lessLikeLabelKeys;
  final Set<String> recentExposureContentIds;
  final int recentExposureCount;
  final int recentTopicExposureCount;
  final Map<String, int> recentCreatorCounts;
  final Map<String, int> recentLabelCounts;
}

void _incrementCount(Map<String, int> counts, String key) {
  counts.update(key, (count) => count + 1, ifAbsent: () => 1);
}

_PreparedProfile _prepareProfile(ViewerProfile profile, RankerConfig config) {
  final explicitInterestKeys = <String>{};
  for (final interest in profile.explicitInterests) {
    if (interest.labelId.trim().isEmpty ||
        !_labelDimensions.contains(interest.dimension)) {
      throw ArgumentError(
        'Explicit interests require a valid taxonomy dimension and label ID.',
      );
    }
    if (interest.taxonomyVersion != config.taxonomyVersion) {
      throw ArgumentError(
        'Explicit interests must be migrated before activating a new taxonomy version.',
      );
    }
    explicitInterestKeys.add(
      _labelKey(interest.taxonomyVersion, interest.dimension, interest.labelId),
    );
  }

  Set<String> indexControls(List<TaxonomyLabelRef> controls) {
    final keys = <String>{};
    for (final control in controls) {
      if (control.taxonomyVersion != config.taxonomyVersion) {
        throw ArgumentError(
          'Explicit label controls must be migrated before activating a new taxonomy version.',
        );
      }
      if (control.labelId.trim().isEmpty) {
        throw ArgumentError('Explicit label controls require a label ID.');
      }
      if (!_labelDimensions.contains(control.dimension)) {
        throw ArgumentError('Explicit label control dimension is invalid.');
      }
      keys.add(
        _labelKey(control.taxonomyVersion, control.dimension, control.labelId),
      );
    }
    return keys;
  }

  final hiddenLabelKeys = indexControls(profile.hiddenLabels);
  final lessLikeLabelKeys = indexControls(profile.lessLikeLabels);
  final preferencesByKey = <String, PreferenceFeature>{};
  final positivePreferenceLabelIds = <String>{};
  for (final feature in profile.preferences) {
    if (!feature.score.isFinite ||
        feature.score < -1 ||
        feature.score > 1 ||
        !feature.confidence.isFinite ||
        feature.confidence < 0 ||
        feature.confidence > 1 ||
        !feature.updatedAtMs.isFinite ||
        feature.updatedAtMs > config.nowMs ||
        !feature.expiresAtMs.isFinite ||
        feature.expiresAtMs <= feature.updatedAtMs ||
        feature.taxonomyVersion.trim().isEmpty ||
        feature.labelId.trim().isEmpty ||
        !_labelDimensions.contains(feature.dimension) ||
        feature.sourceSummary.isEmpty ||
        feature.sourceSummary.any(
          (kind) => !_preferenceSignalKinds.contains(kind),
        ) ||
        feature.sourceSummary.toSet().length != feature.sourceSummary.length) {
      throw RangeError('Viewer preference features contain invalid values.');
    }
    if (feature.taxonomyVersion != config.taxonomyVersion ||
        feature.expiresAtMs <= config.nowMs) {
      continue;
    }
    final key = _labelKey(
      feature.taxonomyVersion,
      feature.dimension,
      feature.labelId,
    );
    if (preferencesByKey.containsKey(key)) {
      throw ArgumentError(
        'Viewer preference features must be unique per taxonomy label.',
      );
    }
    final decay = math
        .pow(
          2.0,
          -(config.nowMs - feature.updatedAtMs) / config.preferenceHalfLifeMs,
        )
        .toDouble();
    final currentFeature = PreferenceFeature(
      taxonomyVersion: feature.taxonomyVersion,
      dimension: feature.dimension,
      labelId: feature.labelId,
      sourceSummary: feature.sourceSummary,
      score: feature.score * decay,
      confidence: feature.confidence * decay,
      updatedAtMs: feature.updatedAtMs,
      expiresAtMs: feature.expiresAtMs,
    );
    preferencesByKey[key] = currentFeature;
    if (currentFeature.score > 0 &&
        currentFeature.confidence >= config.minimumPreferenceConfidence) {
      positivePreferenceLabelIds.add(feature.labelId);
    }
  }

  final recentExposures = profile.recentExposures.where((exposure) {
    if (exposure.contentId.trim().isEmpty ||
        exposure.creatorId.trim().isEmpty ||
        exposure.taxonomyVersion.trim().isEmpty ||
        !exposure.exposedAtMs.isFinite ||
        exposure.exposedAtMs > config.nowMs ||
        exposure.topicLabelIds.any((labelId) => labelId.trim().isEmpty)) {
      throw RangeError('Recent exposure records contain invalid values.');
    }
    return config.nowMs - exposure.exposedAtMs <= config.recentExposureWindowMs;
  }).toList();

  final recentExposureContentIds = <String>{};
  final recentCreatorCounts = <String, int>{};
  final recentLabelCounts = <String, int>{};
  var recentTopicExposureCount = 0;
  for (final exposure in recentExposures) {
    recentExposureContentIds.add(exposure.contentId);
    _incrementCount(recentCreatorCounts, exposure.creatorId);
    if (exposure.taxonomyVersion == config.taxonomyVersion) {
      recentTopicExposureCount += 1;
      for (final labelId in exposure.topicLabelIds.toSet()) {
        _incrementCount(recentLabelCounts, labelId);
      }
    }
  }

  return _PreparedProfile(
    explicitInterestKeys: explicitInterestKeys,
    preferencesByKey: preferencesByKey,
    positivePreferenceLabelIds: positivePreferenceLabelIds.toList(),
    followingCreatorIds: profile.followingCreatorIds.toSet(),
    blockedCreatorIds: profile.blockedCreatorIds.toSet(),
    mutedCreatorIds: profile.mutedCreatorIds.toSet(),
    hiddenContentIds: profile.hiddenContentIds.toSet(),
    hiddenLabelKeys: hiddenLabelKeys,
    lessLikeLabelKeys: lessLikeLabelKeys,
    recentExposureContentIds: recentExposureContentIds,
    recentExposureCount: recentExposures.length,
    recentTopicExposureCount: recentTopicExposureCount,
    recentCreatorCounts: recentCreatorCounts,
    recentLabelCounts: recentLabelCounts,
  );
}

double _labelMatchScore(
  List<ContentLabel> labels,
  _PreparedProfile profile,
  LabelDimension dimension,
  RankerConfig config,
) {
  var best = 0.0;
  for (final label in labels) {
    if (label.dimension != dimension ||
        _labelIsControlled(label, profile.lessLikeLabelKeys)) {
      continue;
    }
    final key = _labelKey(config.taxonomyVersion, dimension, label.labelId);
    if (profile.explicitInterestKeys.contains(key)) {
      best = math.max(best, label.confidence);
      continue;
    }
    final feature = profile.preferencesByKey[key];
    if (feature != null &&
        feature.score > 0 &&
        feature.confidence >= config.minimumPreferenceConfidence) {
      best = math.max(
        best,
        _clamp01(feature.score) * feature.confidence * label.confidence,
      );
    }
  }
  return _clamp01(best);
}

bool _hasExplicitMatch(
  FeedCandidate candidate,
  _PreparedProfile profile,
  RankerConfig config,
) => candidate.labels.any(
  (label) =>
      !_labelIsControlled(label, profile.lessLikeLabelKeys) &&
      profile.explicitInterestKeys.contains(
        _labelKey(config.taxonomyVersion, label.dimension, label.labelId),
      ),
);

bool _hasStrongPreferenceMatch(
  FeedCandidate candidate,
  _PreparedProfile profile,
  RankerConfig config,
) {
  const dimensions = [
    LabelDimension.topic,
    LabelDimension.format,
    LabelDimension.language,
    LabelDimension.context,
  ];
  return dimensions.any((dimension) {
    final match = _labelMatchScore(
      candidate.labels,
      profile,
      dimension,
      config,
    );
    return match > 0 && match >= config.strongMatchThreshold;
  });
}

double _negativePreferenceScore(
  FeedCandidate candidate,
  _PreparedProfile profile,
  RankerConfig config,
) {
  var strongestNegativeMatch = 0.0;
  for (final label in candidate.labels) {
    if (_labelIsControlled(label, profile.lessLikeLabelKeys)) {
      strongestNegativeMatch = math.max(
        strongestNegativeMatch,
        label.confidence,
      );
      continue;
    }
    final feature =
        profile.preferencesByKey[_labelKey(
          config.taxonomyVersion,
          label.dimension,
          label.labelId,
        )];
    if (feature != null &&
        feature.score < 0 &&
        feature.confidence >= config.minimumPreferenceConfidence) {
      strongestNegativeMatch = math.max(
        strongestNegativeMatch,
        -feature.score * feature.confidence * label.confidence,
      );
    }
  }
  return _clamp01(strongestNegativeMatch);
}

bool _hasAdjacentMatch(
  FeedCandidate candidate,
  _PreparedProfile profile,
  RankerConfig config,
) => candidate.labels.any((candidateLabel) {
  if ((candidateLabel.dimension != LabelDimension.topic &&
          candidateLabel.dimension != LabelDimension.format) ||
      _labelIsControlled(candidateLabel, profile.lessLikeLabelKeys)) {
    return false;
  }
  final candidateNeighbors =
      config.adjacentLabels[candidateLabel.labelId] ?? const <String>[];
  return profile.positivePreferenceLabelIds.any((preferredLabel) {
    final preferredFeature =
        profile.preferencesByKey[_labelKey(
          config.taxonomyVersion,
          candidateLabel.dimension,
          preferredLabel,
        )];
    if (preferredFeature == null) return false;
    final preferredNeighbors =
        config.adjacentLabels[preferredLabel] ?? const <String>[];
    return candidateNeighbors.contains(preferredLabel) ||
        preferredNeighbors.contains(candidateLabel.labelId);
  });
});

({RelevanceTier tier, RecommendationReasonCode reasonCode}) _classifyTier(
  FeedCandidate candidate,
  _PreparedProfile profile,
  RankerConfig config,
) {
  final creatorIsFollowed = profile.followingCreatorIds.contains(
    candidate.creatorId,
  );
  if (creatorIsFollowed &&
      !candidate.labels.any(
        (label) => _labelIsControlled(label, profile.lessLikeLabelKeys),
      )) {
    return (
      tier: RelevanceTier.direct,
      reasonCode: RecommendationReasonCode.followed_creator,
    );
  }
  if (_hasExplicitMatch(candidate, profile, config)) {
    return (
      tier: RelevanceTier.direct,
      reasonCode: RecommendationReasonCode.explicit_interest,
    );
  }
  if (_hasStrongPreferenceMatch(candidate, profile, config)) {
    return (
      tier: RelevanceTier.strong,
      reasonCode: RecommendationReasonCode.learned_interest,
    );
  }
  if (_hasAdjacentMatch(candidate, profile, config)) {
    return (
      tier: RelevanceTier.adjacent,
      reasonCode: RecommendationReasonCode.adjacent_topic,
    );
  }
  return (
    tier: RelevanceTier.fresh,
    reasonCode: RecommendationReasonCode.fresh_content,
  );
}

double _freshnessScore(FeedCandidate candidate, RankerConfig config) {
  final ageMs = math.max(0, config.nowMs - candidate.publishedAtMs);
  return math.pow(2.0, -ageMs / config.freshnessHalfLifeMs).toDouble();
}

double _repetitionScore(FeedCandidate candidate, _PreparedProfile profile) {
  if (profile.recentExposureCount == 0) return 0;
  var repeatedLabelCount = 0;
  for (final label in candidate.labels) {
    if (label.dimension == LabelDimension.topic) {
      repeatedLabelCount += profile.recentLabelCounts[label.labelId] ?? 0;
    }
  }
  final repeatedCreator = profile.recentCreatorCounts[candidate.creatorId] ?? 0;
  final creatorRepetition = repeatedCreator / profile.recentExposureCount;
  final topicRepetition = profile.recentTopicExposureCount == 0
      ? 0.0
      : math.min(profile.recentTopicExposureCount, repeatedLabelCount) /
            profile.recentTopicExposureCount;
  return _clamp01((creatorRepetition + topicRepetition) / 2);
}

double _scoreCandidate(
  FeedCandidate candidate,
  RelevanceTier tier,
  _PreparedProfile profile,
  RankerConfig config,
) {
  final components = <String, double>{
    'topic': _labelMatchScore(
      candidate.labels,
      profile,
      LabelDimension.topic,
      config,
    ),
    'format': _labelMatchScore(
      candidate.labels,
      profile,
      LabelDimension.format,
      config,
    ),
    'language': _labelMatchScore(
      candidate.labels,
      profile,
      LabelDimension.language,
      config,
    ),
    'context': _labelMatchScore(
      candidate.labels,
      profile,
      LabelDimension.context,
      config,
    ),
    'social': profile.followingCreatorIds.contains(candidate.creatorId) ? 1 : 0,
    'freshness': _freshnessScore(candidate, config),
    'exploration': tier == RelevanceTier.adjacent || tier == RelevanceTier.fresh
        ? 1
        : 0,
    'negativePreference': _negativePreferenceScore(candidate, profile, config),
    'repetition': _repetitionScore(candidate, profile),
  };
  if (candidate.qualityScore != null) {
    components['quality'] = candidate.qualityScore!;
  }

  var weightedTotal = 0.0;
  var availableWeight = 0.0;
  for (final entry in components.entries) {
    if (entry.key == 'repetition' || entry.key == 'negativePreference') {
      continue;
    }
    final weight = config.weights.valueFor(entry.key);
    weightedTotal += entry.value * weight;
    availableWeight += weight;
  }
  if (availableWeight == 0) {
    return 0;
  }
  return weightedTotal / availableWeight -
      config.weights.negativePreference *
          (components['negativePreference'] ?? 0) -
      config.weights.repetition * (components['repetition'] ?? 0);
}

String? _primaryTopic(FeedCandidate candidate) {
  ContentLabel? best;
  for (final label in candidate.labels) {
    if (label.dimension != LabelDimension.topic) continue;
    if (best == null ||
        label.confidence > best.confidence ||
        (label.confidence == best.confidence &&
            label.labelId.compareTo(best.labelId) < 0)) {
      best = label;
    }
  }
  return best?.labelId;
}

int _compareRanked(RankedCandidate left, RankedCandidate right) {
  final tierDifference = _tierOrder[left.tier]! - _tierOrder[right.tier]!;
  if (tierDifference != 0) return tierDifference;
  final scoreDifference = right.score.compareTo(left.score);
  if (scoreDifference != 0) return scoreDifference;
  final freshnessDifference = right.candidate.publishedAtMs.compareTo(
    left.candidate.publishedAtMs,
  );
  return freshnessDifference != 0
      ? freshnessDifference
      : left.candidate.id.compareTo(right.candidate.id);
}

class _DiversityCaps {
  const _DiversityCaps(
    this.maxPerCreator,
    this.maxPerTopic,
    this.maxConsecutiveTopic,
  );

  final int maxPerCreator;
  final int maxPerTopic;
  final int maxConsecutiveTopic;
}

({List<RankedCandidate> selected, List<RankedCandidate> deferred})
_selectWithCaps(
  List<RankedCandidate> ranked,
  int limit,
  _DiversityCaps caps,
  List<RankedCandidate> alreadySelected,
) {
  final selected = [...alreadySelected];
  final deferred = <RankedCandidate>[];
  for (final item in ranked) {
    if (selected.length >= limit) {
      deferred.add(item);
      continue;
    }
    final topic = _primaryTopic(item.candidate);
    final creatorCount = selected
        .where(
          (selectedItem) =>
              selectedItem.candidate.creatorId == item.candidate.creatorId,
        )
        .length;
    final topicCount = topic == null
        ? 0
        : selected
              .where(
                (selectedItem) =>
                    _primaryTopic(selectedItem.candidate) == topic,
              )
              .length;
    var consecutiveTopicCount = 0;
    if (topic != null) {
      for (var index = selected.length - 1; index >= 0; index--) {
        if (_primaryTopic(selected[index].candidate) != topic) break;
        consecutiveTopicCount++;
      }
    }
    if (creatorCount >= caps.maxPerCreator ||
        (topic != null && topicCount >= caps.maxPerTopic) ||
        (topic != null && consecutiveTopicCount >= caps.maxConsecutiveTopic)) {
      deferred.add(item);
      continue;
    }
    selected.add(item);
  }
  return (selected: selected, deferred: deferred);
}

List<RankedCandidate> _diversify(
  List<RankedCandidate> ranked,
  int limit,
  RankerConfig config,
) {
  var selected = <RankedCandidate>[];
  var remaining = [...ranked];
  final capPasses = [
    _DiversityCaps(
      config.maxPerCreator,
      config.maxPerTopic,
      config.maxConsecutiveTopic,
    ),
    _DiversityCaps(
      config.maxPerCreator,
      0x7fffffff,
      config.maxConsecutiveTopic,
    ),
    _DiversityCaps(0x7fffffff, 0x7fffffff, config.maxConsecutiveTopic),
    _DiversityCaps(0x7fffffff, 0x7fffffff, 0x7fffffff),
  ];
  for (final caps in capPasses) {
    if (selected.length >= limit) break;
    final result = _selectWithCaps(remaining, limit, caps, selected);
    selected = result.selected;
    remaining = result.deferred;
  }
  return selected.take(limit).toList();
}

void _validateCandidate(FeedCandidate candidate, String taxonomyVersion) {
  if (candidate.id.trim().isEmpty ||
      candidate.creatorId.trim().isEmpty ||
      !candidate.publishedAtMs.isFinite ||
      candidate.labels.isEmpty) {
    throw ArgumentError(
      'Feed candidates require IDs, a valid publish time, and at least one label.',
    );
  }
  if (candidate.kind != ContentKind.text &&
      candidate.kind != ContentKind.short_video) {
    throw ArgumentError('Candidate content kind is invalid.');
  }
  if (candidate.duplicateGroupId != null &&
      candidate.duplicateGroupId!.trim().isEmpty) {
    throw ArgumentError('Duplicate group ID cannot be empty when provided.');
  }
  final seenLabels = <String>{};
  for (final label in candidate.labels) {
    if (label.taxonomyVersion != taxonomyVersion ||
        label.labelId.trim().isEmpty ||
        !_labelDimensions.contains(label.dimension) ||
        !label.confidence.isFinite ||
        label.confidence < 0 ||
        label.confidence > 1) {
      throw ArgumentError(
        'Candidate labels must be valid and use the active taxonomy version.',
      );
    }
    final key = _labelKey(
      label.taxonomyVersion,
      label.dimension,
      label.labelId,
    );
    if (!seenLabels.add(key)) {
      throw ArgumentError(
        'Candidate labels must be unique per taxonomy dimension and label.',
      );
    }
  }
  if (candidate.qualityScore != null &&
      (!candidate.qualityScore!.isFinite ||
          candidate.qualityScore! < 0 ||
          candidate.qualityScore! > 1)) {
    throw RangeError('Candidate quality score must be between 0 and 1.');
  }
}

/// Ranks eligible feed items while applying privacy controls and a diversity fallback.
/// This function is deterministic and does not perform I/O or mutate the input lists.
List<RankedCandidate> rankCandidates(
  List<FeedCandidate> candidates,
  ViewerProfile profile,
  RankerConfig config,
  int limit,
) {
  _validateConfig(config, limit);
  final preparedProfile = _prepareProfile(profile, config);
  final hasLearnedNegativePreference = preparedProfile.preferencesByKey.values
      .any(
        (feature) =>
            feature.score < 0 &&
            feature.confidence >= config.minimumPreferenceConfidence,
      );
  if ((preparedProfile.lessLikeLabelKeys.isNotEmpty ||
          hasLearnedNegativePreference) &&
      config.weights.negativePreference == 0) {
    throw ArgumentError(
      'Negative preference weight must be positive when the viewer has negative preferences.',
    );
  }
  for (final candidate in candidates) {
    _validateCandidate(candidate, config.taxonomyVersion);
  }
  if (limit == 0) return const [];

  final eligible = candidates.where((candidate) {
    if (!candidate.eligible ||
        !candidate.visibleToViewer ||
        preparedProfile.blockedCreatorIds.contains(candidate.creatorId) ||
        preparedProfile.mutedCreatorIds.contains(candidate.creatorId) ||
        preparedProfile.hiddenContentIds.contains(candidate.id) ||
        preparedProfile.recentExposureContentIds.contains(candidate.id) ||
        candidate.labels.any(
          (label) => _labelIsControlled(label, preparedProfile.hiddenLabelKeys),
        )) {
      return false;
    }
    return true;
  });

  final ranked = <RankedCandidate>[];
  for (final candidate in eligible) {
    final match = _classifyTier(candidate, preparedProfile, config);
    ranked.add(
      RankedCandidate(
        candidate: candidate,
        tier: match.tier,
        score: _scoreCandidate(candidate, match.tier, preparedProfile, config),
        reasonCode: match.reasonCode,
        rankerVersion: config.rankerVersion,
      ),
    );
  }
  ranked.sort(_compareRanked);

  final seenContentIds = <String>{};
  final seenDuplicateGroups = <String>{};
  final deduplicated = ranked.where((item) {
    final candidate = item.candidate;
    if (!seenContentIds.add(candidate.id)) return false;
    final duplicateGroupId = candidate.duplicateGroupId;
    return duplicateGroupId == null ||
        seenDuplicateGroups.add(duplicateGroupId);
  }).toList();

  return _diversify(deduplicated, limit, config);
}
