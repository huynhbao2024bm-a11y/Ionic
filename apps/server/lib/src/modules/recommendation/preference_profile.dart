import 'dart:convert';
import 'dart:math' as math;

import 'types.dart';

const _signalKinds = PreferenceSignalKind.values;

double _clamp(double value, double lower, double upper) =>
    math.min(upper, math.max(lower, value));

double _decayFactor(double elapsedMs, double halfLifeMs) =>
    elapsedMs <= 0 ? 1 : mathPow2(-elapsedMs / halfLifeMs);

double mathPow2(double exponent) => math.pow(2.0, exponent).toDouble();

String _featureKey({
  required String taxonomyVersion,
  required LabelDimension dimension,
  required String labelId,
}) => jsonEncode([taxonomyVersion, dimension.name, labelId]);

int _compareFeatures(PreferenceFeature left, PreferenceFeature right) {
  final taxonomyOrder = left.taxonomyVersion.compareTo(right.taxonomyVersion);
  if (taxonomyOrder != 0) return taxonomyOrder;
  final dimensionOrder = left.dimension.name.compareTo(right.dimension.name);
  return dimensionOrder != 0
      ? dimensionOrder
      : left.labelId.compareTo(right.labelId);
}

void _validatePolicy(PreferenceUpdatePolicy policy) {
  if (!policy.nowMs.isFinite ||
      !policy.halfLifeMs.isFinite ||
      policy.halfLifeMs <= 0 ||
      !policy.expiryAfterMs.isFinite ||
      policy.expiryAfterMs <= 0 ||
      !(policy.nowMs + policy.expiryAfterMs).isFinite ||
      !policy.maxAbsoluteScore.isFinite ||
      policy.maxAbsoluteScore <= 0 ||
      policy.maxAbsoluteScore > 1) {
    throw RangeError(
      'Preference update policy values must be finite and positive.',
    );
  }
  if (policy.signalWeights.values.any((weight) => !weight.isFinite) ||
      _signalKinds.any(
        (kind) =>
            !policy.signalWeights.containsKey(kind) ||
            !policy.signalWeights[kind]!.isFinite,
      )) {
    throw RangeError(
      'Every preference signal kind must have a finite configured weight.',
    );
  }
}

void _validateSignal(PreferenceSignal signal, PreferenceUpdatePolicy policy) {
  if (signal.idempotencyKey.trim().isEmpty ||
      signal.taxonomyVersion.trim().isEmpty ||
      signal.labelId.trim().isEmpty) {
    throw ArgumentError('Preference signal key and label ID are required.');
  }
  if (!signal.confidence.isFinite ||
      signal.confidence < 0 ||
      signal.confidence > 1) {
    throw RangeError('Preference signal confidence must be between 0 and 1.');
  }
  if (!signal.occurredAtMs.isFinite || signal.occurredAtMs > policy.nowMs) {
    throw RangeError(
      'Preference signal time must be valid and cannot be in the future.',
    );
  }
}

