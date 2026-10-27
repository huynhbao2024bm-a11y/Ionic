export type LabelDimension =
  | "topic"
  | "format"
  | "language"
  | "context"
  | "lineage";

export type ContentKind = "text" | "short_video";

export type LabelSource = "creator" | "user_corrected" | "rule";

export interface ContentLabel {
  readonly taxonomyVersion: string;
  readonly dimension: LabelDimension;
  readonly labelId: string;
  readonly confidence: number;
  readonly source: LabelSource;
}

export interface FeedCandidate {
  readonly id: string;
  readonly creatorId: string;
  readonly kind: ContentKind;
  readonly publishedAtMs: number;
  readonly labels: readonly ContentLabel[];
  readonly eligible: boolean;
  readonly visibleToViewer: boolean;
  readonly duplicateGroupId?: string;
  readonly qualityScore?: number;
}

export interface ExplicitInterest {
  readonly taxonomyVersion: string;
  readonly dimension: LabelDimension;
  readonly labelId: string;
}

export interface TaxonomyLabelRef {
  readonly taxonomyVersion: string;
  readonly dimension: LabelDimension;
  readonly labelId: string;
}

export interface PreferenceFeature {
  readonly taxonomyVersion: string;
  readonly dimension: LabelDimension;
  readonly labelId: string;
  readonly sourceSummary: readonly PreferenceSignalKind[];
  /** Signed score. Positive values indicate interest; negative values indicate less interest. */
  readonly score: number;
  readonly confidence: number;
  readonly updatedAtMs: number;
  readonly expiresAtMs: number;
}

export interface ExposureRecord {
  readonly contentId: string;
  readonly creatorId: string;
  readonly taxonomyVersion: string;
  readonly topicLabelIds: readonly string[];
  readonly exposedAtMs: number;
}

export interface ViewerProfile {
  readonly explicitInterests: readonly ExplicitInterest[];
  readonly preferences: readonly PreferenceFeature[];
  readonly followingCreatorIds: readonly string[];
  readonly blockedCreatorIds: readonly string[];
  readonly mutedCreatorIds: readonly string[];
  readonly hiddenContentIds: readonly string[];
  readonly hiddenLabels: readonly TaxonomyLabelRef[];
  readonly lessLikeLabels: readonly TaxonomyLabelRef[];
  readonly recentExposures: readonly ExposureRecord[];
}

export type RelevanceTier = "direct" | "strong" | "adjacent" | "fresh";

export type RecommendationReasonCode =
  | "followed_creator"
  | "explicit_interest"
  | "learned_interest"
  | "adjacent_topic"
  | "fresh_content";

export interface RankedCandidate {
  readonly candidate: FeedCandidate;
  readonly tier: RelevanceTier;
  readonly score: number;
  readonly reasonCode: RecommendationReasonCode;
  readonly rankerVersion: string;
}

export interface RankerWeights {
  readonly topic: number;
  readonly format: number;
  readonly language: number;
  readonly context: number;
  readonly social: number;
  readonly freshness: number;
  readonly quality: number;
  readonly exploration: number;
  readonly negativePreference: number;
  readonly repetition: number;
}

export interface RankerConfig {
  readonly rankerVersion: string;
  readonly taxonomyVersion: string;
  readonly nowMs: number;
  readonly weights: RankerWeights;
  readonly freshnessHalfLifeMs: number;
  readonly preferenceHalfLifeMs: number;
  readonly recentExposureWindowMs: number;
  readonly minimumPreferenceConfidence: number;
  readonly strongMatchThreshold: number;
  readonly maxPerCreator: number;
  readonly maxPerTopic: number;
  readonly maxConsecutiveTopic: number;
  /** Neighbor labels are keyed by label ID and come from the active taxonomy version. */
  readonly adjacentLabels: Readonly<Record<string, readonly string[]>>;
}

export type PreferenceSignalKind =
  | "like"
  | "unlike"
  | "save"
  | "unsave"
  | "follow"
  | "unfollow"
  | "comment"
  | "share"
  | "active_view"
  | "skip"
  | "more_like_this"
  | "less_like_this"
  | "hide";

export interface PreferenceSignal {
  readonly idempotencyKey: string;
  readonly taxonomyVersion: string;
  readonly dimension: LabelDimension;
  readonly labelId: string;
  readonly kind: PreferenceSignalKind;
  readonly confidence: number;
  readonly occurredAtMs: number;
}

export interface PreferenceUpdatePolicy {
  readonly nowMs: number;
  readonly halfLifeMs: number;
  readonly expiryAfterMs: number;
  readonly maxAbsoluteScore: number;
  readonly learningPaused?: boolean;
  /** Signed contribution per signal kind; product calibration owns these values. */
  readonly signalWeights: Readonly<Record<PreferenceSignalKind, number>>;
}

export interface PreferenceUpdateResult {
  readonly features: readonly PreferenceFeature[];
  readonly appliedIdempotencyKeys: readonly string[];
}
