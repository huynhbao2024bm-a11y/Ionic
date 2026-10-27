import { BadRequestException, ForbiddenException, Injectable, NotFoundException } from "@nestjs/common";
import { randomUUID } from "node:crypto";
import { DatabaseService } from "../database/database.service.js";

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const handlePattern = /^[a-z0-9_]{3,24}$/;

export interface ConversationView {
  readonly id: string;
  readonly partnerId: string;
  readonly partnerHandle: string;
  readonly partnerDisplayName: string;
  readonly lastMessage: string;
  readonly updatedAt: string;
}

export interface MessageView {
  readonly id: string;
  readonly senderId: string;
  readonly body: string;
  readonly createdAt: string;
}

function parseUuid(input: unknown, name: string): string {
  if (typeof input !== "string" || !uuidPattern.test(input)) throw new BadRequestException(`${name} is invalid.`);
  return input;
}

function parseBody(input: unknown): { readonly body: string; readonly id: string } {
  if (typeof input !== "object" || input === null || Array.isArray(input)) throw new BadRequestException("Body must be an object.");
  const record = input as Record<string, unknown>;
  if (Object.keys(record).some((key) => key !== "body" && key !== "clientMessageId")) {
    throw new BadRequestException("Request contains an unsupported field.");
  }
  if (typeof record.body !== "string") throw new BadRequestException("Message body must be text.");
  const body = record.body.normalize("NFC").trim();
  if (body.length < 1 || body.length > 2000) throw new BadRequestException("Message must contain 1–2000 characters.");
  return { body, id: record.clientMessageId === undefined ? randomUUID() : parseUuid(record.clientMessageId, "Message ID") };
}

function parseCursor(input: unknown): { readonly createdAt: Date; readonly id: string } | undefined {
  if (input === undefined) return undefined;
  if (typeof input !== "string" || input.length > 256) throw new BadRequestException("Cursor is invalid.");
  try {
    const decoded: unknown = JSON.parse(Buffer.from(input, "base64url").toString("utf8"));
    if (!Array.isArray(decoded) || decoded.length !== 2 || typeof decoded[0] !== "string") throw new Error();
    const createdAt = new Date(decoded[0]);
    if (!Number.isFinite(createdAt.getTime())) throw new Error();
    return { createdAt, id: parseUuid(decoded[1], "Cursor") };
  } catch {
    throw new BadRequestException("Cursor is invalid.");
  }
}

function makeCursor(createdAt: Date, id: string): string {
  return Buffer.from(JSON.stringify([createdAt.toISOString(), id])).toString("base64url");
}

@Injectable()
export class MessagesService {
  constructor(private readonly database: DatabaseService) {}

  async listConversations(viewerId: string): Promise<{ readonly items: readonly ConversationView[] }> {
    const result = await this.database.query<{
      id: string; partner_id: string; handle: string; display_name: string; body: string; updated_at: Date;
    }>(
      `SELECT c.id, partner.id AS partner_id, partner.handle, p.display_name,
              COALESCE(latest.body, '') AS body,
              COALESCE(c.last_message_at, c.created_at) AS updated_at
       FROM direct_conversation c
       JOIN app_user partner ON partner.id = CASE WHEN c.participant_low = $1 THEN c.participant_high ELSE c.participant_low END
       JOIN user_profile p ON p.user_id = partner.id
       LEFT JOIN LATERAL (
         SELECT m.body FROM direct_message m
         WHERE m.conversation_id = c.id ORDER BY m.created_at DESC, m.id DESC LIMIT 1
       ) latest ON true
       WHERE ($1 = c.participant_low OR $1 = c.participant_high)
         AND partner.state = 'active'
         AND NOT EXISTS (SELECT 1 FROM account_block b WHERE
           (b.blocker_id = c.participant_low AND b.blocked_id = c.participant_high) OR
           (b.blocker_id = c.participant_high AND b.blocked_id = c.participant_low))
       ORDER BY c.last_message_at DESC NULLS LAST, c.created_at DESC
       LIMIT 100`,
      [viewerId],
    );
    return { items: result.rows.map((row) => ({
      id: row.id,
      partnerId: row.partner_id,
      partnerHandle: row.handle,
      partnerDisplayName: row.display_name,
      lastMessage: row.body,
      updatedAt: row.updated_at.toISOString(),
    })) };
  }

