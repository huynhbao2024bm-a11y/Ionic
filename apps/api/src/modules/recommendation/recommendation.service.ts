import { createHash } from "node:crypto";
import { BadRequestException, Injectable, NotFoundException } from "@nestjs/common";
import { DatabaseService } from "../database/database.service.js";
import { rankCandidates } from "./ranker.js";
import { buildRankerConfig, readCandidateLimit } from "./ranker-config.js";
import { RecommendationSignalsService } from "./recommendation-signals.service.js";
import type { ContentKind, ContentLabel, FeedCandidate, PreferenceFeature, PreferenceSignalKind, ViewerProfile } from "./types.js";

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

interface FeedCursor {
  readonly asOfMs: number;
  readonly afterId: string;
  readonly snapshotKey: string;
}

interface FeedPostRow {
  readonly id: string;
  readonly author_id: string;
  readonly body: string;
  readonly kind: ContentKind;
  readonly mime_type: "video/webm" | "video/mp4" | null;
  readonly created_at: Date;
  readonly author_handle: string;
  readonly author_display_name: string;
  readonly taxonomy_version: string;
  readonly dimension: ContentLabel["dimension"];
  readonly label_id: string;
  readonly confidence: number;
  readonly source: ContentLabel["source"];
  readonly like_count: number;
  readonly reply_count: number;
  readonly liked: boolean;
  readonly saved: boolean;
}

type MutableFeedCandidate = Omit<FeedCandidate, "labels"> & { labels: ContentLabel[] };

function parseCursor(input: unknown): FeedCursor | undefined {
  if (input === undefined) return undefined;
  if (typeof input !== "string" || input.length > 256 || !/^[A-Za-z0-9_-]+$/.test(input)) {
    throw new BadRequestException("Feed cursor is invalid.");
  }
  try {
    const value: unknown = JSON.parse(Buffer.from(input, "base64url").toString("utf8"));
    if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error("Invalid cursor shape");
    const record = value as Record<string, unknown>;
    if (
      Object.keys(record).length !== 3 ||
      !Number.isSafeInteger(record.asOfMs) || (record.asOfMs as number) < 0 ||
      (record.asOfMs as number) > Date.now() + 60_000 ||
      typeof record.afterId !== "string" || !uuidPattern.test(record.afterId) ||
      typeof record.snapshotKey !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(record.snapshotKey)
    ) {
      throw new Error("Invalid cursor values");
    }
    return { asOfMs: record.asOfMs as number, afterId: record.afterId, snapshotKey: record.snapshotKey };
  } catch {
    throw new BadRequestException("Feed cursor is invalid.");
  }
}

function encodeCursor(cursor: FeedCursor): string {
  return Buffer.from(JSON.stringify(cursor)).toString("base64url");
}

function rankedSnapshotKey(rankedIds: readonly string[]): string {
  return createHash("sha256").update(JSON.stringify(rankedIds)).digest("base64url");
}

function parseContentId(value: string): string {
  if (!uuidPattern.test(value)) throw new BadRequestException("Content ID is invalid.");
  return value;
}

function parsePreference(input: unknown): "more" | "less" | "none" {
  if (typeof input !== "object" || input === null || Array.isArray(input)) {
    throw new BadRequestException("Preference must be an object.");
  }
  const record = input as Record<string, unknown>;
  if (Object.keys(record).length !== 1 || !["more", "less", "none"].includes(String(record.preference))) {
    throw new BadRequestException("Preference is invalid.");
  }
  return record.preference as "more" | "less" | "none";
}

function parseVideoSignal(input: unknown): { readonly eventId: string; readonly kind: "active_view" | "skip" } {
  if (typeof input !== "object" || input === null || Array.isArray(input)) {
    throw new BadRequestException("Video signal is invalid.");
  }
  const record = input as Record<string, unknown>;
  if (
    Object.keys(record).length !== 2 ||
    typeof record.eventId !== "string" || !uuidPattern.test(record.eventId) ||
    (record.kind !== "active_view" && record.kind !== "skip")
  ) {
    throw new BadRequestException("Video signal is invalid.");
  }
  return { eventId: record.eventId, kind: record.kind };
}

