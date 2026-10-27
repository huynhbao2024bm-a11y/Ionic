# Delivery Roadmap

This is the active execution order. The immediate target is a usable text-first launch candidate with optional image and voice attachments; short video remains deferred. No launch date is asserted until the release gates below pass. Prioritize Flutter/Dart Android, then validate iOS on macOS/Xcode; retain the web PWA. Preserve PostgreSQL records and HTTP/data semantics. Keep NestJS and Angular as references/rollback until parity and signed-in client flows are verified; do not delete either early.

## Text-first delivery target — usable launch candidate (2026-10-23 onward)

The previous 2026-11-06 target included video and is superseded by the owner's text-first direction. No launch date is asserted here. The first usable product slice is: open Home and read real public posts; register/sign in and restore the account session; publish and read text with optional image/voice attachments in posts and replies; use profiles/follows and one-to-one messages; control personalization; and manage implemented account/privacy/display settings. Flutter Android already completed a narrow signed-in flow against the Dart API: login, session restore after app restart, For You request, and text post publish/readback. The image/voice implementation is now in Flutter/Dart source; database application, build, and runtime/device verification remain outstanding. Guest-feed, profile-edit, theme, and settings changes are also not all runtime verified. Video capture, upload, discovery, and playback are deferred until Ionic has a user base and is prepared for processing, moderation, delivery, and cost controls. Keep internal labels and ranking rationales out of the interface.

| Days | Focus | Exit evidence |
| --- | --- | --- |
| 1 | Text-first product contract and navigation: remove video from launch surfaces, expose real public text reading, keep account actions authenticated. | Flutter guest and signed-in Home use server content; no demo data is passed off as real. |
| 2 | Account and publishing reliability: registration/login/session, draft recovery, text publish/read/edit/delete, replies, likes, saves, search, image/voice attachment upload and playback. | Persistent journeys work with loading, validation, bounded progress/retry, parent authorization, and duplicate-submit handling. |
| 3 | Settings and account controls: profile, security, privacy, blocked/muted, feed personalization, charcoal-dark default/light display, accessibility. | Every visible control persists and changes behavior; unimplemented delivery/provider controls are hidden. |
| 4 | Recommendation baseline: text labels, candidate retrieval, ranking/diversity, explicit controls, judged evaluation, query plans/latency. Images/audio remain attachments only until content understanding is evaluated and approved. | A versioned baseline and limits are recorded before weight changes; no labels/rationales appear in UI. |
| 5 | Release hardening: access boundaries, moderation operation, account recovery/deletion, accessibility, mobile/web performance, backup/restore, rollback. | Text-first release gates pass on supported targets or remain explicitly blocked with evidence. |

**Scope limits for this target:** video is outside the first release. Image/voice attachment limits and serverless object-storage requirements stay configurable until payload and cost measurements exist. No Monolith-style embedding retrieval, trained multi-task ranker, online gradient updates, Kafka/Flink deployment, or high-scale capacity claim. Do not ship fake persistence or imply demo records are live user content. A production-quality interface does not equal production deployment; recovery delivery, moderation operations, TLS/signing, performance, privacy retention, and rollback remain release gates.

## Phase 0 — Product and interaction blueprint

**Status: Flutter/Dart remains the active implementation.** Android is the first native target and Web is retained; iOS needs macOS/Xcode verification. Existing Android login/session restoration and authenticated post read/write were previously verified against the local Dart/PostgreSQL stack. This turn wires signed-out Home to bounded public text posts, adds a server profile-update contract and working settings UI, and excludes short videos from the two recommendation implementations. The new guest-feed, profile-edit, settings, and text-only retrieval changes still need analysis/build plus database-backed verification. Physical-device performance, API parity, accessibility, and release operations remain open. Keep NestJS/Angular as migration references.

