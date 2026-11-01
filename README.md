# Ionic

Flutter app and Dart API for text posts, photo/voice attachments, profiles, account settings and private messages. Android is the first native target; short video is deferred.

## Source

- `apps/client`: Flutter Android/iOS/Web client.
- `apps/server`: active Dart/Shelf API, tests and recommendation code.
- `apps/api/migrations`: shared, checksum-verified PostgreSQL migrations.
- `apps/api` and `apps/web`: earlier server/web references.
- `infra`: database container and public Supabase CA certificate.

Product documents remain local under `docs/` and are intentionally excluded from the published branch. No private configuration, credentials, customer records, build output or model weights belong in this repository.

## Local development

Use Flutter 3.47.8 / Dart 3.13.7, Node for the Web preview, and PostgreSQL 17 with pgvector.

1. Start PostgreSQL: `docker compose -f compose.dev.yaml up -d db`.
2. In `apps/server`, configure a local `DATABASE_URL`, run `dart pub get`, `dart run bin/migrate.dart`, then `dart run lib/main.dart`.
3. In `apps/client`, run `flutter pub get`, then `node tool/run_dev.mjs`. The local preview proxies API traffic to port 3001.
4. For an emulator: `flutter run --dart-define=API_BASE_URL=http://10.0.2.2:3001/api/v1`. A phone build requires the deployed HTTPS API instead.

Safe example values are in `apps/server/.env.example`; local no-TLS PostgreSQL is only for development.

## Cloud preview

Build from repository root with `docker build -t ionic-api:preview .`. The Docker image contains native Linux API/maintenance executables and migrations; it runs as a non-root user. Render supplies `PORT`; the API listens on `0.0.0.0`.

Configure these only in the server's environment:

- `DATABASE_URL`: the dedicated Ionic role/session-pooler URL, `sslmode=verify-full`, and `sslrootcert=/app/infra/supabase/prod-ca-2021.crt`.
- `SUPABASE_URL`, `SUPABASE_SECRET_KEY`, `IONIC_STORAGE_BUCKET=ionic-media`: private cloud storage. The server key never belongs in Flutter.
- `IONIC_ATTACHMENT_STORAGE=supabase`, `APP_ENV=production`, `ALLOW_SIGNUP=true` for the intended controlled preview.
- `RECOMMENDATION_ADAPTIVE_ENABLED=true`, `RECOMMENDATION_MIN_RANDOM_SHARE=0.40`.
- The owner-selected free preview sets `RECOMMENDATION_SEMANTIC_ENABLED=false`; local-model semantics needs separate compute before enabling online.
- `WEB_ORIGINS`: only intended browser origins, when hosting a Web client.

Apply migrations before starting the service. Check `GET /api/v1/health/ready`; a successful build alone does not prove a working database or object store. Validate actual upload/read/delete and account flows before distributing the preview.

The preview has single-process request budgets and bounded upload processing. These do not replace full abuse prevention, moderation operations, backup/restore or a production signing/release review. Free hosting can sleep and require a cold start.

## Verification

From `apps/server`: `dart analyze`, `dart run bin/verify_attachment_storage.dart`, `dart run bin/verify_preview_limits.dart`, `dart run bin/verify_migration_checksum.dart`. Database suites explicitly require separate empty verification databases and remove their synthetic fixtures.

From `apps/client`: `flutter analyze`, `flutter test`, and native integration tests on an Android device/emulator. Build a phone preview with `flutter build apk --release --split-per-abi --dart-define=API_BASE_URL=https://your-api.example/api/v1`. Current release configuration uses the local debug signing key; it is a preview build, not Play Store distribution.
