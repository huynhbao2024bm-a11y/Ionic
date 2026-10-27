# Data Model and Event Contracts

This is a logical schema, not a migration. Use normalized relational records for authoritative product state; derived ranking features are rebuildable and must never become the authority for access control.

## 1. Core entities

| Entity | Key fields / relationships | Notes |
| --- | --- | --- |
| User | id, normalized handle, password salt/hash or credential/provider reference, state, created_at | The first controlled implementation stores a scrypt hash and unique salt in PostgreSQL; never log credentials. |
| Profile | user_id, display_name, bio, avatar_media_id, visibility, settings | Profile visibility is enforced server-side. |
| UserSession | token_hash, user_id, created_at, expires_at | Store only a digest of an opaque random session token; expire and revoke sessions server-side. |
| Follow | follower_id, followed_id, state, created_at | Unique pair; state can support pending requests if private accounts ship. |
| AccountFollow | follower_id, followed_id, created_at | Directed relationship used by Following and social ranking; independent of mute. |
| AccountBlock | blocker_id, blocked_id, created_at | Either-direction block is a hard profile/content/feed/message access constraint. |
| AccountMute | muter_id, muted_id, created_at | Directed user choice. Excludes the muted creator's posts from the muter's For You and Following feeds; does not change follow edges, profile visibility, or messaging access. |
| Content | id, author_id, kind, body/ref, visibility, status, created_at, updated_at | `kind` distinguishes text and video; status gates recommendation eligibility. |
| ContentLabel | content_id, taxonomy_version, dimension, label_id, confidence, source, status | Internal multi-dimensional ranking metadata. Never expose labels in feed cards, profiles, or client APIs. Safety/visibility states stay outside preference labels. |
| ContentReaction | id, content_id, user_id, reaction, created_at | The first slice supports one like per user/content pair. The unique pair makes repeated like/unlike requests idempotent. |
| ContentBookmark | id, content_id, user_id, created_at | One save per user/content pair. Domain state is authoritative. |
| ContentReply | id, content_id, author_id, body, status, created_at | Root reply up to 500 characters with optional image or voice attachments; nested replies are not implemented yet. |
| MediaAsset | id, owner_id, storage_key, media_type (image/audio), mime_type, byte_size, width/height or duration_ms, processing_state, created_at | Current schema for local photo/voice assets; keys are opaque and never authorize reads. Stage uploads privately and attach them only in the post/reply transaction. Video drafts use a separate legacy table. |
| ContentAttachment | content_id or reply_id, media_asset_id, position, created_at | Exactly one parent per attachment; enforce ownership, per-item count/type limits, order, and no cross-account reuse. Parent deletion must clean the binary object; the current local adapter does not yet schedule that cleanup. |
| MediaRendition | id, media_asset_id, profile, codec, width, height, bitrate, container, manifest_object_key, processing_state | One output profile for adaptive playback; record the encoding/packaging version and readiness. Keep the manifest private until all required processing and safety gates pass. |
| MediaSegment | media_rendition_id, sequence, object_key, duration, bytes | Logical reference to an immutable segmented output object (for example HLS segments); do not store media bytes in PostgreSQL. Exact schema may be collapsed into object manifests if the chosen provider does not require a relational segment index. |
| Conversation | id, created_at, state | Initial design supports one-to-one membership. |
| ConversationMember | conversation_id, user_id, settings, joined_at | Enforce membership before every message read/write. |
| Message | id, conversation_id, sender_id, body/ref, created_at, delivery_state | Not a recommendation input. Define encryption and retention policy before launch. |
| DirectConversation (migration 0006) | id, participant_low, participant_high, created_at, last_message_at | One deterministic unique pair per two active users. Either-direction blocks deny list, history, and send access. |
| DirectMessage (migration 0006) | id, conversation_id, sender_id, body, created_at | UUID supplied by the client makes retries idempotent; 1–2,000 normalized text characters; history is returned newest-page-first through stable timestamp/ID cursors. |
| VideoAsset (migration 0007) | content_id, storage_key, mime_type, byte_size, state, created_at | Current local preview accepts WebM/MP4, verifies container signature and 60 MB cap, and stays `pending_review`; current uploads cannot be distributed or ranked. The For You gate accepts only separately processed/approved assets in `ready` state. |
| Report | id, reporter_id, target_type/id, reason, status, created_at | Access is restricted to reporter and authorized safety staff. |
| ContentReport (migration 0008) | id, reporter_id, content_id, reason, details, status, created_at | One row per reporter/content pair; report text is private and separate from recommendation signals. The current API records receipt only; staff review, enforcement, and appeals are not implemented. |
| UserPreferenceFeature | user_id, taxonomy_version, dimension, label_id, score, confidence, source_summary, updated_at, expires_at | Internal derived ranking feature from permitted feed behavior and generic item feedback; bounded, controllable, and resettable. |
| UserPreferenceControl | user_id, taxonomy_version, dimension, label_id, control (more/less/hidden), source, updated_at | Internal mapping of generic user feedback to taxonomy dimensions; has higher precedence than inferred preference features. Migrate these controls before activating a new taxonomy version. |
| RecommendationVideoSignal (migration 0010) | user_id, event_id, content_id, signal_kind, created_at, expires_at | Stores only coarse `active_view` or `skip` outcomes for authorized, ready videos; no exact duration or playback position. Idempotent per event ID and capped at one event of each kind per viewer/video in a rolling 24-hour window; expires after 30 days and is cleared on recommendation reset. Recent active views also provide exact short-term video repeat suppression. |
| FeedEvent | event_id, idempotency_key, action_id?, user_id, content_id, event_type, occurred_at, session_id, position, schema_version, measurement_quality | Minimize metadata; apply user controls and retention. Never store message bodies or raw text inputs here. |
| ModerationDecision | target_type/id, decision, reason_code, actor, timestamps | Audit changes; keep sensitive review details access-controlled. |