- Keep the scope and constraints in `PRODUCT_REQUIREMENTS.md`, `ARCHITECTURE.md`, `DATA_MODEL.md`, `RECOMMENDATION_SYSTEM.md`, and `SECURITY_PRIVACY.md` aligned.
- Establish the responsive Home, feed cards, navigation, and core states directly in Flutter code. Use X and TikTok for selected interaction patterns, not as copied screen templates.
- Define the opening flow, mobile and desktop navigation, loading/empty/error states, and which actions need an account.
- Keep non-technical decisions (age, account privacy, hosting, region, retention, moderation operations) open until their feature or launch needs them.

**Exit:** the first code-backed screen and interaction spec are reviewable; no mandatory interest survey or tutorial blocks the first view of Home.

## Phase 1 — Usable client shell and feed interactions

**Status: existing Flutter shell and Android session/post baseline build and run; text-first UI source is updated.** Guest Home calls the public text feed and does not contain synthetic fallback data; Video is removed from primary navigation. Settings now has profile editing, persisted pause/reset, mute/block management, and sign-out. The latest screen/settings changes have not yet been manually reviewed on a device. Keyboard/accessibility review, physical-device sizing, smoothness measurements, and iOS macOS/Xcode verification remain open.

- Build the Flutter app with Home as the initial destination, responsive navigation, and an accessible single text feed without visible mode tabs. Keep personalized retrieval on signed-in Home; reserve For You / Following mode selection for later video discovery. Release and verify Android first; retain Web and then validate iOS on macOS/Xcode.
- Add high-frequency feed actions and visible states: follow, react, save, reply, hide, report, generic more/less similar content, pause, and reset. Do not display a recommendation reason.
- Build the text composer, profile, inbox entry, personalization controls, and guest/sign-in prompts as coherent UI flows; clearly distinguish prototype data from persisted account data.
- Support touch, keyboard, reduced motion, narrow viewports, and useful loading/empty/error states.

**Exit:** a new visitor can open Home and understand how to browse immediately; primary screens and controls work in Flutter Web and a native-installable Android build. iOS shares the Flutter UI but remains a later macOS/Xcode verification gate.

## Phase 2 — Text social core and API contracts

**Status: existing Dart account and post slice has local runtime evidence; newly added profile edit and guest public-feed routes still need database verification.** The shared profile update contract is now present in Dart and NestJS source. Verify post lifecycle, profile/follow, two-account messaging, reports, pagination, privacy/block authorization, and failure paths through Flutter and Dart before launch. Message idempotency exists in source but still needs a Dart runtime check.

- Verify registration/sign-in, publish/readback, follow/unfollow, mute/unmute, react/save/reply, and the personalized Home path against persistent account data. Keep the chronological Following endpoint as a service capability; its visible selector is deferred to the later video-discovery surface.
- Review cross-account authorization, block behavior, pagination boundaries, and loading/error/retry states from the client through the API.
- Clear account-scoped client state on sign-out/account change and ignore late responses from a previous session.
- Keep sign-in prompts contextual to account-required actions; do not require onboarding interests just to view Home.
- Keep demo fixtures separate from live records; do not imply that local prototype state is already saved to an account.

**Exit:** an authenticated user can publish, follow, react, save, reply, and browse chronological Following content with server-enforced access and stable pagination.

## Phase 3 — Integrate recommendation v1 (product differentiator)

**Status: deterministic core remains the priority; both active retrieval queries are now text-only.** A narrow Android request reached Dart For You previously, but this turn's SQL scope changes are not yet runtime-verified. That earlier connectivity/readback does not prove personalized reranking. Preference writes/controls, guest retrieval, candidate-source recall, cursor stability, query plans, and ranking quality remain unverified against representative data. The NestJS/TypeScript implementation remains the behavioral reference. Synthetic scenarios cover selected mechanics only; they are not representative relevance judgments.

