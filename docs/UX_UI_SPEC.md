# UX and UI Specification (Draft)

This document defines the text-first launch experience with optional image and voice attachments; short video remains deferred. It records intended behavior and layout and identifies which interactions use persistence versus remain part of the prototype.

## Design source of truth

- Build and maintain the product UI directly in Flutter code. The implementation and this specification are the review artifacts; no Figma or Canva file is required for product runtime or delivery. Flutter replaces the old Angular client after the migration build and core journeys are verified.
- Use X as a reference for a readable text timeline, clear author identity, and compact post actions. Short video is a later product phase and does not shape the launch navigation. Keep Ionic's own brand, navigation, language, and interaction details; do not copy another product's complete visual design.
- Revisit these choices from observed use and measured evidence. Treat references as interaction patterns, not templates.

### Color tokens

| Token | Value | Use |
| --- | --- | --- |
| Background | `#121418` (default) / `#F2F4FB` | Charcoal canvas / light page canvas |
| Surface | `#1A1D23` (default) / `#FFFFFF` | Cards, composer, menus |
| Raised surface | `#242830` (default) / `#F1F3F8` | Secondary controls and grouped rows |
| Text | `#EEF0F5` (default) / `#1B2340` | Main copy |
| Muted | `#A8AFBD` (default) / `#526079` | Supporting text and metadata |
| Primary action | `#34383F` (dark) / `#4C5FDB` (light) | Filled actions; dark buttons use white text |
| Selected/icon emphasis | `#C4C9D1` (dark) / `#4C5FDB` (light) | Legible selected state without blue-filled dark controls |
| Accent | `#8052E8` | Restrained light-mode brand accent |
| On primary action | `#FFFFFF` | Text and icons on filled buttons |
| Outline | `#30343D` (default) / `#DBE1EF` | Card and field borders |
| Neutral emphasis | `#3C4149` | Selected navigation indicator and soft emphasis in dark mode |

## Product rules

The launch target is a responsive Flutter client on Android and web using the Dart `/api/v1` server; Flutter owns presentation only, while authorization, durable data, and feed ranking remain server-owned. NestJS and Angular stay available during parity work as references/rollback. Video-related modules are dormant for the text-first launch.

1. Opening the app lands on Home in charcoal dark mode. Do not put a tutorial, registration form, or interest questionnaire between the user and the first view. A saved device preference may switch to light mode.
2. Home shows a single text feed with search and a compact composer; do not show the “Bảng tin” heading or **Dành cho bạn / Đang theo dõi** tabs. The signed-in Home still uses personalized retrieval internally. Keep pause/reset in Settings and reserve visible feed selectors for the later video discovery surface.
3. Use consistent, labeled navigation for Home, Search, Create, Inbox, and Profile. Settings open from the account menu and Profile. Use a bottom bar on narrow screens and a persistent side rail/navigation region on wide screens.
4. Keep feed reading primary. A post starts with author identity and time, then readable text, attached media, and reachable actions. Images are lazy-loaded; voice notes never autoplay and have visible play/pause, duration, and loading/error state.
5. Make the primary actions one tap/click away. Secondary actions such as report, hide, and mute stay findable in a labeled overflow menu and must provide clear completion feedback. Muting removes that account's posts from eligible Home retrieval without unfollowing, blocking profile access, or disabling direct messages; the account can be unmuted from profile controls.
6. Do not require swiping to move, pause, open a post, or dismiss a surface. Provide visible controls with keyboard and screen-reader labels.
7. Never imply that a UI-only action has been saved by the server. Prototype fixtures and temporary interaction state are clearly separated from account data.

## Responsive Home layout

### Phone

- Compact Ionic header with wordmark, search, and account entry.
- One text feed; no feed-mode switch or extra page title.
- Single-column feed with comfortable line length and clear boundaries between posts.
- Bottom navigation with persistent labels and a visually distinct Create action.
- Post actions remain visible after the text; no hover-only controls.

### Desktop

- Centered content area with a left navigation rail, a readable primary feed, and a small account panel on wide screens.
- Give the feed enough width for readable posts while keeping paragraph line length comfortable. Increase card padding, hit areas, and corner radii consistently.
- Keep the first post and composer visually primary. The account panel must not explain why a post or account was selected.
- Do not display taxonomy labels, ranking reason codes, generated topic chips, or copy such as “vì bạn quan tâm đến …”. Keep feed controls available without exposing the ranking system.