function parsePaused(input: unknown): boolean {
  if (typeof input !== "object" || input === null || Array.isArray(input)) {
    throw new BadRequestException("Settings must be an object.");
  }
  const record = input as Record<string, unknown>;
  if (Object.keys(record).length !== 1 || typeof record.paused !== "boolean") {
    throw new BadRequestException("Settings are invalid.");
  }
  return record.paused;
}

function activeTaxonomyVersion(): string {
  const version = process.env.RECOMMENDATION_TAXONOMY_VERSION?.trim() || "ionic-taxonomy-v1";
  if (version.length > 64) throw new Error("RECOMMENDATION_TAXONOMY_VERSION cannot exceed 64 characters.");
  return version;
}

const validSignalKinds = new Set<PreferenceSignalKind>([
  "like", "unlike", "save", "unsave", "follow", "unfollow", "comment", "share", "active_view", "skip",
  "more_like_this", "less_like_this", "hide",
]);

function parseSourceSummary(values: readonly string[]): readonly PreferenceSignalKind[] {
  if (values.length === 0 || values.some((value) => !validSignalKinds.has(value as PreferenceSignalKind))) {
    throw new Error("Stored preference feature has an invalid source summary.");
  }
  return values as readonly PreferenceSignalKind[];
}

@Injectable()
export class RecommendationService {
  constructor(
    private readonly database: DatabaseService,
    private readonly signals: RecommendationSignalsService,
  ) {}

  async forYou(
    viewerId: string,
    limit: number,
    cursorInput: unknown,
  ): Promise<{
    readonly items: readonly {
      readonly id: string;
      readonly authorId: string;
      readonly body: string;
      readonly kind: ContentKind;
      readonly mimeType?: "video/webm" | "video/mp4";
      readonly createdAt: string;
      readonly authorHandle: string;
      readonly authorDisplayName: string;
      readonly likeCount: number;
      readonly replyCount: number;
      readonly liked: boolean;
      readonly saved: boolean;
    }[];
    readonly nextCursor: string | null;
  }> {
    const cursor = parseCursor(cursorInput);
    const asOfMs = cursor?.asOfMs ?? Date.now();
    const taxonomyVersion = activeTaxonomyVersion();
    const candidateLimit = readCandidateLimit();
    const rankerConfig = buildRankerConfig(asOfMs);
    const [profile, rows] = await Promise.all([
      this.loadViewerProfile(viewerId, taxonomyVersion, asOfMs),
      this.loadCandidates(
        viewerId,
        taxonomyVersion,
        asOfMs,
        candidateLimit,
        rankerConfig.minimumPreferenceConfidence,
        rankerConfig.preferenceHalfLifeMs,
        rankerConfig.adjacentLabels,
      ),
    ]);

    const candidatesById = new Map<string, { candidate: MutableFeedCandidate; post: FeedPostRow }>();
    for (const row of rows) {
      const item = candidatesById.get(row.id);
      const label: ContentLabel = {
        taxonomyVersion: row.taxonomy_version,
        dimension: row.dimension,
        labelId: row.label_id,
        confidence: row.confidence,
        source: row.source,
      };
      if (item) {
        item.candidate.labels = [...item.candidate.labels, label];
      } else {
        candidatesById.set(row.id, {
          candidate: {
            id: row.id,
            creatorId: row.author_id,
            kind: row.kind,
            publishedAtMs: row.created_at.getTime(),
            labels: [label],
            eligible: true,
            visibleToViewer: true,
          },
          post: row,
        });
      }
    }

    const ranked = rankCandidates(
      [...candidatesById.values()].map((item) => item.candidate),
      profile,
      rankerConfig,
      candidateLimit,
    );
    const snapshotKey = rankedSnapshotKey(ranked.map(({ candidate }) => candidate.id));
    let startIndex = 0;
    if (cursor) {
      if (cursor.snapshotKey !== snapshotKey) {
        throw new BadRequestException("Feed ranking changed; refresh the feed.");
      }
      const cursorIndex = ranked.findIndex((item) => item.candidate.id === cursor.afterId);
      if (cursorIndex < 0) throw new BadRequestException("Feed cursor is no longer valid.");
      startIndex = cursorIndex + 1;
    }
    const page = ranked.slice(startIndex, startIndex + limit);
    const items = page.map(({ candidate }) => {
      const post = candidatesById.get(candidate.id)!.post;
      return {
        id: post.id,
        authorId: post.author_id,
        body: post.body,
        kind: post.kind,
        ...(post.mime_type ? { mimeType: post.mime_type } : {}),
        createdAt: post.created_at.toISOString(),
        authorHandle: post.author_handle,
        authorDisplayName: post.author_display_name,
        likeCount: post.like_count,
        replyCount: post.reply_count,
        liked: post.liked,
        saved: post.saved,
      };
    });
    const last = page.at(-1);
    const nextCursor = startIndex + page.length < ranked.length && last
      ? encodeCursor({ asOfMs, afterId: last.candidate.id, snapshotKey })
      : null;
    return { items, nextCursor };
  }

