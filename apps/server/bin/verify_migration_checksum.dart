import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ionic_server/src/modules/database/migration_checksum.dart';

void main() {
  const sql = 'CREATE TABLE example(id int);\n-- retained comment\n';
  final legacy = sha256
      .convert(utf8.encode(sql.replaceAll('\n', '\r\n')))
      .toString();
  if (migrationChecksum(sql) !=
          migrationChecksum(sql.replaceAll('\n', '\r\n')) ||
      !matchesMigrationChecksum(sql, legacy) ||
      !matchesMigrationChecksum(sql, migrationChecksum(sql)) ||
      matchesMigrationChecksum(sql.replaceFirst('int', 'text'), legacy) ||
      matchesMigrationChecksum(sql.replaceFirst('retained', 'changed'), legacy)) {
    throw StateError('Migration checksum regression.');
  }
  stdout.writeln(
    'PASS: 5 migration checksum checks; line endings only, source changes rejected.',
  );
}
