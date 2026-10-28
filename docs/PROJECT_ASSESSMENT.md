# Project Reality Check

This is a dated engineering evidence snapshot, not a replacement for product requirements, architecture, security, or recommendation contracts. Recheck the repository and running application before relying on it; update this file only when new evidence changes a status.

## Earlier snapshot — 2026-10-24 (before the latest recheck)

### Evidence collected in this review

- The guest Home loaded in the browser. Switching feed tabs changed the selected state while the visible posts remained demo fixtures.
- The create entry opened account registration; Messages showed a sign-in gate; Video explained its account requirement; the demo profile remained identified as a preview.
- A read-only request to `/api/v1/health/ready` returned `status: ready` and `dependencies.database: ready`.
- The first mute endpoint probe returned `404` because the API process was still running the pre-mute build. After restarting the API, Nest logged both mute routes as registered. The post-restart HTTP probe and readiness call timed out in the shell environment, so route response and live API/database health are not re-confirmed there.
- No browser console errors appeared on the screens reviewed.
- No account, post, message, report, or media upload was created in this review. No signed-in journey or persisted write was exercised.
- Docker/socket inspection from the shell was denied in this review. The readiness response confirms that the API could reach its database at that moment, but it does not identify the container state or validate database-backed feature behavior.
- In preceding work, migration 0009 was applied successfully; earlier checks also recorded migrations 0001–0008 and a passing synthetic recommendation scenario command. That scenario command was not rerun in this review.
- An earlier slice connected public-ready short-video candidates to the existing For You retrieval/ranking path and added in-feed playback through the guarded video endpoint. API/web typechecks and builds passed; the local database has no public-ready video sample, and live API/browser verification was unavailable, so actual mixed-format ranking and playback remain unconfirmed.
- An earlier slice added coarse foreground video active-view/skip events, immediate preference updates, and exact repeat suppression for materially played videos. Migrations 0010–0011 applied; API/web typechecks and builds passed. Nest registered the signal route at startup. Liveness/readiness HTTP requests timed out, and no public-ready video exists locally, so the event and query paths are not verified end-to-end.
- This turn capped each viewer/video/signal-kind combination to one event per rolling 24 hours under a PostgreSQL transaction advisory lock, preventing fresh client event IDs from repeatedly amplifying the same signal. API/web typechecks and builds pass; PostgreSQL concurrency and authorized playback behavior remain unverified because no public-ready video exists locally.
- After rebuilding, the API process started and registered its routes; Windows reports a listener on `127.0.0.1:3000`, but liveness/readiness HTTP requests from this task environment timed out, so route responses are still unconfirmed. A read-only aggregate query against the dedicated local `ionic` database at `127.0.0.1:5433` returned 0 users, 0 published text posts, 0 active content labels, and 0 ready videos. No database records were changed.
- This turn also centralized client cleanup for account-scoped data on sign-out and account identity changes, including search results and unsent private drafts, and invalidates prior-account request revisions. Web typecheck/build pass; browser session-switch behavior remains unverified.

## Latest recheck — 2026-10-24

- API liveness and readiness both returned HTTP 200 directly on port 3000 and through the web dev proxy on port 4200. Readiness reported the PostgreSQL dependency as `ready`; all 11 migrations were recorded as applied.
- Through the local web proxy, two temporary accounts completed registration, text publishing, automatic internal labeling, For You retrieval, liking, persisted preference update, and feed refresh. A separate ranking scenario started with the newer software post first; after the viewer liked an older design post, the design post moved above it. This confirms the basic data path and one deterministic rerank case only.
- A second two-account journey created a conversation, sent a message, retried with the same client message ID, and read the stored message as the recipient. The retry returned the existing message rather than creating a duplicate.
- The recommendation scenario runner passed its six authored synthetic scenarios. Its precision/recall/nDCG values describe those fixtures only; they are not user relevance or launch-quality measurements.
- All temporary test accounts were removed. The dedicated local database returned to zero users, published content, active labels, ready videos, messages, and learned preference features.
- A later code-first UI review covered guest Home, Video, Messages, Profile, and the account modal in the running Chrome app. Home was also inspected at a narrow browser width. No account, post, message, or upload was submitted. This confirms rendered guest surfaces only, not authenticated UI behavior or physical-device accessibility.
- The interface pass registered Ionicons, removed the tagline below the logo, clarified the feed and card hierarchy, increased small type on account/video/message surfaces, fixed the account modal's unused blank area, and put a sign-in action directly inside the guest video empty state. Internal labels and ranking explanations remain absent from the UI.
- Web typecheck and production build pass after the UI edits. Angular reports the component CSS at 29.68 kB: over its 25 kB advisory budget but below the 30 kB build-failure threshold. The warning is a size/maintainability concern; it is not a failed build or a performance measurement.