  async settings(viewerId: string): Promise<{ readonly paused: boolean }> {
    const result = await this.database.query<{ learning_paused: boolean }>(
      "SELECT learning_paused FROM user_recommendation_setting WHERE user_id = $1",
      [viewerId],
    );
    return { paused: result.rows[0]?.learning_paused ?? false };
  }

  async recordVideoSignal(
    viewerId: string,
    inputContentId: string,
    input: unknown,
  ): Promise<{ readonly status: "recorded" | "duplicate" | "paused" }> {
    const contentId = parseContentId(inputContentId);
    const signal = parseVideoSignal(input);
    const version = activeTaxonomyVersion();
    return this.database.transaction(async (client) => {
      await client.query(
        `INSERT INTO user_recommendation_setting(user_id, learning_paused)
         VALUES ($1, false) ON CONFLICT (user_id) DO NOTHING`,
        [viewerId],
      );
      const setting = await client.query<{ learning_paused: boolean }>(
        "SELECT learning_paused FROM user_recommendation_setting WHERE user_id = $1 FOR UPDATE",
        [viewerId],
      );
      if (setting.rows[0]?.learning_paused) return { status: "paused" };

      const eligible = await client.query<{ id: string }>(
        `SELECT c.id
         FROM content c
         JOIN video_asset a ON a.content_id = c.id AND a.state = 'ready'
         JOIN app_user u ON u.id = c.author_id AND u.state = 'active'
         JOIN user_profile p ON p.user_id = u.id
         WHERE c.id = $1 AND c.kind = 'short_video' AND c.visibility = 'public'
           AND c.status = 'published' AND c.deleted_at IS NULL
           AND (p.visibility = 'public' OR EXISTS (
             SELECT 1 FROM account_follow f WHERE f.follower_id = $2 AND f.followed_id = u.id
           ))
           AND EXISTS (
             SELECT 1 FROM content_label l
             WHERE l.content_id = c.id AND l.taxonomy_version = $3 AND l.status = 'active'
           )
           AND NOT EXISTS (
             SELECT 1 FROM account_block b
             WHERE (b.blocker_id = $2 AND b.blocked_id = u.id)
                OR (b.blocker_id = u.id AND b.blocked_id = $2)
           )
           AND NOT EXISTS (SELECT 1 FROM account_mute m WHERE m.muter_id = $2 AND m.muted_id = u.id)
           AND NOT EXISTS (SELECT 1 FROM feed_content_hide h WHERE h.user_id = $2 AND h.content_id = c.id)`,
        [contentId, viewerId, version],
      );
      if (!eligible.rows[0]) throw new NotFoundException("Video was not found.");

      await client.query(
        "DELETE FROM recommendation_video_signal WHERE user_id = $1 AND expires_at <= now()",
        [viewerId],
      );
      // The browser's playback measurement is client-reported. Serialize the
      // per-viewer/content/kind check so fresh event IDs cannot repeatedly
      // amplify one clip's preference signal within the same cooldown window.
      await client.query(
        `SELECT pg_advisory_xact_lock(hashtextextended(concat_ws(':', $1::text, $2::text, $3::text), 0))`,
        [viewerId, contentId, signal.kind],
      );
      const recentSignal = await client.query(
        `SELECT 1
         FROM recommendation_video_signal
         WHERE user_id = $1 AND content_id = $2 AND signal_kind = $3
           AND created_at > now() - interval '24 hours'
         LIMIT 1`,
        [viewerId, contentId, signal.kind],
      );
      if (recentSignal.rows[0]) return { status: "duplicate" };

      const inserted = await client.query<{ event_id: string }>(
        `INSERT INTO recommendation_video_signal(user_id, event_id, content_id, signal_kind)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (user_id, event_id) DO NOTHING
         RETURNING event_id`,
        [viewerId, signal.eventId, contentId, signal.kind],
      );
      if (!inserted.rows[0]) return { status: "duplicate" };

      await this.signals.recordContentAction(client, viewerId, contentId, signal.eventId, signal.kind);
      return { status: "recorded" };
    });
  }

