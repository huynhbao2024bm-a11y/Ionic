import assert from "node:assert/strict";
import { applyPreferenceSignals } from "../dist/modules/recommendation/preference-profile.js";
import { buildRankerConfig } from "../dist/modules/recommendation/ranker-config.js";
import { evaluateRanking } from "../dist/modules/recommendation/evaluation.js";
import { rankCandidates } from "../dist/modules/recommendation/ranker.js";

const taxonomyVersion = process.env.RECOMMENDATION_TAXONOMY_VERSION?.trim() || "ionic-taxonomy-v1";
const nowMs = Date.now();
const config = buildRankerConfig(nowMs);

function label(dimension, labelId) {
  return { taxonomyVersion, dimension, labelId, confidence: 0.95, source: "rule" };
}

function post(id, creatorId, topic, ageHours, extra = {}) {
  return {
    id,
    creatorId,
    kind: "text",
    publishedAtMs: nowMs - ageHours * 3_600_000,
    labels: [label("topic", `topic.${topic}`), label("format", "format.text"), label("language", "language.vi")],
    eligible: true,
    visibleToViewer: true,
    ...extra,
  };
}

const scenarios = [
  {
    name: "explicit and learned design interest with adjacent exploration",
    limit: 6,
    profile: {
      explicitInterests: [{ taxonomyVersion, dimension: "topic", labelId: "topic.design" }],
      preferences: [{
        taxonomyVersion,
        dimension: "topic",
        labelId: "topic.design",
        sourceSummary: ["like"],
        score: 0.9,
        confidence: 0.9,
        updatedAtMs: nowMs,
        expiresAtMs: nowMs + 30 * 86_400_000,
      }],
      followingCreatorIds: ["creator.followed"],
      blockedCreatorIds: ["creator.blocked"],
      mutedCreatorIds: [],
      hiddenContentIds: [],
      hiddenLabels: [],
      lessLikeLabels: [],
      recentExposures: [],
    },
    candidates: [
      post("design-current", "creator.design-a", "design", 1),
      post("design-older", "creator.design-b", "design", 36),
      post("product-adjacent", "creator.product", "product", 2),
      post("creativity-adjacent", "creator.creative", "creativity", 3),
      post("followed-learning", "creator.followed", "learning", 4),
      post("fresh-cooking", "creator.cooking", "cooking", 0.5),
      post("blocked-design", "creator.blocked", "design", 0.25),
    ],
    grades: {
      "design-current": 3,
      "design-older": 3,
      "product-adjacent": 2,
      "creativity-adjacent": 2,
      "followed-learning": 1,
      "fresh-cooking": 0,
    },
    expectations: {
      before: [["design-current", "product-adjacent"], ["product-adjacent", "fresh-cooking"]],
      excluded: ["blocked-design"],
    },
  },
  {
    name: "cold start prioritizes fresh eligible posts",
    limit: 5,
    profile: {
      explicitInterests: [],
      preferences: [],
      followingCreatorIds: [],
      blockedCreatorIds: [],
      mutedCreatorIds: [],
      hiddenContentIds: [],
      hiddenLabels: [],
      lessLikeLabels: [],
      recentExposures: [],
    },
    candidates: [
      post("cold-1", "creator.one", "design", 0.25),
      post("cold-2", "creator.two", "learning", 1),
      post("cold-3", "creator.three", "product", 2),
      post("cold-4", "creator.four", "creativity", 8),
      post("cold-5", "creator.five", "writing", 48),
    ],
    grades: { "cold-1": 3, "cold-2": 2, "cold-3": 2, "cold-4": 1, "cold-5": 0 },
    expectations: { before: [["cold-1", "cold-2"], ["cold-2", "cold-3"]] },
  },
  {
    name: "access controls and near-duplicate suppression",
    limit: 10,
    profile: {
      explicitInterests: [],
      preferences: [],
      followingCreatorIds: [],
      blockedCreatorIds: ["creator.blocked"],
      mutedCreatorIds: ["creator.muted"],
      hiddenContentIds: ["hidden-post"],
      hiddenLabels: [{ taxonomyVersion, dimension: "topic", labelId: "topic.cooking" }],
      lessLikeLabels: [],
      recentExposures: [],
    },
    candidates: [
      post("allowed-post", "creator.allowed", "design", 1),
      post("blocked-post", "creator.blocked", "design", 0.1),
      post("muted-post", "creator.muted", "learning", 0.2),
      post("hidden-post", "creator.allowed-two", "product", 0.3),
      post("hidden-label-post", "creator.allowed-three", "cooking", 0.4),
      post("ineligible-post", "creator.allowed-four", "writing", 0.5, { eligible: false }),
      post("not-visible-post", "creator.allowed-five", "creativity", 0.6, { visibleToViewer: false }),
      post("similar-original", "creator.original", "design", 0.7, { duplicateGroupId: "same-story" }),
      post("similar-copy", "creator.copy", "product", 0.8, { duplicateGroupId: "same-story" }),
    ],
    grades: { "allowed-post": 2, "similar-original": 1, "similar-copy": 0 },
    expectations: {
      excluded: ["blocked-post", "muted-post", "hidden-post", "hidden-label-post", "ineligible-post", "not-visible-post"],
      duplicateGroups: { "same-story": 1 },
    },
  },
  {
    name: "less-like feedback lowers a topic without hiding it",
    limit: 2,
    profile: {
      explicitInterests: [],
      preferences: [],
      followingCreatorIds: [],
      blockedCreatorIds: [],
      mutedCreatorIds: [],
      hiddenContentIds: [],
      hiddenLabels: [],
      lessLikeLabels: [{ taxonomyVersion, dimension: "topic", labelId: "topic.cooking" }],
      recentExposures: [],
    },
    candidates: [
      post("less-topic", "creator.less", "cooking", 1),
      post("neutral-topic", "creator.neutral", "writing", 2),
    ],
    grades: { "neutral-topic": 2, "less-topic": 1 },
    expectations: {
      before: [["neutral-topic", "less-topic"]],
      included: ["less-topic", "neutral-topic"],
    },
  },
  {
    name: "creator and topic caps preserve variety when alternatives exist",
    limit: 4,
    profile: {
      explicitInterests: [],
      preferences: [],
      followingCreatorIds: [],
      blockedCreatorIds: [],
      mutedCreatorIds: [],
      hiddenContentIds: [],
      hiddenLabels: [],
      lessLikeLabels: [],
      recentExposures: [],
    },
    config: { maxPerCreator: 1, maxPerTopic: 1, maxConsecutiveTopic: 1 },
    candidates: [
      post("01-a-design", "creator.a", "design", 3),
      post("02-a-learning", "creator.a", "learning", 3),
      post("03-b-design", "creator.b", "design", 3),
      post("04-b-product", "creator.b", "product", 3),
      post("05-c-creativity", "creator.c", "creativity", 3),
      post("06-d-writing", "creator.d", "writing", 3),
    ],
    grades: {
      "01-a-design": 2,
      "02-a-learning": 2,
      "03-b-design": 2,
      "04-b-product": 2,
      "05-c-creativity": 2,
      "06-d-writing": 2,
    },
    expectations: { uniqueCreators: true, uniqueTopics: true },
  },
];

