import 'dart:io';
import 'dart:math' as math;

import 'types.dart';

class FeedDistributionPolicy {
  const FeedDistributionPolicy({this.randomBasisPoints = 4000});
  factory FeedDistributionPolicy.fromEnvironment({
    Map<String, String>? environment,
  }) {
    final raw =
        (environment ?? Platform.environment)['RECOMMENDATION_MIN_RANDOM_SHARE']
            ?.trim();
    final share = raw == null || raw.isEmpty ? .4 : double.tryParse(raw);
    if (share == null ||
        !share.isFinite ||
        share < .4 ||
        share > 1 ||
        (share * 10000 - (share * 10000).round()).abs() > .000001) {
      throw const FormatException(
        'RECOMMENDATION_MIN_RANDOM_SHARE must be 0.40..1.00 with at most four decimal places.',
      );
    }
    return FeedDistributionPolicy(randomBasisPoints: (share * 10000).round());
  }
  final int randomBasisPoints;
  int randomSlots(int size) => (size * randomBasisPoints + 9999) ~/ 10000;
  int snapshotRandomSlots(int size, int pageSize) =>
      size ~/ pageSize * randomSlots(pageSize) + randomSlots(size % pageSize);
}

class MixedFeedEntry {
  const MixedFeedEntry(this.item, {required this.isRandom});
  final RankedCandidate item;
  final bool isRandom;
}

class MixedFeedSnapshot {
  const MixedFeedSnapshot(
    this.entries, {
    required this.eligibleGroups,
    required this.randomGroups,
  });
  final List<MixedFeedEntry> entries;
  final int eligibleGroups;
  final int randomGroups;
  bool get supplyLimited => entries.length < eligibleGroups;
}

String _group(RankedCandidate item) => item.candidate.duplicateGroupId == null
    ? 'item:${item.candidate.id}'
    : 'clone:${item.candidate.duplicateGroupId}';

String? _topic(RankedCandidate item) {
  final topics =
      item.candidate.labels
          .where((l) => l.dimension == LabelDimension.topic)
          .toList()
        ..sort((a, b) {
          final score = b.confidence.compareTo(a.confidence);
          return score != 0 ? score : a.labelId.compareTo(b.labelId);
        });
  return topics.firstOrNull?.labelId;
}

class _PageCounts {
  final creators = <String, int>{};
  final topics = <String, int>{};
  void add(RankedCandidate item) {
    final author = item.candidate.creatorId, topic = _topic(item);
    creators[author] = (creators[author] ?? 0) + 1;
    if (topic != null) topics[topic] = (topics[topic] ?? 0) + 1;
  }
}

RankedCandidate _takeDiverse(
  List<RankedCandidate> queue,
  _PageCounts counts,
  RankerConfig config,
) {
  bool creatorOK(RankedCandidate item) =>
      (counts.creators[item.candidate.creatorId] ?? 0) < config.maxPerCreator;
  bool topicOK(RankedCandidate item) {
    final topic = _topic(item);
    return topic == null || (counts.topics[topic] ?? 0) < config.maxPerTopic;
  }

  var index = queue.indexWhere((item) => creatorOK(item) && topicOK(item));
  if (index < 0) index = queue.indexWhere(creatorOK);
  // Only relax the creator cap after exhausting other creators in this lane.
  if (index < 0) index = 0;
  final item = queue.removeAt(index);
  counts.add(item);
  return item;
}

/// Both inputs must come from the same already-authorized/scored snapshot.
/// Random IDs retain source permutation: positive relevance never orders them.
MixedFeedSnapshot mixFeedSnapshot({
  required List<RankedCandidate> ranked,
  required List<String> randomOrderedIds,
  required int pageSize,
  required RankerConfig config,
  FeedDistributionPolicy policy = const FeedDistributionPolicy(),
}) {
  if (pageSize < 1 ||
      pageSize > 50 ||
      policy.randomBasisPoints < 4000 ||
      policy.randomBasisPoints > 10000) {
    throw ArgumentError('Invalid feed distribution policy/page size.');
  }
  final byId = {for (final item in ranked) item.candidate.id: item};
  final personalizedByGroup = <String, RankedCandidate>{};
  for (final item in ranked) {
    personalizedByGroup.putIfAbsent(_group(item), () => item);
  }
  final randomByGroup = <String, RankedCandidate>{};
  for (final id in randomOrderedIds) {
    final item = byId[id];
    if (item != null) randomByGroup.putIfAbsent(_group(item), () => item);
  }
  // Reserve before personalization consumes overlapping IDs/clone groups.
  var low = 0, high = personalizedByGroup.length;
  while (low < high) {
    final middle = (low + high + 1) ~/ 2;
    if (policy.snapshotRandomSlots(middle, pageSize) <= randomByGroup.length) {
      low = middle;
    } else {
      high = middle - 1;
    }
  }
  final total = low, reserve = policy.snapshotRandomSlots(total, pageSize);
  final randomSupply = randomByGroup.values.toList();
  final randomQueue = <RankedCandidate>[];
  for (var offset = 0; offset < total; offset += pageSize) {
    final counts = _PageCounts();
    final size = math.min(pageSize, total - offset);
    for (var i = 0; i < policy.randomSlots(size); i++) {
      randomQueue.add(_takeDiverse(randomSupply, counts, config));
    }
  }
  assert(randomQueue.length == reserve);
  final reserved = randomQueue.map(_group).toSet();
  final personalizedQueue = personalizedByGroup.entries
      .where((e) => !reserved.contains(e.key))
      .map((e) => e.value)
      .toList();
  final output = <MixedFeedEntry>[];
  while (output.length < total) {
    final size = math.min(pageSize, total - output.length);
    final randomCount = policy.randomSlots(size);
    final counts = _PageCounts();
    final random = <RankedCandidate>[], personal = <RankedCandidate>[];
    for (var i = 0; i < randomCount; i++) {
      random.add(_takeDiverse(randomQueue, counts, config));
    }
    for (var i = 0; i < size - randomCount; i++) {
      personal.add(_takeDiverse(personalizedQueue, counts, config));
    }
    var randomUsed = 0;
    for (var position = 0; position < size; position++) {
      var chooseRandom =
          randomUsed < ((position + 1) * randomCount + size - 1) ~/ size;
      if (random.isEmpty) chooseRandom = false;
      if (personal.isEmpty) chooseRandom = true;
      final previous = output.lastOrNull?.item.candidate.creatorId;
      bool differentAuthor(RankedCandidate item) =>
          item.candidate.creatorId != previous;
      final preferred = chooseRandom ? random : personal,
          other = chooseRandom ? personal : random;
      // Swap lane timing if it avoids adjacent authors; page totals are fixed.
      if (preferred.every((item) => !differentAuthor(item)) &&
          other.any(differentAuthor)) {
        chooseRandom = !chooseRandom;
      }
      final queue = chooseRandom ? random : personal;
      var index = queue.indexWhere((item) {
        if (!differentAuthor(item)) return false;
        final topic = _topic(item);
        if (topic == null) return true;
        final recent = output.reversed.take(config.maxConsecutiveTopic);
        return recent.length < config.maxConsecutiveTopic ||
            recent.any((entry) => _topic(entry.item) != topic);
      });
      if (index < 0) index = queue.indexWhere(differentAuthor);
      if (index < 0) index = 0;
      output.add(MixedFeedEntry(queue.removeAt(index), isRandom: chooseRandom));
      if (chooseRandom) randomUsed++;
    }
  }
  return MixedFeedSnapshot(
    output,
    eligibleGroups: personalizedByGroup.length,
    randomGroups: randomByGroup.length,
  );
}
