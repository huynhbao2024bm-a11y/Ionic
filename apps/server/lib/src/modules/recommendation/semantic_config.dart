import 'dart:io';

const semanticModelVersion = 'e5-small-614241f6-qint8-v1';

class SemanticConfig {
  SemanticConfig({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final flag = env['RECOMMENDATION_SEMANTIC_ENABLED'] ?? 'false';
    if (!const ['true', 'false'].contains(flag)) {
      throw const FormatException('Invalid semantic enable flag.');
    }
    enabled = flag == 'true';
    double unit(String key, double fallback) {
      final value = double.tryParse(env[key] ?? '$fallback');
      if (value == null || !value.isFinite || value <= 0 || value > 1) {
        throw FormatException('Invalid $key.');
      }
      return value;
    }

    minimumSimilarity = unit('RECOMMENDATION_SEMANTIC_MIN_SIMILARITY', .84);
    if (minimumSimilarity == 1) {
      throw const FormatException(
        'Semantic minimum similarity must be below 1.',
      );
    }
    negativeMargin = unit('RECOMMENDATION_SEMANTIC_NEGATIVE_MARGIN', .025);
  }
  late final bool enabled;
  late final double minimumSimilarity;
  late final double negativeMargin;
}
