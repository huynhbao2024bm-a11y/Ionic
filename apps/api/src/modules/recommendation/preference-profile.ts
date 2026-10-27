import type {
  PreferenceFeature,
  PreferenceSignal,
  PreferenceSignalKind,
  PreferenceUpdatePolicy,
  PreferenceUpdateResult,
} from "./types.js";

const labelDimensions = ["topic", "format", "language", "context", "lineage"] as const;
const signalKinds: readonly PreferenceSignalKind[] = [
  "like", "unlike", "save", "unsave", "follow", "unfollow", "comment", "share", "active_view", "skip",
  "more_like_this", "less_like_this", "hide",
];

function clamp(value: number, lower: number, upper: number): number {
  return Math.min(upper, Math.max(lower, value));
}

function decayFactor(elapsedMs: number, halfLifeMs: number): number {
  if (elapsedMs <= 0) {
    return 1;
  }
  return 2 ** (-elapsedMs / halfLifeMs);
}

function featureKey(feature: Pick<PreferenceFeature, "taxonomyVersion" | "dimension" | "labelId">): string {
  return JSON.stringify([feature.taxonomyVersion, feature.dimension, feature.labelId]);
}

function compareFeatures(left: PreferenceFeature, right: PreferenceFeature): number {
  const taxonomyOrder = left.taxonomyVersion.localeCompare(right.taxonomyVersion);
  if (taxonomyOrder !== 0) {
    return taxonomyOrder;
  }
  const dimensionOrder = left.dimension.localeCompare(right.dimension);
  return dimensionOrder !== 0 ? dimensionOrder : left.labelId.localeCompare(right.labelId);
}

function validatePolicy(policy: PreferenceUpdatePolicy): void {
  if (
    !Number.isFinite(policy.nowMs) ||
    !Number.isFinite(policy.halfLifeMs) ||
    policy.halfLifeMs <= 0 ||
    !Number.isFinite(policy.expiryAfterMs) ||
    policy.expiryAfterMs <= 0 ||
    !Number.isFinite(policy.nowMs + policy.expiryAfterMs) ||
    !Number.isFinite(policy.maxAbsoluteScore) ||
    policy.maxAbsoluteScore <= 0 ||
    policy.maxAbsoluteScore > 1
  ) {
    throw new RangeError("Preference update policy values must be finite and positive.");
  }

  for (const weight of Object.values(policy.signalWeights)) {
    if (!Number.isFinite(weight)) {
      throw new RangeError("Preference signal weights must be finite.");
    }
  }

  if (signalKinds.some((kind) => !Number.isFinite(policy.signalWeights[kind]))) {
    throw new RangeError("Every preference signal kind must have a finite configured weight.");
  }
}

function validateSignal(signal: PreferenceSignal, policy: PreferenceUpdatePolicy): void {
  if (
    signal.idempotencyKey.trim().length === 0 ||
    signal.taxonomyVersion.trim().length === 0 ||
    signal.labelId.trim().length === 0
  ) {
    throw new Error("Preference signal key and label ID are required.");
  }
  if (!labelDimensions.includes(signal.dimension) || !signalKinds.includes(signal.kind)) {
    throw new Error("Preference signal dimension or kind is invalid.");
  }
  if (
    !Number.isFinite(signal.confidence) ||
    signal.confidence < 0 ||
    signal.confidence > 1
  ) {
    throw new RangeError("Preference signal confidence must be between 0 and 1.");
  }
  if (!Number.isFinite(signal.occurredAtMs) || signal.occurredAtMs > policy.nowMs) {
    throw new RangeError("Preference signal time must be valid and cannot be in the future.");
  }
}

/**
 * Applies deduplicated, eligible feed signals to bounded preference features.
 * Event ingestion must enforce authorization and retention before calling this function.
 */
