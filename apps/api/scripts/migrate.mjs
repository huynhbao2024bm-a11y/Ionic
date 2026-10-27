import { createHash } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";

const { Pool } = pg;
const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const migrationsDirectory = join(scriptDirectory, "..", "migrations");
const connectionString = process.env.DATABASE_URL?.trim();

if (!connectionString) {
  throw new Error("Set DATABASE_URL before running database migrations.");
}

const pool = new Pool({ connectionString, max: 1, connectionTimeoutMillis: 2_000 });
const client = await pool.connect();

try {
  await client.query("SELECT pg_advisory_lock(hashtext('ionic:schema-migrations'))");
  await client.query(`
    CREATE TABLE IF NOT EXISTS schema_migration (
      version text PRIMARY KEY,
      checksum varchar(64) NOT NULL,
      applied_at timestamptz NOT NULL DEFAULT now()
    )
  `);

  const names = (await readdir(migrationsDirectory))
    .filter((name) => /^\d{4}_[a-z0-9_]+\.sql$/.test(name))
    .sort();

  for (const name of names) {
    const sql = await readFile(join(migrationsDirectory, name), "utf8");
    const checksum = createHash("sha256").update(sql).digest("hex");
    const existing = await client.query(
      "SELECT checksum FROM schema_migration WHERE version = $1",
      [name],
    );

    if (existing.rowCount > 0) {
      if (existing.rows[0].checksum !== checksum) {
        throw new Error(`Applied migration ${name} was modified; create a new migration instead.`);
      }
      continue;
    }

    await client.query("BEGIN");
    try {
      await client.query(sql);
      await client.query(
        "INSERT INTO schema_migration(version, checksum) VALUES ($1, $2)",
        [name, checksum],
      );
      await client.query("COMMIT");
      process.stdout.write(`Applied ${name}\n`);
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    }
  }
} finally {
  try {
    await client.query("SELECT pg_advisory_unlock(hashtext('ionic:schema-migrations'))");
  } finally {
    client.release();
    await pool.end();
  }
}
