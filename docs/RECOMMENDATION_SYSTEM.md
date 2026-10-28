# Feed Recommendation System

## 1. Goals and constraints

Make the feed increasingly relevant to each person while keeping it easy to adjust. The ranker is a core product function: it labels eligible content internally, estimates topic and format interests from permitted signals, and orders candidates by match quality. Freshness, variety, and explicit user controls remain part of the ranking contract. Raw watch time or interaction rate alone is not the objective. The client never displays taxonomy labels, inferred interests, or per-item recommendation rationales.

Use four configurable relevance tiers to make the ranking behavior concrete:

1. **Direct match:** a followed creator or a direct item-level preference mapped internally to matching labels.
2. **Strong match:** a label with positive evidence and sufficient configured confidence, even without an explicit choice.
3. **Adjacent discovery:** a nearby topic/subtopic or format in the versioned taxonomy that extends a demonstrated interest.
4. **Fresh discovery:** other eligible, recent content; this is the main fallback when history is sparse.

Resolve membership from the strongest applicable tier. Keep confidence thresholds and the amount of exploration configurable; compare items within a tier using the score below.

Hard eligibility rules apply before these tiers. The 3–5–10–25 position schedule remains a possible way to allocate positions across tiers, but its exact meaning and ratios are not fixed until evaluated. It is not a guarantee of item counts or a claim that a trained model exists.

## 2. Candidate pipeline

1. **Eligibility:** the text-first For You endpoint removes unpublished, deleted, unlabelled, inaccessible, hidden, muted-creator, and either-direction blocked posts before returning them. Candidates must be public, published text posts. Following applies mutes, blocks, and per-user hides in SQL. Mute is an explicit feed-level exclusion and does not change follow or message access. Video candidates are excluded until the later video phase.
2. **Candidate retrieval:** the API builds bounded result pools from eligible public text posts: followed creators, exact matches to explicit or sufficiently confident positive preference labels, topic matches adjacent to sufficiently confident learned interests, and newest eligible items. It takes up to the configured candidate limit from each source, removes duplicate IDs, then interleaves source positions deterministically and caps the merged set at the same limit before ranking. Source availability is not a feed quota: the ranker still applies relevance tiers and diversity rules. This lets older followed or label-matched items reach ranking. The pool size is bounded; database scan cost still needs a measured query plan. The source mix is an initial retrieval hypothesis, not a calibrated ratio.
3. **Deduplicate:** exact ID uniqueness comes from the content table. Similarity/repost grouping and full rendered-impression history are not implemented. Video repeat suppression is dormant with the deferred video flow.
4. **Match and tier:** the deterministic ranker compares active versioned labels to explicit more/less controls, bounded preference features, and followed creators, then assigns direct, strong, adjacent, or fresh tier.
5. **Score and diversify:** rank inside each tier by available match, follow, freshness, and exploration components, subtract configured negative/repetition penalties, then apply per-creator, primary-topic, and consecutive-topic caps. Quality is not currently scored because no calibrated quality feature is supplied.
6. **Return:** send cursor-paginated text posts and action state. The For You cursor carries an as-of cutoff, last item, and a digest of the ordered content IDs; if ranking produces a different sequence on the next request, reject the stale cursor so the client can restart cleanly. The digest contains no user features or content labels. Ranker version and reason codes stay internal; no labels, score, or per-item rationale is sent to the client. The text-first MVP does not collect video events.

Safety and authorization are hard gates, never score bonuses that can be outweighed.

## 3. Content labeling

The intended taxonomy supports multiple internal labels across topic/subtopic, format, language, context, and content lineage. The text-first MVP labels published post text with `format.text` and the small keyword ruleset can add design, software, product, writing, learning, creativity, how-to context, and Vietnamese-language labels. Attached photos and voice notes are delivered as media but their bytes are not analyzed or used for ranking in this release; video captions and video media also remain outside scope. Rules emit confidence and taxonomy version. A small, version-scoped topic adjacency map connects the current topic vocabulary for adjacent discovery; it is a provisional editorial graph, not a claim of semantic similarity learned from users. This starter vocabulary has limited recall and is not deep semantic understanding. Computer vision, speech transcription, image features, learned labels, and lineage labels are not implemented. Never render labels on posts, profiles, or settings surfaces. Low-confidence labels have less influence and are not used to infer sensitive traits.