## Core screen order

1. **Home:** One text feed, search, create entry point, hide/report, and generic more/less similar-content controls. Signed-out readers see only real public text posts.
2. **Search:** discover public posts and profiles with clear empty/error states; apply the same visibility and block rules as the feed.
3. **Create:** text composer with optional image selection and short voice recording, audience shown before publish, draft recovery, character count and validation, explicit upload/cancel/save/publish feedback. Ask for microphone permission only after the user starts recording; do not ask for camera access in this phase.
4. **Profile:** identity, follow state, posts, privacy state, and account controls.
5. **Inbox:** persistent one-to-one conversations with immediate local send feedback, bounded history fetches, visible send failure, and no message text flowing to recommendation telemetry.
6. **Settings:** grouped account/security, privacy/audience, feed/personalization, appearance/accessibility, notification, and content controls. Only show controls with a real persistence and behavior path.

## Home interaction states

- **Feed selection:** Home has one personalized text feed and no visible mode selector. Following remains a separate chronological capability for a later discovery surface.
- **Like/save/follow:** signed-out readers are prompted to sign in. Signed-in actions wait for server confirmation and show an error if persistence fails; do not simulate a successful domain write locally.
- **More / less like this:** available from a post's overflow menu. It adjusts internal ranking signals for similar items without displaying the underlying taxonomy labels or a reason the item appeared. Feedback is never applied to sensitive-trait profiles.
- **Hide/report:** separate actions. Hiding affects the viewer's feed; reporting starts the trust-and-safety flow and is not treated as a preference signal.
- **Empty feed:** state that no posts are available and offer refresh as the next step. Keep the state text-first and omit decorative icon tiles or ranking explanations.
- **Error/offline:** retain safe shell content, show retry status, and do not display stale private feed/message content from shared caches.
- **Sign-in prompt:** appear at the action that requires an account, with a clear return to the user's current screen. Creating a text post opens registration/sign-in and resumes the composer after authentication. Guest reads return only public, published text; guest actions never write account state.

## Visual and accessibility direction

- Practical, calm, readable, and recognizable as Ionic. Use a clear type hierarchy, stronger card boundaries, and generous touch targets; avoid blank columns, tiny labels, glass effects, and oversized decoration in the reading feed.
- The project-owner supplied Ionic symbol and wordmark are the brand source of truth. Use the supplied lockup in the desktop rail and mobile header, with matching mark-only PWA icons. Keep the mark legible at small sizes.
- Keep feed cards and reading surfaces mostly neutral. In dark mode, use charcoal and neutral gray for filled actions/navigation, with white text. Preserve Ionic blue actions for light mode. Avoid decorative empty-state tiles or treatments that compete with post content.
- Dark mode is default with charcoal surfaces, restrained borders, and text contrast checked independently from light mode. Do not use pure black as the main canvas or invert colors mechanically.
- Use real interface labels instead of icon-only controls wherever meaning could be unclear. Maintain visible focus, touch targets, scalable text, reduced-motion behavior, and reflow at narrow widths.
- Sample posts, account names, and avatars are synthetic; never present them as persisted user records.
- Prefer a compact, editorial interface with strong typography and clear post boundaries. Avoid toy-like decoration, oversized gradients, fake activity counts, or unused empty areas. Settings use a readable grouped list, clear current values, explicit save state, and confirmation only for destructive/reset actions.

## Settings interaction contract

- **Account and security:** profile details, password change, recovery, active sessions, account export/deletion, and sign out. Sensitive changes require a clear confirmation and server response. Email recovery is unavailable until delivery is configured and verified.
- **Privacy and audience:** public/private profile and follow requests, messaging permissions, blocked/muted accounts, and hidden content. The server enforces each choice; client switches are not authorization.
- **Feed:** pause/resume and reset personalization, with generic language and no taxonomy labels or item-level recommendations rationale.
- **Appearance/accessibility:** appearance, text size, reduced motion, and language are device preferences; show when an option is local rather than synced.
- **Notifications:** expose only when the selected delivery channel is implemented; a stored switch without delivery behavior is not a finished setting.
- **Content:** drafts, saved posts, and own-post management must link to real APIs and show accurate empty, loading, failure, and success states.

