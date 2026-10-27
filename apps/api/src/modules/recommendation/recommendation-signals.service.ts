import { Injectable } from "@nestjs/common";
import type { PoolClient } from "pg";
import { applyPreferenceSignals } from "./preference-profile.js";
import { buildRankerConfig } from "./ranker-config.js";
import type { ContentLabel, PreferenceFeature, PreferenceSignal, PreferenceSignalKind, PreferenceUpdatePolicy } from "./types.js";

type ContentActionSignal = Extract<PreferenceSignalKind, "like" | "unlike" | "save" | "unsave" | "comment">
  | "active_view"
  | "skip";

const defaultSignalWeights: Readonly<Record<PreferenceSignalKind, number>> = {
  like: 0.18,
  unlike: -0.12,
  save: 0.24,
  unsave: -0.16,
  follow: 0.25,
  unfollow: -0.2,
  comment: 0,
  share: 0,
  active_view: 0.05,
  skip: -0.03,
  more_like_this: 0.35,
  less_like_this: -0.35,
  hide: -0.2,
};

function configuredSignalWeights(): Readonly<Record<PreferenceSignalKind, number>> {
  return Object.fromEntries(Object.entries(defaultSignalWeights).map(([kind, fallback]) => {
    const key = `RECOMMENDATION_SIGNAL_WEIGHT_${kind.replace(/[A-Z]/g, (letter) => `_${letter}`).toUpperCase()}`;
    const raw = process.env[key]?.trim();
    if (!raw) return [kind, fallback];
    const value = Number(raw);
    if (!Number.isFinite(value) || value < -1 || value > 1) {
      throw new Error(`${key} must be between -1 and 1.`);
    }
    return [kind, value];
  })) as unknown as Readonly<Record<PreferenceSignalKind, number>>;
}

function taxonomyVersion(): string {
  return process.env.RECOMMENDATION_TAXONOMY_VERSION?.trim() || "ionic-taxonomy-v1";
}

function updatePolicy(nowMs: number): PreferenceUpdatePolicy {
  const config = buildRankerConfig(nowMs);
  const expiryRaw = process.env.RECOMMENDATION_PREFERENCE_EXPIRY_MS?.trim();
  const expiryAfterMs = expiryRaw ? Number(expiryRaw) : 5_184_000_000;
  if (!Number.isFinite(expiryAfterMs) || expiryAfterMs <= 0) {
    throw new Error("RECOMMENDATION_PREFERENCE_EXPIRY_MS must be a finite positive number.");
  }
  return {
    nowMs,
    halfLifeMs: config.preferenceHalfLifeMs,
    expiryAfterMs,
    maxAbsoluteScore: 1,
    signalWeights: configuredSignalWeights(),
  };
}

@Injectable()
export class RecommendationSignalsService {
  /** The caller supplies a domain-transition or persisted behavior-event ID as the idempotency key. */
  async recordContentAction(
    client: PoolClient,
    userId: string,
    contentId: string,
    actionId: string,
    kind: ContentActionSignal,
  ): Promise<void> {
    const nowMs = Date.now();
    const policy = updatePolicy(nowMs);
    if (policy.signalWeights[kind] === 0) return;
    await client.query(
      `INSERT INTO user_recommendation_setting(user_id, learning_paused)
       VALUES ($1, false) ON CONFLICT (user_id) DO NOTHING`,
      [userId],
    );
    const setting = await client.query<{ learning_paused: boolean }>(
      "SELECT learning_paused FROM user_recommendation_setting WHERE user_id = $1 FOR UPDATE",
      [userId],
    );
    if (setting.rows[0]?.learning_paused) return;

    const version = taxonomyVersion();
    const labelsResult = await client.query<{
      dimension: ContentLabel["dimension"];
      label_id: string;
      confidence: number;
    }>(
      `SELECT dimension, label_id, confidence FROM content_label
       WHERE content_id = $1 AND taxonomy_version = $2 AND status = 'active'
       ORDER BY dimension, label_id`,
      [contentId, version],
    );
    if (labelsResult.rows.length === 0) return;

    for (const label of labelsResult.rows) {
      const idempotencyKey = `${actionId}:${kind}:${label.dimension}:${label.label_id}`;

      const existingResult = await client.query<{
        score: number;
        confidence: number;
        source_summary: string[];
        updated_at: Date;
        expires_at: Date;
      }>(
        `SELECT score, confidence, source_summary, updated_at, expires_at
         FROM user_preference_feature
         WHERE user_id = $1 AND taxonomy_version = $2 AND dimension = $3 AND label_id = $4`,
        [userId, version, label.dimension, label.label_id],
      );
      const existing: PreferenceFeature[] = existingResult.rows.map((row) => ({
        taxonomyVersion: version,
        dimension: label.dimension,
        labelId: label.label_id,
        sourceSummary: row.source_summary as PreferenceSignalKind[],
        score: row.score,
        confidence: row.confidence,
        updatedAtMs: row.updated_at.getTime(),
        expiresAtMs: row.expires_at.getTime(),
      }));
      const signal: PreferenceSignal = {
        idempotencyKey,
        taxonomyVersion: version,
        dimension: label.dimension,
        labelId: label.label_id,
        kind,
        confidence: label.confidence,
        occurredAtMs: nowMs,
      };
      const updated = applyPreferenceSignals(existing, [signal], [], policy).features[0];
      if (!updated) continue;
      await client.query(
        `INSERT INTO user_preference_feature
          (user_id, taxonomy_version, dimension, label_id, score, confidence, source_summary, updated_at, expires_at)
         VALUES ($1, $2, $3, $4, $5, $6, $7, to_timestamp($8 / 1000.0), to_timestamp($9 / 1000.0))
         ON CONFLICT (user_id, taxonomy_version, dimension, label_id)
         DO UPDATE SET score = EXCLUDED.score, confidence = EXCLUDED.confidence,
           source_summary = EXCLUDED.source_summary, updated_at = EXCLUDED.updated_at, expires_at = EXCLUDED.expires_at`,
        [userId, updated.taxonomyVersion, updated.dimension, updated.labelId, updated.score,
          updated.confidence, updated.sourceSummary, updated.updatedAtMs, updated.expiresAtMs],
      );
    }
  }
}