Labeling a person's published post makes it searchable and rankable for others; it does not by itself count as evidence that the author wants to view more of that topic. Keep creator activity separate from the viewer preference profile.

Operational properties such as visibility, moderation, upload processing, and blocks are eligibility states, not recommendation labels. User-interest features use the same topic/format/language taxonomy and summarize explicit preferences and eligible feed behavior. They do not copy private messages, credentials, precise location, or raw text entry into the preference profile.

### MVP translation of the supplied TikTok/Monolith reference

| Reference layer | Ionic MVP implementation | Deferred beyond the core release |
| --- | --- | --- |
| Content feature extraction | Versioned, internal sparse labels from text-post content; the same classifier output is used by retrieval and ranking. | Video-caption labels, frame-level vision, audio transcription, learned semantic labels, and media embeddings. |
| User/content representation | PostgreSQL features keyed by taxonomy label with bounded score, confidence, recency, and expiry; this is a sparse preference vector, not a dense embedding. | Dense user/content embeddings, Cuckoo/collisionless embedding tables, and vector-index operations. |
| Retrieval | Bounded SQL sources for followed creators, explicit/learned label matches, adjacent topics, and fresh eligible text posts. | Two-tower retrieval, beam search, large candidate pools, and high-scale serving claims. |
| Filtering | Server-side publication, visibility, block/mute/hide and active-label checks plus exact-ID deduplication. | Video repeat suppression, Bloom filters, production near-duplicate detection, and large-scale moderation models. |
| Ranking and re-ranking | Deterministic relevance tiers and configurable scores, followed by creator/topic diversity and exploration rules. Likes/saves update preference features in the same transaction. | MMoE or other learned multi-task rankers and online gradient training. |
| Behavioral updates | Like/save transitions and generic more/less controls update sparse features synchronously and respect pause/reset controls. | Video active-view/skip, impression streams, Kafka/Flink, and minute-based online training; larger event systems require measured volume and operating need. |

This keeps the algorithm's essential data path real in the MVP while avoiding a misleading claim that a static keyword match is computer vision or deep semantic understanding. The reference's numerical scale, thresholds, and private TikTok implementation details are not treated as Ionic requirements.

## 4. Behavior signals

| Signal | Initial interpretation | Ranking treatment |
| --- | --- | --- |
| More / less similar content | Explicit item-level feedback mapped internally to eligible labels | Bounded preference update; user can reverse it with later feedback, pause, or reset. |
| Follow | Interest in a creator and nearby topics | Strong positive evidence; remove or reduce on unfollow/mute. |
| Like / unlike | Explicit domain state transition on a labeled item | Configurable positive / negative feature contribution, applied once with the unique reaction transition. |
| Save / unsave | Explicit domain state transition on a labeled item | Configurable positive / negative feature contribution, applied once with the unique bookmark transition. |
| Comment or share | Ambiguous active interest | Reply is durable but defaults to zero ranking weight; share is not implemented. |
| Rendered impression | Exposure opportunity | Not positive preference on its own. |
| Active video playback | Possible sustained attention | When at least 50% of the player is visible and foreground playback accumulates 3 seconds, apply the configurable `active_view` signal. Pause, buffering, and background-tab time do not count. |
| Fast video skip | Possible lack of interest | If foreground playback accumulated at least 800 ms but less than 3 seconds before the player leaves the visible area, apply the configurable weak `skip` signal. A missing/failed measurement is not a skip. |
| Less like this | Explicit negative preference | Apply a configured negative score to matching internal labels; it is not an implicit hide action. |
| Report or block | Safety/account action | Handle through eligibility and trust workflows, not as ordinary dislike evidence. |

