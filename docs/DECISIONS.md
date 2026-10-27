# Design Decisions and Open Questions

This log records intentional choices and assumptions. Add a dated entry when a decision changes; do not silently contradict the current baseline.

## Accepted baseline

### D-001 — PWA-first client

- **Status:** The responsive PWA remains a supported client; native Android-first delivery is added by D-035.
- **Decision:** The original client was a responsive, installable Ionic + Angular + TypeScript PWA; the current client framework is tracked by D-033.
- **Reason:** Matches the requested PWA direction and provides one primary client across mobile and desktop browsers.
- **Revisit when:** Native-only capabilities or distribution requirements materially change.

### D-002 — Modular monolith first

- **Status:** Accepted direction; supporting infrastructure is staged
- **Decision:** Use a NestJS modular monolith with PostgreSQL. Add Redis, durable workers, and object storage/CDN when the corresponding cache, media, or asynchronous-processing phase requires them.
- **Reason:** Keeps domain ownership explicit without requiring every production component before a working product exists.
- **Revisit when:** Measured scale, reliability, or team ownership makes a different topology worthwhile.

### D-003 — Position-based 3–5–10–25 ranking

- **Status:** Hypothesis, not a release contract
- **Decision:** Keep 3–5–10–25 as a configurable position schedule to evaluate. The first ranker uses relevance tiers and tunable score components; it does not hard-code item ratios or unvalidated stage weights.
- **Reason:** The product needs relevance ordering and exploration, but the schedule's value should be demonstrated against user feedback and feed-quality metrics.
- **Revisit when:** The first deterministic ranker has representative evaluation data.

### D-004 — Rules-based recommendation before ML

- **Status:** Accepted
- **Decision:** Launch recommendation v1 with generic user controls, auditable weighted rules, calibrated behavior signals, and safe fallback. Introduce ML only after data quality, consent, evaluation, and rollback are ready.
- **Reason:** Avoids treating an unvalidated model as a prerequisite and provides a measurable baseline.

### D-005 — Recommendation labels and input scope

- **Status:** Implemented in part; raw-media labeling and exposure events remain future work
- **Decision:** Label every eligible post and video internally. Build viewer-interest features from generic item feedback and eligible feed interactions. Do not render internal labels on posts, profiles, or settings. Do not rank from credentials, private-message bodies, precise location, raw keystrokes, or sensitive-trait inference.
- **Reason:** The ranker needs consistent item features, while user controls can act on items without exposing the taxonomy or turning unrelated private data into ranking inputs.
- **Open detail:** Whether public profile text may contribute to internal content labeling remains unresolved and must be decided with its consent, privacy, and control model before implementation.

### D-006 — Relevance tiers for the first ranker

- **Status:** Proposed for v1
- **Decision:** Start with four ordered tiers: direct match, strong match, adjacent discovery, and fresh discovery. Score and diversify items within each tier; keep weights configurable. Reason codes are internal diagnostics only.
- **Reason:** This gives engineering a testable ranking contract without pretending the initial weights are already optimal or asserting an unverified reason to the user.
- **Revisit when:** User studies and offline evaluation support a better tier or scoring design.

### D-007 — Algorithm-first delivery

- **Status:** Superseded by D-010
- **Decision:** The original delivery sequence was to finish the recommendation core before the client and content loop.
- **Reason:** The pure recommendation slice was a useful technical baseline, but the user later directed that the interface and core user flows should be built first. The interface is now developed directly in code under D-032.
- **Revisit when:** The client feed can supply real, eligible content and the recommendation core is ready for integration.

### D-008 — Pure, versioned recommendation core

- **Status:** Accepted implementation boundary; calibration values remain open
- **Decision:** Keep the first recommendation implementation as a deterministic TypeScript module. Require matching taxonomy and ranker versions, bound preference scores to `[-1, 1]`, apply explicit less-like controls as a configured score penalty, and leave authorization, persistence, and candidate assembly to the API module.
- **Reason:** This makes the algorithm reviewable and reusable in the modular monolith while preventing uncalibrated constants or stale taxonomy labels from silently defining production behavior.
- **Revisit when:** Evaluation data supports changes to tier boundaries, signal weights, taxonomy migration, or ranking architecture.

### D-009 — Keep diversity selection simple for the feed page

- **Status:** Accepted for the current request path
- **Decision:** Use the straightforward diversity-cap scan for ordinary page-sized feed requests. An indexed counter implementation was faster only for some candidate/output sizes in the local synthetic comparison; do not add a size threshold until representative request measurements show a repeatable benefit.
- **Reason:** The feed endpoint will request a bounded page, and the measured differences at page sizes were small and inconsistent. The current pure-ranker reference and benchmark scope are recorded in [`RECOMMENDATION_SYSTEM.md`](RECOMMENDATION_SYSTEM.md).
- **Revisit when:** Real candidate counts, requested page sizes, and tail latency are available.

### D-010 — Home-first, interaction-led delivery

- **Status:** Home-first sequence accepted; Figma-specific design workflow superseded by D-032; visitor authorization remains provisional
- **Decision:** Build the usable client shell before expanding unrelated backend features. Open the app directly to Home without a mandatory tutorial or interest survey. For the first local prototype, use synthetic feed items and do not present prototype actions as persisted. The interface may defer account setup until an account-required action.
- **Reason:** The user explicitly prioritized interface and functionality, immediate use, and ease of interaction while keeping recommendation quality the central product differentiator.
- **Provisional assumption:** A future read-only visitor may browse only public, eligible content. This is not a production authorization decision; the API and account policy must confirm it before live anonymous feed access.
- **Revisit when:** The first end-to-end feed and identity policy are ready for review, or usability evidence shows the opening flow needs adjustment.

### D-011 — Keep taxonomy and ranking rationale out of the interface

