import { BadRequestException, ForbiddenException, Injectable, NotFoundException } from "@nestjs/common";
import { DatabaseService } from "../database/database.service.js";

const handlePattern = /^[a-z0-9_]{3,24}$/;

function parseHandle(input: string): string {
  const handle = input.startsWith("@") ? input.slice(1) : input;
  const normalized = handle.toLowerCase();
  if (!handlePattern.test(normalized)) throw new BadRequestException("Handle is invalid.");
  return normalized;
}

function escapeLike(value: string): string {
  return value.replace(/[\\%_]/g, "\\$&");
}

export interface ProfileView {
  readonly handle: string;
  readonly displayName: string;
  readonly bio: string;
  readonly visibility: "public" | "private";
  readonly followerCount: number;
  readonly followingCount: number;
  readonly postCount: number;
  readonly isFollowing: boolean;
  readonly isMuted: boolean;
  readonly isSelf: boolean;
}

export interface ProfileSearchItem {
  readonly handle: string;
  readonly displayName: string;
  readonly bio: string;
  readonly isFollowing: boolean;
}

export interface ManagedProfileItem {
  readonly handle: string;
  readonly displayName: string;
  readonly bio: string;
}

@Injectable()
export class ProfilesService {
  constructor(private readonly database: DatabaseService) {}

  async updateMe(viewerId: string, input: unknown): Promise<{ readonly displayName: string; readonly bio: string }> {
    if (typeof input !== "object" || input === null || Array.isArray(input)) {
      throw new BadRequestException("Profile details are invalid.");
    }
    const record = input as Record<string, unknown>;
    if (
      Object.keys(record).length !== 2 ||
      typeof record.displayName !== "string" ||
      typeof record.bio !== "string"
    ) {
      throw new BadRequestException("Profile details are invalid.");
    }
    const displayName = record.displayName.trim().normalize("NFC");
    const bio = record.bio.trim().normalize("NFC");
    if (displayName.length < 1 || displayName.length > 48) {
      throw new BadRequestException("Display name must contain 1–48 characters.");
    }
    if (bio.length > 160) throw new BadRequestException("Biography must contain at most 160 characters.");
    const result = await this.database.query<{ display_name: string; bio: string }>(
      `UPDATE user_profile
       SET display_name = $2, bio = $3, updated_at = now()
       WHERE user_id = $1
       RETURNING display_name, bio`,
      [viewerId, displayName, bio],
    );
    const profile = result.rows[0];
    if (profile === undefined) throw new NotFoundException("Profile was not found.");
    return { displayName: profile.display_name, bio: profile.bio };
  }

  async search(viewerId: string, input: unknown): Promise<{ readonly items: readonly ProfileSearchItem[] }> {
    if (input !== undefined && typeof input !== "string") throw new BadRequestException("Search query is invalid.");
    if (input === undefined) return { items: [] };
    const query = input.trim().replace(/^@/, "").normalize("NFC");
    if (query.length < 2 || query.length > 48) return { items: [] };
    const prefix = `${escapeLike(query.toLocaleLowerCase("en-US"))}%`;
    const result = await this.database.query<{
      handle: string;
      display_name: string;
      bio: string;
      is_following: boolean;
    }>(
      `SELECT u.handle, p.display_name, p.bio,
              EXISTS (SELECT 1 FROM account_follow f WHERE f.follower_id = $1 AND f.followed_id = u.id) AS is_following
       FROM app_user u
       JOIN user_profile p ON p.user_id = u.id
       WHERE u.state = 'active' AND p.visibility = 'public' AND u.id <> $1
         AND (lower(u.handle) LIKE $2 ESCAPE '\\' OR lower(p.display_name) LIKE $2 ESCAPE '\\')
         AND NOT EXISTS (
           SELECT 1 FROM account_block b
           WHERE (b.blocker_id = $1 AND b.blocked_id = u.id) OR (b.blocker_id = u.id AND b.blocked_id = $1)
         )
       ORDER BY lower(p.display_name), u.handle
       LIMIT 20`,
      [viewerId, prefix],
    );
    return {
      items: result.rows.map((row) => ({
        handle: row.handle,
        displayName: row.display_name,
        bio: row.bio,
        isFollowing: row.is_following,
      })),
    };
  }

