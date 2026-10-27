import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart';

Future<void> main() async {
  final connectionString = Platform.environment['DATABASE_URL']?.trim();
  if (connectionString == null || connectionString.isEmpty) {
    throw StateError('Set DATABASE_URL before running database migrations.');
  }

  final serverDirectory = File.fromUri(Platform.script).parent.parent;
  final migrationsDirectory = Directory(
    '${serverDirectory.parent.path}${Platform.pathSeparator}'
    'api${Platform.pathSeparator}migrations',
  );
  if (!migrationsDirectory.existsSync()) {
    throw StateError(
      'Migration directory was not found: ${migrationsDirectory.path}',
    );
  }

  final poolUrl = Uri.parse(connectionString).replace(
    queryParameters: {
      ...Uri.parse(connectionString).queryParameters,
      'max_connection_count': '1',
      'connect_timeout': '2',
    },
  );
  final pool = Pool<Endpoint>.withUrl(poolUrl.toString());
  try {
    final files =
        migrationsDirectory
            .listSync(followLinks: false)
            .whereType<File>()
            .where(
              (file) =>
                  RegExp(r'^\d{4}_[a-z0-9_]+\.sql$')
                      .hasMatch(file.uri.pathSegments.last),
            )
            .toList()
          ..sort(
            (left, right) => left.uri.pathSegments.last.compareTo(
              right.uri.pathSegments.last,
            ),
          );
    final appliedVersions = <String>[];

    await pool.runTx((transaction) async {
      await transaction.execute(
        "SELECT pg_advisory_xact_lock(hashtext('ionic:schema-migrations'))",
      );
      await transaction.execute('''
        CREATE TABLE IF NOT EXISTS schema_migration (
          version text PRIMARY KEY,
          checksum varchar(64) NOT NULL,
          applied_at timestamptz NOT NULL DEFAULT now()
        )
      ''', queryMode: QueryMode.simple);

      for (final file in files) {
        final name = file.uri.pathSegments.last;
        final sql = await file.readAsString();
        final checksum = sha256.convert(await file.readAsBytes()).toString();
        final existing = await transaction.execute(
          r'SELECT checksum FROM schema_migration WHERE version = $1',
          parameters: [name],
        );
        if (existing.isNotEmpty) {
          final savedChecksum = existing.first.toColumnMap()['checksum'];
          if (savedChecksum != checksum) {
            throw StateError(
              'Applied migration $name was modified; create a new migration instead.',
            );
          }
          continue;
        }

        await transaction.execute(sql, queryMode: QueryMode.simple);
        await transaction.execute(
          r'INSERT INTO schema_migration(version, checksum) VALUES ($1, $2)',
          parameters: [name, checksum],
        );
        appliedVersions.add(name);
      }
    });

    for (final version in appliedVersions) {
      stdout.writeln('Applied $version');
    }
    if (appliedVersions.isEmpty) {
      stdout.writeln('Database schema is up to date.');
    }
  } finally {
    await pool.close();
  }
}
