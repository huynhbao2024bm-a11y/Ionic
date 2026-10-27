# Project Instructions

## Evolving product direction

This project is exploring a social app that brings together text publishing and reading, short-video discovery, personal profiles and social connections, and private messaging. This is a working direction, not a frozen scope.

The discovery experience may use multiple behavior signals and multi-dimensional content labels to balance exploration with increasing relevance across the feed, while reducing repeated items and overly similar topics. The exact signals, consent and retention rules, use of machine learning, percentages, thresholds, and meaning of any staged sequence are still product decisions. Do not copy the initial pitch verbatim into requirements or treat unvalidated mechanics as permanent.

Use the product documents as the current draft. Before implementing a choice that locks in recommendation data, privacy behavior, or ranking semantics, surface material assumptions for user review. When the direction is confirmed, update the relevant canonical documents and decision log together. Keep safety, privacy, accessibility, and user controls as hard boundaries.
These instructions apply to all work in this repository. Follow them together with the canonical design documents linked below. If a request conflicts with a documented security, privacy, or product invariant, stop and explain the conflict before changing behavior.

## Source of truth

- Product scope and acceptance criteria: [`docs/PRODUCT_REQUIREMENTS.md`](docs/PRODUCT_REQUIREMENTS.md).
- Architecture and module boundaries: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).
- Data model and event semantics: [`docs/DATA_MODEL.md`](docs/DATA_MODEL.md).
- Feed ranking, exploration, and diversity: [`docs/RECOMMENDATION_SYSTEM.md`](docs/RECOMMENDATION_SYSTEM.md).
- Privacy and security: [`docs/SECURITY_PRIVACY.md`](docs/SECURITY_PRIVACY.md).
- Delivery sequence: [`docs/ROADMAP.md`](docs/ROADMAP.md).
- Decisions and open assumptions: [`docs/DECISIONS.md`](docs/DECISIONS.md).
- Dated evidence and known gaps: [`docs/PROJECT_ASSESSMENT.md`](docs/PROJECT_ASSESSMENT.md). Read before implementation and update after new verification; it is a status snapshot and does not override the canonical product or engineering contracts above.

When changing a behavior or contract, update its canonical document in the same change. Do not silently redefine a requirement in code or duplicate a competing specification.

## Non-negotiable product invariants

1. The client is Flutter. Prioritize a native-installable Android release first, then validate the shared iOS client on macOS/Xcode. Keep the responsive PWA as a supported browser client; a web build does not prove native readiness.
2. Text posts, short videos, profiles/follows, and direct messages are distinct product capabilities with clear module ownership.
3. The feed is not a pure engagement-maximizer. Ranking must account for explicit user controls, relevance, freshness, safety, and topic/creator diversity.
4. Recommendation stages and values such as 3–5–10–25 are configurable hypotheses. Confirm their intended units, ratios, and thresholds before locking them into code; never weaken safety or user controls to improve engagement.
5. Dwell time, skips, and other behavioral signals are probabilistic evidence, never proof of a user's identity, sensitive traits, or intent.
6. Collect only documented events needed for a product purpose. Do not record message contents, raw keystrokes, or precise location as recommendation signals.
7. Provide controls to tune or reset personalization and to report, block, mute, or hide content/accounts.
8. Enforce authorization and privacy on the server. Never rely on client-side checks for access control.
9. Keep media private until authorized publication; validate uploads and use asynchronous processing.
10. Do not add dark patterns, undisclosed sponsored ranking, or engagement targets that override safety and user controls.

## Engineering rules

- Preserve the modular-monolith boundaries in `docs/ARCHITECTURE.md`; modules own their application logic and persistence access.
- Use Dart with sound null safety for the Flutter client and server. Validate all external input at API boundaries and return stable, documented error shapes.
- Use migrations for database schema changes. Migrations must be reviewed for data safety and have a documented rollout/rollback approach when destructive.
- Make event ingestion idempotent. Never use an analytics event as the authoritative record for a follow, message, reaction, or other domain action.
- Keep secrets out of source control, logs, test fixtures, and client bundles. Use environment-based secret management and provide only safe example values.
- Treat user-generated text and media as untrusted input. Encode output, restrict upload types and sizes, and apply moderation/reporting controls.
- Add or update focused tests for changed behavior, including authorization, boundary conditions, and failure paths where relevant.
- Run the narrowest relevant formatter, lint, type-check, and tests available. Report commands and any validation that could not be run.
- Do not invent infrastructure, packages, API contracts, or current behavior. Inspect the repository first and record new architectural decisions in `docs/DECISIONS.md`.
- Make focused changes. Do not introduce a distributed service, machine-learning dependency, or data collection field without a documented requirement and operational rationale.

## Delivery expectations

- State assumptions explicitly in documentation and code reviews.
- Keep API contracts and data retention aligned across client, API, workers, and documentation.
- Update the relevant design document whenever implementation changes a user-visible contract, data event, ranking rule, or security boundary.
- Summarize completed work and validation in Vietnamese for this project. Technical source code and design documents may be in English.