  async getProfile(viewerId: string, inputHandle: string): Promise<{ readonly profile: ProfileView }> {
    const handle = parseHandle(inputHandle);
    const result = await this.database.query<{
      id: string;
      handle: string;
      display_name: string;
      bio: string;
      visibility: "public" | "private";
      follower_count: string;
      following_count: string;
      post_count: string;
      is_following: boolean;
      is_muted: boolean;
    }>(
      `SELECT u.id, u.handle, p.display_name, p.bio, p.visibility,
              (SELECT count(*) FROM account_follow f WHERE f.followed_id = u.id) AS follower_count,
              (SELECT count(*) FROM account_follow f WHERE f.follower_id = u.id) AS following_count,
              (SELECT count(*) FROM content c WHERE c.author_id = u.id AND c.status = 'published' AND c.deleted_at IS NULL) AS post_count,
              EXISTS (SELECT 1 FROM account_follow f WHERE f.follower_id = $1 AND f.followed_id = u.id) AS is_following,
              EXISTS (SELECT 1 FROM account_mute m WHERE m.muter_id = $1 AND m.muted_id = u.id) AS is_muted
       FROM app_user u
       JOIN user_profile p ON p.user_id = u.id
       WHERE u.handle_normalized = $2 AND u.state = 'active'
         AND NOT EXISTS (
           SELECT 1 FROM account_block b
           WHERE (b.blocker_id = $1 AND b.blocked_id = u.id) OR (b.blocker_id = u.id AND b.blocked_id = $1)
         )`,
      [viewerId, handle],
    );
    const row = result.rows[0];
    if (row === undefined || (row.visibility === "private" && row.id !== viewerId && !row.is_following)) {
      throw new NotFoundException("Profile was not found.");
    }
    return {
      profile: {
        handle: row.handle,
        displayName: row.display_name,
        bio: row.bio,
        visibility: row.visibility,
        followerCount: Number(row.follower_count),
        followingCount: Number(row.following_count),
        postCount: Number(row.post_count),
        isFollowing: row.is_following,
        isMuted: row.is_muted,
        isSelf: row.id === viewerId,
      },
    };
  }

  async listFollowing(viewerId: string): Promise<{ readonly items: readonly ProfileSearchItem[] }> {
    const result = await this.database.query<{
      handle: string;
      display_name: string;
      bio: string;
    }>(
      `SELECT u.handle, p.display_name, p.bio
       FROM account_follow f
       JOIN app_user u ON u.id = f.followed_id AND u.state = 'active'
       JOIN user_profile p ON p.user_id = u.id
       WHERE f.follower_id = $1
         AND NOT EXISTS (
           SELECT 1 FROM account_block b
           WHERE (b.blocker_id = $1 AND b.blocked_id = u.id) OR (b.blocker_id = u.id AND b.blocked_id = $1)
         )
       ORDER BY f.created_at DESC, u.handle`,
      [viewerId],
    );
    return {
      items: result.rows.map((row) => ({
        handle: row.handle,
        displayName: row.display_name,
        bio: row.bio,
        isFollowing: true,
      })),
    };
  }

  async listBlocked(viewerId: string): Promise<{ readonly items: readonly ProfileSearchItem[] }> {
    const result = await this.database.query<{
      handle: string;
      display_name: string;
      bio: string;
    }>(
      `SELECT u.handle, p.display_name, p.bio
       FROM account_block b
       JOIN app_user u ON u.id = b.blocked_id
       JOIN user_profile p ON p.user_id = u.id
       WHERE b.blocker_id = $1
       ORDER BY b.created_at DESC, u.handle`,
      [viewerId],
    );
    return {
      items: result.rows.map((row) => ({
        handle: row.handle,
        displayName: row.display_name,
        bio: row.bio,
        isFollowing: false,
      })),
    };
  }

  async listMuted(viewerId: string): Promise<{ readonly items: readonly ManagedProfileItem[] }> {
    const result = await this.database.query<{
      handle: string;
      display_name: string;
      bio: string;
    }>(
      `SELECT u.handle, p.display_name, p.bio
       FROM account_mute m
       JOIN app_user u ON u.id = m.muted_id AND u.state = 'active'
       JOIN user_profile p ON p.user_id = u.id
       WHERE m.muter_id = $1
       ORDER BY m.created_at DESC, u.handle`,
      [viewerId],
    );
    return {
      items: result.rows.map((row) => ({
        handle: row.handle,
        displayName: row.display_name,
        bio: row.bio,
      })),
    };
  }

