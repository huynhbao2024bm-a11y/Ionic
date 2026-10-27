import { Injectable, OnModuleDestroy, ServiceUnavailableException } from "@nestjs/common";
import { Pool, type PoolClient, type QueryResult, type QueryResultRow } from "pg";

export type DatabaseReadiness = "ready" | "unconfigured" | "unavailable" | "schema_pending";

const requiredMigrations = [
  "0001_identity_and_text_posts.sql",
  "0002_profiles_follows_and_blocks.sql",
  "0003_personalized_feed_controls.sql",
  "0004_persistent_post_actions.sql",
  "0005_recommendation_candidate_retrieval.sql",
  "0006_direct_messaging.sql",
  "0007_video_uploads.sql",
  "0008_post_search_and_reports.sql",
  "0009_account_mutes.sql",
  "0010_video_recommendation_signals.sql",
  "0011_video_signal_lookup_index.sql",
  "0012_image_voice_attachments.sql",
] as const;

function isConnectionFailure(error: unknown): boolean {
  if (typeof error !== "object" || error === null || !("code" in error)) return false;
  const code = error.code;
  return typeof code === "string" && (
    code.startsWith("08") ||
    ["ECONNREFUSED", "ECONNRESET", "ETIMEDOUT", "EHOSTUNREACH", "ENETUNREACH", "ENOTFOUND"].includes(code)
  );
}

function asUnavailable(error: unknown): never {
  if (isConnectionFailure(error)) {
    throw new ServiceUnavailableException("PostgreSQL is unavailable.");
  }
  throw error;
}

@Injectable()
export class DatabaseService implements OnModuleDestroy {
  private readonly connectionPool: Pool | null;

  constructor() {
    const connectionString = process.env.DATABASE_URL?.trim();
    this.connectionPool = connectionString
      ? new Pool({
          connectionString,
          max: 5,
          connectionTimeoutMillis: 2_000,
          idleTimeoutMillis: 30_000,
          allowExitOnIdle: false,
        })
      : null;
  }

  get pool(): Pool | null {
    return this.connectionPool;
  }

  async query<Row extends QueryResultRow = QueryResultRow>(
    text: string,
    values: unknown[] = [],
  ): Promise<QueryResult<Row>> {
    if (this.connectionPool === null) {
      throw new ServiceUnavailableException("PostgreSQL is not configured.");
    }
    try {
      return await this.connectionPool.query<Row>(text, values);
    } catch (error) {
      return asUnavailable(error);
    }
  }

  async transaction<Result>(operation: (client: PoolClient) => Promise<Result>): Promise<Result> {
    if (this.connectionPool === null) {
      throw new ServiceUnavailableException("PostgreSQL is not configured.");
    }

    let client: PoolClient;
    try {
      client = await this.connectionPool.connect();
    } catch (error) {
      return asUnavailable(error);
    }
    try {
      await client.query("BEGIN");
      const result = await operation(client);
      await client.query("COMMIT");
      return result;
    } catch (error) {
      try {
        await client.query("ROLLBACK");
      } catch {
        // Preserve the operation error if the connection has already been lost.
      }
      return asUnavailable(error);
    } finally {
      client.release();
    }
  }

  async checkReadiness(): Promise<DatabaseReadiness> {
    if (this.connectionPool === null) {
      return "unconfigured";
    }

    try {
      const client = await this.connectionPool.connect();
      try {
        const migrationTable = await client.query<{ table_name: string | null }>(
          "SELECT to_regclass('public.schema_migration')::text AS table_name",
        );
        if (migrationTable.rows[0]?.table_name == null) return "schema_pending";
        const appliedMigrations = await client.query<{ version: string }>(
          "SELECT version FROM schema_migration WHERE version = ANY($1::text[])",
          [requiredMigrations],
        );
        return appliedMigrations.rowCount === requiredMigrations.length ? "ready" : "schema_pending";
      } finally {
        client.release();
      }
    } catch {
      return "unavailable";
    }
  }

  async onModuleDestroy(): Promise<void> {
    await this.connectionPool?.end();
  }
}
