import type {
  ContentLabel,
  FeedCandidate,
  LabelDimension,
  PreferenceFeature,
  PreferenceSignalKind,
  RankerConfig,
  RankedCandidate,
  RecommendationReasonCode,
  RelevanceTier,
  ViewerProfile,
} from "./types.js";

const tierOrder: Readonly<Record<RelevanceTier, number>> = {
  direct: 0,
  strong: 1,
  adjacent: 2,
  fresh: 3,
};
const labelDimensions: readonly LabelDimension[] = ["topic", "format", "language", "context", "lineage"];
const preferenceSignalKinds: readonly PreferenceSignalKind[] = [
  "like", "unlike", "save", "unsave", "follow", "unfollow", "comment", "share", "active_view", "skip",
  "more_like_this", "less_like_this", "hide",
];

function clamp01(value: number): number {
  return Math.min(1, Math.max(0, value));
}

function labelKey(taxonomyVersion: string, dimension: LabelDimension, labelId: string): string {
  return JSON.stringify([taxonomyVersion, dimension, labelId]);
}

function labelIsControlled(label: ContentLabel, controlKeys: ReadonlySet<string>): boolean {
  return controlKeys.has(labelKey(label.taxonomyVersion, label.dimension, label.labelId));
}

function validateConfig(config: RankerConfig, limit: number): void {
  if (config.rankerVersion.trim().length === 0 || config.taxonomyVersion.trim().length === 0) {
    throw new Error("Ranker and taxonomy versions are required.");
  }
  if (!Number.isFinite(config.nowMs)) {
    throw new RangeError("Ranker time must be finite.");
  }
  if (
    !Number.isFinite(config.freshnessHalfLifeMs) ||
    config.freshnessHalfLifeMs <= 0 ||
    !Number.isFinite(config.preferenceHalfLifeMs) ||
    config.preferenceHalfLifeMs <= 0 ||
    !Number.isFinite(config.recentExposureWindowMs) ||
    config.recentExposureWindowMs < 0
  ) {
    throw new RangeError("Ranker time windows must be finite and valid.");
  }
  if (
    !Number.isFinite(config.minimumPreferenceConfidence) ||
    !Number.isFinite(config.strongMatchThreshold) ||
    config.minimumPreferenceConfidence < 0 ||
    config.minimumPreferenceConfidence > 1 ||
    config.strongMatchThreshold <= 0 ||
    config.strongMatchThreshold > 1
  ) {
    throw new RangeError("Ranker confidence and match thresholds must be between 0 and 1.");
  }
  if (
    !Number.isInteger(limit) ||
    limit < 0 ||
    !Number.isInteger(config.maxPerCreator) ||
    config.maxPerCreator < 1 ||
    !Number.isInteger(config.maxPerTopic) ||
    config.maxPerTopic < 1 ||
    !Number.isInteger(config.maxConsecutiveTopic) ||
    config.maxConsecutiveTopic < 1
  ) {
    throw new RangeError("Feed limit and diversity caps must be positive integers.");
  }

  const weightNames: readonly (keyof RankerConfig["weights"])[] = [
    "topic", "format", "language", "context", "social", "freshness",
    "quality", "exploration", "negativePreference", "repetition",
  ];
  const nonPenaltyWeightTotal = weightNames
    .filter((name) => name !== "repetition" && name !== "negativePreference")
    .reduce((sum, name) => {
      const weight = config.weights[name];
      if (!Number.isFinite(weight) || weight < 0) {
        throw new RangeError("Ranker weights must be finite and non-negative.");
      }
      return sum + weight;
    }, 0);
  for (const name of weightNames) {
    const weight = config.weights[name];
    if (!Number.isFinite(weight) || weight < 0) {
      throw new RangeError("Ranker weights must be finite and non-negative.");
    }
  }
  if (!Number.isFinite(nonPenaltyWeightTotal) || nonPenaltyWeightTotal <= 0) {
    throw new RangeError("At least one positive ranking weight must be greater than zero.");
  }
}

interface PreparedProfile extends Omit<
  ViewerProfile,
  | "explicitInterests"
  | "preferences"
  | "followingCreatorIds"
  | "blockedCreatorIds"
  | "mutedCreatorIds"
  | "hiddenContentIds"
  | "hiddenLabels"
  | "lessLikeLabels"
  | "recentExposures"