Do not require or expose a topic-interest questionnaire. Authenticated like/save transitions and generic more/less controls can update the profile; replies remain neutral. Video-event ingestion is deferred with video. Recommendation feature and control rows store only the documented identifiers, signal source, scores, confidence, and timestamps; they expire under the documented retention policy and are removed on personalization reset. Thresholds and weights are provisional and must be calibrated from representative data. Maintain confidence and recency for every derived feature. Apply bounded contribution and decay; broader endpoint abuse/rate protections remain a release gap.

## 5. Ranking formulation

For eligible candidate `i` and viewer `u`, a conceptual score within its tier is:

```text
score(u, i) =
    weighted_mean(
      w_topic * topic_match(u, i),
      w_format * format_match(u, i),
      w_language * language_match(u, i),
      w_context * context_match(u, i),
      w_social * relationship_match(u, i),
      w_freshness * freshness(i),
      w_quality * calibrated_quality(i),
      w_explore * exploration(i, u)
    )
  - w_negative * negative_preference(u, i)
  - w_repetition * repetition(u, i)
```

Use the formula to compare items within a relevance tier. `weighted_mean` divides by the sum of available positive weights, so an absent optional quality value does not count as a zero. In the current deterministic implementation, calculate label match from taxonomy overlap and preference confidence, include explicit follow/interest matches and freshness, then apply configured negative-preference and repetition penalties. If an active less-like control or negative feature exists, the negative-preference weight must be greater than zero. Adjacent/fresh status supplies the exploration component within its tier. A “less like this” control applies immediately to matching labels; learned negative evidence is confidence-weighted and decays. Keep weights configurable and do not ship arbitrary hand-picked percentages as if validated. Aggregate quality can enter the score only after it is normalized and shown not to reward raw popularity alone. Apply eligibility and hard user controls before scoring. Then diversify in relevance-tier order: a diversity cap may defer an item within its tier, but a lower tier must not leapfrog deferred higher-tier candidates. Sponsored content is out of scope for the initial release.

When preference evidence is unavailable, do not fabricate a personalized score. Use the fresh-discovery tier and Following view. Version every ranker configuration and taxonomy; the service retains its version with each result and only matches labels and preference features on the active taxonomy version. Migrate preference controls before activating a new taxonomy version. Changes can then be compared and rolled back.

## 6. Preference profile

- Represent interests as versioned taxonomy labels with bounded scores, confidence, a coarse source summary, last-updated time, and configurable expiry.
- Seed from eligible events and generic item feedback; update with type-specific weights, recency decay, and contribution caps. Do not require a topic-selection onboarding flow.
- Keep topic, format, and language preferences separate where evidence permits.
- A new “more,” “less,” or “hidden” control replaces the previous control for that exact versioned label; clearing it removes all three states for that label.
- Treat hide, mute, block, moderation, and authorization as hard eligibility constraints. A generic “less similar content” control is a bounded negative ranking score and is not an implicit hide.
- Provide inspect/tune/pause/reset controls. Reset invalidates derived profile and relevant caches; future learning begins from the new state.
- When learning is paused, keep the domain action but skip its feature update. Do not queue it for replay after resume. Existing learned features and explicit controls remain active until reset or expiry.
- Do not infer protected characteristics, health status, political affiliation, precise location, or other sensitive traits for ranking.

## 7. Diversity and repetition

Avoid repetition at several levels, not merely exact video IDs:

- Exact content and recent creator exposure cooldown.
- Repost/near-duplicate media or text detection, using a conservative similarity threshold and human/report correction path.
- Per-window creator cap.
- Per-window topic/subtopic cap, with a limit on consecutive items from the same topic family.
- Format/language mix where compatible with user preferences and accessibility.
- Suppress content already seen recently, with an explicit “show again” user control if product policy allows.

Initial caps and cooldown lengths must be configuration and measured on representative data. For a short candidate pool, relax soft constraints in this order: topic cap, creator cap, then consecutive-topic cap. Never relax privacy, block, moderation, or authorization constraints.

The current default diversity limits are 3 items per creator, 4 per primary topic, and 2 consecutive items from one topic. The ranker relaxes topic cap first, then creator cap, then consecutive-topic cap. It does not have exposure history yet, so repetition penalties from prior impressions remain zero.

## 8. Thresholds and calibration

Avoid universal raw dwell thresholds: a two-second text read and a two-second long-video view are not equivalent. For each signal:

- define measurement semantics, active-view conditions, and minimum quality;
- normalize by item format and duration;
- record uncertainty and missingness;
- calibrate thresholds using labeled/validated data and cohort analysis;
- version thresholds and support rollback.

### MVP operational defaults (unvalidated)

The initial API configures a 500-candidate bound; 1-day freshness half-life; 14-day preference half-life; 60-day feature expiry; 0.55 minimum preference confidence; and 0.18 strong-match threshold. Available score components start with equal weights, except quality weight is 0. Signal defaults are like +0.18, unlike -0.12, save +0.24, unsave -0.16, active view +0.05, skip -0.03, and reply 0; values are configurable via environment. Active-view and skip thresholds are 3,000 ms and 800 ms respectively. These are conservative bootstrapping defaults for integration, not optimized or validated weights. Do not infer predictive quality from them. Tune only after building an offline dataset and measuring relevance, negative feedback, safety, diversity, and latency.

Likes/saves and their undo transitions update per-label preference features inside the same transaction as their authoritative domain action. Qualified video events use an idempotent event row and update features in the same transaction; a pause is checked under a user-setting row lock before storing or applying them. No action observation is queued. Reset clears feature rows, explicit more/less controls, and retained video-signal rows, while preserving domain actions and hidden-item records.

### Current integration limits

- For You and Following return action counts plus the viewer's own like/save state; internal taxonomy and scores are omitted. Both are text-only for the first release, and both exclude creator accounts the viewer has muted. Short-video eligibility, ranking, and event paths are deferred and must remain outside launch navigation and results.
- For You pagination recomputes the bounded ranking snapshot and rejects a cursor if the ordered candidate IDs changed; the client restarts the feed on the stale-cursor response. The Dart API's basic For You request and a text post readback were exercised from Flutter Android against local PostgreSQL, but pagination stability and full candidate/ranking parity are not yet verified.
- Candidate retrieval now includes followed-creator, exact positive-label, adjacent-topic, and fresh sources in a bounded result pool with deterministic deduplication/interleaving. This is structured-label retrieval, not semantic search; the synthetic scenario runner exists, while representative recall judgments and feed query-plan measurements remain future work.
- The first release has no rendered-impression history, text-dwell/skip collection, quality model, duplicate-similarity detector, trained embeddings, MMoE, online gradient updates, Kafka, or Flink. Older video active-view/skip and repeat-suppression code is retained for a later phase, but short videos are excluded from current For You candidate SQL and are not a launch signal. User-uploaded videos still do not transition into a public-ready state.
- The first taxonomy is rule-based and reads post text or video captions only. All output should be treated as weak metadata; users must never see its labels or be described through them.
- PostgreSQL migrations 0001–0011 are applied locally. On 2026-10-26, the Dart migration runner reported the schema up to date, readiness reported PostgreSQL ready, and the Android app completed sign-in/session restore, a For You request, and text-post publish/readback. On 2026-10-27, Dart analysis passed for both server and Flutter client, and the NestJS API build passed after guest-feed, profile/settings, and theme source changes. This confirms only source/build status and the earlier narrow Dart path; current settings behavior, persisted feedback updates, preference-driven reranking, and ranking quality still need verification.

Threshold crossings can classify evidence (for example, meaningful view vs. quick pass), but should not independently determine eligibility or sensitive user profiles.

## 9. Evaluation and rollout

### Current local performance reference

On 2026-10-23, the pure ranker completed a synthetic request with 1,800 candidates, 180 preference features, 900 recent exposures, and an 80-item result in a median 11.87 ms on the development machine (eight runs; observed range 9.00–19.51 ms). This is an implementation reference, not a production latency target.

A separate diversity-selection microbenchmark compared scan-based selection with indexed counters over synthetic candidates distributed across 800 creators and 120 topics (nine runs per case):

| Ranked candidates | Requested items | Scan median | Indexed median |
| ---: | ---: | ---: | ---: |
| 1,000 | 20 | 0.11 ms | 0.14 ms |
| 1,800 | 80 | 0.24 ms | 0.11 ms |
| 20,000 | 500 | 1.15 ms | 2.27 ms |
| 50,000 | 1,000 | 426.80 ms | 10.10 ms |

