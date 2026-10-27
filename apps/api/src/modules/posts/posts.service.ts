import { BadRequestException, Injectable, NotFoundException } from "@nestjs/common";
import { randomUUID } from "node:crypto";
import { DatabaseService } from "../database/database.service.js";
import { RecommendationSignalsService } from "../recommendation/recommendation-signals.service.js";
import { labelContent } from "../recommendation/content-labeler.js";
import { textLabelRules } from "../recommendation/text-label-rules.js";
import type { ContentLabel } from "../recommendation/types.js";

export interface PostView {
  readonly id: string;
  readonly authorId: string;
  readonly body: string;
  readonly createdAt: string;
  readonly likeCount: number;
  readonly replyCount: number;
  readonly liked: boolean;
  readonly saved: boolean;
}

export interface FollowingPostView extends PostView {
  readonly authorHandle: string;
  readonly authorDisplayName: string;
}

export interface PostReplyView {
  readonly id: string;
  readonly authorId: string;
  readonly authorHandle: string;
  readonly authorDisplayName: string;
  readonly body: string;
  readonly createdAt: string;
}

function parseAuthorHandle(input: string): string {
  const handle = input.startsWith("@") ? input.slice(1) : input;
  const normalized = handle.toLowerCase();
  if (!/^[a-z0-9_]{3,24}$/.test(normalized)) throw new BadRequestException("Handle is invalid.");
  return normalized;
}

function parseSearchQuery(input: unknown): string {
  if (typeof input !== "string") throw new BadRequestException("Search query is invalid.");
  const query = input.normalize("NFC").trim();
  if (query.length < 2 || query.length > 48) {
    throw new BadRequestException("Search query must contain 2–48 characters.");
  }
  return query;
}

function parsePostBody(input: unknown): string {
  if (typeof input !== "object" || input === null || Array.isArray(input)) {
    throw new BadRequestException("Body must be an object.");
  }
  const record = input as Record<string, unknown>;
  if (Object.keys(record).some((key) => key !== "body")) {
    throw new BadRequestException("Request contains an unsupported field.");
  }
  const body = record.body;
  if (typeof body !== "string") throw new BadRequestException("Post body must be text.");
  const normalized = body.normalize("NFC").trim();
  if (normalized.length < 1 || normalized.length > 280) {
    throw new BadRequestException("Post body must contain 1–280 characters.");
  }
  return normalized;
}

function parseReplyBody(input: unknown): string {
  if (typeof input !== "object" || input === null || Array.isArray(input)) {
    throw new BadRequestException("Body must be an object.");
  }
  const record = input as Record<string, unknown>;
  if (Object.keys(record).length !== 1 || typeof record.body !== "string") {
    throw new BadRequestException("Reply body is invalid.");
  }
  const body = record.body.normalize("NFC").trim();
  if (body.length < 1 || body.length > 500) throw new BadRequestException("Reply must contain 1–500 characters.");
  return body;
}

function parseContentId(input: string): string {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(input)) {
    throw new BadRequestException("Content ID is invalid.");
  }
  return input;
}

function labelsFor(body: string): readonly ContentLabel[] {
  return labelContent({
    taxonomyVersion: process.env.RECOMMENDATION_TAXONOMY_VERSION ?? "ionic-taxonomy-v1",
    kind: "text",
    text: body,
    formatLabelIds: { text: "format.text", short_video: "format.short_video" },
    keywordRules: textLabelRules,
  });
}

@Injectable()
export class PostsService {
  constructor(
    private readonly database: DatabaseService,
    private readonly recommendationSignals: RecommendationSignalsService,
  ) {}

  async create(authorId: string, input: unknown): Promise<PostView> {
    const body = parsePostBody(input);
    const id = randomUUID();
    const labels = labelsFor(body);
    const created = await this.database.transaction(async (client) => {
      const inserted = await client.query<{ id: string; author_id: string; body: string; created_at: Date }>(
        `INSERT INTO content (id, author_id, body)
         VALUES ($1, $2, $3)
         RETURNING id, author_id, body, created_at`,
        [id, authorId, body],
      );
      for (const label of labels) {
        await client.query(
          `INSERT INTO content_label
            (content_id, taxonomy_version, dimension, label_id, confidence, source)
           VALUES ($1, $2, $3, $4, $5, $6)`,
          [id, label.taxonomyVersion, label.dimension, label.labelId, label.confidence, label.source],
        );
      }
      return inserted.rows[0];
    });
    return {
      id: created.id,
      authorId: created.author_id,
      body: created.body,
      createdAt: created.created_at.toISOString(),
      likeCount: 0,
      replyCount: 0,
      liked: false,
      saved: false,
    };
  }