> {
  readonly explicitInterestKeys: ReadonlySet<string>;
  readonly preferencesByKey: ReadonlyMap<string, PreferenceFeature>;
  readonly positivePreferenceLabelIds: readonly string[];
  readonly followingCreatorIds: ReadonlySet<string>;
  readonly blockedCreatorIds: ReadonlySet<string>;
  readonly mutedCreatorIds: ReadonlySet<string>;
  readonly hiddenContentIds: ReadonlySet<string>;
  readonly hiddenLabelKeys: ReadonlySet<string>;
  readonly lessLikeLabelKeys: ReadonlySet<string>;
  readonly recentExposureContentIds: ReadonlySet<string>;
  readonly recentExposureCount: number;
  readonly recentTopicExposureCount: number;
  readonly recentCreatorCounts: ReadonlyMap<string, number>;
  readonly recentLabelCounts: ReadonlyMap<string, number>;
}

function incrementCount(counts: Map<string, number>, key: string): void {
  counts.set(key, (counts.get(key) ?? 0) + 1);
}

function prepareProfile(profile: ViewerProfile, config: RankerConfig): PreparedProfile {
  const explicitInterestKeys = new Set<string>();
  for (const interest of profile.explicitInterests) {
    if (interest.labelId.trim().length === 0 || !labelDimensions.includes(interest.dimension)) {
      throw new Error("Explicit interests require a valid taxonomy dimension and label ID.");
    }
    if (interest.taxonomyVersion !== config.taxonomyVersion) {
      throw new Error("Explicit interests must be migrated before activating a new taxonomy version.");
    }
    explicitInterestKeys.add(labelKey(interest.taxonomyVersion, interest.dimension, interest.labelId));
  }

  const indexControls = (controls: ViewerProfile["hiddenLabels"]): Set<string> => {
    const keys = new Set<string>();
    for (const control of controls) {
      if (control.taxonomyVersion !== config.taxonomyVersion) {
        throw new Error("Explicit label controls must be migrated before activating a new taxonomy version.");
      }
      if (control.labelId.trim().length === 0) {
        throw new Error("Explicit label controls require a label ID.");
      }
      if (!labelDimensions.includes(control.dimension)) {
        throw new Error("Explicit label control dimension is invalid.");
      }
      keys.add(labelKey(control.taxonomyVersion, control.dimension, control.labelId));
    }
    return keys;
  }
  const hiddenLabelKeys = indexControls(profile.hiddenLabels);
  const lessLikeLabelKeys = indexControls(profile.lessLikeLabels);

  const preferencesByKey = new Map<string, PreferenceFeature>();
  const positivePreferenceLabelIds = new Set<string>();
  for (const feature of profile.preferences) {
    if (
      !Number.isFinite(feature.score) ||
      feature.score < -1 ||
      feature.score > 1 ||
      !Number.isFinite(feature.confidence) ||
      feature.confidence < 0 ||
      feature.confidence > 1 ||
      !Number.isFinite(feature.updatedAtMs) ||
      feature.updatedAtMs > config.nowMs ||
      !Number.isFinite(feature.expiresAtMs) ||
      feature.expiresAtMs <= feature.updatedAtMs ||
      feature.taxonomyVersion.trim().length === 0 ||
      feature.labelId.trim().length === 0 ||
      !labelDimensions.includes(feature.dimension) ||
      feature.sourceSummary.length === 0 ||
      feature.sourceSummary.some((kind) => !preferenceSignalKinds.includes(kind)) ||
      new Set(feature.sourceSummary).size !== feature.sourceSummary.length
    ) {
      throw new RangeError("Viewer preference features contain invalid values.");
    }
    if (feature.taxonomyVersion !== config.taxonomyVersion || feature.expiresAtMs <= config.nowMs) {
      continue;
    }
    const key = labelKey(feature.taxonomyVersion, feature.dimension, feature.labelId);
    if (preferencesByKey.has(key)) {
      throw new Error("Viewer preference features must be unique per taxonomy label.");
    }
    const decay = 2 ** (-(config.nowMs - feature.updatedAtMs) / config.preferenceHalfLifeMs);
    const currentFeature: PreferenceFeature = {
      ...feature,
      score: feature.score * decay,
      confidence: feature.confidence * decay,
    };
    preferencesByKey.set(key, currentFeature);
    if (currentFeature.score > 0 && currentFeature.confidence >= config.minimumPreferenceConfidence) {
      positivePreferenceLabelIds.add(feature.labelId);
    }
  }

  const recentExposures = profile.recentExposures.filter((exposure) => {
    if (
      exposure.contentId.trim().length === 0 ||
      exposure.creatorId.trim().length === 0 ||
      exposure.taxonomyVersion.trim().length === 0 ||
      !Number.isFinite(exposure.exposedAtMs) ||
      exposure.exposedAtMs > config.nowMs ||
      exposure.topicLabelIds.some((labelId) => labelId.trim().length === 0)
    ) {
      throw new RangeError("Recent exposure records contain invalid values.");
    }
    return config.nowMs - exposure.exposedAtMs <= config.recentExposureWindowMs;
  });
  const recentExposureContentIds = new Set<string>();
  const recentCreatorCounts = new Map<string, number>();
  const recentLabelCounts = new Map<string, number>();
  let recentTopicExposureCount = 0;
  for (const exposure of recentExposures) {
    recentExposureContentIds.add(exposure.contentId);
    incrementCount(recentCreatorCounts, exposure.creatorId);
    if (exposure.taxonomyVersion === config.taxonomyVersion) {
      recentTopicExposureCount += 1;
      for (const labelId of new Set(exposure.topicLabelIds)) {
        incrementCount(recentLabelCounts, labelId);
      }
    }
  }

  return {
    explicitInterestKeys,
    preferencesByKey,
    positivePreferenceLabelIds: [...positivePreferenceLabelIds],
    followingCreatorIds: new Set(profile.followingCreatorIds),
    blockedCreatorIds: new Set(profile.blockedCreatorIds),
    mutedCreatorIds: new Set(profile.mutedCreatorIds),
    hiddenContentIds: new Set(profile.hiddenContentIds),
    hiddenLabelKeys,
    lessLikeLabelKeys,
    recentExposureContentIds,
    recentExposureCount: recentExposures.length,
    recentTopicExposureCount,
    recentCreatorCounts,
    recentLabelCounts,
  };
}

