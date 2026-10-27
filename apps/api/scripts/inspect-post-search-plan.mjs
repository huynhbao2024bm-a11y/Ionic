import pg from "pg";

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL?.trim(),
  max: 1,
  connectionTimeoutMillis: 2_000,
});

if (!process.env.DATABASE_URL?.trim()) {
  throw new Error("Set DATABASE_URL before inspecting the local post-search plan.");
}

function collectNodes(plan, nodes = []) {
  if (!plan || typeof plan !== "object") return nodes;
  nodes.push({
    nodeType: plan["Node Type"],
    indexName: plan["Index Name"] ?? null,
    estimatedRows: plan["Plan Rows"],
  });
  for (const child of plan.Plans ?? []) collectNodes(child, nodes);
  return nodes;
}

try {
  const [counts, index, explain] = await Promise.all([
    pool.query(`SELECT count(*)::int AS published_text_posts
                FROM content WHERE kind = 'text' AND status = 'published' AND deleted_at IS NULL`),
    pool.query(`SELECT indexdef FROM pg_indexes
                WHERE schemaname = 'public' AND indexname = 'content_published_text_search_idx'`),
    pool.query(`EXPLAIN (FORMAT JSON)
                SELECT c.id FROM content c
                JOIN app_user u ON u.id = c.author_id AND u.state = 'active'
                JOIN user_profile p ON p.user_id = u.id
                WHERE c.kind = 'text' AND c.status = 'published' AND c.deleted_at IS NULL
                  AND to_tsvector('simple', c.body::text) @@ websearch_to_tsquery('simple', $1)
                  AND (p.visibility = 'public' OR EXISTS (
                    SELECT 1 FROM account_follow f WHERE f.follower_id = $2 AND f.followed_id = u.id
                  ))
                  AND NOT EXISTS (
                    SELECT 1 FROM account_block b
                    WHERE (b.blocker_id = $2 AND b.blocked_id = u.id)
                       OR (b.blocker_id = u.id AND b.blocked_id = $2)
                  )
                ORDER BY c.created_at DESC, c.id DESC LIMIT $3`,
      ["ionic", "00000000-0000-4000-8000-000000000000", 20]),
  ]);
  const root = explain.rows[0]?.["QUERY PLAN"]?.[0]?.Plan;
  process.stdout.write(`${JSON.stringify({
    publishedTextPosts: counts.rows[0]?.published_text_posts ?? 0,
    searchIndexPresent: index.rowCount === 1,
    planNodes: collectNodes(root),
    note: "Planner estimates only; this command does not run EXPLAIN ANALYZE or read post bodies.",
  })}\n`);
} finally {
  await pool.end();
}
