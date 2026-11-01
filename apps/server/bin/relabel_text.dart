import 'dart:convert';
import 'dart:io';

import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/recommendation/content_labeler.dart';
import 'package:ionic_server/src/modules/recommendation/text_label_rules.dart';
import 'package:ionic_server/src/modules/recommendation/types.dart';

/// Dry-run by default. Reclassifies current public text in bounded transactions;
/// does not emit viewer signals or overwrite creator/user-corrected labels.
Future<void> main(List<String> args) async {
  if (args.any((a) => a != '--apply')) {
    throw ArgumentError('Use --apply or no arguments for dry-run.');
  }
  final database = DatabaseService.fromEnvironment();
  final version =
      Platform.environment['RECOMMENDATION_TAXONOMY_VERSION']?.trim() ??
      'ionic-taxonomy-v1';
  if (version != 'ionic-taxonomy-v1') {
    throw StateError('No migration mapping for that taxonomy.');
  }
  var items = 0, proposedLabels = 0;
  String? after;
  try {
    while (true) {
      final batch = await database.transaction((tx) async {
        final rows = await tx.execute(
          r'''SELECT c.id, c.body FROM content c
          JOIN app_user u ON u.id = c.author_id AND u.state = 'active'
          JOIN user_profile p ON p.user_id = u.id AND p.visibility = 'public'
          WHERE c.kind = 'text' AND c.status = 'published' AND c.deleted_at IS NULL
            AND ($1::uuid IS NULL OR c.id > $1)
          ORDER BY c.id LIMIT 200 FOR UPDATE OF c''',
          parameters: [after],
        );
        for (final row in rows) {
          final id = '${row[0]}';
          final labels = labelContent(
            LabelContentInput(
              taxonomyVersion: version,
              kind: ContentKind.text,
              text: '${row[1]}',
              formatLabelIds: const {ContentKind.text: 'format.text'},
              keywordRules: textLabelRules,
            ),
          );
          proposedLabels += labels.length;
          if (args.contains('--apply')) {
            await tx.execute(
              r"DELETE FROM content_label WHERE content_id = $1 AND taxonomy_version = $2 AND source = 'rule'",
              parameters: [id, version],
            );
            for (final label in labels) {
              await tx.execute(
                r'''INSERT INTO content_label(content_id, taxonomy_version, dimension, label_id, confidence, source)
                VALUES ($1, $2, $3, $4, $5, 'rule') ON CONFLICT DO NOTHING''',
                parameters: [
                  id,
                  version,
                  label.dimension.name,
                  label.labelId,
                  label.confidence,
                ],
              );
            }
          }
        }
        return rows;
      });
      items += batch.length;
      if (batch.isEmpty) break;
      after = '${batch.last[0]}';
    }
    stdout.writeln(
      jsonEncode({
        'mode': args.contains('--apply') ? 'applied' : 'dry-run',
        'classifierVersion': textLabelRulesVersion,
        'posts': items,
        'proposedLabels': proposedLabels,
      }),
    );
  } finally {
    await database.close();
  }
}
