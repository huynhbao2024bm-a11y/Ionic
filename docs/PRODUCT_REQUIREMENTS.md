# Product Requirements

## 1. Product goal

Launch Ionic as a text-first social app for reading and publishing posts, building profiles and social connections, and messaging privately. Make sign-up optional for reading public posts and required for actions that create or personalize account data. Defer video capture, upload, discovery, and playback until Ionic has an established user base and time to prepare media processing, safety, delivery, and cost controls. The main product differentiator is a recommendation system that learns from permitted post-level signals and keeps the feed useful and controllable.

Use familiar interaction patterns: a readable social timeline, recognizable profiles, and one-to-one chat. These are product references, not requirements to reproduce another service screen for screen.

## 2. Target users and core journeys

### Reader / viewer

1. Open the app directly to Home and start browsing without a mandatory tutorial or interest questionnaire.
2. Optionally create an account when they want to follow, publish, react, save, or use messaging.
3. Browse public text posts in the first release; use clear content controls and move through the feed without gesture-only navigation.
4. Tune, pause, or reset personalization whenever they choose.

### Creator

1. Set up a profile and publish text posts; add media publishing only in a later phase.
2. Set audience visibility and accessibility details. Internal content classification is handled by the product and is never exposed as taxonomy chips or a required creator form.
3. Review post status and meaningful aggregate engagement.
4. Edit or delete their own content.

### Messaging user

1. Start or accept a conversation subject to recipient privacy settings.
2. Send and receive messages, manage conversation state, and block/report abuse.

## 3. Product areas

### Client platform

- The native mobile app is built with Flutter and must be installable on Android and iOS. Deliver and verify Android first; then validate the shared iOS client on macOS/Xcode. Keep the responsive web PWA as a supported browser client, not as a substitute for native app delivery. All clients use the same server API for authorization, persistence, and recommendation ranking.
- Text-first native readiness requires a real platform build and installation, usable account/API connectivity, reading and publishing flows, responsive layouts, and secure session behavior. Camera and video permissions are outside the initial release and must not block it.

### Main navigation and surfaces

- Keep the primary destinations consistent across phone and desktop: **Home**, **Search**, **Create**, **Inbox**, and **Profile**. Settings are reachable from the account menu and profile. Adapt navigation to the available screen width.
- Home is the initial route. The first meaningful content must appear without mandatory onboarding; account setup and interest selection are optional and can be deferred.
- Home reads public, published posts from the API. Never substitute synthetic records when the service is offline; show a retry state instead.
- Home presents one text feed without visible **For You / Following** tabs or a “Bảng tin” heading. Signed-in requests use personalized retrieval; signed-out visitors may read only public, published text posts. Keep the chronological Following capability in the service and reserve visible feed-mode selection for the later video discovery surface. Account actions require sign-in.
- Video is deferred and has no entry in launch navigation or the post composer. Retain its design and server work as a later phase without surfacing upload or playback controls in the text-first release.
- Create opens a text composer that can attach images or a short voice note. Draft recovery, clear audience setting, validation, upload progress, retry, and publish state must be explicit.
- Inbox and Profile remain separate destinations so private conversations and public content do not blend together.

### Home and post interactions

- Post and reply cards show author, time, text, attached images, and optional voice playback alongside the existing actions. Images load lazily from bounded renditions; audio never autoplays.
- Do not render internal taxonomy labels, topic chips, generated hashtags, or item-level recommendation explanations in the feed or public profile.
- Provide accessible **More like this / Less like this** controls in each eligible item's menu without exposing the labels that the ranker uses.
- Keep personalization pause/reset in Settings and report/hide in each item's menu. Do not add a feed-mode switch to text Home; reserve visible mode selection for the later video discovery surface.
- Keep internal taxonomy labels and inferred interests invisible in the interface. Generic “xem thêm/ít tương tự” feedback is the only item-level personalization control.
- Do not make a swipe or autoplay the only way to navigate or control playback.

### Identity and profile

- Sign up, sign in, sign out, account recovery, and session/device management.
- Signing out or switching accounts clears the previous account's search results, conversations, feed state, media preview, and unsent drafts before another account can use the client.
- Profile fields: display name, unique handle, optional biography and avatar, and privacy settings.
- Do not display machine-generated recommendation labels on public profiles. Profile description remains ordinary user-authored text.
- Follow/unfollow; private-account follow requests may be introduced with the privacy model.
- Search and follow public profiles from authenticated account results; inspect public profile text and cursor-paginated posts. A Following feed is chronological and excludes blocked accounts in either direction.
- Block/unblock from a profile. Blocking removes follow edges in both directions and prevents further follow actions while the block is active.
- Account deactivation and deletion workflows must be documented and propagated to derived data.

### Posts and interactions