  async updateSettings(viewerId: string, input: unknown): Promise<{ readonly paused: boolean }> {
    const paused = parsePaused(input);
    await this.database.query(
      `INSERT INTO user_recommendation_setting(user_id, learning_paused)
       VALUES ($1, $2)
       ON CONFLICT (user_id) DO UPDATE SET learning_paused = EXCLUDED.learning_paused, updated_at = now()`,
      [viewerId, paused],
    );
    return { paused };
  }

  async reset(viewerId: string): Promise<{ readonly status: "reset" }> {
    await this.database.transaction(async (client) => {
      await client.query("DELETE FROM user_preference_control WHERE user_id = $1", [viewerId]);
      await client.query("DELETE FROM user_preference_feature WHERE user_id = $1", [viewerId]);
      await client.query("DELETE FROM recommendation_video_signal WHERE user_id = $1", [viewerId]);
      await client.query(
        `INSERT INTO user_recommendation_setting(user_id, learning_paused)
         VALUES ($1, false)
         ON CONFLICT (user_id) DO UPDATE SET learning_paused = false, updated_at = now()`,
        [viewerId],
      );
    });
    return { status: "reset" };
  }

  async setPreference(
    viewerId: string,
    inputContentId: string,
    body: unknown,
  ): Promise<{ readonly status: "updated" }> {
    const contentId = parseContentId(inputContentId);
    const preference = parsePreference(body);
    const taxonomyVersion = activeTaxonomyVersion();
    await this.database.transaction(async (client) => {
      const labels = await this.accessibleContentLabels(client, viewerId, contentId, taxonomyVersion);
      if (labels.length === 0) throw new BadRequestException("Content has no active recommendation labels.");
      for (const label of labels) {
        if (preference === "none") {
          await client.query(
            `DELETE FROM user_preference_control
             WHERE user_id = $1 AND taxonomy_version = $2 AND dimension = $3 AND label_id = $4`,
            [viewerId, taxonomyVersion, label.dimension, label.label_id],
          );
        } else {
          await client.query(
            `INSERT INTO user_preference_control(user_id, taxonomy_version, dimension, label_id, control)
             VALUES ($1, $2, $3, $4, $5)
             ON CONFLICT (user_id, taxonomy_version, dimension, label_id)
             DO UPDATE SET control = EXCLUDED.control, source = 'item_feedback', updated_at = now()`,
            [viewerId, taxonomyVersion, label.dimension, label.label_id, preference],
          );
        }
      }
    });
    return { status: "updated" };
  }

  async hide(viewerId: string, inputContentId: string): Promise<{ readonly status: "hidden" }> {
    const contentId = parseContentId(inputContentId);
    await this.database.transaction(async (client) => {
      await this.accessibleContentLabels(client, viewerId, contentId, activeTaxonomyVersion(), false);
      await client.query(
        "INSERT INTO feed_content_hide(user_id, content_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
        [viewerId, contentId],
      );
    });
    return { status: "hidden" };
  }

