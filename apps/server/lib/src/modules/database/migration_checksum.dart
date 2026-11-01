import 'dart:convert';

import 'package:crypto/crypto.dart';

String canonicalMigrationSql(String source) => source.replaceAll('\r\n', '\n');
String migrationChecksum(String source) =>
    sha256.convert(utf8.encode(canonicalMigrationSql(source))).toString();

/// Accept the original Windows hash only when it differs solely in line endings.
/// Never accept a changed statement/comment as an already applied migration.
bool matchesMigrationChecksum(String source, String saved) {
  final canonical = canonicalMigrationSql(source);
  return saved == migrationChecksum(canonical) ||
      saved ==
          sha256
              .convert(utf8.encode(canonical.replaceAll('\n', '\r\n')))
              .toString();
}
