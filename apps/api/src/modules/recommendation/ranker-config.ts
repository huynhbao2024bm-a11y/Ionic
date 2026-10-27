import type { RankerConfig, RankerWeights } from "./types.js";

const defaultWeights: RankerWeights = {
  topic: 1,
  format: 1,
  language: 1,
  context: 1,
  social: 1,
  freshness: 1,
  quality: 0,
  exploration: 1,
  negativePreference: 1,
  repetition: 1,
};

const taxonomyV1AdjacentLabels: Readonly<Record<string, readonly string[]>> = {
  "topic.design": ["topic.product", "topic.creativity"],
  "topic.software": ["topic.product", "topic.learning"],
  "topic.product": ["topic.design", "topic.software"],
  "topic.writing": ["topic.learning", "topic.creativity"],
  "topic.learning": ["topic.software", "topic.writing", "topic.creativity"],
  "topic.creativity": ["topic.design", "topic.writing", "topic.learning"],
};

function adjacentLabelsFor(taxonomyVersion: string): Readonly<Record<string, readonly string[]>> {
  return taxonomyVersion === "ionic-taxonomy-v1" ? taxonomyV1AdjacentLabels : {};
}

function readWeight(name: keyof RankerWeights): number {
  const key = `RECOMMENDATION_WEIGHT_${name.replace(/[A-Z]/g, (letter) => `_${letter}`).toUpperCase()}`;
  const raw = process.env[key]?.trim();
  if (!raw) return defaultWeights[name];
  const value = Number(raw);
  if (!Number.isFinite(value) || value < 0) throw new Error(`${key} must be a finite non-negative number.`);
  return value;
}

function readPositiveNumber(key: string, fallback: number): number {
  const raw = process.env[key]?.trim();
  if (!raw) return fallback;
  const value = Number(raw);
  if (!Number.isFinite(value) || value <= 0) throw new Error(`${key} must be a finite positive number.`);
  return value;
}

function readUnitNumber(key: string, fallback: number): number {
  const value = readPositiveNumber(key, fallback);
  if (value > 1) throw new Error(`${key} must be between 0 and 1.`);
  return value;
}

function readInteger(key: string, fallback: number): number {
  const raw = process.env[key]?.trim();
  if (!raw) return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 1) throw new Error(`${key} must be a positive integer.`);
  return value;
}

export function buildRankerConfig(nowMs: number): RankerConfig {
  const weights = Object.fromEntries(
    Object.keys(defaultWeights).map((name) => [name, readWeight(name as keyof RankerWeights)]),
  ) as unknown as RankerWeights;
  const taxonomyVersion = process.env.RECOMMENDATION_TAXONOMY_VERSION?.trim() || "ionic-taxonomy-v1";
  return {
    rankerVersion: process.env.RECOMMENDATION_RANKER_VERSION?.trim() || "ionic-deterministic-v1",
    taxonomyVersion,
    nowMs,
    weights,
    freshnessHalfLifeMs: readPositiveNumber("RECOMMENDATION_FRESHNESS_HALF_LIFE_MS", 86_400_000),
    preferenceHalfLifeMs: readPositiveNumber("RECOMMENDATION_PREFERENCE_HALF_LIFE_MS", 1_209_600_000),
    recentExposureWindowMs: readPositiveNumber("RECOMMENDATION_RECENT_EXPOSURE_WINDOW_MS", 604_800_000),
    minimumPreferenceConfidence: readUnitNumber("RECOMMENDATION_MIN_PREFERENCE_CONFIDENCE", 0.55),
    strongMatchThreshold: readUnitNumber("RECOMMENDATION_STRONG_MATCH_THRESHOLD", 0.18),
    maxPerCreator: readInteger("RECOMMENDATION_MAX_PER_CREATOR", 3),
    maxPerTopic: readInteger("RECOMMENDATION_MAX_PER_TOPIC", 4),
    maxConsecutiveTopic: readInteger("RECOMMENDATION_MAX_CONSECUTIVE_TOPIC", 2),
    adjacentLabels: adjacentLabelsFor(taxonomyVersion),
  };
}

export function readCandidateLimit(): number {
  const limit = readInteger("RECOMMENDATION_CANDIDATE_LIMIT", 500);
  if (limit > 5_000) throw new Error("RECOMMENDATION_CANDIDATE_LIMIT cannot exceed 5000.");
  return limit;
}
