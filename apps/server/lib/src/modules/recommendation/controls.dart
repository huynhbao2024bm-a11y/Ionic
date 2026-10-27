import 'dart:convert';

import 'types.dart';

enum LabelControl { more, less, hidden, none }

class PreferenceControlState {
  const PreferenceControlState({
    required this.explicitInterests,
    required this.lessLikeLabels,
    required this.hiddenLabels,
  });

  final List<ExplicitInterest> explicitInterests;
  final List<TaxonomyLabelRef> lessLikeLabels;
  final List<TaxonomyLabelRef> hiddenLabels;
}

String _controlKey(TaxonomyLabelRef reference) => jsonEncode([
  reference.taxonomyVersion,
  reference.dimension.name,
  reference.labelId,
]);

int _compareReferences(TaxonomyLabelRef left, TaxonomyLabelRef right) {
  final versionOrder = left.taxonomyVersion.compareTo(right.taxonomyVersion);
  if (versionOrder != 0) return versionOrder;
  final dimensionOrder = left.dimension.name.compareTo(right.dimension.name);
  return dimensionOrder != 0
      ? dimensionOrder
      : left.labelId.compareTo(right.labelId);
}

/// Applies one explicit control as the latest state for its versioned taxonomy label.
PreferenceControlState setLabelControl(
  PreferenceControlState current,
  TaxonomyLabelRef reference,
  LabelControl control,
) {
  if (reference.taxonomyVersion.trim().isEmpty ||
      reference.labelId.trim().isEmpty) {
    throw ArgumentError(
      'A preference control requires a valid versioned taxonomy label.',
    );
  }

  final key = _controlKey(reference);
  final explicitInterests = current.explicitInterests
      .where(
        (item) =>
            _controlKey(
              TaxonomyLabelRef(
                taxonomyVersion: item.taxonomyVersion,
                dimension: item.dimension,
                labelId: item.labelId,
              ),
            ) !=
            key,
      )
      .toList();
  final lessLikeLabels = current.lessLikeLabels
      .where((item) => _controlKey(item) != key)
      .toList();
  final hiddenLabels = current.hiddenLabels
      .where((item) => _controlKey(item) != key)
      .toList();

  switch (control) {
    case LabelControl.more:
      explicitInterests.add(
        ExplicitInterest(
          taxonomyVersion: reference.taxonomyVersion,
          dimension: reference.dimension,
          labelId: reference.labelId,
        ),
      );
    case LabelControl.less:
      lessLikeLabels.add(reference);
    case LabelControl.hidden:
      hiddenLabels.add(reference);
    case LabelControl.none:
      break;
  }

  final sortedExplicit = explicitInterests.toList()
    ..sort(
      (left, right) => _compareReferences(
        TaxonomyLabelRef(
          taxonomyVersion: left.taxonomyVersion,
          dimension: left.dimension,
          labelId: left.labelId,
        ),
        TaxonomyLabelRef(
          taxonomyVersion: right.taxonomyVersion,
          dimension: right.dimension,
          labelId: right.labelId,
        ),
      ),
    );
  lessLikeLabels.sort(_compareReferences);
  hiddenLabels.sort(_compareReferences);
  return PreferenceControlState(
    explicitInterests: sortedExplicit,
    lessLikeLabels: lessLikeLabels,
    hiddenLabels: hiddenLabels,
  );
}