/// Applies deduplicated, eligible feed signals to bounded preference features.
/// Event ingestion must enforce authorization and retention before calling this function.
PreferenceUpdateResult applyPreferenceSignals(
  List<PreferenceFeature> currentFeatures,
  List<PreferenceSignal> signals,
  List<String> previouslyAppliedKeys,
  PreferenceUpdatePolicy policy,
) {
  _validatePolicy(policy);

  final previouslyApplied = previouslyAppliedKeys.toSet();
  final seenInBatch = <String>{};
  final acceptedSignals = <PreferenceSignal>[];
  for (final signal in signals) {
    _validateSignal(signal, policy);
    if (previouslyApplied.contains(signal.idempotencyKey) ||
        !seenInBatch.add(signal.idempotencyKey)) {
      continue;
    }
    acceptedSignals.add(signal);
  }

  final byFeature = <String, PreferenceFeature>{};
  for (final feature in currentFeatures) {
    if (feature.taxonomyVersion.trim().isEmpty ||
        feature.labelId.trim().isEmpty ||
        !feature.score.isFinite ||
        !feature.confidence.isFinite ||
        feature.confidence < 0 ||
        feature.confidence > 1 ||
        !feature.updatedAtMs.isFinite ||
        feature.updatedAtMs > policy.nowMs ||
        !feature.expiresAtMs.isFinite ||
        feature.expiresAtMs <= feature.updatedAtMs ||
        feature.score.abs() > policy.maxAbsoluteScore ||
        feature.sourceSummary.isEmpty ||
        feature.sourceSummary.toSet().length != feature.sourceSummary.length) {
      throw RangeError('Existing preference features contain invalid values.');
    }
    final key = _featureKey(
      taxonomyVersion: feature.taxonomyVersion,
      dimension: feature.dimension,
      labelId: feature.labelId,
    );
    if (byFeature.containsKey(key)) {
      throw StateError(
        'Existing preference features must be unique per taxonomy label.',
      );
    }
    if (feature.expiresAtMs > policy.nowMs) byFeature[key] = feature;
  }

  if (policy.learningPaused) {
    final features = byFeature.values.toList()..sort(_compareFeatures);
    return PreferenceUpdateResult(
      features: features,
      appliedIdempotencyKeys: acceptedSignals
          .map((signal) => signal.idempotencyKey)
          .toList(),
    );
  }

  final signalsByFeature = <String, List<PreferenceSignal>>{};
  for (final signal in acceptedSignals) {
    final key = _featureKey(
      taxonomyVersion: signal.taxonomyVersion,
      dimension: signal.dimension,
      labelId: signal.labelId,
    );
    (signalsByFeature[key] ??= <PreferenceSignal>[]).add(signal);
  }

  final allKeys = <String>{...byFeature.keys, ...signalsByFeature.keys};
  final features = <PreferenceFeature>[];
  for (final key in allKeys) {
    final existing = byFeature[key];
    final keySignals = signalsByFeature[key] ?? const <PreferenceSignal>[];
    if (existing == null && keySignals.isEmpty) continue;
    final taxonomyVersion =
        existing?.taxonomyVersion ?? keySignals.first.taxonomyVersion;
    final dimension = existing?.dimension ?? keySignals.first.dimension;
    final labelId = existing?.labelId ?? keySignals.first.labelId;

    final previousDecay = existing == null
        ? 0.0
        : _decayFactor(policy.nowMs - existing.updatedAtMs, policy.halfLifeMs);
    var score = existing == null ? 0.0 : existing.score * previousDecay;
    var remainingConfidence = existing == null
        ? 1.0
        : 1 - existing.confidence * previousDecay;
    for (final signal in keySignals) {
      final weight = policy.signalWeights[signal.kind]!;
      final signalDecay = _decayFactor(
        policy.nowMs - signal.occurredAtMs,
        policy.halfLifeMs,
      );
      score += weight * signal.confidence * signalDecay;
      remainingConfidence *= 1 - signal.confidence * signalDecay;
    }

    final sourceSummary = <PreferenceSignalKind>{...?existing?.sourceSummary};
    sourceSummary.addAll(keySignals.map((signal) => signal.kind));
    final sortedSources = sourceSummary.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    features.add(
      PreferenceFeature(
        taxonomyVersion: taxonomyVersion,
        dimension: dimension,
        labelId: labelId,
        sourceSummary: sortedSources,
        score: _clamp(score, -policy.maxAbsoluteScore, policy.maxAbsoluteScore),
        confidence: _clamp(1 - remainingConfidence, 0, 1),
        updatedAtMs: policy.nowMs,
        expiresAtMs: keySignals.isNotEmpty
            ? policy.nowMs + policy.expiryAfterMs
            : (existing?.expiresAtMs ?? policy.nowMs + policy.expiryAfterMs),
      ),
    );
  }

  features.sort(_compareFeatures);
  return PreferenceUpdateResult(
    features: features,
    appliedIdempotencyKeys: acceptedSignals
        .map((signal) => signal.idempotencyKey)
        .toList(),
  );
}