Production schema must define foreign keys, indexes, uniqueness, partitioning, and deletion semantics based on actual query patterns.

`FeedEvent` above remains a future generalized contract. Migration 0010 stores only one narrow class of coarse video signals, separate from that event schema. Like/save domain transitions and qualified video signals update preference features transactionally; raw watch-duration streams and message content are not retained for ranking. Expired rows are removed opportunistically on a later signal write by that user; a scheduled cleanup remains a public-beta requirement.

Migrations 0001–0011 implement identity/text posts, profiles/follows/blocks/mutes, recommendation controls, persistent post actions, candidate retrieval, direct messages, private local video drafts, indexed post search, persisted reports, and short-lived video recommendation signals. Migration 0012 adds private image/voice asset metadata and content/reply attachment links; it is applied to the dedicated local PostgreSQL database. The runner applies pending migrations under an advisory lock and rejects checksum changes. Migration 0008 adds a partial GIN index over published text for bounded full-text search; migration 0009 adds directed account mute state; migration 0010 adds the idempotent coarse video-signal table; migration 0011 indexes viewer/video/signal lookups for repeat suppression.

Authenticated users can search public profiles and accessible published text posts, read accessible profiles/posts, follow/block accounts, publish text, browse Following and For You, and use persisted like/save/reply actions. Post search uses PostgreSQL full-text matching, a GIN index, stable timestamp/ID pagination, and the same visibility and block boundaries as profile reads. The deterministic For You service retrieves bounded followed, exact-label, adjacent-topic, and fresh text candidates, then applies internal ranking/diversity rules. Image/voice attachment metadata is returned with parent content but bytes and attachment type are not ranking signals; no image/audio content analysis is implemented. Recommendation ranking quality and query latency still need measurement. One-to-one conversations and messages persist in PostgreSQL, use client UUIDs for idempotent retry, and are inaccessible while either account blocks the other. Message bodies are excluded from ranking. Content reports are persisted privately and deduplicated per reporter/content; no staff queue, review API, enforcement, or appeals flow exists yet. The Videos module records/uploads WebM/MP4 originals into local private storage and exposes owner-only range playback; current uploads remain processing/pending review and cannot enter For You. It has no server-side duration verification, scanning, transcoding, public-ready transition, or cleanup yet.

### Image and voice attachment implementation boundary

- The Flutter composer downscales/re-encodes images and removes metadata; Dart validates JPEG bytes/dimensions and decodes/re-encodes to strip remaining metadata. Voice is mono 16 kHz, 16-bit PCM WAV, 1–60 seconds. Current limits are four images, 8 MiB per image, and 2 MiB per voice asset.
- The development adapter writes bytes outside PostgreSQL under random opaque keys in `.data/attachments`; production requires private object storage and lifecycle cleanup.
- Only the owning author can attach staged assets inside the same transaction as the post/reply. Readers resolve access through the published parent, profile visibility, and bidirectional block rules. The file endpoint never accepts an object key as authority and disables caching.
- Images are fetched lazily and voice only after explicit play. Upload retry/cancellation UI, rate limiting, scheduled cleanup after parent deletion, object-store deletion propagation, and end-to-end/device verification remain open.
- Provisional starting product ceilings are four optimized images per post/reply and one voice note up to 60 seconds. Keep limits configurable and validate real device/network payloads before public release.