The results vary with pool and output size. Keep the simpler scan for the current bounded feed-page request path; revisit with representative traffic before adding a threshold or changing the implementation.

On 2026-10-24, `npm run inspect:post-search --prefix apps/api` confirmed the partial GIN search index exists. The dedicated local database currently has zero published text posts, so PostgreSQL estimated a tiny relation and selected other existing indexes for its plan; this gives no evidence about search latency or GIN selection at realistic volume. The command reports planner estimates only and intentionally does not run `EXPLAIN ANALYZE` or read post bodies.

### Offline

- Candidate coverage, freshness, relevance labels, calibration, and ranking stability. The core evaluation helper reports precision@k, recall@k, nDCG@k, creator/topic coverage, repetition, duplicate-group rates, and tier counts from a versioned set of eligible candidate judgments.
- Run `npm run evaluate:recommendation --prefix apps/api` for deterministic scenarios covering like/save feature updates, idempotency, pause behavior, adjacent exploration, cold-start ordering, blocked/muted/hidden/ineligible filtering, suppression when fixtures supply a shared duplicate-group ID, soft “less like this” ranking, and creator/topic caps. No production duplicate detector currently generates those group IDs, and real exposure history is not persisted or supplied to ranking. On 2026-10-24 with the default `ionic-deterministic-v1` configuration, the synthetic fixtures produced nDCG@6 0.931 / precision@6 0.833 / recall@6 1.0 for the explicit-interest scenario and nDCG@5 1.0 / precision@5 0.8 / recall@5 1.0 for cold start; all scenario assertions passed. These hand-authored labels and outputs only verify expected mechanics; they are not measured user relevance, unbiased ground truth, or a basis for tuning production weights.
- Before calibration, assemble a privacy-reviewed and representative judgment set with multiple users, candidate-source coverage, negative-control cases, and an independent review of grades. Do not log message contents or infer sensitive traits to build it.
- The bootstrap set at `apps/server/data/recommendation/judgments-v1.json` contains six fixed-pool scenarios for cold start, explicit and learned interests, adjacent topics, negative feedback, creator/topic diversity, and freshness. Run it from `apps/server` with `dart run bin/evaluate_recommendation.dart`. It passes candidate text through the active text labeler, then ranks with the active Dart implementation. Its AI-authored hypothetical judgments are for regression analysis only; they are not human/user relevance data, retrieval-recall evidence, or grounds for production weight tuning. Replace or supplement them with independently judged, privacy-reviewed examples before calibration.
- Diversity: unique creators/topics, concentration, and near-duplicate rate.
- Safety: ineligible-item leakage must be zero in test fixtures and monitored production checks.
- Counterfactual and cohort analysis, with privacy-preserving access controls.

### Online

- User-reported usefulness/satisfaction, hides/reports, negative feedback, creator/topic diversity, latency, and operational health.
- Watch time and interaction are diagnostics only, balanced against negative outcomes and quality.
- Use limited experiments, guardrails, holdouts where ethical, and an immediate rollback path.
- Do not A/B test away blocks, privacy rights, accessibility, moderation, or user control.

## 10. Cold start and fallback

- Start without a forced interest questionnaire; let eligible feed behavior and generic item feedback improve relevance over time.
- Use safe, fresh, diverse public content for cold start; avoid importing contact lists without explicit consent.
- Fallback order: eligible followed content, then safe fresh content, then a clear empty state.
- If preference services fail, do not fabricate a personalized profile; return the safe fallback with observability.

## 11. Future scale design — Monolith-inspired, not MVP scope

The design direction is to grow from the current bounded deterministic ranker into a staged, multi-source recommendation system as Ionic earns real, permissioned data and demonstrates a need. This is a future architecture hypothesis inspired by published recommender-system work. It is not a claim that TikTok's current production For You pipeline uses these exact components. A paper by ByteDance researchers describes Monolith as a real-time recommendation system with a collisionless embedding table, expirable/frequency-filtered embeddings, and streaming training infrastructure; it does not establish that every mechanism below is used by TikTok.