  async listMine(
    authorId: string,
    limit: number,
    cursor: { createdAt: string; id: string } | undefined,
  ): Promise<{ items: readonly PostView[]; nextCursor: string | null }> {
    const result = await this.database.query<{
      id: string; author_id: string; body: string; created_at: Date;
      like_count: number; reply_count: number; liked: boolean; saved: boolean;
    }>(
      `SELECT c.id, c.author_id, c.body, c.created_at,
              (SELECT count(*)::int FROM content_reaction r WHERE r.content_id = c.id) AS like_count,
              (SELECT count(*)::int FROM content_reply r WHERE r.content_id = c.id AND r.status = 'published') AS reply_count,
              EXISTS (SELECT 1 FROM content_reaction r WHERE r.content_id = c.id AND r.user_id = $1) AS liked,
              EXISTS (SELECT 1 FROM content_bookmark b WHERE b.content_id = c.id AND b.user_id = $1) AS saved
       FROM content c
       WHERE c.author_id = $1 AND c.kind = 'text' AND c.status = 'published' AND c.deleted_at IS NULL
         AND ($2::timestamptz IS NULL OR (c.created_at, c.id) < ($2::timestamptz, $3::uuid))
       ORDER BY c.created_at DESC, c.id DESC
       LIMIT $4`,
      [authorId, cursor?.createdAt ?? null, cursor?.id ?? null, limit + 1],
    );
    const hasMore = result.rows.length > limit;
    const rows = result.rows.slice(0, limit);
    const items = rows.map((row) => ({
      id: row.id,
      authorId: row.author_id,
      body: row.body,
      createdAt: row.created_at.toISOString(),
      likeCount: row.like_count,
      replyCount: row.reply_count,
      liked: row.liked,
      saved: row.saved,
    }));
    const last = rows.at(-1);
    const nextCursor = hasMore && last
      ? Buffer.from(JSON.stringify({ createdAt: last.created_at.toISOString(), id: last.id })).toString("base64url")
      : null;
    return { items, nextCursor };
  }

  async listPublic(
    limit: number,
    cursor: { createdAt: string; id: string } | undefined,
  ): Promise<{ items: readonly FollowingPostView[]; nextCursor: string | null }> {
    const result = await this.database.query<{
      id: string;
      author_id: string;
      body: string;
      created_at: Date;
      author_handle: string;
      author_display_name: string;
      like_count: number;
      reply_count: number;
      liked: boolean;
      saved: boolean;
    }>(
      `SELECT c.id, c.author_id, c.body, c.created_at,
              u.handle AS author_handle, p.display_name AS author_display_name,
              (SELECT count(*)::int FROM content_reaction r WHERE r.content_id = c.id) AS like_count,
              (SELECT count(*)::int FROM content_reply r WHERE r.content_id = c.id AND r.status = 'published') AS reply_count,
              false AS liked, false AS saved
       FROM content c
       JOIN app_user u ON u.id = c.author_id AND u.state = 'active'
       JOIN user_profile p ON p.user_id = u.id
       WHERE c.kind = 'text' AND c.visibility = 'public'
         AND c.status = 'published' AND c.deleted_at IS NULL
         AND p.visibility = 'public'
         AND ($1::timestamptz IS NULL OR (c.created_at, c.id) < ($1::timestamptz, $2::uuid))
       ORDER BY c.created_at DESC, c.id DESC
       LIMIT $3`,
      [cursor?.createdAt ?? null, cursor?.id ?? null, limit + 1],
    );
    const hasMore = result.rows.length > limit;
    const rows = result.rows.slice(0, limit);
    const items = rows.map((row) => ({
      id: row.id,
      authorId: row.author_id,
      authorHandle: row.author_handle,
      authorDisplayName: row.author_display_name,
      body: row.body,
      createdAt: row.created_at.toISOString(),
      likeCount: row.like_count,
      replyCount: row.reply_count,
      liked: row.liked,
      saved: row.saved,
    }));
    const last = rows.at(-1);
    const nextCursor = hasMore && last
      ? Buffer.from(JSON.stringify({ createdAt: last.created_at.toISOString(), id: last.id })).toString("base64url")
      : null;
    return { items, nextCursor };
  }

