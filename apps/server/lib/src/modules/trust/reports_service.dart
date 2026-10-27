import 'dart:math';
import 'dart:typed_data';

import 'package:ionic_server/src/http/api_exception.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:postgres/postgres.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

const _reportReasons = {
  'spam',
  'harassment',
  'harmful',
  'impersonation',
  'other',
};
final _contentIdPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
);

class ReportsService {
  ReportsService(this._database);

  final DatabaseService _database;

  Future<Map<String, Object?>> create(
    String reporterId,
    Map<String, Object?> input,
  ) async {
    if (input.keys.any(
      (key) => !const {'contentId', 'reason', 'details'}.contains(key),
    )) {
      throw const ApiException(400, 'Report contains an unsupported field.');
    }
    final contentId = input['contentId'];
    if (contentId is! String || !_contentIdPattern.hasMatch(contentId)) {
      throw const ApiException(400, 'Content ID is invalid.');
    }
    final reason = input['reason'];
    if (reason is! String || !_reportReasons.contains(reason)) {
      throw const ApiException(400, 'Report reason is invalid.');
    }
    final rawDetails = input.containsKey('details') ? input['details'] : '';
    if (rawDetails is! String) {
      throw const ApiException(400, 'Report details must be text.');
    }
    final details = unorm.nfc(rawDetails.trim());
    if (details.length > 500) {
      throw const ApiException(
        400,
        'Report details must be 500 characters or fewer.',
      );
    }

    return _database.transaction((transaction) async {
      await _assertReportable(transaction, reporterId, contentId);
      final inserted = await transaction.execute(
        r'''INSERT INTO content_report (id, reporter_id, content_id, reason, details)
            VALUES ($1, $2, $3, $4, $5)
            ON CONFLICT (reporter_id, content_id) DO NOTHING
            RETURNING id, status, created_at''',
        parameters: [_randomUuid(), reporterId, contentId, reason, details],
      );
      final result = inserted.isNotEmpty
          ? inserted
          : await transaction.execute(
              r'''SELECT id, status, created_at FROM content_report
                  WHERE reporter_id = $1 AND content_id = $2''',
              parameters: [reporterId, contentId],
            );
      if (result.isEmpty) {
        throw const ApiException(404, 'Content was not found.');
      }
      final row = result.first.toColumnMap();
      return {
        'id': '${row['id']}',
        'status': '${row['status']}',
        'createdAt': _dateTime(row['created_at']).toUtc().toIso8601String(),
      };
    });
  }

  Future<void> _assertReportable(
    TxSession transaction,
    String reporterId,
    String contentId,
  ) async {
    final result = await transaction.execute(
      r'''SELECT c.id FROM content c
          JOIN app_user u ON u.id = c.author_id AND u.state = 'active'
          JOIN user_profile p ON p.user_id = u.id
          WHERE c.id = $1 AND c.kind = 'text' AND c.status = 'published'
            AND c.deleted_at IS NULL AND u.id <> $2
            AND (p.visibility = 'public' OR EXISTS (
              SELECT 1 FROM account_follow f
              WHERE f.follower_id = $2 AND f.followed_id = u.id
            ))
            AND NOT EXISTS (
              SELECT 1 FROM account_block b
              WHERE (b.blocker_id = $2 AND b.blocked_id = u.id)
                 OR (b.blocker_id = u.id AND b.blocked_id = $2)
            )
          FOR SHARE OF c, u, p''',
      parameters: [contentId, reporterId],
    );
    if (result.length != 1) {
      throw const ApiException(404, 'Content was not found.');
    }
  }
}

String _randomUuid() {
  final random = Random.secure();
  final bytes = Uint8List.fromList(
    List<int>.generate(16, (_) => random.nextInt(256)),
  );
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

DateTime _dateTime(Object? value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.parse(value);
  throw StateError('Database returned an invalid timestamp.');
}