- Verify the persisted For You path from eligible posts and viewer features through bounded retrieval, ranking, pagination, controls, and returned content.
- Build a representative, explicitly judged evaluation set and record relevance, freshness, negative feedback, creator/topic variety, and duplication metrics before tuning.
- Inspect ranking/retrieval SQL with realistic row counts and measure comparable latency before optimizing.
- Keep reason codes and ranking version internal for diagnostics; provide generic pause/reset and per-item feedback controls without exposing taxonomy.
- Instrument only documented, idempotent, purpose-limited feed events; keep domain actions authoritative in their own modules.

**Exit:** the text feed is personalized end to end, controllable, and measured against a versioned baseline without weakening safety or privacy boundaries or displaying item-level rationales.

## Phase 4 — Messaging and controlled-release readiness

**Status: the NestJS one-to-one message path passed a limited local two-account proxy journey; Dart source now contains the same conversation, history, and idempotent-send routes.** Neither Dart message SQL nor authenticated Flutter messaging has been runtime-verified. Report submission is also ported to Dart, but staff review and enforcement are not implemented.

- Verify signed-in conversation listing, send/read, idempotent retry, block behavior, and visible failure states across accounts. Read receipts and notifications remain optional follow-up work.
- Define report review ownership, retention, response targets, enforcement, and appeals; then implement the smallest moderation queue needed for a controlled release.
- Complete account deletion, incident response, backup/restore, and support notes appropriate to the invited group.
- Keep message bodies and private message activity outside feed personalization.

**Exit:** conversation access and abuse handling are validated for the closed MVP; privacy, retention, and operational gates are documented before a wider beta.

## Phase 5 — Video discovery and publishing (deferred)

**Status: deferred by product direction.** The Flutter and Dart source for private capture/upload/owner preview exists, but it must stay out of the text-first launch navigation and content retrieval. Video work resumes only after an established audience and operational readiness for validation, safety review, encoding, cloud delivery, and cost monitoring.

- Add private, size/duration-bounded upload authorization, validation, asynchronous processing, and visible processing/error/retry states.
- Use the MVP/Beta serverless-first media path: client-to-private-object-store upload; durable idempotent queue; scale-to-zero orchestration; managed or ephemeral transcoding; private originals and segmented adaptive-bitrate renditions; CDN playback after moderation/processing gates. Keep exact provider, codec/rendition ladder, and segment duration open until device/network coverage and cost are measured.
- Add resource and spend controls: per-upload ceilings, bounded queue concurrency/retries/timeouts, abandoned-upload/temp-output cleanup, lifecycle policy aligned to retention/deletion, and dashboards for stored bytes, encoding work, CDN egress/cache, and failure/retry rates.
- Implement an accessible vertical viewer with explicit pause/mute/caption/next controls and reduced-motion/data-saving behavior.
- Reuse the same content-labeling, eligibility, ranking, diversity, and feedback contract as text.

**Exit (future phase):** only processed and eligible video is viewable or rankable; all key playback actions work without gesture-only controls; deletion and takedown cover source and derived assets; expected usage has a measured cost envelope and retry/failure behavior.

## Phase 6 — Measurement, tuning, and scale

- Tune rules using representative outcomes and feedback; evaluate learned ranking only after data quality, consent, offline evaluation, and rollback are in place.
- Add analytics storage, workers, caches, or service extraction only after purpose, privacy, load, cost, and operations justify them.

**Exit:** ranking changes are reversible and improve measured usefulness without harming safety, diversity, privacy, reliability, or user controls.

## Ongoing execution loop

1. Start from the current phase and its exit criteria, then inspect existing code and docs before changing a contract.
2. Finish one user-visible vertical slice before starting an unrelated feature.
3. Update the canonical product/architecture/data/security document and decision log with the code when behavior changes.
4. Run only the narrowest applicable validation; report what was and was not verified.
5. Mark phase status and the next concrete slice here so future work can resume without rebuilding the plan.