- Text posts with a documented character limit, visibility, timestamps, and edit/delete behavior.
- Posts and replies support image attachments and a short voice recording. Initial engineering ceilings are provisional: up to four optimized images per item, a maximum 60-second voice note, and server-enforced per-file byte caps. Confirm final values from real-device upload size, network, and moderation measurements before public launch.
- Resize/re-encode images on-device before upload and remove location/camera metadata; the server also normalizes JPEG before storage. The first voice format is bounded mono 16 kHz PCM WAV (1–60 seconds, at most 2 MiB), which is portable but not compressed. Measure payload and device behavior before selecting a smaller codec. Show duration/upload state and do not fetch voice bytes until explicit play.
- Attachment uploads remain private and unattached until the owning post/reply is committed. Serve an attachment only when its owner is authorized to read the parent item; clean up abandoned uploads and all derived objects when the parent is deleted.
- Replies/comments, reactions, saves, and follows.
- For signed-in users, likes, saves, and root replies must persist on the server and reappear with correct counts/state after reload. Signed-out readers cannot create interactions; the UI asks them to sign in.
- Signed-in users can search published text posts and public profiles. Post results are server-authorized, bounded, paginated, and respect private-profile visibility and blocks.
- Server-side authorization for private, deleted, blocked, and otherwise restricted content.
- Pagination uses stable cursors; no feed relies on offset pagination for a growing timeline. For You cursors bind to the ordered result snapshot and are rejected if it changes, so the client can refresh instead of silently duplicating or skipping items.

### Deferred: short-video publishing and viewing

- Upload with size/type/duration validation, processing status, captions, and accessible controls.
- Feed playback must be user-controllable, respect reduced-motion/data-saving preferences, and avoid playing multiple videos audibly at once.
- A video is eligible for recommendation only after processing and required safety checks.
- Provide captions or a path to add them; do not make critical meaning depend on audio alone.
- In MVP/Beta video phases, use a serverless-first, event-driven processing path and private cloud object storage to limit idle compute and keep media unavailable until checks pass. Package approved playback as segmented adaptive-bitrate output behind a CDN; retain originals and derivatives under documented lifecycle/retention rules. Provider, codec, rendition ladder, segment duration, and numeric cost targets remain open until tested against the intended devices, networks, and actual provider pricing.
- Keep upload authorization, file/duration ceilings, retry/concurrency limits, temporary-object cleanup, and storage/encoding/egress visibility in the release design. Do not make recommendation eligibility depend on a client-supplied processing status.

### Feed and discovery

- Home feed combines eligible followed-account content and recommended text posts.
- Discovery feed can emphasize exploration but obeys safety, blocks, mutes, and user controls.
- Muting an account removes its posts from both For You and Following until unmuted; it does not silently unfollow, block profile access, or disable messaging. Users can inspect and undo muted accounts from their profile controls.
- Every candidate passes authorization, moderation eligibility, deduplication, and diversity rules before final ranking.
- Keep recommendation reason codes internal to ranking diagnostics. The client feed does not display a per-item rationale; user control is provided through generic feedback, pause, and reset actions.
- Keep the Following data mode chronological for the later discovery surface. Home uses personalized text retrieval internally without a visible feed-mode label; provide pause/reset controls instead of hidden ranking overrides.

### Direct messages

- One-to-one conversations for the initial product baseline; group messaging is a later scope decision.
- Inbox shows conversation order, unread state, and any message requests allowed by the recipient's settings; opening a conversation shows delivery/read state and the recipient's privacy controls.
- The initial message composer supports text and clear send/failure feedback. Media attachments can be added only after upload privacy and retention are designed.
- Message delivery/read state and notification preferences are separate from recommendation telemetry.
- Blocked users cannot continue to contact the blocker through new message requests.
- Message content is not used to infer interests or rank public content.

### Safety and trust

- Report content/accounts, block, mute, hide an item, and manage blocked accounts. Do not expose internal topic labels as a hide menu.
- Reports on accessible published posts are recorded privately with a reason and optional bounded details. A staffed review, response-time, account-report, enforcement, and appeal workflow remains a launch requirement.
- Moderation status and appeal/escalation workflow must be defined before public launch.
- Rate limits and abuse controls apply to signup, publishing, comments, messaging, and reporting.

### Settings and account controls

Settings are a real product area, not a list of decorative switches. Every visible option must load its current value, persist changes, explain scope, handle errors, and affect the corresponding behavior. Organize settings into:

- **Account and security:** profile details, password change, recovery, active sessions, sign out, sign out all devices, account export, and account deletion. Email recovery and verification require a configured delivery provider and must not pretend a code was sent when delivery is unavailable.
- **Privacy and audience:** public/private profile, follow requests, who can message, discoverability, blocked and muted accounts, and hidden posts. Server authorization must enforce every choice.
- **Feed and recommendations:** pause/resume learning, reset learned preferences, and review the meaning of permitted signals without exposing internal labels or per-post rationales.
- **Notifications:** in-app, push, and email categories only when the corresponding delivery channel exists; a saved preference must actually suppress or allow that notification.
- **Appearance and accessibility:** theme, text scaling, reduced motion, language, and data-saving behavior; local display preferences may be device-specific and should be labeled as such.
- **Content and activity:** drafts, own-post edit/delete, saved posts, and account/content controls.

