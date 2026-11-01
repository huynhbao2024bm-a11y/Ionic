import 'dart:convert';
import 'dart:io';

import 'package:ionic_server/src/modules/recommendation/feed_distribution.dart';
import 'package:ionic_server/src/modules/recommendation/ranker.dart';
import 'package:ionic_server/src/modules/recommendation/ranker_config.dart';
import 'package:ionic_server/src/modules/recommendation/types.dart';

/// Synthetic allocation/authorization mechanics, not human satisfaction labels.
void main() {
  final config = buildRankerConfig(1793491200000, environment: {});
  var checks = 0;
  void check(bool value, String name) {
    if (!value) throw StateError(name);
    checks++;
  }

  RankedCandidate item(int n, {String? creator, String? clone}) =>
      RankedCandidate(
        candidate: FeedCandidate(
          id: 'post-$n',
          creatorId: creator ?? 'author-$n',
          kind: ContentKind.text,
          publishedAtMs: config.nowMs - 60000,
          labels: [
            ContentLabel(
              taxonomyVersion: config.taxonomyVersion,
              dimension: LabelDimension.format,
              labelId: 'format.text',
              confidence: 1,
              source: LabelSource.rule,
            ),
          ],
          eligible: true,
          visibleToViewer: true,
          duplicateGroupId: clone,
        ),
        tier: RelevanceTier.direct,
        score: 1 - n / 1000,
        reasonCode: RecommendationReasonCode.followed_creator,
        rankerVersion: config.rankerVersion,
      );
  var pageChecks = 0;
  for (final share in [4000, 5000, 7000, 10000]) {
    final policy = FeedDistributionPolicy(randomBasisPoints: share);
    for (final pageSize in [1, 2, 3, 7, 10, 20, 49, 50]) {
      for (final size in [0, 1, 2, 4, 19, 20, 21, 53, 121]) {
        final ranked = [for (var i = 0; i < size; i++) item(i)];
        for (final available in {0, size ~/ 3, size}) {
          final randomIds = ranked.reversed
              .take(available)
              .map((e) => e.candidate.id)
              .toList();
          final snapshot = mixFeedSnapshot(
            ranked: ranked,
            randomOrderedIds: randomIds,
            pageSize: pageSize,
            config: config,
            policy: policy,
          );
          final entries = snapshot.entries;
          check(
            entries.map((e) => e.item.candidate.id).toSet().length ==
                entries.length,
            'No duplicated IDs',
          );
          check(
            entries
                .where((e) => e.isRandom)
                .every((e) => randomIds.contains(e.item.candidate.id)),
            'No false random attribution',
          );
          for (var i = 0; i < entries.length; i += pageSize) {
            final page = entries.skip(i).take(pageSize).toList();
            check(
              page.where((e) => e.isRandom).length * 10000 >=
                  page.length * share,
              'Rounded per-page minimum',
            );
            pageChecks++;
          }
          final again = mixFeedSnapshot(
            ranked: ranked,
            randomOrderedIds: randomIds,
            pageSize: pageSize,
            config: config,
            policy: policy,
          );
          check(
            jsonEncode(entries.map((e) => e.item.candidate.id).toList()) ==
                jsonEncode(
                  again.entries.map((e) => e.item.candidate.id).toList(),
                ),
            'Stable recomputation',
          );
        }
      }
    }
  }
  final crowded = [
    for (var i = 0; i < 12; i++) item(i, creator: 'followed'),
    for (var i = 12; i < 25; i++) item(i),
  ];
  final mixed = mixFeedSnapshot(
    ranked: crowded,
    randomOrderedIds: crowded.map((e) => e.candidate.id).toList(),
    pageSize: 10,
    config: config,
  );
  final first = mixed.entries.take(10).toList();
  check(
    first.where((e) => e.isRandom).length == 4,
    'Four real random selections on page ten',
  );
  check(
    first.where((e) => e.item.candidate.creatorId == 'followed').length <= 3,
    'Personalized tier cannot defeat page creator cap with alternatives',
  );
  check(
    first.map((e) => e.item.candidate.creatorId).toSet().length >= 7,
    'Fresh alternatives fill saturated tier',
  );
  final clones = [
    item(1, clone: 'same'),
    item(2, clone: 'same'),
    item(3),
    item(4),
    item(5),
  ];
  final dedup = mixFeedSnapshot(
    ranked: clones,
    randomOrderedIds: ['post-2', 'post-1', 'post-3', 'post-4', 'post-5'],
    pageSize: 3,
    config: config,
  );
  check(
    dedup.entries
            .where((e) => e.item.candidate.duplicateGroupId == 'same')
            .length ==
        1,
    'Clone represented once across both lanes',
  );
  check(
    dedup.entries.any((e) => e.isRandom && e.item.candidate.id == 'post-2'),
    'Random clone representative independent of positive score',
  );
  final reversed = mixFeedSnapshot(
    ranked: crowded.reversed.toList(),
    randomOrderedIds: crowded.map((e) => e.candidate.id).toList(),
    pageSize: 10,
    config: config,
  );
  check(
    jsonEncode(
          mixed.entries
              .where((e) => e.isRandom)
              .map((e) => e.item.candidate.id)
              .toList(),
        ) ==
        jsonEncode(
          reversed.entries
              .where((e) => e.isRandom)
              .map((e) => e.item.candidate.id)
              .toList(),
        ),
    'Positive ordering does not choose random lane',
  );
  var invalid = 0;
  for (final raw in ['0.39', '0', 'NaN', '1.1', '.40001']) {
    try {
      FeedDistributionPolicy.fromEnvironment(
        environment: {'RECOMMENDATION_MIN_RANDOM_SHARE': raw},
      );
    } on FormatException {
      invalid++;
    }
  }
  check(invalid == 5, 'Reject sub-floor/nonfinite/overprecision policy');
  final profile = ViewerProfile(
    explicitInterests: const [],
    preferences: const [],
    followingCreatorIds: const [],
    blockedCreatorIds: ['blocked'],
    mutedCreatorIds: ['muted'],
    hiddenContentIds: ['post-3'],
    hiddenLabels: const [],
    lessLikeLabels: const [],
    recentExposures: const [],
  );
  final gated = rankCandidates(
    [
      item(1, creator: 'blocked').candidate,
      item(2, creator: 'muted').candidate,
      item(3).candidate,
      item(4).candidate,
    ],
    profile,
    config,
    4,
    diversify: false,
    deduplicateGroups: false,
  );
  final safe = mixFeedSnapshot(
    ranked: gated,
    randomOrderedIds: ['post-1', 'post-2', 'post-3', 'post-4'],
    pageSize: 20,
    config: config,
  );
  check(
    safe.entries.length == 1 &&
        safe.entries.single.item.candidate.id == 'post-4' &&
        safe.entries.single.isRandom,
    'Random lane never restores hard-filtered items',
  );
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'rankerVersion': config.rankerVersion,
      'checks': checks,
      'pageAllocationsChecked': pageChecks,
      'source': 'Synthetic policy mechanics only',
      'saturatedFollowedCreatorFirstPage': first
          .map(
            (e) => {
              'id': e.item.candidate.id,
              'creator': e.item.candidate.creatorId,
              'random': e.isRandom,
            },
          )
          .toList(),
    }),
  );
}
