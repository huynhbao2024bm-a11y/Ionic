import { BadRequestException, Injectable, NotFoundException, PayloadTooLargeException } from "@nestjs/common";
import { randomUUID } from "node:crypto";
import { createWriteStream } from "node:fs";
import { mkdir, open, rename, rm } from "node:fs/promises";
import { resolve } from "node:path";
import { Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import type { IncomingMessage } from "node:http";
import { DatabaseService } from "../database/database.service.js";
import { labelContent } from "../recommendation/content-labeler.js";
import { textLabelRules } from "../recommendation/text-label-rules.js";
import type { ContentLabel } from "../recommendation/types.js";

const maxUploadBytes = 60 * 1024 * 1024;

export interface VideoView {
  readonly id: string;
  readonly authorId: string;
  readonly authorHandle: string;
  readonly authorDisplayName: string;
  readonly caption: string;
  readonly createdAt: string;
  readonly mimeType: "video/webm" | "video/mp4";
  readonly state: "pending_review" | "ready";
}

export interface StoredVideo {
  readonly path: string;
  readonly mimeType: "video/webm" | "video/mp4";
  readonly byteSize: number;
}

function parseCaption(input: unknown): string {
  const encoded = Array.isArray(input) ? input[0] : input;
  if (typeof encoded !== "string" || encoded.length > 2_240 || encoded.length % 2 !== 0 || !/^[0-9a-f]*$/i.test(encoded)) {
    throw new BadRequestException("Caption is invalid.");
  }
  const decoded = Buffer.from(encoded, "hex").toString("utf8");
  if (Buffer.from(decoded, "utf8").toString("hex") !== encoded.toLowerCase()) throw new BadRequestException("Caption is invalid.");
  const caption = decoded.normalize("NFC").trim();
  if (caption.length < 1 || caption.length > 280) throw new BadRequestException("Caption must contain 1–280 characters.");
  return caption;
}

function videoLabels(caption: string): readonly ContentLabel[] {
  return labelContent({
    taxonomyVersion: process.env.RECOMMENDATION_TAXONOMY_VERSION ?? "ionic-taxonomy-v1",
    kind: "short_video",
    text: caption,
    formatLabelIds: { text: "format.text", short_video: "format.short_video" },
    keywordRules: textLabelRules,
  });
}

function mimeTypeOf(input: string | string[] | undefined): "video/webm" | "video/mp4" {
  const value = Array.isArray(input) ? input[0] : input;
  const mime = value?.split(";", 1)[0]?.trim().toLowerCase();
  if (mime !== "video/webm" && mime !== "video/mp4") throw new BadRequestException("Use a WebM or MP4 video.");
  return mime;
}

function looksLikeVideo(header: Buffer, declaredMime: string): boolean {
  const webm = header.length >= 4 && header[0] === 0x1a && header[1] === 0x45 && header[2] === 0xdf && header[3] === 0xa3;
  const mp4 = header.length >= 8 && header.subarray(4, 8).toString("ascii") === "ftyp";
  return (declaredMime === "video/webm" && webm) || (declaredMime === "video/mp4" && mp4);
}

@Injectable()
export class VideosService {
  private readonly storageDirectory = resolve(process.env.IONIC_MEDIA_DIR ?? ".data/media");

  constructor(private readonly database: DatabaseService) {}

  async list(viewerId: string): Promise<{ readonly items: readonly VideoView[] }> {
    const result = await this.database.query<{
      id: string; author_id: string; handle: string; display_name: string; body: string; created_at: Date; mime_type: "video/webm" | "video/mp4"; state: "pending_review" | "ready";
    }>(
      `SELECT c.id, c.author_id, u.handle, p.display_name, c.body, c.created_at, a.mime_type
       FROM content c
       JOIN video_asset a ON a.content_id = c.id
       JOIN app_user u ON u.id = c.author_id AND u.state = 'active'
       JOIN user_profile p ON p.user_id = u.id
       WHERE c.kind = 'short_video' AND c.deleted_at IS NULL AND
         ((c.visibility = 'public' AND c.status = 'published' AND a.state = 'ready') OR (c.author_id = $1 AND c.status = 'processing'))
         AND NOT EXISTS (SELECT 1 FROM account_block b WHERE
           (b.blocker_id = $1 AND b.blocked_id = c.author_id) OR (b.blocker_id = c.author_id AND b.blocked_id = $1))
       ORDER BY c.created_at DESC, c.id DESC
       LIMIT 40`,
      [viewerId],
    );
    return { items: result.rows.map((row) => ({
      id: row.id,
      authorId: row.author_id,
      authorHandle: row.handle,
      authorDisplayName: row.display_name,
      caption: row.body,
      createdAt: row.created_at.toISOString(),
      mimeType: row.mime_type,
      state: row.state,
    })) };
  }

  async upload(authorId: string, request: IncomingMessage, captionInput: unknown): Promise<VideoView> {
    const caption = parseCaption(captionInput);
    const mimeType = mimeTypeOf(request.headers["content-type"]);
    const declaredLength = Number(request.headers["content-length"] ?? 0);
    if (Number.isFinite(declaredLength) && declaredLength > maxUploadBytes) {
      throw new PayloadTooLargeException("Video exceeds the 60 MB upload limit.");
    }

    const id = randomUUID();
    const storageKey = randomUUID();
    const temporaryPath = resolve(this.storageDirectory, `${storageKey}.part`);
    const finalPath = resolve(this.storageDirectory, storageKey);
    let size = 0;
    await mkdir(this.storageDirectory, { recursive: true });
    try {
      const byteLimit = new Transform({
        transform(chunk: Buffer, _encoding, callback) {
          size += chunk.length;
          if (size > maxUploadBytes) {
            callback(new PayloadTooLargeException("Video exceeds the 60 MB upload limit."));
            return;
          }
          callback(null, chunk);
        },
      });
      await pipeline(request, byteLimit, createWriteStream(temporaryPath, { flags: "wx", mode: 0o600 }));
      if (size === 0) throw new BadRequestException("Video file is empty.");
      const file = await open(temporaryPath, "r");
      const header = Buffer.alloc(12);
      try {
        const { bytesRead } = await file.read(header, 0, header.length, 0);
        if (!looksLikeVideo(header.subarray(0, bytesRead), mimeType)) throw new BadRequestException("Video file content does not match its type.");
      } finally {
        await file.close();
      }
      await rename(temporaryPath, finalPath);
      const inserted = await this.database.transaction(async (client) => {
        const content = await client.query<{ id: string; author_id: string; body: string; created_at: Date }>(
          `INSERT INTO content (id, author_id, kind, body, status) VALUES ($1, $2, 'short_video', $3, 'processing')
           RETURNING id, author_id, body, created_at`,
          [id, authorId, caption],
        );
        await client.query(
          "INSERT INTO video_asset(content_id, storage_key, mime_type, byte_size, state) VALUES ($1, $2, $3, $4, 'pending_review')",
          [id, storageKey, mimeType, size],
        );
        for (const label of videoLabels(caption)) {
          await client.query(
            `INSERT INTO content_label(content_id, taxonomy_version, dimension, label_id, confidence, source)
             VALUES ($1, $2, $3, $4, $5, $6)`,
            [id, label.taxonomyVersion, label.dimension, label.labelId, label.confidence, label.source],
          );
        }
        const author = await client.query<{ handle: string; display_name: string }>(
          "SELECT u.handle, p.display_name FROM app_user u JOIN user_profile p ON p.user_id = u.id WHERE u.id = $1", [authorId],
        );
        return { ...content.rows[0]!, ...author.rows[0]! };
      });
      return {
        id: inserted.id,
        authorId: inserted.author_id,
        authorHandle: inserted.handle,
        authorDisplayName: inserted.display_name,
        caption: inserted.body,
        createdAt: inserted.created_at.toISOString(),
        mimeType,
        state: "pending_review",
      };
    } catch (error) {
      await Promise.all([rm(temporaryPath, { force: true }), rm(finalPath, { force: true })]);
      throw error;
    }
  }

  async playback(viewerId: string, contentId: string): Promise<StoredVideo> {
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(contentId)) {
      throw new BadRequestException("Video ID is invalid.");
    }
    const result = await this.database.query<{ author_id: string; status: string; state: "pending_review" | "ready"; storage_key: string; mime_type: "video/webm" | "video/mp4"; byte_size: string }>(
      `SELECT c.author_id, c.status, a.state, a.storage_key, a.mime_type, a.byte_size
       FROM content c JOIN video_asset a ON a.content_id = c.id
       JOIN app_user u ON u.id = c.author_id AND u.state = 'active'
       WHERE c.id = $1 AND c.kind = 'short_video' AND c.deleted_at IS NULL
         AND ((c.author_id = $2 AND c.status = 'processing') OR
              (c.visibility = 'public' AND c.status = 'published' AND a.state = 'ready'))
         AND NOT EXISTS (SELECT 1 FROM account_block b WHERE
           (b.blocker_id = $2 AND b.blocked_id = c.author_id) OR (b.blocker_id = c.author_id AND b.blocked_id = $2))`,
      [contentId, viewerId],
    );
    const asset = result.rows[0];
    if (!asset) throw new NotFoundException("Video was not found.");
    const byteSize = Number(asset.byte_size);
    if (!Number.isSafeInteger(byteSize) || byteSize < 1) throw new NotFoundException("Video was not found.");
    return { path: resolve(this.storageDirectory, asset.storage_key), mimeType: asset.mime_type, byteSize };
  }
}