const signalKinds = ["like", "unlike", "save", "unsave", "follow", "unfollow", "comment", "share", "active_view", "skip", "more_like_this", "less_like_this", "hide"];
const signalWeights = Object.fromEntries(signalKinds.map((kind) => [kind, 0]));
signalWeights.like = 0.18;
signalWeights.unlike = -0.12;
signalWeights.save = 0.24;
signalWeights.unsave = -0.16;
const signalPolicy = {
  nowMs,
  halfLifeMs: 14 * 86_400_000,
  expiryAfterMs: 60 * 86_400_000,
  maxAbsoluteScore: 1,
  signalWeights,
};
const positiveSignals = [
  { idempotencyKey: "synthetic-like-once", taxonomyVersion, dimension: "topic", labelId: "topic.design", kind: "like", confidence: 0.8, occurredAtMs: nowMs },
  { idempotencyKey: "synthetic-save-once", taxonomyVersion, dimension: "topic", labelId: "topic.design", kind: "save", confidence: 0.9, occurredAtMs: nowMs },
];
const learned = applyPreferenceSignals([], [...positiveSignals, positiveSignals[0]], [], signalPolicy);
assert.equal(learned.features.length, 1, "like/save signals should update one feature per taxonomy label");
assert.equal(learned.appliedIdempotencyKeys.length, 2, "duplicate signal delivery should be ignored");
assert.ok(Math.abs(learned.features[0].score - 0.36) < 1e-12, "like/save contributions should use configured weights scaled by signal confidence");
assert.deepEqual(learned.features[0].sourceSummary, ["like", "save"]);
const paused = applyPreferenceSignals(learned.features, [
  { idempotencyKey: "synthetic-paused-like", taxonomyVersion, dimension: "topic", labelId: "topic.design", kind: "like", confidence: 1, occurredAtMs: nowMs },
], [], { ...signalPolicy, learningPaused: true });
assert.deepEqual(paused.features, learned.features, "pausing learning should retain existing preferences without applying new weight");