  async listFollowing(
    viewerId: string,
    limit: number,
    cursor: { createdAt: string; id: string } | undefined,
  ): Promise<{ items: readonly FollowingPostView[]; nextCursor: string | null }> {
    const result = await this.database.query<{
      id: string;
      author_id: string;
      body: string;
      created_at: Date;
      author_handle: string;
      author_display_name: string;
      like_count: number; reply_count: number; liked: boolean; saved: boolean;
    }>(
      `SELECT c.id, c.author_id, c.body, c.created_at, u.handle AS author_handle, p.display_name AS author_display_name,
              (SELECT count(*)::int FROM content_reaction r WHERE r.content_id = c.id) AS like_count,
              (SELECT count(*)::int FROM content_reply r WHERE r.content_id = c.id AND r.status = 'published') AS reply_count,
              EXISTS (SELECT 1 FROM content_reaction r WHERE r.content_id = c.id AND r.user_id = $1) AS liked,
              EXISTS (SELECT 1 FROM content_bookmark b WHERE b.content_id = c.id AND b.user_id = $1) AS saved
       FROM account_follow f
       JOIN app_user u ON u.id = f.followed_id AND u.state = 'active'
       JOIN user_profile p ON p.user_id = u.id
       JOIN content c ON c.author_id = u.id
       WHERE f.follower_id = $1 AND c.kind = 'text' AND c.status = 'published' AND c.deleted_at IS NULL
         AND ($2::timestamptz IS NULL OR (c.created_at, c.id) < ($2::timestamptz, $3::uuid))
         AND NOT EXISTS (SELECT 1 FROM feed_content_hide h WHERE h.user_id = $1 AND h.content_id = c.id)
         AND NOT EXISTS (
           SELECT 1 FROM account_block b
           WHERE (b.blocker_id = $1 AND b.blocked_id = u.id) OR (b.blocker_id = u.id AND b.blocked_id = $1)
         )
         AND NOT EXISTS (
           SELECT 1 FROM account_mute m WHERE m.muter_id = $1 AND m.muted_id = u.id
         )
       ORDER BY c.created_at DESC, c.id DESC
       LIMIT $4`,
      [viewerId, cursor?.createdAt ?? null, cursor?.id ?? null, limit + 1],
    );
    const hasMore = result.rows.length > limit;
    const rows = result.rows.slice(0, limit);
    const items = rows.map((row) => ({
      id: row.id,
      authorId: row.author_id,
      body: row.body,
      createdAt: row.created_at.toISOString(),
      authorHandle: row.author_handle,
      authorDisplayName: row.author_display_name,
      likeCount: row.like_count,
      replyCount: row.reply_count,
      liked: row.liked,
      saved: row.saved,
    }));
    const last = rows.at(-1);
    const nextCursor = hasMore && last
      ? Buffer.from(JSON.stringify({ createdAt: last.created_at.toISOString(), id: last.id })).toString("base64url")
      : null;
    return { items, nextCursor };
  }

