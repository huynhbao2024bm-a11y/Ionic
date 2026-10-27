import 'dart:convert';

import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'types.dart';

class LabelProposal {
  const LabelProposal({
    required this.dimension,
    required this.labelId,
    required this.confidence,
    required this.source,
  });

  final LabelDimension dimension;
  final String labelId;
  final double confidence;
  final LabelSource source;
}

class KeywordRule {
  const KeywordRule({
    required this.dimension,
    required this.labelId,
    required this.terms,
    required this.confidence,
    this.minimumMatches = 1,
  });

  final LabelDimension dimension;
  final String labelId;
  final List<String> terms;
  final int minimumMatches;
  final double confidence;
}

class LabelContentInput {
  const LabelContentInput({
    required this.taxonomyVersion,
    required this.kind,
    required this.text,
    required this.formatLabelIds,
    this.suppliedLabels = const [],
    this.keywordRules = const [],
    this.declaredLanguageLabelId,
  });

  final String taxonomyVersion;
  final ContentKind kind;
  final String text;
  final Map<ContentKind, String> formatLabelIds;
  final List<LabelProposal> suppliedLabels;
  final List<KeywordRule> keywordRules;
  final String? declaredLanguageLabelId;
}

const _sourcePriority = <LabelSource, int>{
  LabelSource.rule: 1,
  LabelSource.creator: 2,
  LabelSource.user_corrected: 3,
};

const _labelDimensions = LabelDimension.values;

List<String> _tokenize(String value) {
  final normalized = unorm.nfkc(value).toLowerCase();
  return RegExp(r'[\p{L}\p{M}\p{N}]+', unicode: true)
      .allMatches(normalized)
      .map((match) => match.group(0)!)
      .toList(growable: false);
}

bool _containsTokens(List<String> tokens, List<String> termTokens) {
  if (termTokens.isEmpty || termTokens.length > tokens.length) return false;
  for (var start = 0; start <= tokens.length - termTokens.length; start++) {
    var matches = true;
    for (var offset = 0; offset < termTokens.length; offset++) {
      if (tokens[start + offset] != termTokens[offset]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

void _validateConfidence(double confidence) {
  if (!confidence.isFinite || confidence < 0 || confidence > 1) {
    throw RangeError('Label confidence must be between 0 and 1.');
  }
}

List<LabelProposal> suggestLabelsFromText(
  String text,
  List<KeywordRule> rules,
) {
  final tokens = _tokenize(text);
  final proposals = <LabelProposal>[];

  for (final rule in rules) {
    _validateConfidence(rule.confidence);
    final normalizedTerms = rule.terms.map(_tokenize).toList(growable: false);
    final normalizedKeys = normalizedTerms.map(jsonEncode).toSet();
    final minimumMatches = rule.minimumMatches;
    if (normalizedTerms.isEmpty ||
        normalizedTerms.any((termTokens) => termTokens.isEmpty) ||
        normalizedKeys.length != normalizedTerms.length ||
        !_labelDimensions.contains(rule.dimension) ||
        minimumMatches < 1 ||
        minimumMatches > normalizedTerms.length) {
      throw RangeError(
        'Keyword rule must have terms and a valid minimum match count.',
      );
    }

    final matchedTerms = normalizedTerms
        .where((termTokens) => _containsTokens(tokens, termTokens))
        .length;
    if (matchedTerms >= minimumMatches) {
      proposals.add(
        LabelProposal(
          dimension: rule.dimension,
          labelId: rule.labelId,
          confidence: rule.confidence,
          source: LabelSource.rule,
        ),
      );
    }
  }
  return proposals;
}

List<ContentLabel> resolveContentLabels(
  String taxonomyVersion,
  List<LabelProposal> proposals,
) {
  if (taxonomyVersion.trim().isEmpty) {
    throw ArgumentError('Taxonomy version is required.');
  }

  final resolved = <String, ContentLabel>{};
  for (final proposal in proposals) {
    if (proposal.labelId.trim().isEmpty) {
      throw ArgumentError('Label ID is required.');
    }
    if (!_labelDimensions.contains(proposal.dimension) ||
        !_sourcePriority.containsKey(proposal.source)) {
      throw ArgumentError('Label dimension or source is invalid.');
    }
    _validateConfidence(proposal.confidence);

    final key = jsonEncode([proposal.dimension.name, proposal.labelId]);
    final next = ContentLabel(
      taxonomyVersion: taxonomyVersion,
      dimension: proposal.dimension,
      labelId: proposal.labelId,
      confidence: proposal.confidence,
      source: proposal.source,
    );
    final current = resolved[key];
    final nextPriority = _sourcePriority[next.source]!;
    final currentPriority = current == null
        ? -1
        : _sourcePriority[current.source]!;
    if (current == null ||
        nextPriority > currentPriority ||
        (nextPriority == currentPriority &&
            next.confidence > current.confidence)) {
      resolved[key] = next;
    }
  }

  final result = resolved.values.toList();
  result.sort((left, right) {
    final dimensionOrder = left.dimension.name.compareTo(right.dimension.name);
    return dimensionOrder != 0
        ? dimensionOrder
        : left.labelId.compareTo(right.labelId);
  });
  return result;
}

List<ContentLabel> labelContent(LabelContentInput input) {
  final formatLabelId = input.formatLabelIds[input.kind];
  if (formatLabelId == null || formatLabelId.trim().isEmpty) {
    throw ArgumentError(
      "A format label is required for content kind '${input.kind.name}'.",
    );
  }

  final proposals = <LabelProposal>[
    ...input.suppliedLabels,
    ...suggestLabelsFromText(input.text, input.keywordRules),
    LabelProposal(
      dimension: LabelDimension.format,
      labelId: formatLabelId,
      confidence: 1,
      source: LabelSource.rule,
    ),
  ];
  final languageLabelId = input.declaredLanguageLabelId;
  if (languageLabelId != null) {
    proposals.add(
      LabelProposal(
        dimension: LabelDimension.language,
        labelId: languageLabelId,
        confidence: 1,
        source: LabelSource.creator,
      ),
    );
  }
  return resolveContentLabels(input.taxonomyVersion, proposals);
}