### Evidence by product area at this 2026-10-24 recheck

| Area | Evidence level | What is still unknown or missing |
| --- | --- | --- |
| Guest Home and navigation | Guest Home and navigation manually reviewed in Chrome at desktop and narrow window sizes; icons render and the bottom navigation is visible | No physical phone/tablet review, keyboard traversal, screen-reader review, or authenticated persistence through the visible controls |
| Accounts and text posts | Registration modal was visually reviewed; registration, persistent post creation, internal labeling, For You readback, like state, and feed refresh passed through the local dev proxy using temporary accounts | The visible registration/publish flow, follow/profile persistence, session expiry, authorization failures, account recovery, email/age policy, rate limiting, and deletion remain unverified |
| Profiles, follows, blocks, and feed actions | Source and persistence paths exist | Real multi-account behavior, block races/access boundaries, feed action persistence, cursor edge cases, and error/retry handling have not been verified in the browser |
| Account mute | Migration 0009 applied; source includes private mute state and filters on both feed endpoints; API/web builds and typechecks pass | Authenticated mute/unmute and feed refresh have not been exercised end-to-end. Mute should not alter follows, profile access, or messages. |
| Recommendation | Two-item authenticated API journey confirmed cold-start freshness, persisted like-derived preference, and one preference-driven rerank; all six synthetic scenario groups pass | This is not a representative relevance or latency study. No public-ready video exists; calibrated weights, query plans at realistic scale, raw-media feature extraction, trained model, and full exposure history remain missing. Video signal/cooldown/suppression paths are unverified. Duplicate-group suppression requires an input group ID; no production detector generates it. |
| Messages | Guest sign-in screen visually reviewed; a two-account API journey confirmed conversation creation, persistent send/read, and idempotent retry through the local dev proxy | Authenticated browser UI, unauthorized-account access/failure paths, blocking behavior, push delivery, retention, and operational encryption decisions remain unverified |
| Search and reports | Server-side text search and report submission are in source; a search index exists | Database has no published text corpus for a meaningful query plan; authorization/performance are unreviewed. Reports have no staffed queue, enforcement workflow, response target, account-report flow, or appeal path. |
| Video | Guest vertical empty state and direct sign-in action visually reviewed; local capture/file upload and owner-only preview paths exist | No public publishing: no server-side duration validation, scan, moderation operations, transcoding, segmented delivery, CDN, deletion propagation, or measured cost/playback quality |
| Smoothness and reliability | Acceptance targets are documented | No measured Core Web Vitals, representative-device media metrics, backup/restore exercise, deployment evidence, rollback rehearsal, or operational monitoring review |
| Privacy and launch operations | Product boundaries are documented | Account policy, message retention, report retention/review ownership, incident response, support, and production access policy remain incomplete |

## Flutter/Dart full migration snapshot — 2026-10-26