  async search(
    viewerId: string,
    inputQuery: unknown,
    limit: number,
    cursor: { createdAt: string; id: string } | undefined,
  ): Promise<{ items: readonly FollowingPostView[]; nextCursor: string | null }> {
    const query = parseSearchQuery(inputQuery);
    const result = await this.database.query<{
      id: string;
      author_id: string;
      body: string;
      created_at: Date;
      author_handle: string;
      author_display_name: string;
      like_count: number;
      reply_count: number;
      liked: boolean;
      saved: boolean;
    }>(
      `WITH search_term AS (
         SELECT websearch_to_tsquery('simple', $2) AS value
       )
       SELECT c.id, c.author_id, c.body, c.created_at,
              u.handle AS author_handle, p.display_name AS author_display_name,
              (SELECT count(*)::int FROM content_reaction r WHERE r.content_id = c.id) AS like_count,
              (SELECT count(*)::int FROM content_reply r WHERE r.content_id = c.id AND r.status = 'published') AS reply_count,
              EXISTS (SELECT 1 FROM content_reaction r WHERE r.content_id = c.id AND r.user_id = $1) AS liked,
              EXISTS (SELECT 1 FROM content_bookmark b WHERE b.content_id = c.id AND b.user_id = $1) AS saved
       FROM content c
       JOIN app_user u ON u.id = c.author_id AND u.state = 'active'
       JOIN user_profile p ON p.user_id = u.id
       CROSS JOIN search_term term
       WHERE c.kind = 'text' AND c.status = 'published' AND c.deleted_at IS NULL
         AND to_tsvector('simple', c.body::text) @@ term.value
         AND (u.id = $1 OR p.visibility = 'public' OR
              EXISTS (SELECT 1 FROM account_follow f WHERE f.follower_id = $1 AND f.followed_id = u.id))
         AND NOT EXISTS (
           SELECT 1 FROM account_block b
           WHERE (b.blocker_id = $1 AND b.blocked_id = u.id) OR (b.blocker_id = u.id AND b.blocked_id = $1)
         )
         AND ($3::timestamptz IS NULL OR (c.created_at, c.id) < ($3::timestamptz, $4::uuid))
       ORDER BY c.created_at DESC, c.id DESC
       LIMIT $5`,
      [viewerId, query, cursor?.createdAt ?? null, cursor?.id ?? null, limit + 1],
    );
    const hasMore = result.rows.length > limit;
    const rows = result.rows.slice(0, limit);
    const items = rows.map((row) => ({
      id: row.id,
      authorId: row.author_id,
      body: row.body,
      createdAt: row.created_at.toISOString(),
      authorHandle: row.author_handle,
      authorDisplayName: row.author_display_name,
      likeCount: row.like_count,
      replyCount: row.reply_count,
      liked: row.liked,
      saved: row.saved,
    }));
    const last = rows.at(-1);
    const nextCursor = hasMore && last
      ? Buffer.from(JSON.stringify({ createdAt: last.created_at.toISOString(), id: last.id })).toString("base64url")
      : null;
    return { items, nextCursor };
  }

  async listAuthor(
    viewerId: string,
    inputHandle: string,
    limit: number,
    cursor: { createdAt: string; id: string } | undefined,
  ): Promise<{ items: readonly PostView[]; nextCursor: string | null }> {
    const handle = parseAuthorHandle(inputHandle);
    const access = await this.database.query<{ allowed: boolean; author_id: string }>(
      `SELECT u.id AS author_id,
              (u.id = $1 OR p.visibility = 'public' OR
               EXISTS (SELECT 1 FROM account_follow f WHERE f.follower_id = $1 AND f.followed_id = u.id))
              AND NOT EXISTS (
                SELECT 1 FROM account_block b
                WHERE (b.blocker_id = $1 AND b.blocked_id = u.id) OR (b.blocker_id = u.id AND b.blocked_id = $1)
              ) AS allowed
       FROM app_user u
       JOIN user_profile p ON p.user_id = u.id
       WHERE u.handle_normalized = $2 AND u.state = 'active'`,
      [viewerId, handle],
    );
    const account = access.rows[0];
    if (account === undefined || !account.allowed) throw new NotFoundException("Profile was not found.");

    const result = await this.database.query<{
      id: string; author_id: string; body: string; created_at: Date;
      like_count: number; reply_count: number; liked: boolean; saved: boolean;
    }>(
      `SELECT c.id, c.author_id, c.body, c.created_at,
              (SELECT count(*)::int FROM content_reaction r WHERE r.content_id = c.id) AS like_count,
              (SELECT count(*)::int FROM content_reply r WHERE r.content_id = c.id AND r.status = 'published') AS reply_count,
              EXISTS (SELECT 1 FROM content_reaction r WHERE r.content_id = c.id AND r.user_id = $2) AS liked,
              EXISTS (SELECT 1 FROM content_bookmark b WHERE b.content_id = c.id AND b.user_id = $2) AS saved
       FROM content c
       WHERE c.author_id = $1 AND c.kind = 'text' AND c.status = 'published' AND c.deleted_at IS NULL
         AND ($3::timestamptz IS NULL OR (c.created_at, c.id) < ($3::timestamptz, $4::uuid))
       ORDER BY c.created_at DESC, c.id DESC
       LIMIT $5`,
      [account.author_id, viewerId, cursor?.createdAt ?? null, cursor?.id ?? null, limit + 1],
    );
    const hasMore = result.rows.length > limit;
    const rows = result.rows.slice(0, limit);
    const items = rows.map((row) => ({
      id: row.id,
      authorId: row.author_id,
      body: row.body,
      createdAt: row.created_at.toISOString(),
      likeCount: row.like_count,
      replyCount: row.reply_count,
      liked: row.liked,
      saved: row.saved,
    }));
    const last = rows.at(-1);
    const nextCursor = hasMore && last
      ? Buffer.from(JSON.stringify({ createdAt: last.created_at.toISOString(), id: last.id })).toString("base64url")
      : null;
    return { items, nextCursor };
  }