const learnedRanked = rankCandidates([
  post("learned-design", "creator.learned-design", "design", 24),
  post("learned-adjacent", "creator.learned-adjacent", "product", 1),
  post("learned-fresh", "creator.learned-fresh", "cooking", 0.5),
], {
  explicitInterests: [],
  preferences: learned.features,
  followingCreatorIds: [],
  blockedCreatorIds: [],
  mutedCreatorIds: [],
  hiddenContentIds: [],
  hiddenLabels: [],
  lessLikeLabels: [],
  recentExposures: [],
}, config, 3);
assert.equal(learnedRanked[0]?.candidate.id, "learned-design", "learned like/save preference should rank matching content ahead of fresh content");
assert.equal(learnedRanked[1]?.candidate.id, "learned-adjacent", "learned interest should enable adjacent-topic exploration");
const learnedMetrics = evaluateRanking({
  ranked: learnedRanked,
  relevanceByContentId: new Map([["learned-design", 3], ["learned-adjacent", 2], ["learned-fresh", 0]]),
  limit: 3,
});
process.stdout.write("like/save learning, idempotency, pause, and adjacent retrieval\n");
process.stdout.write("  checks: passed\n");
process.stdout.write(`  ranked IDs: ${learnedRanked.map((item) => item.candidate.id).join(", ")}\n`);
process.stdout.write(`  metrics: ${JSON.stringify(learnedMetrics)}\n`);

for (const scenario of scenarios) {
  const ranked = rankCandidates(scenario.candidates, scenario.profile, { ...config, ...scenario.config }, scenario.limit);
  const rankedIds = ranked.map((item) => item.candidate.id);
  const position = (id) => rankedIds.indexOf(id);
  for (const [first, second] of scenario.expectations?.before ?? []) {
    assert.notEqual(position(first), -1, `${scenario.name}: expected '${first}' in the ranking`);
    assert.notEqual(position(second), -1, `${scenario.name}: expected '${second}' in the ranking`);
    assert.ok(position(first) < position(second), `${scenario.name}: expected '${first}' before '${second}'`);
  }
  for (const id of scenario.expectations?.excluded ?? []) {
    assert.equal(position(id), -1, `${scenario.name}: ineligible '${id}' leaked into the ranking`);
  }
  for (const id of scenario.expectations?.included ?? []) {
    assert.notEqual(position(id), -1, `${scenario.name}: expected less-like content '${id}' to remain available`);
  }
  if (scenario.expectations?.uniqueCreators) {
    assert.equal(new Set(ranked.map((item) => item.candidate.creatorId)).size, ranked.length, `${scenario.name}: creator cap was not honored`);
  }
  if (scenario.expectations?.uniqueTopics) {
    const topics = ranked.map((item) => item.candidate.labels.find((itemLabel) => itemLabel.dimension === "topic")?.labelId);
    assert.equal(new Set(topics).size, topics.length, `${scenario.name}: topic cap was not honored`);
  }
  for (const [groupId, maximum] of Object.entries(scenario.expectations?.duplicateGroups ?? {})) {
    const count = ranked.filter((item) => item.candidate.duplicateGroupId === groupId).length;
    assert.equal(count, maximum, `${scenario.name}: expected ${maximum} item from duplicate group '${groupId}'`);
  }
  const metrics = evaluateRanking({
    ranked,
    relevanceByContentId: new Map(Object.entries(scenario.grades)),
    limit: scenario.limit,
  });
  process.stdout.write(`${scenario.name}\n`);
  process.stdout.write(`  checks: passed\n`);
  process.stdout.write(`  ranked IDs: ${rankedIds.join(", ")}\n`);
  process.stdout.write(`  metrics: ${JSON.stringify(metrics)}\n`);
}

process.stdout.write("These are synthetic scenario checks, not observed user relevance or launch evidence.\n");