- The owner explicitly requested migration of the full project, including the server. Target architecture: Flutter client and Dart modular server, preserving PostgreSQL and `/api/v1`; NestJS and Angular remain parity references until replacement gates pass.
- The Flutter client in `apps/client` resolves dependencies and passes `flutter analyze`; Flutter Web release and universal Android debug builds pass. Native `android/` and `ios/` scaffolds exist. The latest APK is `apps/client/build/app/outputs/flutter-apk/app-debug.apk` (191,723,713 bytes; package `app.ionic.mobile`, label `Ionic`, min SDK 24, target SDK 36, universal arm64/armv7/x86_64); SHA-256 `DF8D0352F01E865C54656023E32B7A9F330C8FFC9AAD7DC71D9A225272172262`. AAPT confirmed app backup is disabled and cleartext networking is allowed only in the debug variant. The APK was installed and launched on a Pixel 6 API 35 emulator. The Web dev server started directly at `http://127.0.0.1:4201`; the Node proxy accepts `IONIC_API_PORT` and defaults to the legacy API on 3000.
- The current Dart source mounts all existing API module families: health/auth, For You, posts, profiles/social, messages, reports, and videos. Post/video labels are persisted; actual like/save preference updates are transaction-bound with the authoritative post action; message retries are idempotent; reports are duplicate-safe; and video uploads remain private in `processing`/`pending_review` with byte-range owner playback. These are source contracts except where noted below; media worker/moderation does not exist.
- PostgreSQL migrations 0001–0011 were applied locally; the Dart migration runner reported the schema up to date and Dart readiness reported the database ready. On the Android emulator, login, secure session persistence after force-stop/relaunch, `/auth/me`, For You HTTP 200, and a text-post publish/readback flow completed against the Dart API. A raw-string interpolation bug in the native cookie parser was corrected. The temporary test account and post were removed after verification. This does not verify the other Dart routes or production session interoperability.
- Existing password hashes use Node scrypt. Dart auth uses the same parameters (`N=16384`, `r=8`, `p=1`, 64-byte output), but cross-implementation login for an existing NestJS account remains unverified. PostgreSQL migrations 0001–0011 remain the database contract. The APK is a debug artifact configured for the emulator host address. iOS is scaffolded only and requires macOS/Xcode.
- On 2026-10-26, `flutter analyze` found no issues, Flutter Web release and Android debug APK builds succeeded, the APK installed/launched, and the local authenticated text/feed slice ran. These checks do not establish profile/follow, message, report, video, pagination, authorization-failure, accessibility, physical-device, or performance readiness. Keep `apps/api` and `apps/web` until the Dart server has route-by-route parity and core signed-in journeys work through Flutter. Android is first; iOS needs a macOS/Xcode validation pass.

## Recommendation system reality

The current MVP algorithm is a bounded deterministic baseline, not a production-scale machine-learning recommender. It uses a narrow keyword-based labeler for published text posts, structured preference features, bounded candidate sources, rule-based ranking, and creator/topic diversity controls. The current For You SQL source now excludes short video. Photo/voice attachment bytes are not labeled or used as recommendation signals. Labels and reason codes must stay internal.

The scenario runner verifies selected mechanics using hand-authored fixtures. Its metrics are not user-level relevance, unbiased ground truth, or evidence that the ranker is optimal. A two-item local rerank through the legacy API verifies that one like can influence a closely matched topic; it does not validate Dart parity or quality across a meaningful candidate pool. The latest Flutter-to-Dart slice confirms the For You endpoint responds and a post can be read back, but no preference-driven rerank was evaluated through Dart. A benchmark with synthetic candidate counts is not a realistic database or service latency measurement. Do not claim that Ionic implements TikTok's Monolith, Cuckoo embedding storage, MMoE, Kafka/Flink, streaming gradients, or production-scale retrieval; those remain future hypotheses with explicit evidence and privacy gates.

## Release assessment

**The local backend has limited evidence for account-backed text/feed, one-to-one message persistence, and a Flutter Android login/session/post flow; the app is still not verified as an end-to-end pilot.** The new native journey was run against local Dart/PostgreSQL on an emulator. Message persistence was verified earlier through the legacy API via the web proxy, not through Flutter/Dart. No public-ready video exists locally, and this review did not use a physical phone or exercise actual media processing.

The former 2026-11-06 video-inclusive closed-MVP date is superseded by the text-first direction and is not a commitment. The local legacy API has limited evidence for text, a simple preference-driven rerank, and basic messaging. Flutter Android has a narrower verified slice through Dart: sign-in, session restore, feed response, and post persistence. A person can install and inspect the debug build, but it is not yet a complete usable social product. Dart route parity, Flutter profile/follow and messaging, end-to-end image/voice authorization and playback, production media storage and deletion lifecycle, staffed report handling, account operations, representative ranking evaluation, measured performance, deployment/rollback, and privacy retention remain release gates.

## Anti-overclaim rules for future work

1. Report each feature as **source exists**, **build/typecheck passes**, **health endpoint responds**, **browser smoke reviewed**, **end-to-end behavior verified**, or **production operation verified**. Do not treat one level as the next.
2. A running API/database does not prove domain writes, authorization, pagination, or failure handling work.
3. Synthetic fixtures prove only the scenarios encoded in them. Do not present their ranking metrics as user satisfaction, calibration, or production quality.
4. A local private video preview is not video publishing. A stored report is not a moderation service.
5. A performance target is not a measurement. Record device class, network conditions, sample size, and the actual result before claiming smoothness.
6. Do not use one aggregate completion percentage. State the evidence and open gates by area.
7. Do not render internal taxonomy labels or recommendation rationales in the interface.
8. Before any release-readiness claim, verify the complete account-backed post/feed/message journey, attached-media authorization, safety/access boundaries, operational ownership, and mobile/desktop performance gates.