export function applyPreferenceSignals(
  currentFeatures: readonly PreferenceFeature[],
  signals: readonly PreferenceSignal[],
  previouslyAppliedKeys: readonly string[],
  policy: PreferenceUpdatePolicy,
): PreferenceUpdateResult {
  validatePolicy(policy);

  const previouslyApplied = new Set(previouslyAppliedKeys);
  const seenInBatch = new Set<string>();
  const acceptedSignals: PreferenceSignal[] = [];

  for (const signal of signals) {
    validateSignal(signal, policy);
    if (previouslyApplied.has(signal.idempotencyKey) || seenInBatch.has(signal.idempotencyKey)) {
      continue;
    }
    seenInBatch.add(signal.idempotencyKey);
    acceptedSignals.push(signal);
  }

  const byFeature = new Map<string, PreferenceFeature>();
  for (const feature of currentFeatures) {
    if (
      feature.taxonomyVersion.trim().length === 0 ||
      feature.labelId.trim().length === 0 ||
      !Number.isFinite(feature.score) ||
      !Number.isFinite(feature.confidence) ||
      feature.confidence < 0 ||
      feature.confidence > 1 ||
      !Number.isFinite(feature.updatedAtMs) ||
      feature.updatedAtMs > policy.nowMs ||
      !Number.isFinite(feature.expiresAtMs) ||
      feature.expiresAtMs <= feature.updatedAtMs ||
      Math.abs(feature.score) > policy.maxAbsoluteScore ||
      !labelDimensions.includes(feature.dimension) ||
      feature.sourceSummary.length === 0 ||
      feature.sourceSummary.some((kind) => !signalKinds.includes(kind)) ||
      new Set(feature.sourceSummary).size !== feature.sourceSummary.length
    ) {
      throw new RangeError("Existing preference features contain invalid values.");
    }
    const key = featureKey(feature);
    if (byFeature.has(key)) {
      throw new Error("Existing preference features must be unique per taxonomy label.");
    }
    if (feature.expiresAtMs > policy.nowMs) {
      byFeature.set(key, feature);
    }
  }

  if (policy.learningPaused === true) {
    return {
      features: [...byFeature.values()].sort(compareFeatures),
      appliedIdempotencyKeys: acceptedSignals.map((signal) => signal.idempotencyKey),
    };
  }

  const signalsByFeature = new Map<string, PreferenceSignal[]>();
  for (const signal of acceptedSignals) {
    const key = featureKey(signal);
    const featureSignals = signalsByFeature.get(key) ?? [];
    featureSignals.push(signal);
    signalsByFeature.set(key, featureSignals);
  }

  const allKeys = new Set([...byFeature.keys(), ...signalsByFeature.keys()]);
  const features: PreferenceFeature[] = [];
  for (const key of allKeys) {
    const existing = byFeature.get(key);
    const keySignals = signalsByFeature.get(key) ?? [];
    const reference = existing ?? keySignals[0];
    if (reference === undefined) {
      continue;
    }

    const previousDecay = existing === undefined
      ? 0
      : decayFactor(policy.nowMs - existing.updatedAtMs, policy.halfLifeMs);
    let score = existing === undefined ? 0 : existing.score * previousDecay;
    let remainingConfidence = existing === undefined
      ? 1
      : 1 - existing.confidence * previousDecay;

    for (const signal of keySignals) {
      const weight = policy.signalWeights[signal.kind];
      const signalDecay = decayFactor(policy.nowMs - signal.occurredAtMs, policy.halfLifeMs);
      score += weight * signal.confidence * signalDecay;
      remainingConfidence *= 1 - signal.confidence * signalDecay;
    }

    const sourceSummary = new Set(existing?.sourceSummary ?? []);
    for (const signal of keySignals) {
      sourceSummary.add(signal.kind);
    }

    features.push({
      taxonomyVersion: reference.taxonomyVersion,
      dimension: reference.dimension,
      labelId: reference.labelId,
      sourceSummary: [...sourceSummary].sort(),
      score: clamp(score, -policy.maxAbsoluteScore, policy.maxAbsoluteScore),
      confidence: clamp(1 - remainingConfidence, 0, 1),
      updatedAtMs: policy.nowMs,
      expiresAtMs: keySignals.length > 0
        ? policy.nowMs + policy.expiryAfterMs
        : (existing?.expiresAtMs ?? policy.nowMs + policy.expiryAfterMs),
    });
  }

  features.sort(compareFeatures);

  return {
    features,
    appliedIdempotencyKeys: acceptedSignals.map((signal) => signal.idempotencyKey),
  };
}
