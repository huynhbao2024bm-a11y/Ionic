import 'dart:math' as math;

import 'types.dart';

class RankingEvaluationInput {
  const RankingEvaluationInput({
    required this.ranked,
    required this.relevanceByContentId,
    required this.limit,
    this.relevantAtOrAbove = 1,
  });

  final List<RankedCandidate> ranked;

  /// Complete human relevance judgments for the eligible candidate pool.
  final Map<String, int> relevanceByContentId;
  final int limit;
  final int relevantAtOrAbove;
}

class RankingEvaluation {
  const RankingEvaluation({
    required this.rankerVersion,
    required this.evaluatedCount,
    required this.precisionAtK,
    required this.recallAtK,
    required this.ndcgAtK,
    required this.creatorCoverage,
    required this.topicCoverage,
    required this.repeatedCreatorItemRate,
    required this.repeatedTopicItemRate,
    required this.duplicateGroupItemRate,
    required this.tierCounts,
  });

  final String? rankerVersion;
  final int evaluatedCount;
  final double? precisionAtK;
  final double? recallAtK;
  final double? ndcgAtK;
  final double? creatorCoverage;
  final double? topicCoverage;
  final double? repeatedCreatorItemRate;
  final double? repeatedTopicItemRate;
  final double? duplicateGroupItemRate;
  final Map<RelevanceTier, int> tierCounts;
}

void _validateInput(RankingEvaluationInput input) {
  if (input.limit < 0) {
    throw RangeError('Evaluation limit must be a non-negative integer.');
  }
  final threshold = input.relevantAtOrAbove;
  if (threshold < 1 || threshold > 3) {
    throw RangeError('Relevance threshold must be an integer from 1 to 3.');
  }
  final versions = <String>{};
  for (final item in input.ranked) {
    versions.add(item.rankerVersion);
    final grade = input.relevanceByContentId[item.candidate.id];
    if (grade == null || grade < 0 || grade > 3) {
      throw ArgumentError(
        'Missing or invalid relevance judgment for ${item.candidate.id}.',
      );
    }
  }
  if (versions.length > 1) {
    throw ArgumentError(
      'A ranking evaluation must contain one ranker version.',
    );
  }
  for (final entry in input.relevanceByContentId.entries) {
    if (entry.key.trim().isEmpty || entry.value < 0 || entry.value > 3) {
      throw ArgumentError(
        'Relevance judgments require non-empty IDs and grades from 0 to 3.',
      );
    }
  }
}

double _discountedGain(int grade, int rank) =>
    (math.pow(2, grade).toDouble() - 1) / (math.log(rank + 1) / math.ln2);

double? _coverage(int uniqueCount, int itemCount) =>
    itemCount == 0 ? null : uniqueCount / itemCount;

String? _primaryTopicLabelId(RankedCandidate item) {
  String? bestLabelId;
  var bestConfidence = -1.0;
  for (final label in item.candidate.labels) {
    if (label.dimension == LabelDimension.topic &&
        (label.confidence > bestConfidence ||
            (label.confidence == bestConfidence &&
                bestLabelId != null &&
                label.labelId.compareTo(bestLabelId) < 0))) {
      bestLabelId = label.labelId;
      bestConfidence = label.confidence;
    }
  }
  return bestLabelId;
}

/// Computes offline ranking quality and diversity metrics from human judgments.
/// This is an evaluation helper; it is not used to rank live feed requests.
RankingEvaluation evaluateRanking(RankingEvaluationInput input) {
  _validateInput(input);
  final threshold = input.relevantAtOrAbove;
  final topItems = input.ranked.take(input.limit).toList();
  final tierCounts = {for (final tier in RelevanceTier.values) tier: 0};
  final creatorCounts = <String, int>{};
  final topicCounts = <String, int>{};
  final duplicateGroupCounts = <String, int>{};
  var relevantRetrieved = 0;
  var dcg = 0.0;
  var repeatedCreatorItems = 0;
  var repeatedTopicItems = 0;
  var duplicateGroupItems = 0;

  for (var index = 0; index < topItems.length; index++) {
    final item = topItems[index];
    tierCounts[item.tier] = tierCounts[item.tier]! + 1;
    final grade = input.relevanceByContentId[item.candidate.id]!;
    dcg += _discountedGain(grade, index + 1);
    if (grade >= threshold) relevantRetrieved++;

    final creatorId = item.candidate.creatorId;
    final creatorCount = creatorCounts[creatorId] ?? 0;
    if (creatorCount > 0) repeatedCreatorItems++;
    creatorCounts[creatorId] = creatorCount + 1;

    final topicLabelId = _primaryTopicLabelId(item);
    if (topicLabelId != null) {
      final topicCount = topicCounts[topicLabelId] ?? 0;
      if (topicCount > 0) repeatedTopicItems++;
      topicCounts[topicLabelId] = topicCount + 1;
    }

    final duplicateGroupId = item.candidate.duplicateGroupId;
    if (duplicateGroupId != null) {
      final groupCount = duplicateGroupCounts[duplicateGroupId] ?? 0;
      if (groupCount > 0) duplicateGroupItems++;
      duplicateGroupCounts[duplicateGroupId] = groupCount + 1;
    }
  }

  final idealGrades = input.relevanceByContentId.values.toList()
    ..sort((a, b) => b.compareTo(a));
  var idealDcg = 0.0;
  for (
    var index = 0;
    index < math.min(idealGrades.length, input.limit);
    index++
  ) {
    idealDcg += _discountedGain(idealGrades[index], index + 1);
  }
  final totalRelevant = input.relevanceByContentId.values
      .where((grade) => grade >= threshold)
      .length;
  final evaluatedCount = topItems.length;

  return RankingEvaluation(
    rankerVersion: input.ranked.isEmpty
        ? null
        : input.ranked.first.rankerVersion,
    evaluatedCount: evaluatedCount,
    precisionAtK: evaluatedCount == 0
        ? null
        : relevantRetrieved / evaluatedCount,
    recallAtK: totalRelevant == 0 ? null : relevantRetrieved / totalRelevant,
    ndcgAtK: idealDcg == 0 ? null : dcg / idealDcg,
    creatorCoverage: _coverage(creatorCounts.length, evaluatedCount),
    topicCoverage: _coverage(topicCounts.length, evaluatedCount),
    repeatedCreatorItemRate: _coverage(repeatedCreatorItems, evaluatedCount),
    repeatedTopicItemRate: _coverage(repeatedTopicItems, evaluatedCount),
    duplicateGroupItemRate: _coverage(duplicateGroupItems, evaluatedCount),
    tierCounts: tierCounts,
  );
}
