import { BadRequestException, Injectable, NotFoundException } from "@nestjs/common";
import { randomUUID } from "node:crypto";
import type { PoolClient } from "pg";
import { DatabaseService } from "../database/database.service.js";

const reportReasons = ["spam", "harassment", "harmful", "impersonation", "other"] as const;
type ReportReason = (typeof reportReasons)[number];
type ReportStatus = "received" | "reviewing" | "actioned" | "dismissed";

interface ReportInput {
  readonly contentId: string;
  readonly reason: ReportReason;
  readonly details: string;
}

function parseInput(input: unknown): ReportInput {
  if (typeof input !== "object" || input === null || Array.isArray(input)) {
    throw new BadRequestException("Report must be an object.");
  }
  const record = input as Record<string, unknown>;
  if (Object.keys(record).some((key) => !["contentId", "reason", "details"].includes(key))) {
    throw new BadRequestException("Report contains an unsupported field.");
  }
  if (typeof record.contentId !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(record.contentId)) {
    throw new BadRequestException("Content ID is invalid.");
  }
  if (typeof record.reason !== "string" || !reportReasons.includes(record.reason as ReportReason)) {
    throw new BadRequestException("Report reason is invalid.");
  }
  const details = record.details === undefined ? "" : record.details;
  if (typeof details !== "string") throw new BadRequestException("Report details must be text.");
  const normalizedDetails = details.normalize("NFC").trim();
  if (normalizedDetails.length > 500) throw new BadRequestException("Report details must be 500 characters or fewer.");
  return { contentId: record.contentId, reason: record.reason as ReportReason, details: normalizedDetails };
}

@Injectable()
export class ReportsService {
  constructor(private readonly database: DatabaseService) {}

  async create(reporterId: string, input: unknown): Promise<{ id: string; status: ReportStatus; createdAt: string }> {
    const report = parseInput(input);
    return this.database.transaction(async (client) => {
      await this.assertReportable(client, reporterId, report.contentId);
      const id = randomUUID();
      const inserted = await client.query<{ id: string; status: ReportStatus; created_at: Date }>(
        `INSERT INTO content_report (id, reporter_id, content_id, reason, details)
         VALUES ($1, $2, $3, $4, $5)
         ON CONFLICT (reporter_id, content_id) DO NOTHING
         RETURNING id, status, created_at`,
        [id, reporterId, report.contentId, report.reason, report.details],
      );
      const existing = inserted.rows[0] ?? (await client.query<{ id: string; status: ReportStatus; created_at: Date }>(
        `SELECT id, status, created_at FROM content_report
         WHERE reporter_id = $1 AND content_id = $2`,
        [reporterId, report.contentId],
      )).rows[0];
      if (!existing) throw new NotFoundException("Content was not found.");
      return { id: existing.id, status: existing.status, createdAt: existing.created_at.toISOString() };
    });
  }

  private async assertReportable(client: PoolClient, reporterId: string, contentId: string): Promise<void> {
    const result = await client.query<{ id: string }>(
      `SELECT c.id FROM content c
       JOIN app_user u ON u.id = c.author_id AND u.state = 'active'
       JOIN user_profile p ON p.user_id = u.id
       WHERE c.id = $1 AND c.kind = 'text' AND c.status = 'published' AND c.deleted_at IS NULL
         AND u.id <> $2
         AND (p.visibility = 'public' OR EXISTS (
           SELECT 1 FROM account_follow f WHERE f.follower_id = $2 AND f.followed_id = u.id
         ))
         AND NOT EXISTS (
           SELECT 1 FROM account_block b
           WHERE (b.blocker_id = $2 AND b.blocked_id = u.id) OR (b.blocker_id = u.id AND b.blocked_id = $2)
         )
       FOR SHARE OF c, u, p`,
      [contentId, reporterId],
    );
    if (result.rowCount !== 1) throw new NotFoundException("Content was not found.");
  }
}