The MVP ranker can accept a short video only after the current asset state says `ready` and the content is public and published; the existing local uploader does not yet produce that state. A later media phase must also require the rendition manifest and moderation checks to be ready. Segmenting/transcoding improves delivery and device/network fit; it is a media reliability/cost choice, not a preference signal. Current playback telemetry is limited to qualified active-view/fast-skip outcomes; completion, per-position impressions, and broader playback analytics remain out of ranking. Serverless orchestration, object storage, and CDN choices belong to the media architecture in `ARCHITECTURE.md`; no provider or vendor-specific ranker integration is implied.

### Future pipeline

1. **Content representation:** extract internal topic, format, language, and context features from permitted post text and media metadata. Later, add speech transcription and visual content features for approved video only where policy, consent, moderation, and operating capacity permit. Do not infer identity, face emotion, health, politics, or other sensitive traits for ranking. Keep source, model/taxonomy version, confidence, and correction history.
2. **Preference representation:** build a revisable, bounded user representation from eligible feed actions and generic feedback. A vector/embedding may complement the structured feature profile; it must not turn inferred interests into a permanent identity or use private-message bodies, precise location, credentials, or raw keystrokes.
3. **Candidate retrieval:** combine candidates from followed creators, structured-label matches, fresh eligible items, and (only after offline quality/latency evidence) embedding-based retrieval such as a two-tower model with an approximate-nearest-neighbor index. Retrieval must remain bounded and recall-measured. Beam search, a particular candidate count (including 100,000), and a particular index are implementation options, not requirements.
4. **Eligibility and filtering:** apply server authorization, moderation, hide/block/mute controls, recent-seen suppression, exact/near-duplicate handling, and operational availability before ranking. Probabilistic ranking can never reinstate filtered content.
5. **Fine ranking:** start with a transparent deterministic ranker and validated calibration. If sufficient representative labels and online/offline evaluation later justify it, evaluate a multi-task model for distinct outcomes (e.g. useful completion, save, negative feedback), with quality and safety guardrails. MMoE is one candidate architecture, not a default requirement; do not optimize raw watch time or engagement alone.
6. **Re-ranking:** diversify creators, topics, formats, and freshness; preserve exploration and a healthy cold-start path. Keep repetition, user controls, and safety as constraints/guardrails, not as hidden business targets.
7. **Feedback loop:** first use idempotent domain events plus bounded asynchronous aggregation/outbox processing. Introduce a durable event stream (Kafka/Flink or equivalent) only when measured volume/latency requires it and retention, deletion, replay, and operational ownership are solved. Near-real-time profile refresh can precede online gradient training. Any learned update needs data-quality gates, offline evaluation, staged rollout, model/version logging, rollback, and user reset/deletion propagation. A one-minute update interval is not a requirement.

### Data structure and scale choices

Do not copy a “Cuckoo hashmap” or collisionless embedding implementation by name alone. Benchmark the actual access pattern, memory, update/delete semantics, expiry, collision behavior, and recovery needs before selecting an embedding store. A collisionless embedding table with expiration/frequency controls is a research/industry reference point; ordinary bounded tables or an established vector index may fit Ionic better at its scale.

### Gates before implementation

- The 14-day MVP remains on the existing deterministic in-process ranker; no embedding model, MMoE, Kafka/Flink, or online training dependency is introduced for that target.
- First establish stable authorized event semantics, opt-out/pause/reset, retention/deletion propagation, content eligibility, and a privacy review.
- Collect a representative dataset only for documented purposes; assess coverage, label bias, language/format cohorts, and candidate recall before selecting learned retrieval or ranking.
- Compare new systems against the versioned baseline on relevance/usefulness, diversity, harmful/ineligible exposure, negative feedback, latency, cost, and reliability. Ship only with rollback and fallback paths.

**Reference:** [Monolith: Real Time Recommendation System With Collisionless Embedding Table (ByteDance researchers, 2022)](https://arxiv.org/abs/2209.07663). Its publication and open-source implementation are evidence for a system design, not verification of TikTok's proprietary current production pipeline.