**Current status (2026-10-24, rechecked):** The direct-code UI pass is in source. Chrome review covered guest Home, Video, Messages, Profile, and the sign-up modal; Home was also viewed at a narrow window size. No account or content was created through that browser review. The web typecheck and production build pass; Angular reports the component CSS above its 25 kB warning threshold (29.68 kB) but below its 30 kB build-error threshold. API liveness/readiness returned HTTP 200 on port 3000 and through the web proxy; PostgreSQL reported ready and all 11 migrations applied. Temporary-account proxy journeys verified text publish/read, one preference-driven rerank, persistent message send/read, and idempotent retry; all temporary records were removed. Six synthetic recommendation scenario groups pass, but they are mechanics checks only. Still missing: authenticated browser/UI flows, realistic ranking relevance and latency evidence, moderation operations, server-side video validation/scanning/transcoding/public delivery, scheduled behavioral-event cleanup, and measured phone/desktop performance. No pilot-readiness claim follows from passing builds or local API checks.

**Flutter/Dart migration update (2026-10-26):** `apps/client` resolves dependencies, passes `flutter analyze`, and builds a Web release; native Android and iOS folders have now been generated. The owner wants Android first and iOS after that, with Web retained. `apps/server` is the target Dart modular monolith, with route source now covering current API families. Preserve NestJS/PostgreSQL contracts. Runtime parity is partial: a narrow Android account/post/feed journey is verified; social, messaging, reports, and media routes still need parity review. Keep `apps/api` and `apps/web` until route parity and core account-backed journeys are verified.

**Android client slice (2026-10-26):** Native Flutter persists the opaque `ionic_session` token with OS-protected storage, sends it on API requests, and clears it after a protected-route `401` or a server logout cookie. A raw-string interpolation bug in the native cookie parser was fixed; Android backup is disabled and app minimum SDK is 24. `flutter analyze` reports no issues. Flutter Web release and Android debug builds pass. The latest APK is `apps/client/build/app/outputs/flutter-apk/app-debug.apk` (191,723,713 bytes, universal arm64/armv7/x86_64, package `app.ionic.mobile`, app label `Ionic`, target SDK 36); SHA-256 is `DF8D0352F01E865C54656023E32B7A9F330C8FFC9AAD7DC71D9A225272172262`. It was installed and launched on a Pixel 6 API 35 emulator. Login, secure session persistence after force-stop/relaunch, `/auth/me`, For You HTTP 200, and a text-post publish/readback flow were manually verified against the Dart API and local PostgreSQL. The temporary account and post were deleted; the database contained no retained smoke data at cleanup. Profile, follow, message, report, camera, video, physical-device, keyboard/accessibility, and performance checks remain open. The build required `kotlin.incremental=false` after Kotlin cache failures on Windows; this trades slower clean native builds for a successful build.

**Latest implementation slice (2026-10-26):** Dart source now mounts health/auth, authenticated `/api/v1/feed/*`, `/api/v1/posts/*`, `/api/v1/profiles/*`, `/api/v1/messages/*`, `/api/v1/reports`, and `/api/v1/videos/*`. Feed supports bounded PostgreSQL candidate retrieval, viewer profile/features, ranking, cursor pagination, settings/pause/reset, per-item more/less/hide, and video-signal suppression/cooldown. Posts support create, personal/following/author reads, search, like/save, replies, and internal label persistence; actual like/save transitions update preference features in the same transaction as the action. Profiles support account lookup/search, following lists, block/mute lists, follow/unfollow, block/unblock, and mute/unmute with mutual-block checks and follow cleanup. Messaging supports conversation listing/creation, membership-checked history, stable cursors, and idempotent sends with transaction-bound conversation updates. Reports support duplicate-safe content reporting. Videos support private, size-bounded uploads with signature checks, internal caption labeling, owner-only listing/playback, and byte-range responses; they do not support public processing or duration validation. The pure recommendation core includes content-label rules, bounded/decayed preference updates, diversity, and offline metrics. On 2026-10-26, `dart analyze` found no issues; the migration CLI reported the PostgreSQL schema up to date; the Dart API readiness endpoint reported the database ready; and an Android flow reached sign-in/session restore, For You, and text-post persistence through Dart. This does not establish parity for other routes. Password-hash interoperability was not tested against a legacy NestJS account. Keep Flutter and the Dart server as the active migration target, but retain `apps/api` and `apps/web` until route parity is reviewed.