- **Status:** Accepted
- **Decision:** Do not display internal content/user-interest labels, taxonomy-derived topic chips, or per-item explanations such as “because you are interested in …” on feed, profile, search, or settings surfaces. Keep user controls generic: more/less similar content on an item, pause personalization, and reset. Ranking reason codes stay internal to diagnostics and are excluded from the client feed contract.
- **Reason:** This follows the user's explicit product direction. Research also shows the effect of explanations depends on context: a 2024 SIGIR study of book recommendations (N=237) found explanations increased perceived transparency/scrutability but reduced interest in its single-domain condition; a 2023 CHI study (N=129) found recommendation explanations could significantly affect selections. These studies do not establish a universal rule for social feeds, so the interface will not show a rationale without a separately validated, faithful design.
- **Implementation note:** Internal taxonomy remains available to the ranker. “Less like this” applies a configured negative ranking signal; it is separate from the explicit hide action.
- **Revisit when:** The user requests a change, or a social-feed study demonstrates a clear benefit for an explanation design that is faithful to actual ranking behavior.
- **Evidence:** [SIGIR 2024 study](https://doi.org/10.1145/3626772.3657735); [CHI 2023 study](https://doi.org/10.1145/3544549.3585748).

### D-012 — Stage the Monolith-inspired recommendation direction after the 14-day MVP

- **Status:** Accepted as a future design direction; not implementation approval for the MVP
- **Decision:** Target a usable closed Ionic MVP by 2026-11-06. Keep the current deterministic in-process ranker for that release. Document a later path that may add multimodal content features, user/content embeddings, multi-source candidate retrieval, a learned multi-objective ranker, diversity re-ranking, and low-latency feature updates only after data quality, authorization, retention, evaluation, and operating needs justify each step. Specific technologies such as two-tower retrieval, MMoE, Cuckoo/collisionless embedding tables, Kafka, and Flink are candidates to evaluate, not fixed requirements.
- **Reason:** The ranking system is a core differentiator, but the immediate product objective is a usable end-to-end experience within 14 days. Building high-scale training infrastructure before Ionic has representative, permissioned events would add risk and delay without validated product benefit.
- **Factual boundary:** Monolith is a published ByteDance real-time recommendation-system design; that publication does not verify that the described architecture is TikTok's current For You implementation. Public TikTok material describes broad signal categories and controls, not the proprietary internals claimed in the initial pitch. Do not copy unverified candidate counts, component names, thresholds, or update intervals into requirements.
- **Review gate:** Before implementing a future model or event pipeline, update the recommendation, data, privacy, and architecture documents together with the actual input/retention/rollback contract. Treat event semantics, training objective, sensitivity limits, model topology, and latency target as open until reviewed against real workload evidence.
- **References:** [Monolith paper (2022)](https://arxiv.org/abs/2209.07663); [TikTok: How recommendations work](https://support.tiktok.com/en/using-tiktok/exploring-videos/how-tiktok-recommends-content).

### D-013 — Controlled MVP account and text-post persistence baseline

- **Status:** Implemented as a local/controlled-release baseline; not approved for public signup
- **Decision:** Start with unique lowercase handles and passwords, salted scrypt password hashes, random opaque server-side sessions whose SHA-256 digests are stored in PostgreSQL, and public text posts up to 280 characters. The API exposes registration, sign-in, sign-out, current-account, create-post, and authenticated author-history routes. Each new post and its current internal versioned text labels are committed in one transaction.
- **Reason:** This establishes a real persistence and authorization boundary for the first end-to-end product slice without taking a dependency on an external identity provider or treating client demo state as durable.
- **Security:** Protect cookie-authenticated writes by checking browser `Origin` against the configured web origin allowlist; the HttpOnly/SameSite cookie and origin check are both required for the browser flow.
- **Boundaries:** Text posts receive format plus a small non-sensitive keyword-rule vocabulary and feed labels stay internal. The client account modal and composer use the API. Profiles/follows are recorded in D-014, feed/action behavior in D-015, messaging in D-021, and report submission in D-024. Staff moderation still needs operating policy and review controls. Registration is disabled by default in production. Do not expose it publicly until age/account policy, recovery, email verification policy, rate limiting, account deletion, and moderation operation are addressed.
- **Revisit when:** The controlled user policy and client account flow are ready to be connected, or before any deployment that accepts real users.

### D-014 — Authenticated public profiles, follows, blocks, and Following feed

- **Status:** Implemented in source; migrations 0001–0008 are applied locally. API/database readiness passed before the latest API restart but has not been reconfirmed; end-to-end authorization still needs behavioral review.
- **Decision:** Add directed follow and block tables. Authenticated users can search public handles/display names by prefix, view public profile details and posts, follow/unfollow, block/unblock, and read a cursor-paginated chronological Following feed. Search is bounded to 20 results. Profile, search, and post reads hide a blocked pair in both directions. Creating a block removes follow edges in both directions; a blocked pair cannot create a new follow. The API rejects new follows to private profiles until follow requests are designed.
- **Reason:** These rules enforce the existing requirement that a block is a hard access boundary and make the documented Following option use authorized persisted posts rather than demo-only client filtering.
- **Concurrency and access:** Follow/block transactions lock both account rows in stable ID order, then recheck blocks before writing. Every API route requires the existing server-validated session. The Following query applies block checks before returning records and keeps stable `(created_at, id)` cursors.
- **Boundary:** Private-profile requests, profile editing, and staff moderation/report review remain future work. Report submission is now covered by D-024; persistent messaging by D-021. Migration 0002 is additive and does not alter migration 0001. Rollback can revert application code while leaving tables in place; dropping relationship data requires a reviewed retention plan.
- **Verification:** API/web typechecks and builds pass; migrations are applied and the API readiness endpoint reported `ready`. Account/follow/block behavior has not yet had end-to-end interaction review.

### D-015 — Connect MVP For You and durable text actions

- **Status:** Implemented in source; migrations are applied locally, with recommendation behavior and query plan still unverified
- **Decision:** The authenticated For You API assembles at most 500 candidates from bounded followed-creator, positive-label-match, and fresh-content sources, then calls the deterministic ranker. The retrieval merge is specified in D-018. Internal labels and ranking details stay server-side. Likes, saves, and root replies are domain records in PostgreSQL; unique user/content pairs make like/save transitions idempotent. Like/save and undo transitions update bounded, expiring per-label features in the same transaction. Replies are currently neutral to the ranker. More/less feedback stays in the separate explicit-control table; hide is a hard feed filter. Pause skips future learned updates but retains existing features and manual controls. Reset clears learned features and more/less controls but preserves hides and domain actions.
- **MVP labeler:** Every text post receives `format.text`, and each video caption receives `format.short_video`; the same keyword rules may add neutral design, software, product, writing, learning, creativity, how-to, and Vietnamese-language labels. This is caption/text classification only, not video-frame or audio analysis, and is intentionally a narrow starter vocabulary rather than a semantic model. No image/audio feature extraction or sensitive-trait inference is implemented.
- **Provisional tuning:** Candidate limit 500; feature half-life 14 days; feature expiry 60 days; minimum preference confidence 0.55; strong-match threshold 0.18; freshness half-life 1 day; diversity caps 3 per creator, 4 per primary topic, and 2 consecutive same-topic posts. Base score weights are equal for available signals except quality (0). Initial action weights are like +0.18, unlike -0.12, save +0.24, unsave -0.16, reply 0; each is configurable and uncalibrated. These are engineering defaults for a usable slice, not claims about an optimal model. Do not tune from production use until representative quality/safety evaluation and retention rules exist.
- **Reason:** Ship a coherent persistent social/feed loop quickly, connect the core ranker to real domain content and reversible user controls, and avoid misrepresenting speculative Monolith/TikTok mechanics as implemented.
- **Verification boundary:** Migrations 0001–0011 are applied locally. Typechecks/builds pass; ranking SQL, authorization outcomes, counts, pause/reset, and pagination still need behavioral review. Persistent inbox is implemented under D-021, and post search/report submission under D-024. Rendered impressions, exact dwell duration, streaming training, and embeddings are not included; qualified coarse video active-view/skip outcomes are specified in D-028. Ready short-video candidates share the For You ranker, but current uploads stay private and pending review, so this does not enable public video distribution.

### D-016 — Serverless-first, segmented media delivery for MVP/Beta

- **Status:** Accepted as a provider-neutral design direction; not implemented or cost-validated
- **Decision:** Keep the product backend a modular monolith. For variable MVP/Beta workloads, prefer usage-based/serverless compute where runtime and latency constraints fit, managed PostgreSQL and a durable queue, private cloud object storage, and CDN delivery. Video uploads go to private quarantine storage; idempotent queued jobs validate and scan media, then dispatch a managed or ephemeral transcoder to create segmented adaptive-bitrate playback output (HLS is the initial candidate). Keep original and derived objects private, expose the manifest only after processing and required moderation checks, and apply access-aware CDN policy. Use bounded upload sizes/duration, concurrency/retries/timeouts, cleanup, retention/deletion propagation, and cost observability for storage, encoding, and egress.
- **Constraints:** The local video preview in D-022 does not satisfy this processing/public-delivery design. This direction does not authorize a vendor, codec, rendition ladder, segment length, numeric budget, or permanent archive policy. Do not block an API request on encoding or split the backend into microservices. Revisit deployment choices with representative use, operational measurements, provider pricing, target regions/devices, and a tested failure/deletion path.
- **Reason:** Reduce idle capacity and avoid serving large originals for playback while keeping early operations small and media access private by default.
- **Affected documents:** `ARCHITECTURE.md`, `PRODUCT_REQUIREMENTS.md`, `DATA_MODEL.md`, `SECURITY_PRIVACY.md`, `ROADMAP.md`, and `RECOMMENDATION_SYSTEM.md`.

### D-017 — Bind For You pagination to its ranked result snapshot

- **Status:** Implemented in source; API/database readiness passed before the latest API restart but has not been reconfirmed. Stable and stale-cursor behavior has not had an end-to-end review.
- **Decision:** Include an as-of cutoff, last content ID, and SHA-256 digest of the ordered ranked content IDs in each For You cursor. Recompute the bounded result on the next page and reject the cursor if its ordered IDs differ; the client restarts the feed on that stale-cursor response. Do not put user profile features, taxonomy labels, scores, or rationales in the cursor or response.
- **Reason:** The API recomputes its ranked candidate set on every page. If content eligibility or ranking changes between requests, continuing by position could silently skip or repeat items. The digest detects changes in the visible order without storing a server-side page snapshot or exposing personalization data.
- **Trade-off:** A user may need to reload after a like/save, preference change, moderation action, or other update changes ordering; the first slice favors correct sequencing over continuing a stale feed.
- **Verification boundary:** TypeScript checks/builds pass and the API reports database readiness. Exercise stale and stable cursor cases against the database before release.
- **Affected documents:** `ARCHITECTURE.md`, `PRODUCT_REQUIREMENTS.md`, `RECOMMENDATION_SYSTEM.md`, and `ROADMAP.md`.

### D-018 — Retrieve recommendation candidates from bounded sources

- **Status:** Implemented in source; retrieval quality and database query plan remain unverified
- **Decision:** Before ranking, retrieve up to the configured candidate limit from four eligible-content sources: followed creators, content matching explicit “more” controls or positive preference features above the ranker's decayed confidence threshold, adjacent topics from the versioned graph for sufficiently confident learned positive features, and newest eligible content. Deduplicate by content ID, interleave each source's recency order deterministically, and cap the merged set at the configured candidate limit (500 by default). Apply public/published status, active-account, profile-visibility, either-direction block, mute, hide, as-of, active-taxonomy-label, and format-specific readiness checks before content enters any source; short video requires a `ready` asset. Compute reaction/reply counts and viewer action state only for the merged candidates.
- **Reason:** A single newest-first pool can starve older posts from followed creators or topics with demonstrated positive preference. Multiple bounded result sources improve candidate coverage while retaining a predictable ranker input size and cold-start fallback.
- **Trade-off and calibration:** The interleave order establishes source availability, not a quota or guarantee in the final feed; the ranker's relevance tiers and diversity passes decide the displayed order. Equal source turns are an initial, reversible hypothesis and must be evaluated against eligible-candidate coverage, freshness, relevance, diversity, query plan, and latency before tuning. No new user data or event type is introduced.
- **Migration and rollback:** Migration 0005 adds a partial recency index for the fresh source. Rolling back application code does not require dropping the additive index; remove it only through a separately reviewed migration if future measurements show it is unnecessary.
- **Verification boundary:** Migrations are applied and the API reports database readiness, but the SQL, query plan, and feed behavior have not had database-backed behavioral review.
- **Affected documents:** `ARCHITECTURE.md`, `DATA_MODEL.md`, `RECOMMENDATION_SYSTEM.md`, `ROADMAP.md`, and `DECISIONS.md`.

### D-019 — Enable a version-scoped topic adjacency graph

- **Status:** Implemented in source as an uncalibrated v1 hypothesis
- **Decision:** Use a small, undirected topic adjacency map for the current `ionic-taxonomy-v1` labels (design, software, product, writing, learning, and creativity). Only sufficiently confident positive learned topic features can retrieve an adjacent candidate or place it in the adjacent tier. A different taxonomy version gets no adjacency until its graph is defined. The adjacency map and internal labels never appear in the client contract.
- **Reason:** The ranker already defined an adjacent-discovery tier, but its configured map was empty, leaving that tier unreachable. A narrow explicit graph makes the existing behavior real while remaining reviewable and easy to replace.
- **Trade-off and calibration:** The links are editorial hypotheses rather than learned similarity. Measure whether they improve relevance and topic breadth without creating unexpected jumps or weakening explicit less controls. Do not extend the graph to sensitive or inferred traits.
- **Affected documents:** `RECOMMENDATION_SYSTEM.md`, `ARCHITECTURE.md`, `ROADMAP.md`, and `DECISIONS.md`.

### D-020 — Isolate the local development database from host PostgreSQL

- **Status:** Implemented in local development configuration
- **Decision:** Publish the Compose PostgreSQL container on `127.0.0.1:5433` instead of `5432`, and permit its database/user/password to be supplied through environment variables with local-only defaults. Keep the app's database URL in the ignored `apps/api/.env`; do not store a developer's database credentials in tracked Compose files.
- **Reason:** The development machine already has PostgreSQL 18 listening on port 5432, and its credentials do not match Ionic's API configuration. A separate container avoids stopping, resetting, or migrating an unrelated/local host database while providing a clean project database.
- **Trade-off:** Update `apps/api/.env` to the Compose host port and use matching credentials. The old host PostgreSQL service and its data remain untouched.
- **Affected documents:** `README.md`, `ROADMAP.md`, `ARCHITECTURE.md`, and `DECISIONS.md`.

### D-021 — Persist one-to-one messages with bounded visible-tab refresh

- **Status:** Implemented in source; migration 0006 applied to the local Ionic database; interaction and authorization paths still need behavioral review.
- **Decision:** Keep one unique conversation per sorted two-account pair. Persist normalized text messages (1–2,000 characters), use a client UUID as the idempotency key, return bounded timestamp/ID-paginated history, and deny conversation creation/list/read/send while either account blocks the other. Refresh the selected conversation every four seconds only while its page is visible; send locally first and remove the optimistic item on failure.
- **Reason:** This gives the account experience real persistence and prompt delivery without introducing an always-on socket service or writing message content to the recommendation system.
- **Limits:** Group chat, push delivery, unread/read receipts, requests, attachments, and a retention schedule are not implemented. Four-second polling is a temporary MVP trade-off and needs load/latency measurement before wider use.
- **Affected documents:** `PRODUCT_REQUIREMENTS.md`, `DATA_MODEL.md`, `ARCHITECTURE.md`, `SECURITY_PRIVACY.md`, `UX_UI_SPEC.md`, and `ROADMAP.md`.

### D-022 — Keep the first video capture path private until processing and review exist

- **Status:** Implemented as an owner-only local development preview; not approved for public video distribution.
- **Decision:** Support browser recording with a 60-second client cap and WebM/MP4 file selection; the API caps uploads at 60 MB, checks the declared container signature, stores the file outside public assets, and records an internal short-video caption. Persist uploaded content as `processing` and media as `pending_review`; grant playback only to its owner. Do not expose it to other accounts, feed ranking, or public playback until real server-side duration verification, malware/content checks, moderation, transcoding, and release authorization exist.
- **Reason:** A usable capture/preview can be built now without claiming that a raw, unreviewed local file is safe or ready to distribute.
- **Limits:** This adapter writes unprocessed originals to local disk, offers no resumable/cloud upload, no server-side duration check, no moderation queue, no transcoder, no adaptive stream, and no cleanup/deletion job. Replace it with the private serverless/object-storage path in D-016 before a Beta distribution launch.
- **Affected documents:** `PRODUCT_REQUIREMENTS.md`, `DATA_MODEL.md`, `ARCHITECTURE.md`, `SECURITY_PRIVACY.md`, `UX_UI_SPEC.md`, and `ROADMAP.md`.

### D-023 — Make interaction smoothness a measurable release gate

- **Status:** Accepted as an acceptance target; project measurements not yet collected.
- **Decision:** Require Core Web Vitals “good” thresholds at the 75th percentile, separated by mobile and desktop: LCP ≤2.5 seconds, INP ≤200 milliseconds, CLS ≤0.1. Also measure video upload completion/failure, playback startup/rebuffering, and dropped frames on representative devices/networks. Until field data exists, report these as targets, never as achieved results.
- **Reason:** “Smooth” needs objective checks for page load, response to interaction, and visual stability, plus media-specific evidence.
- **Reference:** [Google Web Vitals](https://web.dev/articles/vitals).
- **Affected documents:** `PRODUCT_REQUIREMENTS.md`, `UX_UI_SPEC.md`, `ROADMAP.md`, and `DECISIONS.md`.

### D-024 — Persist authorized post search and user reports

- **Status:** Implemented in source; migration 0008 is applied locally. API/database readiness passed before the latest API restart but has not been reconfirmed. End-to-end authorization and realistic-volume query plans still need review.
- **Decision:** Search published text posts on the server with PostgreSQL's `simple` full-text configuration, a partial GIN index, and newest-first timestamp/ID cursor pagination. Apply active-account, profile-visibility, and either-direction block rules. Persist one report per reporter/post with a fixed reason set, optional 500-character details, receipt status, and a uniqueness constraint so retries do not create duplicate records. Keep report data outside feed ranking.
- **Reason:** Search results must include content beyond the currently loaded page without exposing private or blocked posts. Reporting needs a durable submission path rather than a client-only confirmation.
- **Limits:** The text search is token based and not semantic; relevance tuning, accent-insensitive matching, realistic-volume query plans, and rate limiting remain. The current database has zero published posts, so its planner did not select the GIN index and cannot establish index behavior or latency at scale. There is no staff review queue, report lookup, enforcement, response target, account-report flow, or appeal process. Until reviewers and retention are defined, do not treat local report storage as an operated moderation service.
- **Affected documents:** `PRODUCT_REQUIREMENTS.md`, `ARCHITECTURE.md`, `DATA_MODEL.md`, `SECURITY_PRIVACY.md`, `UX_UI_SPEC.md`, `ROADMAP.md`, and `DECISIONS.md`.

### D-025 — Add a synthetic ranking scenario runner before calibration

- **Status:** Implemented as a local evaluation command; no representative user judgment set exists.
- **Decision:** Provide a repeatable `npm run evaluate:recommendation --prefix apps/api` command that evaluates the current ranker on small, labeled fixtures for like/save feature updates and idempotency, learning pause, interest/adjacent exploration, cold start, visibility and safety filtering, suppression when fixtures provide a shared duplicate-group ID, soft negative feedback, and diversity caps. The product does not yet detect similar content or provide these group IDs. Use precision@k, recall@k, nDCG@k, and coverage metrics, with explicit assertions for expected ordering and exclusion behavior. Keep fixture labels synthetic and do not use the results to tune or claim user-level quality.
- **Reason:** Check that important deterministic mechanics—including explicit/learned matching, adjacency, cold start, and blocked-account exclusion—remain visible as the algorithm evolves.
- **Limits:** These fixtures do not approximate production distributions or provide unbiased relevance evidence. Representative privacy-reviewed judgments, ranking/query-plan latency, safety evaluation, and rollback comparisons remain required before calibration.
- **Affected documents:** `RECOMMENDATION_SYSTEM.md`, `ROADMAP.md`, and `DECISIONS.md`.

### D-026 — Make account mute a reversible feed exclusion

- **Status:** Implemented in source; migration 0009 is applied locally. Authenticated end-to-end behavior still needs verification.
- **Decision:** Store mute as a directed `(muter_id, muted_id)` relationship. Exclude muted creators server-side from both For You candidate eligibility and Following results. Expose mute/unmute on a profile and from a post menu, plus a private list for restoring accounts. Mute does not delete a follow, hide profile/search access, block direct messages, change learned preference features, or appear as a content label.
- **Reason:** The existing product contract promises a mute control, while the ranker previously accepted muted IDs but the database/API always supplied an empty list. A distinct relationship keeps user choice explicit and separate from relevance signals and blocks.
- **Migration:** Additive migration `0009_account_mutes.sql` creates the relationship table and reverse lookup index. It does not rewrite existing relationships. Rollback may revert the API/client while leaving the mute table in place; dropping mute records requires an explicit retention/deletion decision.
- **Limits:** This only mutes feed posts. It does not affect direct messages, comments on other posts, notifications, profile discovery, or search. Do not describe it as a block. Confirm the migration is applied and review the signed-in flow, both feed modes, self-mute rejection, and unmute behavior before claiming it works end-to-end.
- **Affected documents:** `PRODUCT_REQUIREMENTS.md`, `ARCHITECTURE.md`, `DATA_MODEL.md`, `RECOMMENDATION_SYSTEM.md`, `SECURITY_PRIVACY.md`, `UX_UI_SPEC.md`, `ROADMAP.md`, and `PROJECT_ASSESSMENT.md`.

### D-027 — Rank text and eligible short videos through one For You pipeline

- **Status:** Implemented in source; authenticated feed behavior and playback still need end-to-end verification.
- **Decision:** Extend the existing bounded retrieval and deterministic ranker to include `short_video` content only when the content is public, published, undeleted, has an active taxonomy label, and its media asset state is `ready`. Return the media MIME type as rendering metadata and play through the existing authorization-checked video endpoint. Text and video captions share the current sparse, versioned label features; like/save actions on either format update those label preferences through the existing transaction path. Internal labels and score details remain server-only.
- **Safety boundary:** This does not change the upload state machine or approve any upload. Current uploaded videos remain private and `pending_review`, with content in `processing`; no user-uploaded video becomes For You eligible until a separate media processing and moderation path moves it to public/published/ready.
- **Limits:** Raw frame vision, speech transcription, embeddings, rendered impressions, exact watch duration, Kafka/Flink, and learned ranking remain out of the MVP. Coarse video active-view/skip events are specified separately in D-028. No behavior signal should be inferred from a video playback range request, because browsers issue multiple range requests for one playback.
- **Verification:** Typecheck/build and authenticated SQL/playback interaction review are still required. The local database currently has no public-ready video sample, so candidate retrieval cannot be confirmed with a real public video.
- **Affected documents:** `PRODUCT_REQUIREMENTS.md`, `DATA_MODEL.md`, `RECOMMENDATION_SYSTEM.md`, `SECURITY_PRIVACY.md`, `ROADMAP.md`, and `DECISIONS.md`.

### D-028 — Use bounded foreground video signals for MVP preference updates

- **Status:** Implemented in source; authenticated event behavior remains unverified.
- **Decision:** Count playback time only while a signed-in viewer is on a public, published, ready video, at least 50% of its player is visible, playback is active, and the browser tab is foregrounded. Send one `active_view` event after 3,000 ms of accumulated eligible playback. If the player leaves the visible area after at least 800 ms and before 3,000 ms, send one weak `skip` event. Pause, buffering, and hidden-tab time do not count. Short videos completed before three seconds can produce `active_view` after 75% of their duration.
- **Storage and update:** Persist only user/content/event IDs, the coarse signal kind, and timestamps for idempotency; expire rows after 30 days and delete them when personalization is reset. Do not store raw playback duration, position, impression history, or per-frame activity. Update bounded, decaying label features synchronously in the same transaction. Skip ingestion while learning is paused.
- **Reason:** This provides a small, real-time behavioral signal from the product's core video flow without a separate stream-processing stack. A video signal is weak evidence of content interest, never proof of user identity or intent.
- **Limits:** The thresholds and weights are initial hypotheses, not calibrated values. Current uploads remain private and pending review, so no current user upload reaches the signal path. The signal endpoint rechecks public/readiness/access state and must not treat range requests, pauses, buffering, or missing measurement as a skip.
- **Verification:** Migrations 0010–0011 are applied, and API/web typechecks and builds pass. Behavior still needs checking against an authorized ready-video record; the local data has no public-ready video, and live HTTP/browser verification remains outstanding. Expired rows currently clean up opportunistically on a later signal write by that user; scheduled cleanup must be added before public beta.
- **Affected documents:** `DATA_MODEL.md`, `RECOMMENDATION_SYSTEM.md`, `SECURITY_PRIVACY.md`, `ROADMAP.md`, and `DECISIONS.md`.

### D-029 — Suppress recently played short videos from For You

- **Status:** Implemented in source; database behavior remains unverified with public-ready videos.
- **Decision:** Exclude a short video from For You when the viewer has a qualified `active_view` event newer than the repeat-suppression cutoff. Default the window to 24 hours and configure it through `RECOMMENDATION_VIDEO_REPEAT_SUPPRESSION_MS` from 0 through 30 days. Apply the cutoff at candidate eligibility using the same as-of snapshot as pagination. Do not hard-suppress a video after a fast skip; its weak negative feature can lower its rank and it may return later.
- **Reason:** Prevent immediate repetition of a video that the viewer actually played while preserving the chance to revisit items that were only measured as a fast pass. Exact PostgreSQL exclusion is sufficient at MVP scale; do not add Bloom-filter infrastructure without a measured need.
- **Limits:** This does not detect re-uploads, near-duplicates, or items rendered without qualifying playback. The default 24-hour window is an uncalibrated product hypothesis; zero disables the filter. Reset removes the signal rows and restores eligibility. Pause stops new signals but existing active-view rows continue to filter until they age out.
- **Verification:** Migration 0011 adds the compound viewer/video/signal lookup index; API typecheck/build pass. Query behavior requires database-backed review with authorized video records; the local database has no public-ready video.
- **Affected documents:** `RECOMMENDATION_SYSTEM.md`, `DATA_MODEL.md`, `SECURITY_PRIVACY.md`, `ROADMAP.md`, and `DECISIONS.md`.

### D-030 — Bound repeated video signals from one viewer

- **Status:** Implemented in source; PostgreSQL behavior still needs review with eligible video data.
- **Decision:** Accept at most one `active_view` and one `skip` signal per viewer/content pair in a rolling 24-hour window. Take a transaction-scoped PostgreSQL advisory lock for the viewer/content/signal-kind key before checking the existing event and inserting a new event. Preserve event-ID idempotency and the existing 30-day event expiry.
- **Reason:** The browser supplies the playback qualification and can be manipulated; the API cannot prove that a reported three-second view happened. A per-signal cooldown prevents repeated fresh event IDs from accumulating unbounded preference weight for one video, while retaining a coarse useful signal for the MVP.
- **Limits:** This is a per-content influence cap, not general API rate limiting, bot detection, or proof of playback. A legitimate repeated view of the same kind inside 24 hours is not counted again. The existing lookup index supports the check; no schema migration is needed.
- **Verification:** API typecheck/build pass. The lock/query path has not been exercised against PostgreSQL concurrency or an authorized ready video; the local database has no public-ready video for authenticated end-to-end review.
- **Affected documents:** `RECOMMENDATION_SYSTEM.md`, `DATA_MODEL.md`, `SECURITY_PRIVACY.md`, `PRODUCT_REQUIREMENTS.md`, `ROADMAP.md`, and `DECISIONS.md`.

### D-031 — Clear account-scoped client state on session changes

- **Status:** Implemented in source; browser behavior remains unverified.
- **Decision:** Clear the previous account's feeds, search results, profiles, conversations, video preview/recording, report details, and unsent drafts on sign-out or when a different account is activated. Invalidate pending request revisions so responses from the previous account cannot repopulate the view.
- **Reason:** A shared browser session must not display private or personalized state from the previous account while a new session is loading or after a request fails.
- **Limits:** This is client memory cleanup and race protection; every server operation still requires independent authorization. It does not delete content persisted by the previous account.
- **Verification:** Web typecheck/build pass. Browser account-switch and delayed-response behavior remain unverified because the local HTTP path is unavailable in the current task environment.
- **Affected documents:** `PRODUCT_REQUIREMENTS.md`, `SECURITY_PRIVACY.md`, `UX_UI_SPEC.md`, `ROADMAP.md`, and `DECISIONS.md`.

### D-032 — Develop the interface directly in Ionic code

- **Status:** Accepted; first visual refinement implemented and reviewed in the running local browser.
- **Decision:** Treat the Ionic + Angular implementation and `UX_UI_SPEC.md` as the design source of truth. Do not require Figma or Canva for UI implementation or delivery. Use X's readable text timeline and TikTok's vertical single-item video viewer as interaction references, while preserving Ionic's own brand and behavior. Keep internal content labels and ranking explanations out of the interface.
- **Reason:** The owner wants a polished, usable, original product interface developed and iterated in the application itself. Browser inspection showed specific gaps in hierarchy, icon rendering, typography, whitespace use, and the guest video/account surfaces.
- **Verification:** Web typecheck and production build pass. The guest Home, Video, Messages, Profile, and account modal were reviewed in Chrome at a narrow desktop window; no authenticated UI journey or physical-device validation is claimed. The Angular component CSS is 29.68 kB: above the 25 kB warning threshold but below the 30 kB build-error threshold.
- **Affected documents:** `UX_UI_SPEC.md`, `ROADMAP.md`, and `PROJECT_ASSESSMENT.md`.

### D-033 — Replace the web client with Flutter while retaining the API

- **Status:** Superseded by D-034.
- **Decision:** The initial migration proposal moved only the user-facing app to Flutter and preserved the existing `/api/v1` backend.
- **Reason:** The project owner requested a direct-code Flutter implementation across the product. Preserving the API and ranker keeps this client migration bounded and protects the MVP's account, content, messaging, media privacy, and recommendation behavior.
- **Limits:** This is a client framework migration, not a backend rewrite or a claim of native iOS/Android readiness. Camera/media plugin behavior, PWA installation, responsive layout, accessibility, account-backed flows, and build output remain to be verified with a Flutter SDK and browser/device review. Do not delete the old client before the replacement passes the migration gates.
- **Affected documents:** `PRODUCT_REQUIREMENTS.md`, `ARCHITECTURE.md`, `UX_UI_SPEC.md`, `ROADMAP.md`, `PROJECT_ASSESSMENT.md`, and `README.md`.

### D-034 — Port the full application to Flutter and Dart

- **Status:** Accepted; implementation in progress. Flutter Web and Android debug APK builds pass, Android/iOS native scaffolds exist, and all current API families have Dart source. A narrow Android sign-in/session/feed/text-post flow is verified against Dart and local PostgreSQL; other route parity and native release readiness remain open.
- **Decision:** Use Flutter for the user-facing app and Dart for the server-side modular monolith. Use Shelf and shelf_router for the HTTP boundary and PostgreSQL as the unchanged system of record. Preserve `/api/v1`, migrations 0001–0011, cookie/session behavior, authorization, error shapes, and recommendation semantics during migration. Keep NestJS and Angular available as references and rollback paths until every API and signed-in client journey is verified against Dart; then remove the old TypeScript applications in a final cleanup phase.
- **Reason:** The owner explicitly requested that the whole project move to Flutter after clarifying that a Flutter-only client port did not satisfy the request. Flutter is the client framework; the server implementation will use Dart rather than putting privileged logic in the client.
- **Migration constraints:** Port behavior before deleting the reference implementation. Keep password-hash compatibility for existing accounts, maintain the shared PostgreSQL migrations, and do not weaken server-side access checks, privacy, ranking controls, or media privacy. Select dependencies based on current official Dart/package documentation; validate parity and performance before switching the local deployment or claiming completion.
- **Limits:** A generated mobile scaffold is not a native release. Android must build, install, and pass account/media journeys; iOS needs macOS/Xcode. No security or privacy invariant is relaxed. Current recommendation quality remains a deterministic MVP baseline, not a production-scale learned ranker.
- **Affected documents:** `AGENTS.md`, `ARCHITECTURE.md`, `PRODUCT_REQUIREMENTS.md`, `DATA_MODEL.md`, `SECURITY_PRIVACY.md`, `RECOMMENDATION_SYSTEM.md`, `ROADMAP.md`, `PROJECT_ASSESSMENT.md`, and `README.md`.

### D-035 — Prioritize installable native Android, then iOS

- **Status:** Accepted by the owner on 2026-10-26; Android/iOS project scaffolds generated; Android implementation is the active next platform milestone.
- **Decision:** The production client target is an installable Flutter app on Android and iOS. Implement and verify Android first, then validate the shared Flutter client on iOS using macOS/Xcode. Keep the responsive web PWA available for desktop/browser use and development, but do not count it as mobile app delivery.
- **Reason:** The owner chose Flutter specifically so Ionic can be installed as a real app on both Android and iOS, and clarified that Android should receive focus first.
- **Implementation:** Android application ID is currently `app.ionic.mobile`. Debug Android permits local cleartext API traffic only; release builds must supply the production HTTPS API base URL and a separately configured signing key. Camera/microphone permissions are declared, with runtime permission prompts handled by the Flutter plugins. The Dart server must bind to a reachable interface for emulator/device use without weakening its authorization or data-protection rules.
- **Verification gates:** Build and install a debug APK, verify the signed-in text/feed/profile/message flows plus camera capture/upload/playback on an emulator and physical Android device, then validate release signing and production HTTPS. iOS compilation, signing, permissions, and media behavior require macOS/Xcode. Native readiness is not inferred from Web build success or generated scaffold files.
- **Affected documents:** `AGENTS.md`, `PRODUCT_REQUIREMENTS.md`, `ARCHITECTURE.md`, `ROADMAP.md`, `PROJECT_ASSESSMENT.md`, `README.md`, and `apps/client/README.md`.

### D-036 — Persist native API sessions in OS-protected storage

- **Status:** Implemented on 2026-10-26; Flutter analysis and Android debug APK build pass. On a Pixel 6 API 35 emulator, sign-in stored the session in Android secure storage, `/auth/me` and For You returned success after an app restart, and a text post was persisted and read back through the Dart API.
- **Decision:** Keep the existing opaque `ionic_session` cookie contract. On native clients, attach the token to API requests and persist or remove it from Android Keystore-backed secure storage / iOS Keychain based on server `Set-Cookie` responses. Keep the browser's same-origin credential flow unchanged. Disable Android app backup and require HTTPS for release API traffic.
- **Reason:** Android's stateless HTTP client otherwise loses the authenticated session after registration or login, making protected feed, profile, messaging, and publishing flows unusable after the first request.
- **Limits:** The stored token remains valid only while its server-side session exists and expires after the API's configured 30-day lifetime; a protected-route 401 clears the stale native token. This does not add token refresh, device management, or app-level biometric locking. Android auth and one text-post journey now work against the local Dart API; other protected modules, physical devices, release signing, and production TLS remain separate verification gates.
- **Build note:** The Windows Kotlin incremental compiler failed while closing plugin caches. Disabling Kotlin incremental compilation in the Android Gradle properties allowed the APK build to complete; clean Android builds may take longer.
- **Affected documents:** `ARCHITECTURE.md`, `SECURITY_PRIVACY.md`, `ROADMAP.md`, and `PROJECT_ASSESSMENT.md`.

### D-037 — Make local and production PostgreSQL TLS modes explicit

- **Status:** Implemented on 2026-10-26; local Dart migrations, readiness, Android sign-in, and text-post persistence were verified against the Compose database using `sslmode=disable` on loopback.
- **Decision:** The local development PostgreSQL URL explicitly sets `sslmode=disable` because the Compose server is bound to `127.0.0.1` and has no TLS. Shared and production database URLs must use verified TLS, such as `sslmode=verify-full` with a trusted provider CA.
- **Reason:** The Dart `postgres` client defaults to requiring SSL. Making the local exception explicit keeps the development service usable while preventing that exception from becoming a production default. The package documents `disable`, `require`, and verified SSL modes in its [connection URL options](https://pub.dev/documentation/postgres/latest/).
- **Limits:** `sslmode=disable` is only for the host-loopback development database. It must not be used across a LAN, shared environment, or production boundary.
- **Affected documents:** `apps/server/.env.example`, `apps/server/README.md`, `apps/client/README.md`, `ARCHITECTURE.md`, `SECURITY_PRIVACY.md`, `ROADMAP.md`, and `PROJECT_ASSESSMENT.md`.

### D-038 — Launch text-first with attachments and defer video

- **Status:** Text-first and video deferral were accepted on 2026-10-26. On 2026-10-27, the owner added image and voice attachments to posts/replies. Flutter navigation and recommendation candidate SQL target text posts; runtime verification remains open.
- **Decision:** The first public product focuses on reading/publishing text with optional image and short voice attachments, account/profile/social flows, messaging, recommendations, and working account/privacy/feed settings. Keep short video out of launch navigation, composer, feed retrieval, and release gates. Preserve video source for a later phase after Ionic has an audience and is ready for processing, moderation, delivery, and cost controls. Request microphone access only when a user starts recording; do not request camera access for the first attachment slice.
- **Reason:** The owner wants a usable product as soon as possible and explicitly chose posts as the first core experience, with video later.
- **Limits:** Text-first scope does not reduce the need for account security, server-side authorization, media access checks/moderation, or performance evidence. Do not surface dormant video or request microphone/camera permission before a user selects the related action.
- **Affected documents:** `PRODUCT_REQUIREMENTS.md`, `DATA_MODEL.md`, `SECURITY_PRIVACY.md`, `UX_UI_SPEC.md`, `ROADMAP.md`, `PROJECT_ASSESSMENT.md`, `ARCHITECTURE.md`, `README.md`, and `apps/client/README.md`.

### D-039 — Allow read-only access to public text posts

- **Status:** Product direction inferred from the owner's requirement that reading posts is the first launch capability; a bounded Dart public endpoint and Flutter client path are in source. Authorization, abuse-rate protection, pagination, and user-facing error behavior remain verification/release gates.
- **Decision:** Signed-out visitors may read only public, published posts and their authorized image/voice attachments. They cannot like, save, reply, follow, report, message, or personalize a feed until they sign in. Private profiles/content, blocked pairs, removed content, staged media, and any future restricted audience remain inaccessible. Apply bounded pagination and public-read/media rate protection before a broad release.
- **Reason:** A reader should reach the core post-reading experience immediately, while account-specific actions and private data remain protected.
- **Limits:** The client must not use synthetic demo posts as production content or claim a read-only public API is deployed until its authorization and abuse controls are verified. Revisit this policy if the launch audience or privacy model changes.
- **Affected documents:** `PRODUCT_REQUIREMENTS.md`, `SECURITY_PRIVACY.md`, `DATA_MODEL.md`, `ARCHITECTURE.md`, `UX_UI_SPEC.md`, `ROADMAP.md`, and `PROJECT_ASSESSMENT.md`.

### D-040 — Ship only implemented settings controls

- **Status:** Implemented in Flutter/Dart and NestJS source; analyzer/build and database-backed behavior are pending verification.
- **Decision:** The first Settings screen contains account profile editing, persisted personalization pause/reset, server-managed muted/blocked accounts, and current-device sign-out. Do not show controls for recovery email, notification delivery, private-account requests, multi-device session management, or account export/deletion until their server behavior and required providers exist.
- **Reason:** A settings page must provide concrete, persisted behavior rather than decorative toggles, and the release timeline should prioritize functions already required by the social core.
- **Limits:** This is a coherent MVP settings set, not feature parity with larger social platforms. Password change and account lifecycle controls remain release requirements to implement before production.
- **Affected documents:** `PRODUCT_REQUIREMENTS.md`, `UX_UI_SPEC.md`, `ARCHITECTURE.md`, `SECURITY_PRIVACY.md`, `ROADMAP.md`, and `PROJECT_ASSESSMENT.md`.

### D-041 — Add photos and short voice notes to posts and replies

- **Status:** Accepted by the owner on 2026-10-27. A first Flutter/Dart implementation covers staged uploads, server-side validation, transactional post/reply attachment, access-checked reads, lazy image fetch, and explicit voice playback. Migration 0012 is applied locally, and Web/APK builds plus readiness pass. End-to-end media behavior on a signed-in client, device recording/playback, rate limiting, and deletion lifecycle remain unverified or incomplete.
- **Decision:** Posts and root replies may include image attachments or one short voice note. Keep uploads private and unattached until the owning post/reply commits; authorize reads through the visible parent; strip location metadata; validate bytes/type/dimensions/duration on the server; use lazy image/audio loading and explicit audio playback. The first media slice does not perform face recognition, voice identification, emotion inference, transcription, or use media bytes as recommendation signals. Video remains deferred.
- **Reason:** Add expressive media to the core publishing/commenting flow without pulling video capture, streaming, and transcoding into the first usable product.
- **Limits:** Four images per item and a 60-second voice note are provisional implementation ceilings, not validated product limits. The current local backend accepts JPEG up to 8 MiB and canonical PCM WAV up to 2 MiB; keep these limits configurable and confirm through actual device/network and storage/cost evidence. Production requires private object storage, rate limits, scheduled cleanup, deletion propagation, and a defined moderation path; local filesystem storage is for development only.
- **Affected documents:** `PRODUCT_REQUIREMENTS.md`, `DATA_MODEL.md`, `SECURITY_PRIVACY.md`, `ARCHITECTURE.md`, `RECOMMENDATION_SYSTEM.md`, `UX_UI_SPEC.md`, `ROADMAP.md`, and `PROJECT_ASSESSMENT.md`.

### D-042 — Default to charcoal dark appearance

- **Status:** Implemented in Flutter theme/settings source; Android/Web persistence and visual review remain unverified.
- **Decision:** First launch uses a charcoal dark theme. Let the user switch to light mode in Settings and persist that choice locally on the device. Keep separate readable color tokens for both modes and never rely on pure black as the main canvas.
- **Reason:** The owner explicitly prefers a subdued charcoal dark default with a user-controlled light option.
- **Limits:** This preference is device-local, not synced to the account. Contrast, text scaling, screenshots, and every current screen still require visual/accessibility review in both modes.
- **Affected documents:** `UX_UI_SPEC.md`, `PRODUCT_REQUIREMENTS.md`, `ARCHITECTURE.md`, `ROADMAP.md`, and `PROJECT_ASSESSMENT.md`.

### D-043 — Point Flutter local web proxy at the target Dart API

- **Status:** Implemented in the development launcher on 2026-10-27; the Dart server returned ready and the proxy served Flutter Web locally during review.
- **Decision:** The Flutter Web proxy defaults to the target Dart server on port 3001 so the current media endpoints are reachable. Set `IONIC_API_PORT=3000` to use the NestJS behavioral reference during parity checks. This affects only the local launcher; it does not establish complete API parity or change release API configuration.
- **Reason:** The photo/voice routes exist only in Dart. Leaving the proxy on NestJS would make the new composer appear available while all upload calls fail.
- **Limits:** Other Dart routes still require parity and database-backed verification. Keep the override explicit and keep both server implementations until parity is demonstrated.
- **Affected documents:** `ARCHITECTURE.md`, `ROADMAP.md`, `PROJECT_ASSESSMENT.md`, `apps/client/README.md`, and `apps/client/tool/run_dev.mjs`.

### D-044 — Use one unlabeled personalized feed on text Home

- **Status:** Accepted by the owner on 2026-10-27; Flutter Home updated. Dart analysis, Flutter Web release build, and Android debug build pass. A fresh local preview is running on port 4202; rendered UI review is still pending.
- **Decision:** Remove the “Bảng tin” Home heading and the visible **Dành cho bạn / Đang theo dõi** switch from the text-first launch. Signed-in Home continues to call personalized retrieval; signed-out Home continues to read public posts. Keep the chronological Following API capability, but reserve a visible mode selector for the later video-discovery experience.
- **Reason:** The owner wants the mode selector only with video discovery and wants the text Home to open directly into its content/composer flow.
- **Limits:** This is a presentation change, not a ranking change; do not remove follow relationships or silently change feed eligibility. Pause/reset remains available in Settings. Video remains deferred from launch navigation.
- **Affected documents:** `PRODUCT_REQUIREMENTS.md`, `UX_UI_SPEC.md`, `ROADMAP.md`, and `PROJECT_ASSESSMENT.md`.

### D-045 — Neutralize dark-mode actions and remove empty-state decoration

- **Status:** Accepted by the owner on 2026-10-27; Flutter theme and shared empty state updated. Dart analysis, Flutter Web release build, and Android debug build pass. A fresh local preview is running on port 4202; rendered UI review is still pending.
- **Decision:** Use charcoal-gray filled actions with white text and neutral gray selected/navigation emphasis in dark mode. Keep the existing blue brand action palette in light mode. Remove the decorative sparkle tile from shared empty cards.
- **Reason:** The owner found blue action controls and the empty-state tile visually weak in the charcoal interface and requested a restrained dark palette.
- **Limits:** Keep the Ionic logo colors. Preserve error colors and actionable status contrast; do not turn this into a pure-black theme.
- **Affected documents:** `UX_UI_SPEC.md`, `PROJECT_ASSESSMENT.md`, and `ROADMAP.md`.

## Open questions to resolve by feature phase or public launch

Resolve these when their feature phase needs them. They should not block the local recommendation prototype; settle all applicable items before handling production data or opening a public beta.

1. Who is the first-release audience, and which countries/regions are in scope?
2. What age, account visibility, and account recovery policies apply?
3. Which item-level feedback, follows, saves, and other interactions should update internal preferences, and which should remain neutral?
4. Should public profile text contribute to labeling, and what controls should users have over that use?
5. What video duration/file-size limits, upload volume, hosting region, and delivery budget are acceptable? Which provider and runtime meet the region, pricing, media-job, and privacy requirements after a small measured comparison?
6. What retention periods apply to messages, behavioral events, preference features, reports, and backups?
7. Who operates moderation, what response expectations apply, and what appeal policy is required before a public beta?
8. What user and traffic envelope should drive capacity planning and service-level objectives?
9. Is group messaging required, or is one-to-one sufficient for the first release?
10. Should monetization or sponsored content be considered? If so, define labeling and ranking separation before implementation.

Record answers with date, owner, rationale, and affected documents.
