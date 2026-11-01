import 'dart:convert';
import 'dart:io';

import 'package:ionic_server/src/modules/recommendation/adaptive_mixer.dart';
import 'package:ionic_server/src/modules/recommendation/ranker_config.dart';
import 'package:ionic_server/src/modules/recommendation/types.dart';

void main() {
  final config = buildRankerConfig(1793491200000, environment: {});
  var checks = 0;
  void check(bool v, String label) {
    if (!v) throw StateError(label);
    checks++;
  }

  RankedCandidate item(int n, String topic) => RankedCandidate(
    candidate: FeedCandidate(
      id: '$n',
      creatorId: 'author-$n',
      kind: ContentKind.text,
      publishedAtMs: config.nowMs - 60000,
      labels: [
        ContentLabel(
          taxonomyVersion: config.taxonomyVersion,
          dimension: LabelDimension.topic,
          labelId: topic,
          confidence: 1,
          source: LabelSource.rule,
        ),
      ],
      eligible: true,
      visibleToViewer: true,
    ),
    tier: RelevanceTier.strong,
    score: 1,
    reasonCode: RecommendationReasonCode.learned_interest,
    rankerVersion: config.rankerVersion,
  );
  final pool = [
    for (var i = 0; i < 20; i++) item(i, 'topic.pets'),
    for (var i = 20; i < 70; i++) item(i, 'topic.other-$i'),
  ];
  final order = pool.map((e) => e.candidate.id).toList();
  final strong = mixAdaptivePage(
    ranked: pool,
    randomOrderedIds: order,
    pageSize: 20,
    config: config,
    randomBasisPoints: 4000,
    startSequence: 0,
    topicGaps: {'topic.pets': 4},
    lastTopicSequence: {'topic.pets': 0},
  );
  final weak = mixAdaptivePage(
    ranked: pool,
    randomOrderedIds: order,
    pageSize: 20,
    config: config,
    randomBasisPoints: 4000,
    startSequence: 0,
    topicGaps: {'topic.pets': 30},
    lastTopicSequence: {'topic.pets': 0},
  );
  bool cat(FeedCandidate c) => c.labels.any((e) => e.labelId == 'topic.pets');
  check(
    strong.indexWhere((e) => cat(e.item.candidate)) >= 3,
    'Related content waits for due slot',
  );
  check(
    strong.any((e) => cat(e.item.candidate)),
    'Repeated interest can receive later related content',
  );
  check(
    weak.every((e) => !cat(e.item.candidate)),
    'Weak topic deferred across current page when alternatives exist',
  );
  for (final page in [1, 2, 3, 7, 20, 50]) {
    for (final share in [4000, 7000, 10000]) {
      for (final available in [0, 1, 5, 20, 70]) {
        final mixed = mixAdaptivePage(
          ranked: pool,
          randomOrderedIds: order.take(available).toList(),
          pageSize: page,
          config: config,
          randomBasisPoints: share,
          startSequence: 100,
          topicGaps: {'topic.pets': 80},
          lastTopicSequence: {'topic.pets': 100},
        );
        check(
          mixed.where((e) => e.isRandom).length * 10000 >= mixed.length * share,
          'Adaptive cadence never lowers random floor',
        );
        check(
          mixed.map((e) => e.item.candidate.id).toSet().length == mixed.length,
          'Distinct adaptive IDs',
        );
        check(
          mixed
              .where((e) => e.isRandom)
              .every(
                (e) => order.take(available).contains(e.item.candidate.id),
              ),
          'No relabeled random attribution',
        );
      }
    }
  }
  final sparse = mixAdaptivePage(
    ranked: pool.take(2).toList(),
    randomOrderedIds: order.take(2).toList(),
    pageSize: 20,
    config: config,
    randomBasisPoints: 7000,
    startSequence: 1,
    topicGaps: {'topic.pets': 80},
    lastTopicSequence: {'topic.pets': 1},
  );
  check(
    sparse.length == 2,
    'Sparse supply relaxes soft pacing rather than fabricating filler',
  );
  stdout.writeln(
    jsonEncode({
      'checks': checks,
      'strongFirstRelatedSlot':
          strong.indexWhere((e) => cat(e.item.candidate)) + 1,
      'weakRelatedCount': weak.where((e) => cat(e.item.candidate)).length,
      'kind': 'Synthetic scheduling mechanics only',
    }),
  );
}
