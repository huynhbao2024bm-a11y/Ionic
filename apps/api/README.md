# Ionic API

The API is a NestJS modular monolith backed by PostgreSQL. It includes account registration/sign-in, database-backed sessions, text-post creation, private author post history, and liveness/readiness endpoints.

## Local start

1. Start Docker Desktop. From the repository root run `docker compose -f compose.dev.yaml up -d db`. This development-only database binds to `127.0.0.1` and persists in the `ionic_postgres_data` volume.
2. Copy `.env.example` to `.env`. Its sample password matches the local container and must not be reused outside development.
3. From this directory run `npm install`, `npm run migrate`, `npm run build`, then `npm start`.
4. Check `GET /api/v1/health/live` for process liveness and `GET /api/v1/health/ready` for database/schema readiness. Readiness returns `unconfigured`, `unavailable`, or `schema_pending` until migration 0001 is applied.

The migration runner takes a PostgreSQL advisory lock, applies SQL files in order inside transactions, records SHA-256 checksums, and stops if an applied migration was edited. Add a new migration instead of changing one that has already been applied.

## Current API surface

- `POST /api/v1/auth/register` — create a handle-based account and sign in.
- `POST /api/v1/auth/login` — sign in.
- `POST /api/v1/auth/logout` — revoke the current session.
- `GET /api/v1/auth/me` — return the signed-in account.
- `POST /api/v1/posts` — publish a text post (1–280 characters).
- `GET /api/v1/posts/mine?limit=20&cursor=…` — list the signed-in user's posts with a stable cursor.

Authentication returns an HttpOnly, SameSite=Strict cookie; only a SHA-256 digest of its random token is stored in PostgreSQL. Passwords use Node's scrypt with a unique random salt. Mutating requests with a browser Origin are restricted to configured `WEB_ORIGINS`. The initial post labeler writes only the internal format label `format.text`; it does not yet infer topics and this endpoint is not connected to the For You ranker.

Set `ALLOW_SIGNUP=true` only for local development or an explicitly controlled release; registration is disabled by default in production. Account recovery, email verification, age policy, public signup, authentication throttling across multiple API instances, blocks/reporting, and moderation operations are release gates. Keep this implementation in a controlled local environment until those workflows are defined and implemented. Without a configured or reachable PostgreSQL database, the API starts for liveness inspection but account and post operations return HTTP 503; it does not substitute in-memory product state.