## Next execution focus

1. Keep the verified Android sign-in/session/feed/post baseline stable; exercise persisted like/save and generic feed controls through Flutter and the Dart API, confirming that the next feed response changes only according to the documented ranker contract.
2. Build a versioned, human-judged candidate set with cold-start, known-interest, adjacent-topic, negative-feedback, creator-diversity, and freshness cases. Compare retrieval coverage and rank order before tuning weights.
3. Inspect PostgreSQL retrieval plans and measure the same candidate pool and request path before/after each focused algorithm change. Keep synthetic metrics separate from human relevance judgments.
4. Close Flutter/Dart parity for profile/follow privacy, two-account messages, reports, and private-video authorization; verify both success and access-denied paths.
5. Verify the implemented private image/voice staging, validation, and parent authorization end to end; add deletion cleanup and measure image/audio payload behavior. Keep video deferred until processing, scanning, moderation, transcoding/delivery, deletion, and cost controls are demonstrated.

After each verified vertical slice, update this snapshot and [`ROADMAP.md`](ROADMAP.md) with the evidence, remaining gaps, and next concrete exit criterion.

## Previous implementation check — 2026-10-27 (before media attachment source)

- Source changes add a bounded public-post endpoint for signed-out reading, an authenticated `PATCH /profiles/me` contract in Dart and NestJS, and Flutter settings for profile editing, personalization pause/reset, muted/blocked account management, current-device sign-out, and light/dark appearance.
- Both recommendation implementations now retrieve only text posts. The Flutter theme defaults to charcoal dark and stores the appearance selection locally. These code paths have not been reviewed in a browser or emulator during this pass.
- `dart analyze` reported no issues for the Flutter client and Dart server. `npm run build` completed for `apps/api`. Flutter Web/APK build and database-backed checks were not completed for the current edits; no automated tests, user journeys, or performance measurements were run.
- The photo/voice product direction, tentative limits, privacy boundary, and optimization path were documented at this point, but no attachment schema, upload/read API, UI control, or playback code existed yet.
- Earlier 2026-10-26 APK/runtime evidence applies to that prior build only. It does not prove today's settings/profile/theme changes or the text-only retrieval change work end to end.

## Latest implementation check — 2026-10-27

- Migration `0012_image_voice_attachments.sql` adds private staged asset metadata and content/reply attachment links. It was applied to the dedicated local PostgreSQL database under the migration runner; the API now reports database readiness `ready`.
- Flutter composer source now selects up to four images, downsizes/re-encodes them through Flutter's `compute` API, and records one mono 16 kHz PCM voice note up to 60 seconds. Post and reply submission stage uploads first, then attach them atomically with the parent write. The reply composer clears its local media after successful submission and disables send/close while media is being processed or recorded.
- The Dart API accepts JPEG and canonical WAV only. It checks byte limits, JPEG signature/dimensions, decodes and re-encodes JPEG at up to 2048 px, validates WAV fields/duration, stores bytes under private opaque local keys, and authorizes each file read through its published parent/profile/block state. Attachment bytes are not ranking signals. The proxy now points to Dart by default; NestJS remains selectable on port 3000.
- `dart pub get` and formatting completed for the changed packages. `dart analyze` reported no issues for both Flutter client and Dart server. Flutter Web release and Android debug APK builds succeeded. The Web build emitted a WebAssembly compatibility dry-run warning from retained camera/video plugins and a Cupertino font warning; normal Web output completed. The NestJS build passed before the last Dart-only edits. No automated test suite, signed-in media journey, device recording/playback, or performance measurement was run.
- The Dart API returned `live: ok` and `ready` with database dependency `ready`. Chrome review showed the signed-out Home and sign-in dialog; no account, post, or media was created. The visible feed was empty, so the UI presented its empty state rather than sample content. This was visual review only, not a media journey or accessibility review.
- The local development API and Flutter Web proxy remain running on ports 3001 and 4200 for continued work.
- Development storage is local filesystem only. Upload/playback rate limits, aggregate per-parent byte caps, production object storage, scheduled cleanup after parent deletion, and moderation operation are still missing. Unattached staging records older than 24 hours are cleaned opportunistically on later upload. This slice is not public-media release-ready.