  async follow(viewerId: string, inputHandle: string): Promise<{ readonly status: "following" }> {
    const target = await this.target(inputHandle);
    if (target.id === viewerId) throw new BadRequestException("You cannot follow your own account.");
    if (target.visibility === "private") throw new ForbiddenException("Private profile follow requests are not available yet.");
    await this.database.transaction(async (client) => {
      await this.lockAccounts(client, viewerId, target.id);
      const block = await client.query(
        "SELECT 1 FROM account_block WHERE (blocker_id = $1 AND blocked_id = $2) OR (blocker_id = $2 AND blocked_id = $1)",
        [viewerId, target.id],
      );
      if (block.rowCount) throw new ForbiddenException("Following is unavailable for this account.");
      await client.query(
        "INSERT INTO account_follow(follower_id, followed_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
        [viewerId, target.id],
      );
    });
    return { status: "following" };
  }

  async unfollow(viewerId: string, inputHandle: string): Promise<{ readonly status: "not_following" }> {
    const targetId = await this.targetId(inputHandle);
    await this.database.query("DELETE FROM account_follow WHERE follower_id = $1 AND followed_id = $2", [viewerId, targetId]);
    return { status: "not_following" };
  }

  async block(viewerId: string, inputHandle: string): Promise<{ readonly status: "blocked" }> {
    const targetId = await this.targetId(inputHandle);
    if (targetId === viewerId) throw new BadRequestException("You cannot block your own account.");
    await this.database.transaction(async (client) => {
      await this.lockAccounts(client, viewerId, targetId);
      await client.query("INSERT INTO account_block(blocker_id, blocked_id) VALUES ($1, $2) ON CONFLICT DO NOTHING", [viewerId, targetId]);
      await client.query(
        `DELETE FROM account_follow
         WHERE (follower_id = $1 AND followed_id = $2) OR (follower_id = $2 AND followed_id = $1)`,
        [viewerId, targetId],
      );
    });
    return { status: "blocked" };
  }

  async unblock(viewerId: string, inputHandle: string): Promise<{ readonly status: "unblocked" }> {
    const targetId = await this.targetId(inputHandle);
    await this.database.query("DELETE FROM account_block WHERE blocker_id = $1 AND blocked_id = $2", [viewerId, targetId]);
    return { status: "unblocked" };
  }

  async mute(viewerId: string, inputHandle: string): Promise<{ readonly status: "muted" }> {
    const targetId = await this.targetId(inputHandle);
    if (targetId === viewerId) throw new BadRequestException("You cannot mute your own account.");
    await this.database.query(
      "INSERT INTO account_mute(muter_id, muted_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
      [viewerId, targetId],
    );
    return { status: "muted" };
  }

  async unmute(viewerId: string, inputHandle: string): Promise<{ readonly status: "unmuted" }> {
    const targetId = await this.targetId(inputHandle);
    await this.database.query("DELETE FROM account_mute WHERE muter_id = $1 AND muted_id = $2", [viewerId, targetId]);
    return { status: "unmuted" };
  }

  private async targetId(inputHandle: string): Promise<string> {
    const handle = parseHandle(inputHandle);
    const result = await this.database.query<{ id: string }>(
      "SELECT id FROM app_user WHERE handle_normalized = $1 AND state = 'active'",
      [handle],
    );
    const target = result.rows[0];
    if (target === undefined) throw new NotFoundException("Account was not found.");
    return target.id;
  }

  private async target(inputHandle: string): Promise<{ readonly id: string; readonly visibility: "public" | "private" }> {
    const handle = parseHandle(inputHandle);
    const result = await this.database.query<{ id: string; visibility: "public" | "private" }>(
      `SELECT u.id, p.visibility FROM app_user u JOIN user_profile p ON p.user_id = u.id
       WHERE u.handle_normalized = $1 AND u.state = 'active'`,
      [handle],
    );
    const target = result.rows[0];
    if (target === undefined) throw new NotFoundException("Account was not found.");
    return target;
  }

  private async lockAccounts(client: import("pg").PoolClient, viewerId: string, targetId: string): Promise<void> {
    const ids = [viewerId, targetId].sort();
    const result = await client.query("SELECT id FROM app_user WHERE id = ANY($1::uuid[]) ORDER BY id FOR UPDATE", [ids]);
    if (result.rowCount !== 2) throw new NotFoundException("Account was not found.");
  }
}