function labelMatchScore(
  labels: readonly ContentLabel[],
  profile: PreparedProfile,
  dimension: LabelDimension,
  config: RankerConfig,
): number {
  let best = 0;
  for (const label of labels) {
    if (label.dimension !== dimension || labelIsControlled(label, profile.lessLikeLabelKeys)) {
      continue;
    }

    const key = labelKey(config.taxonomyVersion, dimension, label.labelId);
    if (profile.explicitInterestKeys.has(key)) {
      best = Math.max(best, label.confidence);
      continue;
    }

    const feature = profile.preferencesByKey.get(key);
    if (
      feature !== undefined &&
      feature.score > 0 &&
      feature.confidence >= config.minimumPreferenceConfidence
    ) {
      best = Math.max(
        best,
        clamp01(feature.score) * feature.confidence * label.confidence,
      );
    }
  }
  return clamp01(best);
}

function hasExplicitMatch(candidate: FeedCandidate, profile: PreparedProfile, config: RankerConfig): boolean {
  return candidate.labels.some((label) =>
    !labelIsControlled(label, profile.lessLikeLabelKeys) &&
    profile.explicitInterestKeys.has(labelKey(config.taxonomyVersion, label.dimension, label.labelId)),
  );
}

function hasStrongPreferenceMatch(
  candidate: FeedCandidate,
  profile: PreparedProfile,
  config: RankerConfig,
): boolean {
  const dimensions: readonly LabelDimension[] = ["topic", "format", "language", "context"];
  return dimensions.some(
    (dimension) => {
      const match = labelMatchScore(candidate.labels, profile, dimension, config);
      return match > 0 && match >= config.strongMatchThreshold;
    },
  );
}

function negativePreferenceScore(
  candidate: FeedCandidate,
  profile: PreparedProfile,
  config: RankerConfig,
): number {
  let strongestNegativeMatch = 0;
  for (const label of candidate.labels) {
    if (labelIsControlled(label, profile.lessLikeLabelKeys)) {
      strongestNegativeMatch = Math.max(strongestNegativeMatch, label.confidence);
      continue;
    }

    const feature = profile.preferencesByKey.get(
      labelKey(config.taxonomyVersion, label.dimension, label.labelId),
    );
    if (
      feature !== undefined &&
      feature.score < 0 &&
      feature.confidence >= config.minimumPreferenceConfidence
    ) {
      strongestNegativeMatch = Math.max(
        strongestNegativeMatch,
        -feature.score * feature.confidence * label.confidence,
      );
    }
  }
  return clamp01(strongestNegativeMatch);
}