  async setLike(viewerId: string, inputContentId: string, liked: boolean): Promise<{ liked: boolean; likeCount: number }> {
    const contentId = parseContentId(inputContentId);
    const state = await this.database.transaction(async (client) => {
      await this.assertCanInteract(client, viewerId, contentId);
      if (liked) {
        const id = randomUUID();
        const inserted = await client.query<{ id: string }>(
          `INSERT INTO content_reaction(id, content_id, user_id)
           VALUES ($1, $2, $3) ON CONFLICT (content_id, user_id) DO NOTHING RETURNING id`,
          [id, contentId, viewerId],
        );
        if (inserted.rowCount === 1) await this.recommendationSignals.recordContentAction(client, viewerId, contentId, id, "like");
      } else {
        const removed = await client.query<{ id: string }>(
          "DELETE FROM content_reaction WHERE content_id = $1 AND user_id = $2 RETURNING id",
          [contentId, viewerId],
        );
        const id = removed.rows[0]?.id;
        if (id) await this.recommendationSignals.recordContentAction(client, viewerId, contentId, id, "unlike");
      }
      const count = await client.query<{ like_count: number }>(
        "SELECT count(*)::int AS like_count FROM content_reaction WHERE content_id = $1",
        [contentId],
      );
      return { liked, likeCount: count.rows[0]?.like_count ?? 0 };
    });
    return state;
  }

  async setSaved(viewerId: string, inputContentId: string, saved: boolean): Promise<{ saved: boolean }> {
    const contentId = parseContentId(inputContentId);
    return this.database.transaction(async (client) => {
      await this.assertCanInteract(client, viewerId, contentId);
      if (saved) {
        const id = randomUUID();
        const inserted = await client.query<{ id: string }>(
          `INSERT INTO content_bookmark(id, content_id, user_id) VALUES ($1, $2, $3)
           ON CONFLICT (content_id, user_id) DO NOTHING RETURNING id`,
          [id, contentId, viewerId],
        );
        if (inserted.rowCount === 1) await this.recommendationSignals.recordContentAction(client, viewerId, contentId, id, "save");
      } else {
        const removed = await client.query<{ id: string }>(
          "DELETE FROM content_bookmark WHERE content_id = $1 AND user_id = $2 RETURNING id",
          [contentId, viewerId],
        );
        const id = removed.rows[0]?.id;
        if (id) await this.recommendationSignals.recordContentAction(client, viewerId, contentId, id, "unsave");
      }
      return { saved };
    });
  }

  async addReply(viewerId: string, inputContentId: string, input: unknown): Promise<PostReplyView & { replyCount: number }> {
    const contentId = parseContentId(inputContentId);
    const body = parseReplyBody(input);
    const id = randomUUID();
    return this.database.transaction(async (client) => {
      await this.assertCanInteract(client, viewerId, contentId);
      const inserted = await client.query<{
        id: string; author_id: string; author_handle: string; author_display_name: string; body: string; created_at: Date;
      }>(
        `INSERT INTO content_reply(id, content_id, author_id, body)
         SELECT $1, $2, u.id, $4 FROM app_user u JOIN user_profile p ON p.user_id = u.id
         WHERE u.id = $3 AND u.state = 'active'
         RETURNING id, author_id, body, created_at`,
        [id, contentId, viewerId, body],
      );
      const created = inserted.rows[0];
      if (!created) throw new NotFoundException("Account was not found.");
      const author = await client.query<{ handle: string; display_name: string }>(
        "SELECT u.handle, p.display_name FROM app_user u JOIN user_profile p ON p.user_id = u.id WHERE u.id = $1",
        [created.author_id],
      );
      const profile = author.rows[0];
      if (!profile) throw new NotFoundException("Account was not found.");
      await this.recommendationSignals.recordContentAction(client, viewerId, contentId, id, "comment");
      const count = await client.query<{ reply_count: number }>(
        "SELECT count(*)::int AS reply_count FROM content_reply WHERE content_id = $1 AND status = 'published'",
        [contentId],
      );
      return {
        id: created.id,
        authorId: created.author_id,
        authorHandle: profile.handle,
        authorDisplayName: profile.display_name,
        body: created.body,
        createdAt: created.created_at.toISOString(),
        replyCount: count.rows[0]?.reply_count ?? 0,
      };
    });
  }

