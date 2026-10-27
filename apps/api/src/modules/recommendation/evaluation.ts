import type {
  RankedCandidate,
  RelevanceTier,
} from "./types.js";

export type RelevanceGrade = 0 | 1 | 2 | 3;

export interface RankingEvaluationInput {
  readonly ranked: readonly RankedCandidate[];
  /** Complete judgments for the eligible candidate pool used to produce this ranking. */
  readonly relevanceByContentId: ReadonlyMap<string, RelevanceGrade>;
  readonly limit: number;
  readonly relevantAtOrAbove?: RelevanceGrade;
}

export interface RankingEvaluation {
  readonly rankerVersion: string | null;
  readonly evaluatedCount: number;
  readonly precisionAtK: number | null;
  readonly recallAtK: number | null;
  readonly ndcgAtK: number | null;
  readonly creatorCoverage: number | null;
  readonly topicCoverage: number | null;
  readonly repeatedCreatorItemRate: number | null;
  readonly repeatedTopicItemRate: number | null;
  readonly duplicateGroupItemRate: number | null;
  readonly tierCounts: Readonly<Record<RelevanceTier, number>>;
}

function validateInput(input: RankingEvaluationInput): void {
  if (!Number.isInteger(input.limit) || input.limit < 0) {
    throw new RangeError("Evaluation limit must be a non-negative integer.");
  }
  const threshold = input.relevantAtOrAbove ?? 1;
  if (!Number.isInteger(threshold) || threshold < 1 || threshold > 3) {
    throw new RangeError("Relevance threshold must be an integer from 1 to 3.");
  }

  const versions = new Set<string>();
  for (const item of input.ranked) {
    versions.add(item.rankerVersion);
    const grade = input.relevanceByContentId.get(item.candidate.id);
    if (grade === undefined || !Number.isInteger(grade) || grade < 0 || grade > 3) {
      throw new Error(`Missing or invalid relevance judgment for '${item.candidate.id}'.`);
    }
  }
  if (versions.size > 1) {
    throw new Error("A ranking evaluation must contain one ranker version.");
  }
  for (const [contentId, grade] of input.relevanceByContentId) {
    if (contentId.trim().length === 0 || !Number.isInteger(grade) || grade < 0 || grade > 3) {
      throw new Error("Relevance judgments require non-empty IDs and grades from 0 to 3.");
    }
  }
}

function discountedGain(grade: RelevanceGrade, rank: number): number {
  return (2 ** grade - 1) / Math.log2(rank + 1);
}

function coverage(uniqueCount: number, itemCount: number): number | null {
  return itemCount === 0 ? null : uniqueCount / itemCount;
}

function primaryTopicLabelId(item: RankedCandidate): string | undefined {
  let bestLabelId: string | undefined;
  let bestConfidence = -1;
  for (const label of item.candidate.labels) {
    if (
      label.dimension === "topic" &&
      (label.confidence > bestConfidence ||
        (label.confidence === bestConfidence && bestLabelId !== undefined && label.labelId.localeCompare(bestLabelId) < 0))
    ) {
      bestLabelId = label.labelId;
      bestConfidence = label.confidence;
    }
  }
  return bestLabelId;
}

export function evaluateRanking(input: RankingEvaluationInput): RankingEvaluation {
  validateInput(input);
  const threshold = input.relevantAtOrAbove ?? 1;
  const topItems = input.ranked.slice(0, input.limit);
  const tierCounts: Record<RelevanceTier, number> = {
    direct: 0,
    strong: 0,
    adjacent: 0,
    fresh: 0,
  };
  const creatorCounts = new Map<string, number>();
  const topicCounts = new Map<string, number>();
  const duplicateGroupCounts = new Map<string, number>();
  let relevantRetrieved = 0;
  let dcg = 0;
  let repeatedCreatorItems = 0;
  let repeatedTopicItems = 0;
  let duplicateGroupItems = 0;

  for (const [index, item] of topItems.entries()) {
    tierCounts[item.tier] += 1;
    const grade = input.relevanceByContentId.get(item.candidate.id) ?? 0;
    dcg += discountedGain(grade, index + 1);
    if (grade >= threshold) {
      relevantRetrieved += 1;
    }

    const creatorId = item.candidate.creatorId;
    const creatorCount = creatorCounts.get(creatorId) ?? 0;
    if (creatorCount > 0) {
      repeatedCreatorItems += 1;
    }
    creatorCounts.set(creatorId, creatorCount + 1);

    const topicLabelId = primaryTopicLabelId(item);
    if (topicLabelId !== undefined) {
      const topicCount = topicCounts.get(topicLabelId) ?? 0;
      if (topicCount > 0) {
        repeatedTopicItems += 1;
      }
      topicCounts.set(topicLabelId, topicCount + 1);
    }

    const duplicateGroupId = item.candidate.duplicateGroupId;
    if (duplicateGroupId !== undefined) {
      const groupCount = duplicateGroupCounts.get(duplicateGroupId) ?? 0;
      if (groupCount > 0) {
        duplicateGroupItems += 1;
      }
      duplicateGroupCounts.set(duplicateGroupId, groupCount + 1);
    }
  }

  const idealGrades = [...input.relevanceByContentId.values()]
    .sort((left, right) => right - left)
    .slice(0, input.limit);
  const idealDcg = idealGrades.reduce<number>(
    (total, grade, index) => total + discountedGain(grade, index + 1),
    0,
  );
  const totalRelevant = [...input.relevanceByContentId.values()]
    .filter((grade) => grade >= threshold)
    .length;
  const evaluatedCount = topItems.length;

  return {
    rankerVersion: input.ranked[0]?.rankerVersion ?? null,
    evaluatedCount,
    precisionAtK: evaluatedCount === 0 ? null : relevantRetrieved / evaluatedCount,
    recallAtK: totalRelevant === 0 ? null : relevantRetrieved / totalRelevant,
    ndcgAtK: idealDcg === 0 ? null : dcg / idealDcg,
    creatorCoverage: coverage(creatorCounts.size, evaluatedCount),
    topicCoverage: coverage(topicCounts.size, evaluatedCount),
    repeatedCreatorItemRate: coverage(repeatedCreatorItems, evaluatedCount),
    repeatedTopicItemRate: coverage(repeatedTopicItems, evaluatedCount),
    duplicateGroupItemRate: coverage(duplicateGroupItems, evaluatedCount),
    tierCounts,
  };
}