function hasAdjacentMatch(
  candidate: FeedCandidate,
  profile: PreparedProfile,
  config: RankerConfig,
): boolean {
  return candidate.labels.some((candidateLabel) => {
    if (candidateLabel.dimension !== "topic" && candidateLabel.dimension !== "format") {
      return false;
    }
    if (labelIsControlled(candidateLabel, profile.lessLikeLabelKeys)) {
      return false;
    }
    const candidateNeighbors = config.adjacentLabels[candidateLabel.labelId] ?? [];
    return profile.positivePreferenceLabelIds.some((preferredLabel) => {
      const preferredFeature = profile.preferencesByKey.get(
        labelKey(config.taxonomyVersion, candidateLabel.dimension, preferredLabel),
      );
      if (preferredFeature === undefined) {
        return false;
      }
      const preferredNeighbors = config.adjacentLabels[preferredLabel] ?? [];
      return candidateNeighbors.includes(preferredLabel) || preferredNeighbors.includes(candidateLabel.labelId);
    });
  });
}

function classifyTier(
  candidate: FeedCandidate,
  profile: PreparedProfile,
  config: RankerConfig,
): { tier: RelevanceTier; reasonCode: RecommendationReasonCode } {
  const creatorIsFollowed = profile.followingCreatorIds.has(candidate.creatorId);
  if (creatorIsFollowed && !candidate.labels.some((label) => labelIsControlled(label, profile.lessLikeLabelKeys))) {
    return { tier: "direct", reasonCode: "followed_creator" };
  }
  if (hasExplicitMatch(candidate, profile, config)) {
    return { tier: "direct", reasonCode: "explicit_interest" };
  }
  if (hasStrongPreferenceMatch(candidate, profile, config)) {
    return { tier: "strong", reasonCode: "learned_interest" };
  }
  if (hasAdjacentMatch(candidate, profile, config)) {
    return { tier: "adjacent", reasonCode: "adjacent_topic" };
  }
  return { tier: "fresh", reasonCode: "fresh_content" };
}

function freshnessScore(candidate: FeedCandidate, config: RankerConfig): number {
  const ageMs = Math.max(0, config.nowMs - candidate.publishedAtMs);
  return 2 ** (-ageMs / config.freshnessHalfLifeMs);
}

function repetitionScore(
  candidate: FeedCandidate,
  profile: PreparedProfile,
): number {
  if (profile.recentExposureCount === 0) {
    return 0;
  }

  let repeatedLabelCount = 0;
  for (const label of candidate.labels) {
    if (label.dimension === "topic") {
      repeatedLabelCount += profile.recentLabelCounts.get(label.labelId) ?? 0;
    }
  }
  const repeatedCreator = profile.recentCreatorCounts.get(candidate.creatorId) ?? 0;
  const creatorRepetition = repeatedCreator / profile.recentExposureCount;
  const topicRepetition = profile.recentTopicExposureCount === 0
    ? 0
    : Math.min(profile.recentTopicExposureCount, repeatedLabelCount) / profile.recentTopicExposureCount;
  return clamp01((creatorRepetition + topicRepetition) / 2);
}

function scoreCandidate(
  candidate: FeedCandidate,
  tier: RelevanceTier,
  profile: PreparedProfile,
  config: RankerConfig,
): number {
  const components: Partial<Record<keyof RankerConfig["weights"], number>> = {
    topic: labelMatchScore(candidate.labels, profile, "topic", config),
    format: labelMatchScore(candidate.labels, profile, "format", config),
    language: labelMatchScore(candidate.labels, profile, "language", config),
    context: labelMatchScore(candidate.labels, profile, "context", config),
    social: profile.followingCreatorIds.has(candidate.creatorId) ? 1 : 0,
    freshness: freshnessScore(candidate, config),
    exploration: tier === "adjacent" || tier === "fresh" ? 1 : 0,
    negativePreference: negativePreferenceScore(candidate, profile, config),
    repetition: repetitionScore(candidate, profile),
  };

  if (candidate.qualityScore !== undefined) {
    components.quality = candidate.qualityScore;
  }

  let weightedTotal = 0;
  let availableWeight = 0;
  for (const [name, value] of Object.entries(components)) {
    if (value === undefined) {
      continue;
    }
    const weight = config.weights[name as keyof RankerConfig["weights"]];
    if (name !== "repetition" && name !== "negativePreference") {
      weightedTotal += value * weight;
      availableWeight += weight;
    }
  }

  if (availableWeight === 0) {
    return 0;
  }
  return weightedTotal / availableWeight -
    config.weights.negativePreference * (components.negativePreference ?? 0) -
    config.weights.repetition * (components.repetition ?? 0);
}