**Manual browser/UI review (2026-10-24):** Home, Video, Messages, Profile, and the account modal were viewed in the running local Ionic app. Icons render, the Home cards and controls have clearer hierarchy, the old logo caption is gone, guest video has a visible action in its empty player, and the registration form fills its modal without a blank side panel. No account, post, message, or upload was submitted. The narrow window showed the mobile feed and bottom navigation; this is not a physical-device, authenticated, keyboard, or assistive-technology review.

**Current product scope (2026-10-27):** Text-first launch with optional photo/voice attachments to posts and replies; video is deferred and excluded from primary navigation and recommendation retrieval. Signed-out readers should see only public, published posts and authorized attachments from the API; account actions require a session. Settings source now includes profile editing, pause/reset personalization, mute/block management, current-device sign-out, and device-local dark/light appearance. Migration 0012 is applied locally; Flutter Web and Android debug builds pass; Dart readiness is healthy. The guest Home and sign-in dialog were visually reviewed in Chrome. Signed-in media upload, recording, playback, and access-denial paths are not yet exercised. Unsupported account recovery, notification delivery, private-account requests, and multi-device management remain hidden.

**Next concrete slice:** Exercise photo/voice publish and read on posts and replies with a signed-in local account. Verify staged objects cannot be read and private/blocked parents deny access; confirm image/voice attachments never alter ranking. Do not add camera or video capture. Then exercise profile editing, pause/reset, mute/unmute, block/unblock, messages and remaining post interactions against PostgreSQL. Return to the core algorithm by measuring a fixed human-judged text-ranking baseline and PostgreSQL query plans before tuning weights. No synthetic fallback or nonfunctional setting may ship.

## Release gates for every phase

- Product acceptance criteria are current and testable.
- New collection, ranking, privacy, or authorization semantics are documented and reviewed before they become production contracts.
- Migrations and deletion/retention behavior are reviewed for safety.
- Relevant formatter, lint, type-check, and build checks pass; focused tests cover changed behavior as required by project instructions.
- Monitoring, rollback, and moderation/support ownership are defined before public release.

## Continuation update — 2026-10-27

The image/voice local integration smoke is complete as described above. Superseding the earlier `Next concrete slice`, the next active work is to establish a fixed, versioned human-judged text-ranking set and measure the Dart retrieval/ranking and PostgreSQL plan before changing rank weights. Then verify Flutter like/save/feed-control behavior, followed by Android photo/voice UI, playback, recovery, and access-denial checks. The media smoke's synthetic user and all associated test objects were removed; production storage, deletion lifecycle, rate limiting, and staffed moderation remain release gates.

## Home UI and preview — 2026-10-27

The Flutter Home now has one text feed with no “Bảng tin” header or visible feed-mode tabs; signed-in retrieval remains personalized, and Following remains a service capability reserved for a later discovery surface. Dark-mode actions/navigation now use neutral gray and white; light mode retains Ionic blue. Decorative empty-state tiles are removed. `dart analyze`, Flutter Web release build, and Android debug APK build succeeded. The prior preview on port 4200 remained occupied by its older process; a fresh debug preview with the Dart API proxy is running at `http://127.0.0.1:4202`. The updated screen has not yet been visually confirmed in that preview. The debug APK was built but not installed/launched after this UI change.

## Self-assessment follow-up — 2026-10-27

The current evidence and release blockers are recorded in `PROJECT_ASSESSMENT.md`. The first small task is visual/runtime acceptance of the newest Home in the 4202 preview or the new APK; then continue the algorithm-first work by assembling a versioned human-judged text set and measuring retrieval/ranking plus PostgreSQL/request latency before tuning. This ordering does not make the old 4200 page or the current APK a verified runtime result.
