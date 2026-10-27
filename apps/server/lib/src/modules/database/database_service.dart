import 'dart:io';

import 'package:postgres/postgres.dart';

enum DatabaseReadiness { ready, unconfigured, unavailable, schemaPending }

const _requiredMigrations = <String>[
  '0001_identity_and_text_posts.sql',
  '0002_profiles_follows_and_blocks.sql',
  '0003_personalized_feed_controls.sql',
  '0004_persistent_post_actions.sql',
  '0005_recommendation_candidate_retrieval.sql',
  '0006_direct_messaging.sql',
  '0007_video_uploads.sql',
  '0008_post_search_and_reports.sql',
  '0009_account_mutes.sql',
  '0010_video_recommendation_signals.sql',
  '0011_video_signal_lookup_index.sql',
  '0012_image_voice_attachments.sql',
];

class DatabaseService {
  DatabaseService.fromEnvironment({String? connectionString})
    : _pool = _createPool(
        connectionString ?? Platform.environment['DATABASE_URL'],
      );

  final Pool<Endpoint>? _pool;

  static Pool<Endpoint>? _createPool(String? connectionString) {
    final normalized = connectionString?.trim();
    if (normalized == null || normalized.isEmpty) return null;
    final uri = Uri.parse(normalized);
    final parameters = <String, String>{
      ...uri.queryParameters,
      'max_connection_count': '5',
      'connect_timeout': '2',
    };
    return Pool.withUrl(uri.replace(queryParameters: parameters).toString());
  }

  bool get isConfigured => _pool != null;

  Pool<Endpoint> get pool {
    final configured = _pool;
    if (configured == null) throw StateError('PostgreSQL is not configured.');
    return configured;
  }

  Future<Result> query(String sql, {Object? parameters}) =>
      pool.execute(sql, parameters: parameters);

  Future<R> transaction<R>(Future<R> Function(TxSession session) operation) =>
      pool.runTx(operation);

  Future<DatabaseReadiness> checkReadiness() async {
    final configured = _pool;
    if (configured == null) return DatabaseReadiness.unconfigured;

    try {
      final migrationTable = await configured.execute(
        "SELECT to_regclass('public.schema_migration')::text",
      );
      if (migrationTable.isEmpty || migrationTable.first.first == null) {
        return DatabaseReadiness.schemaPending;
      }

      final applied = await configured.execute(
        r'SELECT COUNT(*) FROM schema_migration WHERE version = ANY($1::text[])',
        parameters: [_requiredMigrations],
      );
      final count = int.tryParse('${applied.first.first}') ?? 0;
      return count == _requiredMigrations.length
          ? DatabaseReadiness.ready
          : DatabaseReadiness.schemaPending;
    } on Exception {
      return DatabaseReadiness.unavailable;
    }
  }

  Future<void> close() async {
    await _pool?.close();
  }
}
