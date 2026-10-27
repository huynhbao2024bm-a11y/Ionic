# System Architecture

## 1. Baseline

Move the product client to Flutter and the server application to Dart. Deliver the native Android app first, then validate the shared iOS app on macOS/Xcode; retain the responsive web PWA as a supported client. The target server is one modular Dart monolith using Shelf and shelf_router, with PostgreSQL as the system of record. Keep the `/api/v1` contracts, migrations, authorization rules, and recommendation semantics stable during the port. The existing NestJS API is the behavioral reference until Dart reaches parity; keep Angular as a rollback/reference until Flutter and Dart account-backed flows are verified. Do not move server authorization, ranking, or persistence into the Flutter client. For MVP and Beta operations, prefer a serverless-first deployment where demand is variable: scale-to-zero or usage-based compute for the API when its runtime constraints fit, and event-driven/managed jobs for asynchronous work. Use managed PostgreSQL, a durable queue, private object storage, and a CDN for media. This is a cost and operations hypothesis, not a provider selection or a requirement to split the product into microservices. Keep always-on capacity, provider lock-in, and service extraction out of the baseline until workload and cost measurements justify them.

This is a proposed baseline. Keep the first ranker in the application codebase and avoid a separate ML platform or analytics store until measured needs justify one.

## 2. Logical components

### Flutter Android-first native client and web PWA

- Authentication/session UX, profiles, text posts with optional image/voice attachments, text feed, messaging, settings, and safety controls. Short-video screens and capture are deferred from the launch navigation.
- Route the first visit to Home. Signed-out Home reads only public, published text posts from the API; if the service is unavailable, show a retryable error rather than synthetic content.
- Treat client state as untrusted; the API decides eligibility and authorization.
- Use a service worker for static application shell and explicitly safe cached resources only. Do not cache private messages or sensitive personalized feed data in shared caches.
- Send feed exposure/playback signals through a versioned event contract; buffer only bounded, non-sensitive events and honor consent/settings.

The Flutter app shares the `/api/v1` contract across Android, iOS, and web. Android is the first native build target. Native clients require an explicit HTTPS API base URL in release builds; local Android emulator development uses the host bridge address and a debug-only cleartext policy. Physical-device development uses a reachable LAN host, while production must use HTTPS. Browser requests keep same-origin cookies through the local web proxy. Native clients store the opaque session token in OS-protected storage and send the existing `ionic_session` cookie; Android backup is disabled to protect that device-bound secret. Image-picker access and microphone permission are requested only when the user chooses the related action; camera/video capture remains outside the text-first launch. Platform builds, install, account-backed flows, and release network policy are separate gates.

### API modules (Dart target; NestJS reference during migration)

| Module | Owns |
| --- | --- |
| Identity | Accounts, sessions, recovery, account lifecycle |
| Profiles and graph | Profile visibility, follows, blocks, mutes |
| Content | Text posts, comments, reactions, saves, visibility |
| Media | Upload authorization, processing state, media metadata |
| Feed and recommendation | Candidate assembly, internal content labels, user-interest features, ranking, generic feedback, tuning/reset, and evaluation |
| Messaging | Conversations, message authorization, delivery state |
| Trust and safety | Reports, moderation decisions, appeals, enforcement |
| Notifications | User-configurable notification delivery |
| Analytics events | Schema validation, idempotent event ingestion, aggregation |

Modules own their domain rules and persistence access. Cross-module interaction uses explicit application interfaces/events, not ad hoc table writes.

The NestJS reference has Identity, Content, Profiles/graph, Feed/Recommendation, Messages, Videos, and Trust modules. Dart route source now covers each current module family in `apps/server`, including staged image/voice attachments; full route parity is not established. Text posts, feed actions, follows/blocks/mutes, persistent one-to-one conversations, private video previews, text search, reports, and media metadata use PostgreSQL. Migrations 0001–0012 are managed under an advisory lock; the runner refuses checksum changes. Migration 0012 adds attachment metadata and parent links. Local development uses a separate Compose PostgreSQL 17 container on `127.0.0.1:5433`, isolated from the host PostgreSQL 18 service on 5432; this loopback-only service has TLS disabled, so local Dart URLs must explicitly include `sslmode=disable`. Shared/production database URLs must use verified TLS (`sslmode=verify-full` with a trusted CA). Recommendation SQL, media authorization, and message/video/search/report journeys still need database-backed behavioral and performance review.

Text search uses a bounded PostgreSQL full-text query over published text content, backed by a partial GIN index. It returns the newest matching posts the signed-in viewer may access, and applies account state, visibility, and bidirectional block rules. Reports are stored as private safety records with one report per reporter/content pair; the API currently accepts reports but does not provide staff review operations or enforcement transitions.

### Asynchronous workers (staged)