  private async accessibleContentLabels(
    client: import("pg").PoolClient,
    viewerId: string,
    contentId: string,
    taxonomyVersion: string,
    requireLabels = true,
  ): Promise<readonly { dimension: ContentLabel["dimension"]; label_id: string }[]> {
    const access = await client.query<{ id: string }>(
      `SELECT c.id
       FROM content c
       JOIN app_user u ON u.id = c.author_id AND u.state = 'active'
       JOIN user_profile p ON p.user_id = u.id
       WHERE c.id = $1 AND c.status = 'published' AND c.visibility = 'public' AND c.deleted_at IS NULL
         AND (p.visibility = 'public' OR EXISTS (
           SELECT 1 FROM account_follow f WHERE f.follower_id = $2 AND f.followed_id = u.id
         ))
         AND NOT EXISTS (
           SELECT 1 FROM account_block b
           WHERE (b.blocker_id = $2 AND b.blocked_id = u.id) OR (b.blocker_id = u.id AND b.blocked_id = $2)
         )
       FOR SHARE OF c, u, p`,
      [contentId, viewerId],
    );
    if (access.rowCount !== 1) throw new NotFoundException("Content was not found.");
    if (!requireLabels) return [];
    const labels = await client.query<{ dimension: ContentLabel["dimension"]; label_id: string }>(
      `SELECT dimension, label_id FROM content_label
       WHERE content_id = $1 AND taxonomy_version = $2 AND status = 'active'
       ORDER BY dimension, label_id`,
      [contentId, taxonomyVersion],
    );
    return labels.rows;
  }

  private async loadViewerProfile(viewerId: string, taxonomyVersion: string, nowMs: number): Promise<ViewerProfile> {
    const [following, blocked, muted, hidden, controls, features] = await Promise.all([
      this.database.query<{ creator_id: string }>(
        `SELECT f.followed_id AS creator_id FROM account_follow f
         WHERE f.follower_id = $1 AND NOT EXISTS (
           SELECT 1 FROM account_block b
           WHERE (b.blocker_id = $1 AND b.blocked_id = f.followed_id) OR (b.blocker_id = f.followed_id AND b.blocked_id = $1)
         ) ORDER BY f.followed_id`,
        [viewerId],
      ),
      this.database.query<{ creator_id: string }>(
        `SELECT CASE WHEN blocker_id = $1 THEN blocked_id ELSE blocker_id END AS creator_id
         FROM account_block WHERE blocker_id = $1 OR blocked_id = $1 ORDER BY creator_id`,
        [viewerId],
      ),
      this.database.query<{ creator_id: string }>(
        "SELECT muted_id AS creator_id FROM account_mute WHERE muter_id = $1 ORDER BY muted_id",
        [viewerId],
      ),
      this.database.query<{ content_id: string }>("SELECT content_id FROM feed_content_hide WHERE user_id = $1 ORDER BY content_id", [viewerId]),
      this.database.query<{ dimension: ContentLabel["dimension"]; label_id: string; control: "more" | "less" }>(
        `SELECT dimension, label_id, control FROM user_preference_control
         WHERE user_id = $1 AND taxonomy_version = $2 ORDER BY dimension, label_id`,
        [viewerId, taxonomyVersion],
      ),
      this.database.query<{
        dimension: ContentLabel["dimension"];
        label_id: string;
        score: number;
        confidence: number;
        source_summary: string[];
        updated_at: Date;
        expires_at: Date;
      }>(
        `SELECT dimension, label_id, score, confidence, source_summary, updated_at, expires_at
         FROM user_preference_feature
         WHERE user_id = $1 AND taxonomy_version = $2 AND expires_at > $3
         ORDER BY dimension, label_id`,
        [viewerId, taxonomyVersion, new Date(nowMs)],
      ),
    ]);
    const preferences: PreferenceFeature[] = features.rows.map((row) => ({
      taxonomyVersion,
      dimension: row.dimension,
      labelId: row.label_id,
      sourceSummary: parseSourceSummary(row.source_summary),
      score: row.score,
      confidence: row.confidence,
      updatedAtMs: row.updated_at.getTime(),
      expiresAtMs: row.expires_at.getTime(),
    }));
    return {
      explicitInterests: controls.rows
        .filter((control) => control.control === "more")
        .map((control) => ({ taxonomyVersion, dimension: control.dimension, labelId: control.label_id })),
      preferences,
      followingCreatorIds: following.rows.map((row) => row.creator_id),
      blockedCreatorIds: blocked.rows.map((row) => row.creator_id),
      mutedCreatorIds: muted.rows.map((row) => row.creator_id),
      hiddenContentIds: hidden.rows.map((row) => row.content_id),
      hiddenLabels: [],
      lessLikeLabels: controls.rows
        .filter((control) => control.control === "less")
        .map((control) => ({ taxonomyVersion, dimension: control.dimension, labelId: control.label_id })),
      recentExposures: [],
    };
  }

