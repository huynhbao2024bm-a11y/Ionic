# Ionic

Ionic is a Flutter social app project focused first on reading and publishing text posts, with accounts, profiles, social connections, private messaging, and a relevance-ranked feed. The product and engineering baseline is documented in [`docs/`](docs/), and implementation follows the staged roadmap there.

## Product direction

- **Home:** a readable text timeline with replies and clear follow and interaction controls. Signed-out visitors can read real public posts.
- **Publishing:** text posts and replies support optional optimized photos or a short voice recording. The first local Flutter/Dart implementation is in place; production storage, abuse controls, and full runtime verification remain open.
- **Profiles and connections:** public-facing profiles, follows, and account controls.
- **Messages:** a separate private one-to-one conversation experience.
- **Recommendations:** label text posts, build a revisable profile of topic interests, and rank by relevance, freshness, safety, and variety. Internal labels and reasons stay out of the interface.
- **Appearance:** charcoal dark mode by default; light mode is a device-local setting.

Short video is deferred from the first release and excluded from its main navigation and text-feed ranking. It remains documented as a later phase after processing, moderation, storage, and cost controls are ready.

The product takes interaction patterns as references: a concise social timeline, familiar profiles and chat, and vertical video discovery. It does not depend on copying another product's exact screens or rules.

## Design documents

| Document | Purpose |
| --- | --- |
| [`AGENTS.md`](AGENTS.md) | Mandatory project constraints for AI coding agents and contributors. |
| [`docs/PRODUCT_REQUIREMENTS.md`](docs/PRODUCT_REQUIREMENTS.md) | Product scope, user journeys, functional requirements, and acceptance criteria. |
| [`docs/UX_UI_SPEC.md`](docs/UX_UI_SPEC.md) | Code-first responsive Flutter layouts and interactions. |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | System boundaries, deployment shape, and key flows. |
| [`docs/DATA_MODEL.md`](docs/DATA_MODEL.md) | Core entities, relationships, retention, and event contracts. |
| [`docs/RECOMMENDATION_SYSTEM.md`](docs/RECOMMENDATION_SYSTEM.md) | Signals, content labels, ranking, the 3–5–10–25 progression, and diversity controls. |
| [`docs/SECURITY_PRIVACY.md`](docs/SECURITY_PRIVACY.md) | Privacy, security, moderation, and abuse-prevention requirements. |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | Phased delivery plan and release gates. |
| [`docs/DECISIONS.md`](docs/DECISIONS.md) | Recorded design decisions and assumptions to revisit. |
| [`docs/PROJECT_ASSESSMENT.md`](docs/PROJECT_ASSESSMENT.md) | Dated evidence snapshot, known gaps, and rules against overstating readiness. |

## Current implementation

The recommendation core has been ported to Dart in `apps/server/lib/src/modules/recommendation`; the current For You source is text-only. The Dart server has health/auth/feed/post/profile/message/report route source, while local video source remains a deferred, owner-only preview path. Post labels and like/save preference updates are persisted; internal labels stay out of the interface. A narrow Flutter Android flow was previously verified against Dart and local PostgreSQL: sign-in, session restore after app restart, For You response, and text-post publish/readback. The current media path now has Flutter/Dart source, migration 0012 applied locally, successful Web/APK builds, and database readiness; image/voice create-read flows have not been exercised end to end. The NestJS implementation remains the parity reference while other Dart routes and ranking-feedback behavior are checked. PostgreSQL migrations 0001–0012 are the shared schema contract. Staffed report review, production media storage/lifecycle, and real-device performance review are not implemented or verified. Keep `apps/api` and `apps/web` until the Dart server and Flutter app pass route parity and core signed-in flows.

## Run the client

Start PostgreSQL with `docker compose -f compose.dev.yaml up -d db` from the project root. For the existing NestJS reference API, run `npm run migrate`, `npm run build`, and `npm start` from `apps/api`. For the Dart target, run `dart run bin/migrate.dart` and `dart run lib/main.dart` from `apps/server` with `DATABASE_URL` set; its default port is 3001. Flutter Web runs from `apps/client` with `flutter pub get` and `node tool/run_dev.mjs`; the same-origin proxy defaults to Dart on port 3001 and accepts `IONIC_API_PORT=3000` for NestJS. The Android debug build targets Dart at `10.0.2.2:3001` by default when passed `--dart-define=API_BASE_URL=http://10.0.2.2:3001/api/v1`. A physical Android device needs the development machine's reachable LAN address. Release builds must use an HTTPS API URL. iOS scaffolding exists but compiling/signing requires macOS with Xcode. Keep `apps/api` and `apps/web` until remaining route parity and signed-in journeys pass. See [`docs/ROADMAP.md`](docs/ROADMAP.md) for the active gates.

## Target technology baseline

- Client: Flutter native app, Android first and iOS next; responsive Web PWA remains supported. Android/iOS readiness is tracked separately from Web build success.
- API/server: Dart modular monolith using Shelf and shelf_router; NestJS stays as a parity reference during migration.
- Primary data store: PostgreSQL.
- Cache and short-lived coordination: Redis when required by load or feature needs.
- Media: local photo/voice staging and parent-authorized delivery are implemented for development; production requires private object storage, limits, rate controls, deletion cleanup, and moderation operations. Short-video processing remains a later phase. The current local video preview uses `.data/media` and must not be exposed publicly.
- Initial topology: a modular monolith with explicit module boundaries; split services only when measured operational needs justify it.

The client and server migration is in progress, not a claim of API parity or deployed infrastructure. Add infrastructure only when a project phase needs it.

## Git

The repository uses `main` as its initial branch. Configure your Git author identity before creating commits:

```powershell
git config user.name "Your Name"
git config user.email "you@example.com"
git status
```

See [`AGENTS.md`](AGENTS.md) before making implementation changes.