  async startConversation(viewerId: string, inputHandle: unknown): Promise<{ readonly conversation: ConversationView }> {
    if (typeof inputHandle !== "string") throw new BadRequestException("Handle is invalid.");
    const handle = (inputHandle.startsWith("@") ? inputHandle.slice(1) : inputHandle).trim().toLowerCase();
    if (!handlePattern.test(handle)) throw new BadRequestException("Handle is invalid.");
    const targetResult = await this.database.query<{ id: string; handle: string; display_name: string }>(
      `SELECT u.id, u.handle, p.display_name FROM app_user u
       JOIN user_profile p ON p.user_id = u.id
       WHERE u.handle_normalized = $1 AND u.state = 'active'`, [handle],
    );
    const target = targetResult.rows[0];
    if (!target) throw new NotFoundException("Account was not found.");
    if (target.id === viewerId) throw new BadRequestException("You cannot message your own account.");
    const [low, high] = [viewerId, target.id].sort();
    const result = await this.database.query<{ id: string; created_at: Date; last_message_at: Date | null }>(
      `INSERT INTO direct_conversation(id, participant_low, participant_high)
       SELECT $1, $2, $3
       WHERE NOT EXISTS (SELECT 1 FROM account_block WHERE
         (blocker_id = $2 AND blocked_id = $3) OR (blocker_id = $3 AND blocked_id = $2))
       ON CONFLICT (participant_low, participant_high) DO UPDATE SET participant_low = EXCLUDED.participant_low
       RETURNING id, created_at, last_message_at`,
      [randomUUID(), low, high],
    );
    const conversation = result.rows[0];
    if (!conversation) throw new ForbiddenException("Messaging is unavailable for this account.");
    return { conversation: {
      id: conversation.id,
      partnerId: target.id,
      partnerHandle: target.handle,
      partnerDisplayName: target.display_name,
      lastMessage: "",
      updatedAt: (conversation.last_message_at ?? conversation.created_at).toISOString(),
    } };
  }

  async listMessages(viewerId: string, conversationInput: string, limit: number, cursorInput: unknown): Promise<{
    readonly items: readonly MessageView[];
    readonly nextCursor: string | null;
  }> {
    const conversationId = parseUuid(conversationInput, "Conversation ID");
    const cursor = parseCursor(cursorInput);
    const result = await this.database.query<{
      id: string; sender_id: string; body: string; created_at: Date;
    }>(
      `SELECT m.id, m.sender_id, m.body, m.created_at
       FROM direct_message m
       JOIN direct_conversation c ON c.id = m.conversation_id
       WHERE m.conversation_id = $1 AND ($2 = c.participant_low OR $2 = c.participant_high)
         AND NOT EXISTS (SELECT 1 FROM account_block b WHERE
           (b.blocker_id = c.participant_low AND b.blocked_id = c.participant_high) OR
           (b.blocker_id = c.participant_high AND b.blocked_id = c.participant_low))
         AND ($3::timestamptz IS NULL OR (m.created_at, m.id) < ($3, $4::uuid))
       ORDER BY m.created_at DESC, m.id DESC
       LIMIT $5`,
      [conversationId, viewerId, cursor?.createdAt.toISOString() ?? null, cursor?.id ?? null, limit + 1],
    );
    const rows = result.rows.slice(0, limit);
    const items = rows.reverse().map((row) => ({ id: row.id, senderId: row.sender_id, body: row.body, createdAt: row.created_at.toISOString() }));
    const hasMore = result.rows.length > limit;
    const oldest = items[0];
    return { items, nextCursor: hasMore && oldest ? makeCursor(new Date(oldest.createdAt), oldest.id) : null };
  }

  async sendMessage(viewerId: string, conversationInput: string, input: unknown): Promise<MessageView> {
    const conversationId = parseUuid(conversationInput, "Conversation ID");
    const { body, id } = parseBody(input);
    return this.database.transaction(async (client) => {
      const access = await client.query<{ partner_id: string }>(
        `SELECT CASE WHEN participant_low = $2 THEN participant_high ELSE participant_low END AS partner_id
         FROM direct_conversation c
         WHERE c.id = $1 AND ($2 = participant_low OR $2 = participant_high)
           AND NOT EXISTS (SELECT 1 FROM account_block b WHERE
             (b.blocker_id = c.participant_low AND b.blocked_id = c.participant_high) OR
             (b.blocker_id = c.participant_high AND b.blocked_id = c.participant_low))
         FOR UPDATE`,
        [conversationId, viewerId],
      );
      const conversation = access.rows[0];
      if (!conversation) throw new NotFoundException("Conversation was not found.");
      const inserted = await client.query<{ id: string; sender_id: string; body: string; created_at: Date; conversation_id: string }>(
        `INSERT INTO direct_message(id, conversation_id, sender_id, body)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (id) DO NOTHING
         RETURNING id, sender_id, body, created_at, conversation_id`,
        [id, conversationId, viewerId, body],
      );
      let row = inserted.rows[0];
      if (!row) {
        const existing = await client.query<{ id: string; sender_id: string; body: string; created_at: Date; conversation_id: string }>(
          "SELECT id, sender_id, body, created_at, conversation_id FROM direct_message WHERE id = $1", [id],
        );
        row = existing.rows[0];
        if (!row || row.sender_id !== viewerId || row.conversation_id !== conversationId || row.body !== body) {
          throw new ForbiddenException("Message ID has already been used.");
        }
      } else {
        await client.query("UPDATE direct_conversation SET last_message_at = $2 WHERE id = $1", [conversationId, row.created_at]);
      }
      return { id: row.id, senderId: row.sender_id, body: row.body, createdAt: row.created_at.toISOString() };
    });
  }
}