  async listReplies(
    viewerId: string,
    inputContentId: string,
    limit: number,
    cursor: { createdAt: string; id: string } | undefined,
  ): Promise<{ items: readonly PostReplyView[]; nextCursor: string | null }> {
    const contentId = parseContentId(inputContentId);
    return this.database.transaction(async (client) => {
      await this.assertCanInteract(client, viewerId, contentId);
      const result = await client.query<{
        id: string; author_id: string; author_handle: string; author_display_name: string; body: string; created_at: Date;
      }>(
        `SELECT r.id, r.author_id, u.handle AS author_handle, p.display_name AS author_display_name, r.body, r.created_at
         FROM content_reply r JOIN app_user u ON u.id = r.author_id AND u.state = 'active'
         JOIN user_profile p ON p.user_id = u.id
         WHERE r.content_id = $1 AND r.status = 'published'
           AND ($2::timestamptz IS NULL OR (r.created_at, r.id) < ($2::timestamptz, $3::uuid))
         ORDER BY r.created_at DESC, r.id DESC LIMIT $4`,
        [contentId, cursor?.createdAt ?? null, cursor?.id ?? null, limit + 1],
      );
      const hasMore = result.rows.length > limit;
      const rows = result.rows.slice(0, limit);
      const items = rows.map((row) => ({
        id: row.id, authorId: row.author_id, authorHandle: row.author_handle,
        authorDisplayName: row.author_display_name, body: row.body, createdAt: row.created_at.toISOString(),
      }));
      const last = rows.at(-1);
      const nextCursor = hasMore && last
        ? Buffer.from(JSON.stringify({ createdAt: last.created_at.toISOString(), id: last.id })).toString("base64url")
        : null;
      return { items, nextCursor };
    });
  }

  private async assertCanInteract(client: import("pg").PoolClient, viewerId: string, contentId: string): Promise<void> {
    const result = await client.query<{ id: string }>(
      `SELECT c.id FROM content c
       JOIN app_user u ON u.id = c.author_id AND u.state = 'active'
       JOIN user_profile p ON p.user_id = u.id
       WHERE c.id = $1 AND c.status = 'published' AND c.deleted_at IS NULL
         AND (u.id = $2 OR p.visibility = 'public' OR EXISTS (
           SELECT 1 FROM account_follow f WHERE f.follower_id = $2 AND f.followed_id = u.id
         ))
         AND NOT EXISTS (
           SELECT 1 FROM account_block b
           WHERE (b.blocker_id = $2 AND b.blocked_id = u.id) OR (b.blocker_id = u.id AND b.blocked_id = $2)
         )
       FOR SHARE OF c, u, p`,
      [contentId, viewerId],
    );
    if (result.rowCount !== 1) throw new NotFoundException("Content was not found.");
  }
}

export function parsePostsCursor(value: unknown): { createdAt: string; id: string } | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== "string") throw new BadRequestException("Cursor is invalid.");
  if (value.length > 256 || !/^[A-Za-z0-9_-]+$/.test(value)) {
    throw new BadRequestException("Cursor is invalid.");
  }
  try {
    const parsed: unknown = JSON.parse(Buffer.from(value, "base64url").toString("utf8"));
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) throw new Error("Invalid cursor shape");
    const record = parsed as Record<string, unknown>;
    if (
      typeof record.createdAt !== "string" || !Number.isFinite(Date.parse(record.createdAt)) ||
      typeof record.id !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(record.id)
    ) {
      throw new Error("Invalid cursor values");
    }
    return { createdAt: new Date(record.createdAt).toISOString(), id: record.id };
  } catch {
    throw new BadRequestException("Cursor is invalid.");
  }
}
