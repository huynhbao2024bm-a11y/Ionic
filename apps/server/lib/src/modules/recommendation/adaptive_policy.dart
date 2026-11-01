import 'dart:math' as math;
import 'dart:io';

/// Coarse, client-reported foreground attention; never proof of understanding.
enum AttentionBand { peek, short, read, long }

const attentionLowerBoundMs = <AttentionBand, int>{
  AttentionBand.peek: 1000,
  AttentionBand.short: 3000,
  AttentionBand.read: 8000,
  AttentionBand.long: 20000,
};

class AdaptivePolicy {
  const AdaptivePolicy({
    this.minimumRandomShare = .4,
    this.uncertainRandomShare = .7,
    this.topicBaseGap = 16,
    this.topicMinimumGap = 4,
    this.topicMaximumGap = 80,
    this.evidencePrior = 4,
    this.audienceBase = 32,
    this.audienceMinimum = 8,
    this.audienceMaximum = 256,
    this.audienceWindowMinutes = 10,
  });
  factory AdaptivePolicy.fromEnvironment({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    int integer(String name, int fallback) =>
        int.tryParse(env[name] ?? '$fallback') ??
        (throw FormatException('Invalid $name.'));
    double number(String name, double fallback) =>
        double.tryParse(env[name] ?? '$fallback') ??
        (throw FormatException('Invalid $name.'));
    final minimumRandomShare = number('RECOMMENDATION_MIN_RANDOM_SHARE', .4);
    final policy = AdaptivePolicy(
      minimumRandomShare: minimumRandomShare,
      uncertainRandomShare: number(
        'RECOMMENDATION_UNCERTAIN_RANDOM_SHARE',
        math.max(.7, minimumRandomShare),
      ),
      topicBaseGap: integer('RECOMMENDATION_TOPIC_BASE_GAP', 16),
      topicMinimumGap: integer('RECOMMENDATION_TOPIC_MIN_GAP', 4),
      topicMaximumGap: integer('RECOMMENDATION_TOPIC_MAX_GAP', 80),
      evidencePrior: number('RECOMMENDATION_EVIDENCE_PRIOR', 4),
      audienceBase: integer('RECOMMENDATION_AUDIENCE_BASE', 32),
      audienceMinimum: integer('RECOMMENDATION_AUDIENCE_MIN', 8),
      audienceMaximum: integer('RECOMMENDATION_AUDIENCE_MAX', 256),
      audienceWindowMinutes: integer(
        'RECOMMENDATION_AUDIENCE_WINDOW_MINUTES',
        10,
      ),
    );
    policy.validate();
    return policy;
  }
  final double minimumRandomShare, uncertainRandomShare, evidencePrior;
  final int topicBaseGap, topicMinimumGap, topicMaximumGap;
  final int audienceBase,
      audienceMinimum,
      audienceMaximum,
      audienceWindowMinutes;

  void validate() {
    if (!minimumRandomShare.isFinite ||
        minimumRandomShare < .4 ||
        minimumRandomShare > 1 ||
        !uncertainRandomShare.isFinite ||
        uncertainRandomShare < minimumRandomShare ||
        uncertainRandomShare > 1 ||
        !evidencePrior.isFinite ||
        evidencePrior <= 0 ||
        topicMinimumGap < 1 ||
        topicBaseGap < topicMinimumGap ||
        topicMaximumGap < topicBaseGap ||
        topicMaximumGap > 500 ||
        audienceMinimum < 1 ||
        audienceBase < audienceMinimum ||
        audienceMaximum < audienceBase ||
        audienceMaximum > 10000 ||
        audienceWindowMinutes < 1 ||
        audienceWindowMinutes > 1440) {
      throw ArgumentError('Invalid adaptive recommendation policy.');
    }
  }
}

/// Length/media-aware but deliberately weak: slow reading/idle attention is not
/// an engagement objective, and a brief glance is not a definitive negative.
double attentionReward(
  AttentionBand band, {
  required int textCharacters,
  bool hasMedia = false,
}) {
  if (textCharacters < 0 || textCharacters > 10000) {
    throw ArgumentError('Invalid content length.');
  }
  final expectedMs = (2000 + textCharacters * 35).clamp(3000, 16000);
  final dwell = attentionLowerBoundMs[band]!;
  final normalized = (dwell / expectedMs).clamp(0.0, 1.0);
  final reward = .15 + .65 * normalized;
  return hasMedia ? .5 + (reward - .5) * .5 : reward;
}

class InterestEstimate {
  const InterestEstimate({required this.evidence, required this.rewardTotal});
  final double evidence, rewardTotal;
  void validate() {
    if (!evidence.isFinite ||
        evidence < 0 ||
        !rewardTotal.isFinite ||
        rewardTotal < 0 ||
        rewardTotal > evidence) {
      throw ArgumentError('Invalid bounded recommendation evidence.');
    }
  }

  double mean(AdaptivePolicy policy) =>
      (policy.evidencePrior * .5 + rewardTotal) /
      (policy.evidencePrior + evidence);
  double confidence(AdaptivePolicy policy) =>
      evidence / (policy.evidencePrior + evidence);
}

int topicGap(InterestEstimate estimate, AdaptivePolicy policy) {
  policy.validate();
  estimate.validate();
  final lift = (estimate.mean(policy) - .5) * 2,
      confidence = estimate.confidence(policy);
  final gap = lift >= 0
      ? policy.topicBaseGap / (1 + 2 * lift * confidence)
      : policy.topicBaseGap * (1 + 3 * (-lift) * confidence);
  return gap.round().clamp(policy.topicMinimumGap, policy.topicMaximumGap);
}

int adaptiveRandomBasisPoints(
  InterestEstimate estimate,
  AdaptivePolicy policy,
) {
  policy.validate();
  estimate.validate();
  // More evidence reduces exploration toward the owner floor, not below it.
  final share =
      policy.minimumRandomShare +
      (policy.uncertainRandomShare - policy.minimumRandomShare) *
          (1 - estimate.confidence(policy));
  return (share * 10000).ceil().clamp(
    (policy.minimumRandomShare * 10000).ceil(),
    10000,
  );
}

class AudienceDecision {
  const AudienceDecision({
    required this.allowance,
    required this.mean,
    required this.confidence,
  });
  final int allowance;
  final double mean, confidence;
}

/// Only deduplicated independent random-reader outcomes enter this estimate.
/// A nonzero floor and a rolling window protect new/uncertain content.
AudienceDecision audienceDecision(
  InterestEstimate randomReaders,
  AdaptivePolicy policy,
) {
  policy.validate();
  randomReaders.validate();
  final mean = randomReaders.mean(policy),
      confidence = randomReaders.confidence(policy);
  final multiplier = math.exp(math.log(4) * (mean - .5) * 2 * confidence);
  final allowance = (policy.audienceBase * multiplier).round().clamp(
    policy.audienceMinimum,
    policy.audienceMaximum,
  );
  return AudienceDecision(
    allowance: allowance,
    mean: mean,
    confidence: confidence,
  );
}