Do not mirror every setting found in larger platforms. Ship a smaller coherent catalog whose controls have implemented behavior, then add categories when the underlying feature is operational.

## 4. Delivery priority

Target the earliest safe text-first release: open Home and read real public posts without a tutorial or forced registration; create and secure an account; publish text with optional images or voice, and read/reply to attached posts; view profiles and follow accounts; send persistent one-to-one messages; use one personalized Home feed with implemented account/privacy/feed/display settings. Keep chronological Following as a service capability and expose feed-mode selection in the later video discovery surface. Short-video creation, discovery, and playback remain deferred until there is a user base and the team is ready to prepare processing, moderation, delivery, and cost controls. The deterministic recommendation system remains the central differentiator and must be measured before tuning. Account recovery, operational moderation, deployment/rollback, data retention, and representative performance remain release gates. Do not call a build production-ready until the exit criteria are met.

## 5. Recommendation behavior

The recommendation system is a core product capability. The text-first MVP assigns internal versioned topic/context/language labels to published text, maintains bounded preference features from permitted post actions and generic feedback, and ranks eligible text candidates. Replies and attached media content do not add preference weight by default. Freshness, relevance tiers, explicit controls, and creator/topic diversity caps are in source; full impression history, near-duplicate detection, broad semantic coverage, and ML retrieval are not. Video signals and video candidates stay disabled for the launch scope. The client does not expose taxonomy labels or per-item rationales.

The first ranker should be deterministic and understandable. Keep scoring weights and thresholds configurable; do not present guessed percentages as validated product behavior. The 3–5–10–25 position schedule remains a hypothesis for later evaluation, not a requirement that every feed page contain fixed quantities or ratios.

Detailed inputs, labels, ranking stages, and evaluation are defined in [`RECOMMENDATION_SYSTEM.md`](RECOMMENDATION_SYSTEM.md).

## 6. Non-functional requirements

- Responsive PWA with installability, graceful offline shell behavior, and accessible keyboard/touch interaction.
- API and database authorization are correct under concurrent updates and stale clients.
- Cursor-based pagination and bounded payloads; asynchronous media processing is a later phase.
- Cost-aware MVP/Beta hosting: usage-based/serverless compute where runtime constraints allow, managed asynchronous processing, private cloud object storage, and measured CDN delivery; preserve the modular-monolith application boundary.
- Observability for latency, errors, queue health, moderation outcomes, recommendation quality, and privacy deletion completion.
- Recommendation fallback must remain useful and safe if feature stores, Redis, or model services are unavailable.
- Availability, latency, retention, and scale SLOs must be chosen from launch expectations in a capacity plan; do not present unmeasured targets as achieved.
- Smoothness is a release requirement across the whole app, not a visual flourish: no avoidable blocking work on the UI thread, no false success while writes are pending, clear progress/retry states, and stable phone/desktop layouts.
- The launch appearance is charcoal dark mode by default; light mode is an explicit device-local setting. Image decode/resize work must not block scrolling, media transfers must be bounded/cancellable/retryable, and image/audio playback must be lazy and user-controlled.
- Use the current Core Web Vitals “good” thresholds as measurable launch targets: at the 75th percentile, LCP ≤2.5 s, INP ≤200 ms, and CLS ≤0.1, measured separately on mobile and desktop. These are acceptance targets, not current performance claims; record lab and field evidence before release. [Google's Web Vitals guidance](https://web.dev/articles/vitals).
- Keep deferred video performance targets documented for its later phase; they are not launch requirements for the text-first product.

## 7. Acceptance criteria for a public beta

- A user can browse public text without an account, create and secure an account, manage their profile, and publish/edit/delete text posts.
- Signed-in users can attach supported images or a short voice note to a post or reply; server ownership checks, file validation, parent authorization, deletion propagation, and visible failure/retry states work end to end.
- Feed responses exclude content the viewer cannot access, has blocked, or has hidden.
- Every eligible text post receives internal versioned labels with source and confidence; the client never renders these labels.
- Feed ranking uses configurable relevance stages, retains internal reason codes for diagnostics, and has a useful fallback for users with little or no history.
- For You uses permitted text/feed feedback, explicit controls, freshness, and diversity; recommendation behavior is measured against a versioned evaluation set.
- The first release uses the bounded deterministic ranker; learned retrieval, embeddings, multi-task ranking, and online training remain future work behind the evidence and privacy gates in `RECOMMENDATION_SYSTEM.md`.
- Users can tune, pause, or reset personalization without seeing the taxonomy; reset behavior is covered by tests and documented deletion/decay policy.
- Home, Search, Create, Inbox, Profile, and implemented Settings are usable on phone and desktop with keyboard and assistive-technology access to core controls.
- Dark charcoal mode is the first-run default; switching to light mode survives app restart on that device and remains readable at supported screen sizes.
- Users can follow, react, comment, report, block, and exchange direct messages within privacy rules.
- Moderation, abuse response, backup/restore, incident handling, and account deletion procedures are operationally documented before broad release.
- Automated tests cover authorization boundaries and recommendation eligibility/diversity invariants.