## Manual media smoke — 2026-10-27

- A temporary account completed registration, private image and voice uploads, post creation with an image, reply creation with voice, and anonymous readback through the local Dart API and PostgreSQL. The staged image URL returned 404 before attachment; published image and voice reads returned 200. The API normalized the synthetic 256×256 JPEG to 2,405 bytes and served a 1-second, 32,044-byte WAV attachment. The feed response included the image attachment.
- The temporary account, posts/reply, media rows and exact storage objects were removed. The generated JPEG/WAV fixtures were also deleted; verification returned zero rows for that account and zero corresponding local files.
- Flutter Web and Android builds, Dart analysis, and database readiness were verified earlier in this same implementation slice. Chrome showed the signed-out feed empty state. A later browser capture/control call was blocked because the computer-use tool could not confidently determine the current browser URL; therefore authenticated attachment rendering and playback controls were not visually verified. No microphone, physical device, automated suite, unauthorized private/block-parent case, or performance measurement was exercised.
- This confirms a local API/database media path only. It does not confirm production storage, end-user recording, attachment playback UI, deletion after parent deletion, rate limits, or public-media readiness.

## Home visual adjustment — 2026-10-27

- Flutter Home now opens with search, the create entry, and one feed. The “Bảng tin” heading and **Dành cho bạn / Đang theo dõi** tabs are removed. Signed-in Home still calls the personalized endpoint; the chronological Following route is retained but is not exposed as a Home mode.
- Dark-mode filled actions and the primary Create icon now use charcoal gray with white foregrounds; selected navigation and action emphasis are neutral gray. Light mode retains the blue action palette. Shared empty cards no longer show the sparkle tile.
- `dart format` completed, `dart analyze` reported no issues, and Flutter Web release and Android debug builds succeeded with this adjustment. The Web build still emits dry-run warnings from retained camera/video plugins and a Cupertino font warning. The browser still open on port 4200 serves the older process; a fresh Flutter debug preview now runs on port 4202 with API proxying to 3001. The updated rendering has not yet been visually reviewed in that fresh preview, and the new APK has not been installed on a device.

## Next execution focus

1. Return to Ionic's primary differentiator: build a versioned, human-judged text candidate set covering cold start, known interests, adjacent topics, negative feedback, creator diversity, and freshness. Keep human judgments separate from synthetic mechanics fixtures.
2. Measure current Dart candidate retrieval/ranking and PostgreSQL query plans on a fixed dataset before tuning weights. Record ranking quality and request latency with dataset size and environment; do not call unmeasured targets performance results.
3. Verify like/save and feed controls through Flutter against Dart, then confirm responses change according to the documented ranking contract.
4. Continue media validation on Android: picker and recorder, image/voice rendering and playback, upload failure recovery, and private/block authorization denial. Separately define media deletion lifecycle, production object storage, upload limits, and moderation operations before public-media release.
5. Exercise profile editing, personalization pause/reset, mute/block, messaging, and remaining post interactions end to end through Flutter and Dart/PostgreSQL.

## Self-assessment — 2026-10-27

This is a local development product with real implementations and limited end-to-end evidence. It is not ready for a public pilot or dependable everyday use. Do not report one completion percentage; use the evidence levels below.

