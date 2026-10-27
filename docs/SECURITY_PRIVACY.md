# Security, Privacy, and Trust

## 1. Privacy principles

- Purpose limitation: collect only data needed for a documented product, safety, or reliability purpose.
- Data minimization: no raw keystroke capture, message-body analytics, precise location collection, or covert device fingerprinting.
- User control: document and expose personalization controls, reset, hide/mute/block, account deletion, and notification preferences.
- Transparency: document the kinds of permitted signals and expose clear controls; never display internal labels or per-item recommendation rationales in the feed.
- Retention: assign a retention schedule before launch; expiration and deletion apply to derived features, caches, and analytical stores as well as primary records.
- Least privilege: restrict raw event, message, report, and moderation access by role and audit sensitive access.

Consent and legal basis, age requirements, data residency, and jurisdiction-specific obligations must be determined before launch; this document is not legal advice.

## 1.1 Recommendation data boundary

- Label every post and video that is eligible to enter a recommendation feed. Keep taxonomy labels separate from visibility, moderation, and account-security state.
- Build a user's internal preference profile from generic item feedback and eligible feed interactions, with tune, pause, and reset controls that do not expose the taxonomy.
- Do not classify credentials, private-message bodies, precise location, raw keystrokes, or sensitive personal traits for feed ranking. Public profile fields are not ranking inputs unless the user can understand and control that use.
- Keep only the derived labels and bounded evidence needed for ranking; do not retain a duplicate copy of private or raw source material in the recommendation profile.
- The current text labeler uses a small neutral keyword vocabulary. It does not inspect images, faces, voice, or messages. Internal labels are never rendered as chips, stickers, or public profile metadata.
- The authenticated MVP updates preference features from like/save transitions and qualified foreground video active-view/fast-skip outcomes; undo actions have negative weights and replies default to zero. Video signal events require a published, public, ready video visible to the viewer, accept each signal kind at most once per viewer/video pair in a rolling 24-hour window, have a 30-day expiry, and do not store exact duration or playback position. The client reports playback qualification; the server checks eligibility and caps repeat influence, but cannot independently prove playback. Expired rows are deleted opportunistically for active users; a scheduled global cleanup is required before public beta. A pause stops future learned updates and event storage while leaving prior learned features and explicit more/less choices in effect. Reset deletes learned features, more/less controls, and retained video-signal rows; explicit post hides remain.

## 2. Security controls

