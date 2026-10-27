# Ionic Dart server

This is the target Dart modular monolith for Ionic. The NestJS server remains the API and behavior reference until route parity is verified. Keep the PostgreSQL schema and `/api/v1` contracts stable while porting modules.

## Current slice

The package currently provides health checks, account registration/login/session routes, an authenticated For You service/route backed by the deterministic recommendation core, post routes for creation/feeds/search/actions/replies, profile/social routes for lookup/search/follow/block/mute, one-to-one messaging routes for conversations/history/idempotent sends, report submission, and private local video upload/list/range-playback routes. The image/voice slice supports private staged JPEG and mono 16 kHz PCM WAV uploads; images are decoded, orientation-corrected, resized to at most 2048px, and re-encoded before storage. Staged assets can be attached only by their owner in the post/reply transaction, and reads re-check the published parent, profile visibility, and blocks. Local filesystem storage is development-only. Scheduled deletion cleanup, managed object storage, rate limits, and real device/database verification remain open. Post and video labels are persisted; real like/save state transitions update recommendation preferences in the same database transaction. Video uploads stay private in `processing`/`pending_review`; this is not public video publishing. No report review queue or media processing worker is implemented. Recommendation settings, pause/reset, per-item controls, hide, and video-signal handling are also present in source. A narrow Flutter Android sign-in/session/feed/text-post flow was exercised against this server; profile/social, messaging, report, media, pagination, and preference-update parity still need runtime verification before removing the NestJS reference.

## Local start

1. Start PostgreSQL with `docker compose -f ../../compose.dev.yaml up -d db` from the repository root.
2. Set `DATABASE_URL` to the local Compose database (the example uses `sslmode=disable` because the database listens only on host loopback and has no TLS) and run `dart run bin/migrate.dart` from this directory. The runner uses the existing SQL files under `apps/api/migrations`, verifies checksums, and applies pending migrations under a PostgreSQL advisory transaction lock. Never use the local `sslmode=disable` URL for shared or production databases; configure TLS verification such as `sslmode=verify-full` with the managed database CA instead.
3. Run `dart pub get`, then `dart run lib/main.dart`.
4. Check `GET /api/v1/health/live` and `GET /api/v1/health/ready`.

The server binds to `127.0.0.1:3000` by default. Set `HOST=0.0.0.0` only for a container or production service behind the intended network boundary.