  private async loadCandidates(
    viewerId: string,
    taxonomyVersion: string,
    asOfMs: number,
    candidateLimit: number,
    minimumPreferenceConfidence: number,
    preferenceHalfLifeMs: number,
    adjacentLabels: Readonly<Record<string, readonly string[]>>,
  ): Promise<readonly FeedPostRow[]> {
    const result = await this.database.query<FeedPostRow>(
      `WITH learned_positive_labels AS (
         SELECT feature.dimension, feature.label_id
         FROM user_preference_feature feature
         WHERE feature.user_id = $2
           AND feature.taxonomy_version = $1
           AND feature.dimension IN ('topic', 'format', 'language', 'context')
           AND feature.score > 0
           AND feature.confidence * power(
             2::double precision,
             -((extract(epoch FROM ($3::timestamptz - feature.updated_at)) * 1000.0)::double precision)
               / $6::double precision
           ) >= $5
           AND feature.updated_at <= $3
           AND feature.expires_at > $3
           AND NOT EXISTS (
             SELECT 1 FROM user_preference_control less_control
             WHERE less_control.user_id = $2
               AND less_control.taxonomy_version = $1
               AND less_control.dimension = feature.dimension
               AND less_control.label_id = feature.label_id
               AND less_control.control = 'less'
           )
       ), positive_labels AS (
         SELECT control.dimension, control.label_id
         FROM user_preference_control control
         WHERE control.user_id = $2 AND control.taxonomy_version = $1 AND control.control = 'more'
         UNION
         SELECT dimension, label_id FROM learned_positive_labels
       ), adjacent_pairs AS (
         SELECT preferred.label_id AS preferred_label_id, neighbor.label_id AS adjacent_label_id
         FROM jsonb_each($7::jsonb) AS preferred(label_id, neighbors)
         CROSS JOIN LATERAL jsonb_array_elements_text(preferred.neighbors) AS neighbor(label_id)
       ), eligible_candidates AS NOT MATERIALIZED (
         SELECT c.id, c.author_id, c.created_at, c.kind
         FROM content c
         JOIN app_user u ON u.id = c.author_id AND u.state = 'active'
         JOIN user_profile p ON p.user_id = u.id
         WHERE c.kind = 'text' AND c.visibility = 'public' AND c.status = 'published' AND c.deleted_at IS NULL
           AND (c.kind = 'text' OR EXISTS (
             SELECT 1 FROM video_asset ready_video
             WHERE ready_video.content_id = c.id AND ready_video.state = 'ready'
           ))
           AND c.created_at <= $3
           AND (p.visibility = 'public' OR EXISTS (
             SELECT 1 FROM account_follow f WHERE f.follower_id = $2 AND f.followed_id = u.id
           ))
           AND NOT EXISTS (
             SELECT 1 FROM account_block b
             WHERE (b.blocker_id = $2 AND b.blocked_id = u.id) OR (b.blocker_id = u.id AND b.blocked_id = $2)
           )
           AND NOT EXISTS (
             SELECT 1 FROM account_mute m WHERE m.muter_id = $2 AND m.muted_id = u.id
           )
           AND NOT EXISTS (
             SELECT 1 FROM feed_content_hide h WHERE h.user_id = $2 AND h.content_id = c.id
           )
           AND EXISTS (
             SELECT 1 FROM content_label active_label
             WHERE active_label.content_id = c.id
               AND active_label.taxonomy_version = $1
               AND active_label.status = 'active'
           )
       ), followed_candidates AS (
         SELECT e.id, e.created_at
         FROM eligible_candidates e
         WHERE EXISTS (
           SELECT 1 FROM account_follow f
           WHERE f.follower_id = $2 AND f.followed_id = e.author_id
         )
         ORDER BY e.created_at DESC, e.id DESC
         LIMIT $4
       ), preference_candidates AS (
         SELECT e.id, e.created_at
         FROM eligible_candidates e
         JOIN content_label matched_label
           ON matched_label.content_id = e.id
          AND matched_label.taxonomy_version = $1
          AND matched_label.status = 'active'
         JOIN positive_labels preference
           ON preference.dimension = matched_label.dimension
          AND preference.label_id = matched_label.label_id
         GROUP BY e.id, e.created_at
         ORDER BY e.created_at DESC, e.id DESC
         LIMIT $4
       ), adjacent_candidates AS (
         SELECT e.id, e.created_at
         FROM eligible_candidates e
         JOIN content_label matched_label
           ON matched_label.content_id = e.id
          AND matched_label.taxonomy_version = $1
          AND matched_label.status = 'active'
          AND matched_label.dimension = 'topic'
         JOIN adjacent_pairs adjacent ON adjacent.adjacent_label_id = matched_label.label_id
         JOIN learned_positive_labels learned
           ON learned.dimension = matched_label.dimension
          AND learned.label_id = adjacent.preferred_label_id
         WHERE NOT EXISTS (
           SELECT 1 FROM user_preference_control less_control
           WHERE less_control.user_id = $2
             AND less_control.taxonomy_version = $1
             AND less_control.dimension = matched_label.dimension
             AND less_control.label_id = matched_label.label_id
             AND less_control.control = 'less'
         )
         GROUP BY e.id, e.created_at
         ORDER BY e.created_at DESC, e.id DESC
         LIMIT $4
       ), fresh_candidates AS (
         SELECT e.id, e.created_at
         FROM eligible_candidates e
         ORDER BY e.created_at DESC, e.id DESC
         LIMIT $4
       ), source_candidates AS (
         SELECT e.id, e.created_at, 0 AS source_priority
         FROM followed_candidates e
         UNION ALL
         SELECT e.id, e.created_at, 1 AS source_priority
         FROM preference_candidates e
         UNION ALL
         SELECT e.id, e.created_at, 2 AS source_priority
         FROM adjacent_candidates e
         UNION ALL
         SELECT e.id, e.created_at, 3 AS source_priority
         FROM fresh_candidates e
       ), source_positions AS (
         SELECT id, source_priority,
                row_number() OVER (
                  PARTITION BY source_priority ORDER BY created_at DESC, id DESC
                ) AS source_position
         FROM source_candidates
       ), best_source AS (
         SELECT DISTINCT ON (id) id, source_priority, source_position
         FROM source_positions
         ORDER BY id, source_position, source_priority
       ), selected_ids AS (
         SELECT id
         FROM best_source
         ORDER BY source_position, source_priority, id
         LIMIT $4
       ), selected_candidates AS (
         SELECT c.id, c.author_id, c.body, c.kind, c.created_at, NULL::text AS mime_type,
                u.handle AS author_handle, p.display_name AS author_display_name,
                (SELECT count(*)::int FROM content_reaction r WHERE r.content_id = c.id) AS like_count,
           (SELECT count(*)::int FROM content_reply r WHERE r.content_id = c.id AND r.status = 'published') AS reply_count,
                EXISTS (SELECT 1 FROM content_reaction r WHERE r.content_id = c.id AND r.user_id = $2) AS liked,
                EXISTS (SELECT 1 FROM content_bookmark b WHERE b.content_id = c.id AND b.user_id = $2) AS saved
         FROM selected_ids selected
         JOIN eligible_candidates eligible ON eligible.id = selected.id
         JOIN content c ON c.id = eligible.id
         JOIN app_user u ON u.id = c.author_id
         JOIN user_profile p ON p.user_id = u.id
       )
       SELECT e.id, e.author_id, e.body, e.kind, e.mime_type, e.created_at, e.author_handle, e.author_display_name,
              e.like_count, e.reply_count, e.liked, e.saved,
              l.taxonomy_version, l.dimension, l.label_id, l.confidence, l.source
       FROM selected_candidates e
       JOIN content_label l ON l.content_id = e.id AND l.taxonomy_version = $1 AND l.status = 'active'
       ORDER BY e.created_at DESC, e.id DESC, l.dimension, l.label_id`,
      [
        taxonomyVersion,
        viewerId,
        new Date(asOfMs),
        candidateLimit,
        minimumPreferenceConfidence,
        preferenceHalfLifeMs,
        JSON.stringify(adjacentLabels),
      ],
    );
    return result.rows;
  }
}
