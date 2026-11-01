import 'dart:math' as math;

import 'feed_distribution.dart';
import 'types.dart';

String _group(RankedCandidate item) =>
    item.candidate.duplicateGroupId ?? item.candidate.id;
List<String> _topics(RankedCandidate item) => item.candidate.labels
    .where((e) => e.dimension == LabelDimension.topic)
    .map((e) => e.labelId)
    .toList();

/// Sequential page scheduling. The clock counts issued slots, not proven views.
/// Random source order has no positive-affinity weighting; soft pacing and
/// diversity can defer candidates. Hard eligibility is handled before this call.
List<MixedFeedEntry> mixAdaptivePage({
  required List<RankedCandidate> ranked,
  required List<String> randomOrderedIds,
  required int pageSize,
  required RankerConfig config,
  required int randomBasisPoints,
  required int startSequence,
  Map<String, int> topicGaps = const {},
  Map<String, int> lastTopicSequence = const {},
}) {
  if (pageSize < 1 ||
      pageSize > 50 ||
      startSequence < 0 ||
      randomBasisPoints < 4000 ||
      randomBasisPoints > 10000) {
    throw ArgumentError('Invalid adaptive page contract.');
  }
  final byId = {for (final e in ranked) e.candidate.id: e};
  final personal = <String, RankedCandidate>{};
  for (final e in ranked) {
    personal.putIfAbsent(_group(e), () => e);
  }
  final random = <String, RankedCandidate>{};
  for (final id in randomOrderedIds) {
    final e = byId[id];
    if (e != null) random.putIfAbsent(_group(e), () => e);
  }
  var size = math.min(pageSize, personal.length);
  final allocation = FeedDistributionPolicy(
    randomBasisPoints: randomBasisPoints,
  );
  while (size > 0 && allocation.randomSlots(size) > random.length) {
    size--;
  }
  if (size == 0) return const [];
  var randomLeft = allocation.randomSlots(size),
      personalLeft = size - randomLeft,
      randomUsed = 0;
  final last = {...lastTopicSequence},
      creatorCount = <String, int>{},
      topicCount = <String, int>{};
  final output = <MixedFeedEntry>[];
  for (var slot = 0; slot < size; slot++) {
    final sequence = startSequence + slot + 1;
    bool legalPersonal(String group) =>
        !random.containsKey(group) || random.length > randomLeft;
    bool due(RankedCandidate e) => _topics(e).every(
      (topic) =>
          !topicGaps.containsKey(topic) ||
          !last.containsKey(topic) ||
          sequence - last[topic]! >= topicGaps[topic]!,
    );
    int delay(RankedCandidate e) => _topics(e).fold(
      0,
      (a, t) => math.max(
        a,
        math.max(0, (last[t] ?? -100000) + (topicGaps[t] ?? 0) - sequence),
      ),
    );
    bool authorOK(RankedCandidate e) =>
        (creatorCount[e.candidate.creatorId] ?? 0) < config.maxPerCreator;
    bool topicOK(RankedCandidate e) =>
        _topics(e).every((t) => (topicCount[t] ?? 0) < config.maxPerTopic);
    bool consecutiveOK(RankedCandidate e) =>
        output.isEmpty ||
        output.last.item.candidate.creatorId != e.candidate.creatorId;
    final preferRandom =
        randomUsed <
        ((slot + 1) * allocation.randomSlots(size) + size - 1) ~/ size;
    final lanes = [preferRandom, !preferRandom];
    String? selected;
    var isRandom = false;
    for (var pass = 0; pass < 4 && selected == null; pass++) {
      for (final lane in lanes) {
        if (lane ? randomLeft == 0 : personalLeft == 0) continue;
        final source = lane ? random : personal;
        for (final entry in source.entries) {
          if (!lane && !legalPersonal(entry.key)) continue;
          final e = entry.value;
          if (!due(e) ||
              (pass < 2 && !authorOK(e)) ||
              (pass == 0 && !topicOK(e)) ||
              (pass < 3 && !consecutiveOK(e))) {
            continue;
          }
          selected = entry.key;
          isRandom = lane;
          break;
        }
        if (selected != null) break;
      }
    }
    // If no due alternative exists, prefer the smallest spacing violation.
    if (selected == null) {
      var shortest = 0x7fffffff;
      for (final lane in lanes) {
        if (lane ? randomLeft == 0 : personalLeft == 0) continue;
        for (final entry in (lane ? random : personal).entries) {
          if (!lane && !legalPersonal(entry.key)) continue;
          final wait = delay(entry.value);
          if (wait < shortest) {
            shortest = wait;
            selected = entry.key;
            isRandom = lane;
          }
        }
      }
    }
    if (selected == null) {
      throw StateError('Adaptive quota reservation failed.');
    }
    final item = (isRandom ? random : personal)[selected]!;
    output.add(MixedFeedEntry(item, isRandom: isRandom));
    if (isRandom) {
      randomLeft--;
      randomUsed++;
    } else {
      personalLeft--;
    }
    personal.remove(selected);
    random.remove(selected);
    creatorCount[item.candidate.creatorId] =
        (creatorCount[item.candidate.creatorId] ?? 0) + 1;
    for (final t in _topics(item)) {
      topicCount[t] = (topicCount[t] ?? 0) + 1;
      last[t] = sequence;
    }
  }
  return output;
}
