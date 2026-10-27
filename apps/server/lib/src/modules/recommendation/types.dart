// The enum names are persisted and shared with the existing API contract.
// ignore_for_file: constant_identifier_names

enum LabelDimension { topic, format, language, context, lineage }

enum ContentKind { text, short_video }

enum LabelSource { creator, user_corrected, rule }

enum RelevanceTier { direct, strong, adjacent, fresh }

enum RecommendationReasonCode {
  followed_creator,
  explicit_interest,
  learned_interest,
  adjacent_topic,
  fresh_content,
}

enum PreferenceSignalKind {
  like,
  unlike,
  save,
  unsave,
  follow,
  unfollow,
  comment,
  share,
  active_view,
  skip,
  more_like_this,
  less_like_this,
  hide,
}

class ContentLabel {
  const ContentLabel({
    required this.taxonomyVersion,
    required this.dimension,
    required this.labelId,
    required this.confidence,
    required this.source,
  });

  final String taxonomyVersion;
  final LabelDimension dimension;
  final String labelId;
  final double confidence;
  final LabelSource source;
}

class FeedCandidate {
  const FeedCandidate({
    required this.id,
    required this.creatorId,
    required this.kind,
    required this.publishedAtMs,
    required this.labels,
    required this.eligible,
    required this.visibleToViewer,
    this.duplicateGroupId,
    this.qualityScore,
  });

  final String id;
  final String creatorId;
  final ContentKind kind;
  final double publishedAtMs;
  final List<ContentLabel> labels;
  final bool eligible;
  final bool visibleToViewer;
  final String? duplicateGroupId;
  final double? qualityScore;
}

class ExplicitInterest {
  const ExplicitInterest({
    required this.taxonomyVersion,
    required this.dimension,
    required this.labelId,
  });

  final String taxonomyVersion;
  final LabelDimension dimension;
  final String labelId;
}

class TaxonomyLabelRef {
  const TaxonomyLabelRef({
    required this.taxonomyVersion,
    required this.dimension,
    required this.labelId,
  });

  final String taxonomyVersion;
  final LabelDimension dimension;
  final String labelId;
}

class PreferenceFeature {
  const PreferenceFeature({
    required this.taxonomyVersion,
    required this.dimension,
    required this.labelId,
    required this.sourceSummary,
    required this.score,
    required this.confidence,
    required this.updatedAtMs,
    required this.expiresAtMs,
  });

  final String taxonomyVersion;
  final LabelDimension dimension;
  final String labelId;
  final List<PreferenceSignalKind> sourceSummary;
  final double score;
  final double confidence;
  final double updatedAtMs;
  final double expiresAtMs;
}

class ExposureRecord {
  const ExposureRecord({
    required this.contentId,
    required this.creatorId,
    required this.taxonomyVersion,
    required this.topicLabelIds,
    required this.exposedAtMs,
  });

  final String contentId;
  final String creatorId;
  final String taxonomyVersion;
  final List<String> topicLabelIds;
  final double exposedAtMs;
}

class ViewerProfile {
  const ViewerProfile({
    required this.explicitInterests,
    required this.preferences,
    required this.followingCreatorIds,
    required this.blockedCreatorIds,
    required this.mutedCreatorIds,
    required this.hiddenContentIds,
    required this.hiddenLabels,
    required this.lessLikeLabels,
    required this.recentExposures,
  });

  final List<ExplicitInterest> explicitInterests;
  final List<PreferenceFeature> preferences;
  final List<String> followingCreatorIds;
  final List<String> blockedCreatorIds;
  final List<String> mutedCreatorIds;
  final List<String> hiddenContentIds;
  final List<TaxonomyLabelRef> hiddenLabels;
  final List<TaxonomyLabelRef> lessLikeLabels;
  final List<ExposureRecord> recentExposures;
}

class RankedCandidate {
  const RankedCandidate({
    required this.candidate,
    required this.tier,
    required this.score,
    required this.reasonCode,
    required this.rankerVersion,
  });

  final FeedCandidate candidate;
  final RelevanceTier tier;
  final double score;
  final RecommendationReasonCode reasonCode;
  final String rankerVersion;
}

class RankerWeights {
  const RankerWeights({
    required this.topic,
    required this.format,
    required this.language,
    required this.context,
    required this.social,
    required this.freshness,
    required this.quality,
    required this.exploration,
    required this.negativePreference,
    required this.repetition,
  });

  final double topic;
  final double format;
  final double language;
  final double context;
  final double social;
  final double freshness;
  final double quality;
  final double exploration;
  final double negativePreference;
  final double repetition;

  double valueFor(String name) => switch (name) {
    'topic' => topic,
    'format' => format,
    'language' => language,
    'context' => context,
    'social' => social,
    'freshness' => freshness,
    'quality' => quality,
    'exploration' => exploration,
    'negativePreference' => negativePreference,
    'repetition' => repetition,
    _ => throw ArgumentError.value(name, 'name', 'Unknown ranker weight'),
  };

  List<(String, double)> get entries => [
    ('topic', topic),
    ('format', format),
    ('language', language),
    ('context', context),
    ('social', social),
    ('freshness', freshness),
    ('quality', quality),
    ('exploration', exploration),
    ('negativePreference', negativePreference),
    ('repetition', repetition),
  ];
}

class RankerConfig {
  const RankerConfig({
    required this.rankerVersion,
    required this.taxonomyVersion,
    required this.nowMs,
    required this.weights,
    required this.freshnessHalfLifeMs,
    required this.preferenceHalfLifeMs,
    required this.recentExposureWindowMs,
    required this.minimumPreferenceConfidence,
    required this.strongMatchThreshold,
    required this.maxPerCreator,
    required this.maxPerTopic,
    required this.maxConsecutiveTopic,
    required this.adjacentLabels,
  });

  final String rankerVersion;
  final String taxonomyVersion;
  final double nowMs;
  final RankerWeights weights;
  final double freshnessHalfLifeMs;
  final double preferenceHalfLifeMs;
  final double recentExposureWindowMs;
  final double minimumPreferenceConfidence;
  final double strongMatchThreshold;
  final int maxPerCreator;
  final int maxPerTopic;
  final int maxConsecutiveTopic;
  final Map<String, List<String>> adjacentLabels;
}

class PreferenceSignal {
  const PreferenceSignal({
    required this.idempotencyKey,
    required this.taxonomyVersion,
    required this.dimension,
    required this.labelId,
    required this.kind,
    required this.confidence,
    required this.occurredAtMs,
  });

  final String idempotencyKey;
  final String taxonomyVersion;
  final LabelDimension dimension;
  final String labelId;
  final PreferenceSignalKind kind;
  final double confidence;
  final double occurredAtMs;
}

class PreferenceUpdatePolicy {
  const PreferenceUpdatePolicy({
    required this.nowMs,
    required this.halfLifeMs,
    required this.expiryAfterMs,
    required this.maxAbsoluteScore,
    required this.signalWeights,
    this.learningPaused = false,
  });

  final double nowMs;
  final double halfLifeMs;
  final double expiryAfterMs;
  final double maxAbsoluteScore;
  final bool learningPaused;
  final Map<PreferenceSignalKind, double> signalWeights;
}

class PreferenceUpdateResult {
  const PreferenceUpdateResult({
    required this.features,
    required this.appliedIdempotencyKeys,
  });

  final List<PreferenceFeature> features;
  final List<String> appliedIdempotencyKeys;
}