- Use established authentication/session protections; protect recovery and account-change flows against takeover.
- On logout or a change in the authenticated account, clear account-scoped feed, search, profile, conversation, video-preview, report, and draft state from the client. Ignore late responses from the previous account; server-side authorization remains the access-control boundary.
- The first controlled API implementation uses handle/password credentials, salted scrypt hashes, opaque random session cookies marked HttpOnly and SameSite=Strict, and stores only a SHA-256 digest of each session token. Production cookies also require Secure. Session lifetime is 30 days; logout revokes the server-side session.
- Native Flutter clients retain only the opaque `ionic_session` token in OS-protected storage (Android Keystore-backed storage and iOS Keychain); they send it as the same cookie on API requests and delete it when the server expires the session or confirms logout. Do not place session tokens in ordinary preferences, logs, or client-visible UI. Android app backup is disabled so encrypted session data cannot be restored without its device key. Native release traffic must use HTTPS.
- Browser writes that include an `Origin` header are restricted to the configured web origins as an additional CSRF boundary.
- The development Compose PostgreSQL service is bound to host loopback and does not enable TLS; its `DATABASE_URL` explicitly sets `sslmode=disable`. Never reuse that setting for shared or production databases. Production PostgreSQL connections must verify server TLS (for example, `sslmode=verify-full` with the provider CA).
- Registration is disabled by default when `NODE_ENV=production`; enable it only for a deliberately controlled release after its account policy is set.
- This initial account flow has no recovery, email verification, age gate, or distributed rate limiter. Do not expose registration publicly until these policies and protections are implemented and reviewed.
- Enforce authorization for every content, profile, conversation, media, and moderation operation server-side.
- Profile and post search and profile/post reads require a valid session. Profile search returns public profiles using a bounded handle/display-name prefix query. Post search returns a bounded, newest-first page of published text matches using the built-in `simple` full-text configuration and a GIN index. Both search paths exclude inactive users and either-direction blocks; post search also restricts private profiles to their owner and approved followers. A block hides each account from the other account's profile, search, and feed; creating a block transactionally removes follow edges in both directions. Follow and block writes lock both account rows in stable ID order so a concurrent follow cannot bypass a block. Private-profile follow requests are not implemented; new follows to private profiles are rejected.
- Like, save, reply, and feed-preference writes require a valid session and verify that the content is still published and visible to the viewer; blocks are checked in both directions. Domain unique constraints make repeated like/save requests idempotent. User-generated replies are normalized, length-bounded, encoded by Angular on output, and remain untrusted text.
- Muting requires a valid session and targets an active account other than the viewer. Mute state is private to the acting account. Server-side Following and For You queries exclude muted creators; unmuting restores eligible feed retrieval without changing follow edges. Mute is not a substitute for block and does not restrict profile, search, or messaging access.
- Video learning signals require a valid session and are accepted only for published, public, ready videos that are visible to the viewer after profile, block, mute, hide, and label checks. The browser counts foreground playback only while at least half the player is visible; pause, buffering, and hidden-tab time are excluded. It sends one coarse signal at 3 seconds or when leaving after at least 800 ms but before 3 seconds. The API rechecks eligibility, stores at most one signal of each kind per viewer/video per rolling 24 hours, and expires stored events after 30 days. The client-reported playback qualification is not independently verifiable by the API. This is weak personalization evidence, not a safety or identity signal.
- Content reports require a valid session, an accessible published post, a bounded reason/details payload, and reject self-reports. One report per reporter/content is persisted; duplicate submissions return the existing record. Reports are separate from ranking and preference signals. There is no staff review API or public reporting status lookup yet; restrict database access and logs, and define retention and reviewer roles before operating real user reports.
- Validate and bound request body size, rate, pagination, identifiers, and upload bytes/type; do not trust file extensions or client MIME values.
- Treat attached photos and voice recordings as private staged objects until the owning post/reply transaction commits. The current Dart API accepts JPEG (max 8 MiB, max 8192 per side / 16 MP), decodes and re-encodes to at most 2048 px, and accepts only canonical mono 16 kHz 16-bit PCM WAV (1–60 sec, max 2 MiB). Resolve every image/audio read through the published parent, profile visibility, and bidirectional block rules; never grant access from an opaque object key alone. Staged files are owner-bound and cannot be read. Uploads currently use private local filesystem storage for development only.
- Strip EXIF/GPS metadata from images before storing a public rendition. Do not perform face recognition, voice identification, emotion inference, or transcription for the first attached-media release; image/audio bytes are not recommendation signals. Ask for microphone permission only after an explicit record action, and upload only after the user confirms the voice clip.
- Four-image / one-voice attachment composition is enforced by the transaction service, and unattached staging records older than 24 hours are cleaned opportunistically on later upload requests. Upload/playback rate limits, aggregate per-item byte caps, scheduled cleanup after parent deletion, private cloud object storage, moderation operation, and production deletion verification are not implemented and block public media launch. Keep this boundary visible in release planning.
- Current local video uploads stream to a non-public `.data/media` directory with a 60 MB byte cap and a WebM/MP4 container-signature check. The browser's 60-second cap is a usability check only; the API does not yet verify duration. Upload rows stay `processing` / `pending_review`, and the playback authorization currently grants access only to the owner. This local path is not suitable for public deployment.
- Direct-message rows are visible only to conversation participants. Either-direction blocks deny list, read, and send access. Message text is not copied into ranking or analytics. Retention, operational access, and encryption-at-rest policy still need to be set before real-user launch.
- Use private quarantine storage, malware/content scanning where appropriate, safe transcoding, and controlled delivery.
- For the planned serverless video path, issue narrowly scoped, short-lived upload grants for a single asset/key and expected limits; never give the browser cloud credentials. Keep quarantine, originals, renditions, and temporary segments private by default. Queue messages contain opaque asset identifiers, are authenticated and idempotent, and grant workers least-privilege access to only the required input/output paths.
- Publish a playback manifest only after processing and required safety checks succeed. CDN authorization/cache rules must not make private media public; signed access, when used, must be bounded and revocable through the content authorization path. Ensure deletion, retention expiry, and moderation takedown propagate to originals, renditions, manifests, caches, queued jobs, and temporary objects. Incomplete multipart uploads and failed-job artifacts require bounded cleanup.
- Treat third-party serverless functions, queues, transcoders, object stores, and CDN configuration as security boundaries: encrypt transport/storage, restrict service roles, protect logs from user content and signed URLs, and monitor failed/retried jobs and unexpected egress.
- Protect against XSS, CSRF where applicable, injection, SSRF in media/URL processing, and insecure direct object references.
- Apply rate limits and abuse detection to authentication, interactions, messaging, and reports without blocking reasonable accessibility needs.
- Keep secrets outside source control/client bundles; redact sensitive data from logs and traces.
- Use dependency review, security updates, backups, tested restore, incident response, and audit trails for privileged operations.

## 3. Messaging

- Authorize every conversation read/send against current membership and block state.
- Define encryption-at-rest and transport controls, retention/deletion, notification preview behavior, and abuse review access before launch.
- Do not use message content for public-feed recommendation or general interest inference.
- Clearly document any safety reporting flow that allows user-submitted message evidence to be reviewed.

## 4. Moderation and ranking

- Moderation eligibility and account/content blocks are hard ranking filters.
- Reports initiate a safety process; they are not just negative recommendation feedback.
- Provide creator/user appeal or correction mechanisms appropriate to enforcement severity.
- Evaluate recommendation systems for harmful amplification and disproportionate impact; restrict sensitive inference and targeting.
- Label paid placement clearly and prevent undisclosed promotion if monetization is introduced.

## 5. Operational readiness gates

Before public beta, document and test:

- Threat model and authorization matrix.
- Incident escalation and abuse-response ownership.
- Account recovery, deletion, export/access request, and backup expiry.
- Moderation policies, queue operations, escalation, and appeals.
- Secret rotation, dependency patching, backup/restore, and incident communication.
- Event access, retention, deletion propagation, and recommendation reset verification.