- Image/voice attachments: a first local slice now downsizes images on-device and validates, orientation-corrects, resizes, and re-encodes JPEGs on the Dart API. Mono 16 kHz PCM WAV voice notes are capped at 60 seconds. Uploads are staged under opaque keys in private local filesystem storage, attached in the post/reply transaction, and served only after rechecking parent visibility and block state; images load lazily and voice downloads only on explicit play. The local adapter is not production storage. Managed private object storage, rate limiting, scheduled deletion propagation, moderation operation, and real-device/database verification remain open.
- Media processing: still required before public video distribution. Add scanning, server-side duration verification, segmented adaptive-bitrate transcoding/packaging, captions, and a readiness state machine. Use queued, bounded, retryable jobs; offload long or CPU-heavy encoding to managed/ephemeral workers rather than holding an API request open. The current local slice stores unprocessed originals in `.data/media` and leaves content pending review.
- Labeling and event processing: begin with bounded deterministic logic and idempotent domain events; move expensive classification or aggregation to workers only when its measured load requires it.
- Recommendation refresh: current like/save feature updates are synchronous and bounded inside the domain transaction. Add background refresh/expiry jobs only when measured load or retention needs require them.
- Notifications and deletion jobs: add with bounded retries, idempotency, dead-letter visibility, and operator controls when those capabilities are introduced.

Use a durable queue when asynchronous work is introduced; Redis may support ephemeral coordination but must not silently become the only source of truth for critical jobs. Serverless functions orchestrate short tasks and state transitions; media encoding should use a managed transcoder or ephemeral worker sized for the job, with bounded execution, retry, and concurrency. Cost controls include upload limits, queue backpressure, per-job timeouts, lifecycle cleanup for incomplete uploads and temporary outputs, CDN cache/egress monitoring, and per-release measurement of storage, encoding, and delivery cost. Pick formats, renditions, segment lengths, and storage tiers from device/network coverage, measured playback quality, retention needs, and provider pricing rather than guessed constants. The text-first ranker scores a bounded set of public text posts in-process; video processing and video ranking are deferred. The deterministic recommendation core has a pure Dart port in `apps/server/lib/src/modules/recommendation`; `apps/api/src/modules/recommendation` remains its parity reference. The current For You source is PostgreSQL-backed; deployment, query-plan cost, and full endpoint parity remain open. API handlers validate and authorize inputs, load the active versioned policy and bounded candidate/profile data, then call it. The core does not own persistence or authorize access.

## 3. Storage responsibilities

- PostgreSQL: accounts, profiles, content metadata, follows/blocks, messages, moderation records, user controls, event outbox, and durable event records subject to retention.
- Redis: rate limits, short-lived cache, feed/session coordination, and ephemeral presence if needed. Cache loss must not corrupt authoritative state.
- Object storage: staged images, voice recordings, quarantined inputs, and any future video assets, encrypted at rest with private-by-default access. Keep source originals and derived previews as separately managed objects; use lifecycle tiers only when access, retention, deletion, and restore requirements are understood. Use bounded image/audio delivery and only add a CDN after access and cache policy are measured. Do not expose bucket paths as authorization.
- Analytics/feature storage: start with aggregates in PostgreSQL or a separately governed analytical store only when query/scale needs justify it. Document retention, access, and deletion propagation before adding a store.

## 4. Key flows

### Local private video preview (not public publishing)

1. An authenticated account records in the browser or selects a WebM/MP4 file; the client caps recorded duration at 60 seconds and file size at 60 MB.
2. The API streams the raw file into a mode-restricted local media directory, enforces a 60 MB byte cap while streaming, and checks the file signature against the declared container.
3. In one database transaction, the API saves a `short_video` content record in `processing`, a `video_asset` in `pending_review`, and internal caption/format labels. The client can list and range-play this asset only as its owner.
4. No other account can discover or play it. Do not set the status to published until a real worker has verified duration, scanned/processed media, and passed the required moderation decision. This video flow is deferred from the text+image+voice launch.

This is a development adapter only: no cloud object storage, resumable upload, server-enforced duration parser, scan, transcoder, adaptive renditions, moderation queue, public video feed, or deletion job exists yet.

### Persistent direct messages

1. A signed-in person creates or reuses a unique one-to-one conversation by handle; a two-way block denies creation, listing, history, and send.
2. The API writes a bounded normalized message under the authenticated sender ID. A client UUID is the message idempotency key, so retrying after a connection error cannot duplicate the same send.
3. The inbox lists the latest message per conversation. The open client refreshes every four seconds while visible; it does not poll in background tabs. Push delivery, read receipts, requests, attachments, and encryption at rest beyond the database provider remain open work.

### Publish a video

