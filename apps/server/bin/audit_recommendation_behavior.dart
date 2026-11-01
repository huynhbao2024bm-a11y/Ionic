import 'dart:convert';
import 'dart:io';

import 'package:ionic_server/src/modules/recommendation/ranker.dart';
import 'package:ionic_server/src/modules/recommendation/ranker_config.dart';
import 'package:ionic_server/src/modules/recommendation/types.dart';
import 'package:ionic_server/src/modules/recommendation/feed_distribution.dart';

/// Read-only synthetic policy reproduction, not a quality benchmark or test
/// asserting that these product outcomes are desirable.
void main() {
  const now = 1793491200000.0;
  final config = buildRankerConfig(now, environment: {});
  final profile = ViewerProfile(
    explicitInterests: const [],
    preferences: const [],
    followingCreatorIds: const ['followed'],
    blockedCreatorIds: const [],
    mutedCreatorIds: const [],
    hiddenContentIds: const [],
    hiddenLabels: const [],
    lessLikeLabels: const [],
    recentExposures: const [],
  );
  FeedCandidate item(
    String id,
    String creator,
    double age, {
    double affinity = 0,
  }) => FeedCandidate(
    id: id,
    creatorId: creator,
    kind: ContentKind.text,
    publishedAtMs: now - age,
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
    semanticAffinity: affinity,
  );
  final candidates = [
    for (var i = 0; i < 12; i++) item('followed-$i', 'followed', 20 * 86400000),
    for (var i = 0; i < 12; i++) item('fresh-$i', 'other-$i', 60000),
    item('semantic-discovery', 'new-creator', 60000, affinity: .75),
  ];
  final ranked = rankCandidates(
    candidates,
    profile,
    config,
    500,
    diversify: false,
    deduplicateGroups: false,
  );
  final randomIds = candidates.reversed.map((e) => e.id).toList();
  final mixed = mixFeedSnapshot(
    ranked: ranked,
    randomOrderedIds: randomIds,
    pageSize: 10,
    config: config,
  );
  final firstPage = mixed.entries.take(10).map((e) => e.item).toList();
  final repeated = mixFeedSnapshot(
    ranked: ranked,
    randomOrderedIds: randomIds,
    pageSize: 10,
    config: config,
  ).entries.take(10).map((e) => e.item.candidate.id).toList();
  final firstIds = firstPage.map((r) => r.candidate.id).toList();
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'kind': 'synthetic policy audit; no real-user quality judgment',
      'rankerVersion': config.rankerVersion,
      'scenario': '12 old followed-author posts; 12 fresh alternative authors; one semantic discovery item',
      'pageSize': 10,
      'configuredCreatorCap': config.maxPerCreator,
      'firstPageDistinctCreators': firstPage
          .map((r) => r.candidate.creatorId)
          .toSet()
          .length,
      'personalizedOnlyFirstPageDistinctCreators': ranked
          .take(10)
          .map((e) => e.candidate.creatorId)
          .toSet()
          .length,
      'firstPageRandomSelections': mixed.entries
          .take(10)
          .where((e) => e.isRandom)
          .length,
      'firstPageDirect': firstPage
          .where((r) => r.tier == RelevanceTier.direct)
          .length,
      'firstPageAdjacentOrFresh': firstPage
          .where(
            (r) =>
                r.tier == RelevanceTier.adjacent ||
                r.tier == RelevanceTier.fresh,
          )
          .length,
      'sameSnapshotRecomputationStable':
          jsonEncode(firstIds) == jsonEncode(repeated),
      'firstPageIds': firstIds,
      'interpretation':
          'The v7 mixer reserves random positions and applies diversity across personalized tiers. '
          'A fresh nonce changes the random source at refresh; pagination reuses it. '
          'No actual rendered-impression history is collected by this policy.',
    }),
  );
}
