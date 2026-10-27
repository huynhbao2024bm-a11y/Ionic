import type {
  ExplicitInterest,
  LabelDimension,
  TaxonomyLabelRef,
} from "./types.js";

export type LabelControl = "more" | "less" | "hidden" | "none";

export interface PreferenceControlState {
  readonly explicitInterests: readonly ExplicitInterest[];
  readonly lessLikeLabels: readonly TaxonomyLabelRef[];
  readonly hiddenLabels: readonly TaxonomyLabelRef[];
}

const dimensions: readonly LabelDimension[] = ["topic", "format", "language", "context", "lineage"];

function controlKey(reference: TaxonomyLabelRef): string {
  return JSON.stringify([reference.taxonomyVersion, reference.dimension, reference.labelId]);
}

function compareReferences(left: TaxonomyLabelRef, right: TaxonomyLabelRef): number {
  const versionOrder = left.taxonomyVersion.localeCompare(right.taxonomyVersion);
  if (versionOrder !== 0) {
    return versionOrder;
  }
  const dimensionOrder = left.dimension.localeCompare(right.dimension);
  return dimensionOrder !== 0 ? dimensionOrder : left.labelId.localeCompare(right.labelId);
}

/** Applies one explicit control as the latest state for its versioned taxonomy label. */
export function setLabelControl(
  current: PreferenceControlState,
  reference: TaxonomyLabelRef,
  control: LabelControl,
): PreferenceControlState {
  if (
    reference.taxonomyVersion.trim().length === 0 ||
    reference.labelId.trim().length === 0 ||
    !dimensions.includes(reference.dimension)
  ) {
    throw new Error("A preference control requires a valid versioned taxonomy label.");
  }

  const key = controlKey(reference);
  const explicitInterests = current.explicitInterests.filter((item) => controlKey(item) !== key);
  const lessLikeLabels = current.lessLikeLabels.filter((item) => controlKey(item) !== key);
  const hiddenLabels = current.hiddenLabels.filter((item) => controlKey(item) !== key);

  switch (control) {
    case "more":
      explicitInterests.push(reference);
      break;
    case "less":
      lessLikeLabels.push(reference);
      break;
    case "hidden":
      hiddenLabels.push(reference);
      break;
    case "none":
      break;
    default: {
      const exhaustive: never = control;
      throw new Error(`Unsupported preference control '${exhaustive}'.`);
    }
  }

  return {
    explicitInterests: explicitInterests.sort(compareReferences),
    lessLikeLabels: lessLikeLabels.sort(compareReferences),
    hiddenLabels: hiddenLabels.sort(compareReferences),
  };
}