## Current implementation boundary

- Guest Home is wired to the read-only public text endpoint; the product never falls back to synthetic posts. The endpoint/client path still needs live authorization, pagination, empty/error, and abuse-rate review before release. Icons are explicitly registered by the client and each visible control retains an accessible name.
- Account registration/sign-in and authenticated text publishing use the Flutter/Dart target API by default; the local proxy can select NestJS for parity review. The browser keeps only the HttpOnly session cookie; own-post history is read back from the API. Public signup is disabled by default in production.
- Profile search, follow/block, like/save/reply, hide, generic more/less, pause/reset, and personalized Home retrieval use authenticated API contracts. Home has no feed-mode switch. Guest-only interactions remain session-local. If the API or PostgreSQL is unavailable, account actions show a failure and do not claim persistence.
- The Flutter client targets the Dart API. Settings source reads persisted feed controls, mute/block lists, and the signed-in profile; profile display name and biography can be edited through `PATCH /profiles/me`. The latest media slice builds and the database is ready; newer profile/settings paths still need account-backed runtime verification. Password recovery, session/device management, push delivery, read receipts, and message requests are not implemented.
- The persisted text labeler applies a versioned format label and a small topic/context/language rule set. The authenticated For You endpoint sends eligible labeled posts to the deterministic ranker; labels, ranks, and reasons stay out of the client response.
- Internal taxonomy labels and ranking reason codes are never rendered in feed cards, profile surfaces, search, or preference controls. Do not render generated topic chips, hashtags derived from taxonomy, or explanations such as “because you are interested in …”. Generic item feedback, learning pause, and reset are the user controls; signed-in ranking is performed by the versioned API module described in `RECOMMENDATION_SYSTEM.md`.
- Message bodies and message activity do not enter feed ranking or recommendation events. The server blocks conversation reads/writes while either account blocks the other.
- Report is separate from preference controls. Signed-in users can select a reason and optionally describe a post concern; the server confirms that it received and persisted the report. This is not a staffed moderation queue, enforcement workflow, or promise of a review time.
- Signed-in search returns server-matched posts and accounts with loading, error, and empty states. Post results are paginated; private profiles and either-direction blocks remain excluded according to server authorization.
- Video source is retained for later; it is not a launch destination, composer choice, recommendation candidate, or required device permission. Re-open the video UX only after audience, safety, processing, delivery, and cost gates are ready.
- Image and voice attachment controls are implemented in the Flutter composer. Images are downscaled before upload; the Dart API validates and normalizes JPEG. Voice is recorded as mono 16 kHz PCM WAV and fetched only after the user presses play. Staged uploads remain private until the post/reply transaction commits, and reads are checked against the parent. The local filesystem adapter is development-only; end-to-end/device behavior, upload rate limits, scheduled deletion cleanup, and production storage are still open. Keep media controls explicit and never show internal labels or ranking reasons.
- Flutter does not cache private feed, profile, or message records for offline use. If shell caching is added, it must exclude private or personalized API responses.
- The Flutter video surface preserves the existing coarse video-signal contract: count only foreground, non-buffering playback while at least half the player is visible; send one categorical active-view or skip signal under the existing API rules. Do not store raw play duration or playback position.

## First UI acceptance checklist

- A first-time visitor can read real public posts immediately and identify where to publish, message, search, and view profiles.
- Home opens directly to a single text feed without a setup gate, feed-mode tabs, or a “Bảng tin” heading.
- The first post's author, time, text, and primary actions are readable without opening another screen; no taxonomy label, ranking reason, or algorithm explanation appears on Home.
- Account creation/sign-in opens only when requested and can resume the composer. A successful publish appears in the Home list and account profile only after the API confirms it.
- Signing out or activating another account clears the previous account's search, feed, conversations, video preview, and unsent drafts before the new account data is shown.
- Layout remains usable at phone and desktop widths, with keyboard focus visible and no essential hover-only or swipe-only action.
- Smoothness is a ship gate: assess the Core Web Vitals targets at p75 on both mobile and desktop; verify bounded loading, optimistic-but-reversible actions, upload progress/failure states, and that only the active video plays.
- No synthetic post is presented as live content in a launch build. The interface never claims a failed or demo action reached the server.