function primaryTopic(candidate: FeedCandidate): string | undefined {
  let best: ContentLabel | undefined;
  for (const label of candidate.labels) {
    if (
      label.dimension === "topic" &&
      (best === undefined ||
        label.confidence > best.confidence ||
        (label.confidence === best.confidence && label.labelId.localeCompare(best.labelId) < 0))
    ) {
      best = label;
    }
  }
  return best?.labelId;
}

function compareRanked(left: RankedCandidate, right: RankedCandidate): number {
  const tierDifference = tierOrder[left.tier] - tierOrder[right.tier];
  if (tierDifference !== 0) {
    return tierDifference;
  }
  const scoreDifference = right.score - left.score;
  if (scoreDifference !== 0) {
    return scoreDifference;
  }
  const freshnessDifference = right.candidate.publishedAtMs - left.candidate.publishedAtMs;
  return freshnessDifference !== 0
    ? freshnessDifference
    : left.candidate.id.localeCompare(right.candidate.id);
}

interface DiversityCaps {
  readonly maxPerCreator: number;
  readonly maxPerTopic: number;
  readonly maxConsecutiveTopic: number;
}

function selectWithCaps(
  ranked: readonly RankedCandidate[],
  limit: number,
  caps: DiversityCaps,
  alreadySelected: readonly RankedCandidate[],
): { selected: RankedCandidate[]; deferred: RankedCandidate[] } {
  const selected = [...alreadySelected];
  const deferred: RankedCandidate[] = [];

  for (const item of ranked) {
    if (selected.length >= limit) {
      deferred.push(item);
      continue;
    }

    const topic = primaryTopic(item.candidate);
    const creatorCount = selected.filter(
      (selectedItem) => selectedItem.candidate.creatorId === item.candidate.creatorId,
    ).length;
    const topicCount = topic === undefined
      ? 0
      : selected.filter((selectedItem) => primaryTopic(selectedItem.candidate) === topic).length;
    let consecutiveTopicCount = 0;
    if (topic !== undefined) {
      for (let index = selected.length - 1; index >= 0; index -= 1) {
        if (primaryTopic(selected[index].candidate) !== topic) {
          break;
        }
        consecutiveTopicCount += 1;
      }
    }

    if (
      creatorCount >= caps.maxPerCreator ||
      (topic !== undefined && topicCount >= caps.maxPerTopic) ||
      (topic !== undefined && consecutiveTopicCount >= caps.maxConsecutiveTopic)
    ) {
      deferred.push(item);
      continue;
    }
    selected.push(item);
  }

  return { selected, deferred };
}

function diversify(
  ranked: readonly RankedCandidate[],
  limit: number,
  config: RankerConfig,
): RankedCandidate[] {
  let selected: RankedCandidate[] = [];
  let remaining = [...ranked];
  const capPasses: readonly DiversityCaps[] = [
    {
      maxPerCreator: config.maxPerCreator,
      maxPerTopic: config.maxPerTopic,
      maxConsecutiveTopic: config.maxConsecutiveTopic,
    },
    {
      maxPerCreator: config.maxPerCreator,
      maxPerTopic: Number.MAX_SAFE_INTEGER,
      maxConsecutiveTopic: config.maxConsecutiveTopic,
    },
    {
      maxPerCreator: Number.MAX_SAFE_INTEGER,
      maxPerTopic: Number.MAX_SAFE_INTEGER,
      maxConsecutiveTopic: config.maxConsecutiveTopic,
    },
    {
      maxPerCreator: Number.MAX_SAFE_INTEGER,
      maxPerTopic: Number.MAX_SAFE_INTEGER,
      maxConsecutiveTopic: Number.MAX_SAFE_INTEGER,
    },
  ];

  for (const caps of capPasses) {
    if (selected.length >= limit) {
      break;
    }
    const result = selectWithCaps(remaining, limit, caps, selected);
    selected = result.selected;
    remaining = result.deferred;
  }

  return selected.slice(0, limit);
}

