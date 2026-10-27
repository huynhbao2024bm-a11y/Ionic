import type {
  ContentKind,
  ContentLabel,
  LabelDimension,
  LabelSource,
} from "./types.js";

export interface LabelProposal {
  readonly dimension: LabelDimension;
  readonly labelId: string;
  readonly confidence: number;
  readonly source: LabelSource;
}

export interface KeywordRule {
  readonly dimension: LabelDimension;
  readonly labelId: string;
  readonly terms: readonly string[];
  readonly minimumMatches?: number;
  readonly confidence: number;
}

export interface LabelContentInput {
  readonly taxonomyVersion: string;
  readonly kind: ContentKind;
  readonly text: string;
  readonly formatLabelIds: Readonly<Record<ContentKind, string>>;
  readonly suppliedLabels?: readonly LabelProposal[];
  readonly keywordRules?: readonly KeywordRule[];
  readonly declaredLanguageLabelId?: string;
}

const sourcePriority: Readonly<Record<LabelSource, number>> = {
  rule: 1,
  creator: 2,
  user_corrected: 3,
};
const labelDimensions: readonly LabelDimension[] = ["topic", "format", "language", "context", "lineage"];

function tokenize(value: string): string[] {
  return value
    .normalize("NFKC")
    .toLowerCase()
    .match(/[\p{L}\p{M}\p{N}]+/gu) ?? [];
}

function containsTokens(tokens: readonly string[], termTokens: readonly string[]): boolean {
  if (termTokens.length === 0 || termTokens.length > tokens.length) {
    return false;
  }

  for (let start = 0; start <= tokens.length - termTokens.length; start += 1) {
    if (termTokens.every((token, offset) => tokens[start + offset] === token)) {
      return true;
    }
  }

  return false;
}

function validateConfidence(confidence: number): void {
  if (!Number.isFinite(confidence) || confidence < 0 || confidence > 1) {
    throw new RangeError("Label confidence must be between 0 and 1.");
  }
}

export function suggestLabelsFromText(
  text: string,
  rules: readonly KeywordRule[],
): readonly LabelProposal[] {
  const tokens = tokenize(text);
  const proposals: LabelProposal[] = [];

  for (const rule of rules) {
    validateConfidence(rule.confidence);
    const normalizedTerms = rule.terms.map((term) => tokenize(term));
    const normalizedKeys = normalizedTerms.map((termTokens) => JSON.stringify(termTokens));
    const minimumMatches = rule.minimumMatches ?? 1;
    if (
      normalizedTerms.length === 0 ||
      normalizedTerms.some((termTokens) => termTokens.length === 0) ||
      new Set(normalizedKeys).size !== normalizedKeys.length ||
      !labelDimensions.includes(rule.dimension) ||
      !Number.isInteger(minimumMatches) ||
      minimumMatches < 1 ||
      minimumMatches > normalizedTerms.length
    ) {
      throw new RangeError("Keyword rule must have terms and a valid minimum match count.");
    }

    const matchedTerms = normalizedTerms.filter((termTokens) => containsTokens(tokens, termTokens));
    if (matchedTerms.length >= minimumMatches) {
      proposals.push({
        dimension: rule.dimension,
        labelId: rule.labelId,
        confidence: rule.confidence,
        source: "rule",
      });
    }
  }

  return proposals;
}

export function resolveContentLabels(
  taxonomyVersion: string,
  proposals: readonly LabelProposal[],
): readonly ContentLabel[] {
  if (taxonomyVersion.trim().length === 0) {
    throw new Error("Taxonomy version is required.");
  }

  const resolved = new Map<string, ContentLabel>();
  for (const proposal of proposals) {
    if (proposal.labelId.trim().length === 0) {
      throw new Error("Label ID is required.");
    }
    if (!labelDimensions.includes(proposal.dimension) || !Object.hasOwn(sourcePriority, proposal.source)) {
      throw new Error("Label dimension or source is invalid.");
    }
    validateConfidence(proposal.confidence);

    const key = JSON.stringify([proposal.dimension, proposal.labelId]);
    const next: ContentLabel = { ...proposal, taxonomyVersion };
    const current = resolved.get(key);
    if (
      current === undefined ||
      sourcePriority[next.source] > sourcePriority[current.source] ||
      (sourcePriority[next.source] === sourcePriority[current.source] &&
        next.confidence > current.confidence)
    ) {
      resolved.set(key, next);
    }
  }

  return [...resolved.values()].sort((left, right) => {
    const dimensionOrder = left.dimension.localeCompare(right.dimension);
    return dimensionOrder !== 0
      ? dimensionOrder
      : left.labelId.localeCompare(right.labelId);
  });
}

export function labelContent(input: LabelContentInput): readonly ContentLabel[] {
  const formatLabelId = input.formatLabelIds[input.kind];
  if (typeof formatLabelId !== "string" || formatLabelId.trim().length === 0) {
    throw new Error(`A format label is required for content kind '${input.kind}'.`);
  }

  const proposals: LabelProposal[] = [
    ...(input.suppliedLabels ?? []),
    ...suggestLabelsFromText(input.text, input.keywordRules ?? []),
    {
      dimension: "format",
      labelId: formatLabelId,
      confidence: 1,
      source: "rule",
    },
  ];

  if (input.declaredLanguageLabelId !== undefined) {
    proposals.push({
      dimension: "language",
      labelId: input.declaredLanguageLabelId,
      confidence: 1,
      source: "creator",
    });
  }

  return resolveContentLabels(input.taxonomyVersion, proposals);
}