### Future video processing contract (not implemented)

- PostgreSQL stores ownership, opaque object references, processing/safety state, rendition metadata, and job/version identifiers; it does not store the binary media or every segment payload.
- A durable queue carries an idempotent processing request. Short-lived serverless orchestration validates state and dispatches work; a managed or ephemeral transcoder produces segmented adaptive-bitrate outputs. The API request never waits for encoding to complete.
- Objects remain private through quarantine, scanning, encoding, and moderation. The application exposes playback only after the asset and required rendition manifest are ready and authorized.
- Delete/retry/expiry transitions must cover source, rendition, segments, manifests, temporary objects, queue retries, and CDN caches. Final fields, indexes, provider-specific lifecycle policy, and retention values must be reviewed before a migration is written.

## 2. Taxonomy dimensions

Use a versioned hierarchical taxonomy internally; every feed-eligible post and video can have multiple labels per dimension. Do not expose these labels or derived user-interest labels in any user-facing surface:

- Topic: broad category and subtopic; a post can match more than one.
- Format: text, short video, tutorial, discussion, and other product-defined forms.
- Language: declared or detected language with confidence.
- Context: educational, entertainment, news/current affairs, personal update, and similar neutral descriptions.
- Creator/content lineage: original, reply, repost, or derived media where applicable.
- Provenance: publisher-supplied internally, rule-generated, model-generated, or human-audited, with confidence and taxonomy version.

Moderation, visibility, processing, and account eligibility are operational states, not interest labels. User preference features use the same taxonomy dimensions but store a score, confidence, recency, and coarse source summary rather than a copy of the underlying activity history.

Avoid inferring or storing protected/sensitive traits as preference labels. Authorized maintainers can inspect provenance and confidence for quality work; user controls remain generic and do not reveal a label vocabulary. Reports and item-level feedback provide user-facing correction paths without exposing internal labels.

## 3. Event contract

Common fields:

```json
{
  "event_id": "uuid",
  "idempotency_key": "opaque key",
  "action_id": "optional authoritative action reference",
  "schema_version": 1,
  "event_type": "feed.impression",
  "occurred_at": "RFC3339 timestamp",
  "session_id": "opaque short-lived identifier",
  "content_id": "opaque content identifier",
  "position": 1,
  "client_context": {
    "surface": "home",
    "network_mode": "unknown"
  }
}
```

The example is illustrative. Validate identifiers, event time bounds, enum values, payload size, and ownership/access at ingestion. An idempotency key prevents duplicate delivery; domain actions remain authoritative and are referenced rather than counted again as a second positive signal. Never include message body, raw query text, credentials, precise location, or unrestricted device fingerprint.

### Event types

- `feed.impression`: item actually rendered to a user; not merely returned by the API.
- `feed.dwell`: bounded active-view duration and measurement quality; do not send a high-frequency timer stream.
- `feed.skip`: item left before a calibrated minimum meaningful exposure; distinguish unknown/unmeasured from zero.
- `video.play`, `video.progress`, `video.complete`: coarse progress/completion milestones; avoid per-frame telemetry.
- `content.reaction`, `content.comment`, `content.save`, `content.share`, `creator.follow`, `creator.unfollow`: reference an authoritative domain action; the feature updater applies one signal per action.
- `feed.preference_feedback`: generic item-level “more/less similar” input referencing the content ID and a bounded enum; it never exposes the internal labels.
- `content.hide`, `recommendation.reset`: explicit controls, processed with higher precedence than inferred signals. Hide affects eligibility; reset invalidates derived personalization state.
- `content.report`, `account.block`: safety actions; never treat as ordinary negative preference only.

## 4. Derived preference updates

- Keep raw event access limited and time-bounded; aggregate features where practical.
- Weight signals by confidence, recency, context, and content measurement quality.
- Apply decay and caps so one accidental exposure cannot dominate a profile.
- Separate explicit positive/negative controls from inferred interest; explicit controls win.
- Store feature/ranker versions and internal reason codes for diagnostics without exposing them in feed responses or retaining excessive raw history. Keep advanced embeddings/stream-training tables out of the MVP schema; document and review them only when a gated future phase is approved.
- Reset must clear or invalidate derived preference state and candidate caches within a documented completion window; define behavior for legal/security audit records separately.

## 5. Deletion and retention

Before launch, assign retention periods to raw behavioral events, aggregates, messages, reports, and backups. A deletion request must propagate to primary records, search indexes, caches, feature aggregates, and queued work where legally possible. Backups expire according to a documented schedule; explain any exceptions to users. Do not promise immediate physical erasure if the system cannot guarantee it.
