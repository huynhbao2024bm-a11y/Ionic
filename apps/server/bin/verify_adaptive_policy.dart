import 'dart:convert';
import 'dart:io';

import 'package:ionic_server/src/modules/recommendation/adaptive_policy.dart';

void main() {
  const policy = AdaptivePolicy();
  const none = InterestEstimate(evidence: 0, rewardTotal: 0);
  const one = InterestEstimate(evidence: 1, rewardTotal: .8);
  const positive = InterestEstimate(evidence: 12, rewardTotal: 10.8);
  const negative = InterestEstimate(evidence: 12, rewardTotal: 1.2);
  var checks = 0;
  void check(bool value, String label) {
    if (!value) throw StateError(label);
    checks++;
  }

  final raisedFloor = AdaptivePolicy.fromEnvironment(
    environment: {'RECOMMENDATION_MIN_RANDOM_SHARE': '0.85'},
  );
  check(
    raisedFloor.uncertainRandomShare >= .85 &&
        adaptiveRandomBasisPoints(none, raisedFloor) >= 8500,
    'Raising floor also raises default uncertainty ceiling',
  );

  check(
    topicGap(positive, policy) < topicGap(one, policy),
    'Repeated independent interest contracts topic interval',
  );
  check(
    topicGap(negative, policy) > topicGap(none, policy),
    'Repeated weak responses expand topic interval',
  );
  check(
    (topicGap(one, policy) - topicGap(none, policy)).abs() < 5,
    'One observation cannot dominate pacing',
  );
  check(
    adaptiveRandomBasisPoints(none, policy) >
        adaptiveRandomBasisPoints(positive, policy),
    'Sparse evidence increases random allocation',
  );
  check(
    adaptiveRandomBasisPoints(positive, policy) >= 4000,
    'Owner floor retained',
  );
  check(
    audienceDecision(none, policy).allowance == policy.audienceBase,
    'New item gets initial opportunity',
  );
  check(
    audienceDecision(positive, policy).allowance >
        audienceDecision(none, policy).allowance,
    'Repeated random-reader evidence expands audience',
  );
  check(
    audienceDecision(negative, policy).allowance <
        audienceDecision(none, policy).allowance,
    'Weak independent outcomes reduce new audience',
  );
  check(
    audienceDecision(negative, policy).allowance >= policy.audienceMinimum,
    'Weak sample never permanently kills item',
  );
  check(
    attentionReward(AttentionBand.short, textCharacters: 40) >
        attentionReward(AttentionBand.short, textCharacters: 280),
    'Raw duration does not ignore text length',
  );
  check(
    attentionReward(AttentionBand.long, textCharacters: 280) <= .8,
    'Long dwell cannot become certainty',
  );
  for (var n = 0; n <= 200; n++) {
    for (final ratio in [0.0, .2, .5, .8, 1.0]) {
      final e = InterestEstimate(
        evidence: n.toDouble(),
        rewardTotal: n * ratio,
      );
      final gap = topicGap(e, policy),
          audience = audienceDecision(e, policy).allowance,
          random = adaptiveRandomBasisPoints(e, policy);
      check(
        gap >= policy.topicMinimumGap && gap <= policy.topicMaximumGap,
        'Bounded interval',
      );
      check(
        audience >= policy.audienceMinimum &&
            audience <= policy.audienceMaximum,
        'Bounded audience',
      );
      check(random >= 4000 && random <= 10000, 'Bounded adaptive random share');
    }
  }
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'checks': checks,
      'kind': 'Uncalibrated policy mechanics; not human relevance evidence',
      'noEvidenceGap': topicGap(none, policy),
      'singlePositiveGap': topicGap(one, policy),
      'repeatedPositiveGap': topicGap(positive, policy),
      'repeatedWeakGap': topicGap(negative, policy),
      'newItemAudience': audienceDecision(none, policy).allowance,
      'positiveAudience': audienceDecision(positive, policy).allowance,
      'weakAudience': audienceDecision(negative, policy).allowance,
    }),
  );
}