1. API authorizes the creator and issues a constrained upload authorization.
2. Client uploads directly to private quarantine object storage, using resumable/multipart transfer only if the selected provider and client need it.
3. An idempotent queue event starts a short-lived serverless orchestration; it verifies actual bytes/type/size/duration, scans the media, and dispatches a bounded managed/ephemeral encoding job.
4. The job creates configurable adaptive-bitrate renditions and segmented playback output (HLS as the initial candidate), plus poster/caption artifacts where available. Exact codec, segment duration, and rendition ladder are selected after device, bandwidth, quality, and cost evaluation.
5. Keep source and derived objects private. Resolve required moderation and processing checks before atomically making the playback manifest eligible; never expose incomplete output.
6. Deliver approved segments through a CDN with access-aware cache rules and short-lived authorization when required. Track upload, encoding, storage, CDN egress/cache, retry, and failure costs; clean up abandoned multipart sessions and temporary outputs.
7. API returns processing status and emits an auditable domain event.

### Request a feed

1. Resolve an authenticated viewer and load follows, blocks, hidden content, explicit controls, and active preference features. Client state cannot grant access.
2. Candidate retrieval builds bounded result pools of followed-creator posts, exact active explicit/positive-label matches, adjacent-topic matches, and newest eligible public text posts. It deduplicates and interleaves those source pools before capping the final ranker input at 500 by default. Every source applies the same publication, profile visibility, block, hide, as-of, and active-label eligibility checks; private-profile content requires a follow. This is structured-label retrieval, not semantic search. Query-plan and latency measurements remain open.
3. Rank eligible candidates into direct, strong, adjacent, or fresh tiers. The score uses taxonomy match, followed-creator affinity, freshness, exploration tier, and configured negative/repetition penalties; per-creator/topic/consecutive-topic caps are relaxed in fixed passes when necessary.
4. Return cursor-paginated items with author and action counts/state. Never return labels, score components, or internal reason codes. The cursor pins an as-of time, last item, and a SHA-256 fingerprint of the ordered content IDs; if recomputation yields a different order, reject the stale cursor and let the client restart. The fingerprint contains no profile features or labels.
5. Likes/saves and their undo actions update bounded features transactionally with the authoritative action. Replies are durable but neutral for ranking. More/less controls are explicit and remain active when learning is paused. Hide is a hard eligibility filter in both feed modes.
6. The MVP does not record rendered impressions, dwell, or skips. A feed response is not proof an item was seen.

### Record an interaction

1. Authenticate and validate the action and content access on the server.
2. Persist authoritative reaction/bookmark/reply state with its domain uniqueness constraint.
3. On a like/save transition, apply one bounded label contribution in the same transaction. A duplicate request does not transition domain state or contribute twice. Unlikes/unsaves use configurable negative values; replies default to zero weight.
4. While learning is paused, keep the domain action but do not update preference features. No impression or playback event endpoints are included yet.

### Future recommendation scale path

Use `RECOMMENDATION_SYSTEM.md` §11 as a gated design direction. The 14-day MVP keeps ranking in-process and deterministic. Candidate embeddings, learned retrieval, multi-task fine ranking, event streaming, and online training require measured need, approved event/retention semantics, representative evaluation data, operational ownership, and rollback; they are not implied by the initial module boundary.

## 5. Reliability and degradation

- Expose process liveness separately from dependency readiness. The API can report live while PostgreSQL is unavailable, but product reads/writes must not claim success without the system of record.
- Database readiness stays `schema_pending` until all migrations in the current repository have been applied.
- Feed has a deterministic safe fallback (for example eligible followed content in recency order) if personalized ranking is unavailable.
- If Redis is unavailable, degrade caches and ephemeral features; preserve PostgreSQL domain operations where safe.
- Media processing failures remain visible as retryable/failed status; never mark a failed asset publishable.
- Queue consumers are idempotent; retries are bounded and operationally inspectable.
- Use transactional outbox or an equivalent reliable pattern when domain transactions must publish events.

## 6. Evolution to separate services

Consider extraction only after identifying a concrete bottleneck or team boundary. Likely candidates are media processing and recommendation/event processing. Define ownership, event contracts, service-level objectives, data migration, rollback, and operational ownership before extraction. Do not split messaging or feed merely for architectural fashion.

## 7. Open operational decisions

- Hosting region, data residency, serverless runtime fit, and provider selection for the API, queue, object store, CDN, and video transcoder.
- Expected launch audience, media volume, latency/availability SLOs, and capacity envelope.
- Video duration/size limits, supported devices/networks, rendition ladder, segment format, retention, and cost budget; queue and analytical storage selection.
- Authentication provider and account recovery policy.
- Moderation operations, staffing, and escalation coverage.

Track resolutions in [`DECISIONS.md`](DECISIONS.md).