function validateCandidate(candidate: FeedCandidate, taxonomyVersion: string): void {
  if (
    candidate.id.trim().length === 0 ||
    candidate.creatorId.trim().length === 0 ||
    !Number.isFinite(candidate.publishedAtMs) ||
    candidate.labels.length === 0
  ) {
    throw new Error("Feed candidates require IDs, a valid publish time, and at least one label.");
  }
  if (candidate.kind !== "text" && candidate.kind !== "short_video") {
    throw new Error("Candidate content kind is invalid.");
  }
  if (typeof candidate.eligible !== "boolean" || typeof candidate.visibleToViewer !== "boolean") {
    throw new Error("Candidate eligibility and visibility must be explicit booleans.");
  }
  if (candidate.duplicateGroupId !== undefined && candidate.duplicateGroupId.trim().length === 0) {
    throw new Error("Duplicate group ID cannot be empty when provided.");
  }
  const seenLabels = new Set<string>();
  for (const label of candidate.labels) {
    if (
      label.taxonomyVersion !== taxonomyVersion ||
      label.labelId.trim().length === 0 ||
      !labelDimensions.includes(label.dimension) ||
      !Number.isFinite(label.confidence) ||
      label.confidence < 0 ||
      label.confidence > 1
    ) {
      throw new Error("Candidate labels must be valid and use the active taxonomy version.");
    }
    const key = labelKey(label.taxonomyVersion, label.dimension, label.labelId);
    if (seenLabels.has(key)) {
      throw new Error("Candidate labels must be unique per taxonomy dimension and label.");
    }
    seenLabels.add(key);
  }
  if (
    candidate.qualityScore !== undefined &&
    (!Number.isFinite(candidate.qualityScore) || candidate.qualityScore < 0 || candidate.qualityScore > 1)
  ) {
    throw new RangeError("Candidate quality score must be between 0 and 1.");
  }
}

export function rankCandidates(
  candidates: readonly FeedCandidate[],
  profile: ViewerProfile,
  config: RankerConfig,
  limit: number,
): readonly RankedCandidate[] {
  validateConfig(config, limit);
  const preparedProfile = prepareProfile(profile, config);
  const hasLearnedNegativePreference = [...preparedProfile.preferencesByKey.values()].some(
    (feature) =>
      feature.score < 0 &&
      feature.confidence >= config.minimumPreferenceConfidence,
  );
  if (
    (preparedProfile.lessLikeLabelKeys.size > 0 || hasLearnedNegativePreference) &&
    config.weights.negativePreference === 0
  ) {
    throw new Error("Negative preference weight must be positive when the viewer has negative preferences.");
  }
  for (const candidate of candidates) {
    validateCandidate(candidate, config.taxonomyVersion);
  }
  if (limit === 0) {
    return [];
  }

  const eligible = candidates.filter((candidate) => {
    if (
      !candidate.eligible ||
      !candidate.visibleToViewer ||
      preparedProfile.blockedCreatorIds.has(candidate.creatorId) ||
      preparedProfile.mutedCreatorIds.has(candidate.creatorId) ||
      preparedProfile.hiddenContentIds.has(candidate.id) ||
      preparedProfile.recentExposureContentIds.has(candidate.id) ||
      candidate.labels.some((label) => labelIsControlled(label, preparedProfile.hiddenLabelKeys))
    ) {
      return false;
    }
    return true;
  });

  const ranked = eligible.map((candidate): RankedCandidate => {
    const { tier, reasonCode } = classifyTier(candidate, preparedProfile, config);
    return {
      candidate,
      tier,
      score: scoreCandidate(candidate, tier, preparedProfile, config),
      reasonCode,
      rankerVersion: config.rankerVersion,
    };
  }).sort(compareRanked);

  const seenContentIds = new Set<string>();
  const seenDuplicateGroups = new Set<string>();
  const deduplicated = ranked.filter(({ candidate }) => {
    if (seenContentIds.has(candidate.id)) {
      return false;
    }
    seenContentIds.add(candidate.id);
    if (candidate.duplicateGroupId === undefined) {
      return true;
    }
    if (seenDuplicateGroups.has(candidate.duplicateGroupId)) {
      return false;
    }
    seenDuplicateGroups.add(candidate.duplicateGroupId);
    return true;
  });

  return diversify(deduplicated, limit, config);
}