| Area | Current assessment | Evidence and practical limit |
| --- | --- | --- |
| Flutter delivery | Buildable, but the latest visual change is not confirmed on a device. | `dart analyze` reported no issues; Flutter Web release and Android debug builds succeeded. The current debug APK was built after the Home adjustment but has not been installed/launched. The Web build has existing camera/video WebAssembly dry-run warnings and a Cupertino-font warning. |
| Home UI | Source now follows the single-feed/dark-neutral direction; visual acceptance remains open. | Home source removes the “Bảng tin” heading, two feed tabs, and the empty-state sparkle tile. The old preview at 4200 remained on its previous process; a new debug preview was started on 4202. Browser use is disabled in this assessment session, so that preview was not inspected. |
| Text account/feed/post | A narrow authenticated Android/Dart path has worked before this UI build; overall route parity is incomplete. | Earlier emulator evidence covered login, session restore, feed response, and text post publish/readback. Do not extend that result to profile, follow, messages, settings, failure recovery, or the current APK without rechecking. |
| Image/voice | Local API/database attachment flow works for a synthetic case; client/device flow remains unproven. | A temporary account uploaded an image and WAV, attached them to a post/reply, received 404 before staged publication and 200 after publication, and was fully cleaned up. Flutter image display, real picker/recorder, playback controls, Android device behavior, private/block denial, and failed-upload recovery are still open. |
| Recommendation | A meaningful deterministic prototype exists; relevance quality has not been established. | Current launch ranker uses sparse text labels, bounded PostgreSQL retrieval, preferences, and diversity rules. A versioned six-scenario Dart bootstrap evaluation now runs through the active labeler and ranker, but its judgments are AI-authored and hypothetical, not representative human/user feedback. No independently reviewed relevance set, retrieval-recall study, or realistic database/request latency study exists. Image/audio analysis, dense embeddings, MMoE, and online training are not implemented and are not MVP requirements. |
| Social and operations | Source coverage is broader than verified behavior. | Auth/profile/social/message/report/settings modules exist, but Flutter/Dart multi-account messaging, access-denial cases, report review, account recovery/deletion, retention, and incident/support operations remain incomplete or unverified. A report endpoint is not a staffed moderation workflow. |
| Media release | Development-only; not safe for public media use. | Local filesystem staging and basic validation exist. Production object storage, rate and aggregate-size limits, scheduled deletion propagation, scanning/moderation operations, recovery monitoring, and measured storage/delivery costs are release gates. |
| Reliability and smoothness | Unmeasured. | Builds and analyzer do not show that the app is smooth. No current Core Web Vitals, Android frame/jank, upload/playback network, accessibility, load, backup/restore, deploy, or rollback evidence is recorded. |
| Change control | A tracked GitHub baseline now exists; follow-up implementation changes remain local until reviewed and committed. | The project was initialized on `main` at commit `5f9ff45` and pushed to `origin/main` on 2026-10-27. |

### Practical answer

The APK is suitable for local installation and continued internal exploration, but this evidence does not support calling Ionic ready for real users or a beta. A narrow text account/post journey and synthetic media API journey have worked; the current full Flutter experience has not been exercised after the latest UI build. Public release is blocked by recommendation evaluation, unverified account-backed client journeys, operational moderation/privacy and account lifecycle, production media controls, measured performance/accessibility, and deployment/rollback readiness.

### Immediate next work

1. Verify the latest APK or the 4202 Web preview visually and exercise the current signed-in post journey; distinguish UI build from runtime behavior.
2. Replace or supplement the AI-authored seed with independently reviewed relevance judgments; measure candidate-source recall and PostgreSQL/request latency before changing ranking weights.
3. Verify like/save and generic feed controls through Flutter/Dart, including pause/reset and negative feedback; keep the resulting signals documented and reversible.
4. Close the image/voice Flutter and Android path, then verify profile/follow, messages, reports, and settings against Dart/PostgreSQL.
5. Keep release blockers visible and preserve the tracked Git baseline; do not add scale infrastructure or learned models before data quality justifies them.

## Recommendation evaluation slice — 2026-10-28

- Added `apps/server/data/recommendation/judgments-v1.json` with six fixed-pool cases and fictional Vietnamese text. The judgments are AI-authored hypothetical scenario labels; no user or telemetry data is included, and no independent reviewer has validated them.
- Added `apps/server/bin/evaluate_recommendation.dart`. The runner uses the production Dart text-label rules and ranker, and reports per-scenario P@K, recall@K, nDCG@K, creator/topic coverage, and repetition rates.
- The initial run exposed a real tier-order inversion: global diversity selection could place a fresh candidate above a deferred direct match. The first draft's text/grades were then revised to align with labels emitted by the actual keyword labeler, so its 0.972 macro nDCG@K is not comparable to the revised seed.
- Updated Dart selection to finish each relevance tier's diversity fallback before admitting the next tier, and bumped the default version to `ionic-deterministic-v2`. On the revised seed, macro nDCG@K is 0.996, P@K is 0.725, and recall@K is 0.952. These are scenario diagnostics, not evidence of improved real-user relevance and must not be used to tune weights.
- `dart analyze` reports no issues. The evaluation runner completed successfully. No automated tests, database path, Flutter UI, device flow, or performance benchmark were run in this slice.
- Next: independently review/expand the judgments, measure retrieval recall and PostgreSQL request latency on a fixed eligible dataset, then validate persisted like/save and feed-control updates through Flutter/Dart.
