import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';

/// Read-only verified-TLS probe. The generated password arrives over stdin,
/// never via a command argument, URI log, fixture or source file.
Future<void> main(List<String> args) async {
  if (args.length != 1 || !RegExp(r'^[a-z]{20}$').hasMatch(args.single)) {
    throw ArgumentError('Supply the intended project ref.');
  }
  if (stdin.hasTerminal) stdin.echoMode = false;
  final password = stdin.readLineSync();
  if (stdin.hasTerminal) stdin.echoMode = true;
  if (password == null || password.isEmpty) {
    throw StateError('Credential missing.');
  }
  for (final shard in [0, 1]) {
    final host = 'aws-$shard-ap-southeast-1.pooler.supabase.com';
    Connection? connection;
    try {
      connection = await Connection.open(
        Endpoint(
          host: host,
          port: 5432,
          database: 'postgres',
          username: 'ionic_api.${args.single}',
          password: password,
        ),
        settings: ConnectionSettings(
          sslMode: SslMode.verifyFull,
          securityContext: SecurityContext(withTrustedRoots: true)
            ..setTrustedCertificates('../../infra/supabase/prod-ca-2021.crt'),
          connectTimeout: Duration(seconds: 10),
          queryTimeout: Duration(seconds: 10),
        ),
      );
      final rows = await connection.execute(
        'SELECT current_user,current_schema(),(SELECT count(*) FROM schema_migration)',
      );
      if (rows.first[0] != 'ionic_api' ||
          rows.first[1] != 'ionic' ||
          rows.first[2] != 17) {
        throw StateError('Unexpected application schema.');
      }
      stdout.writeln(
        jsonEncode({
          'host': host,
          'verifiedTls': true,
          'schema': rows.first[1],
          'migrations': rows.first[2],
        }),
      );
      return;
    } catch (error) {
      stderr.writeln('Connection probe $shard: ${error.runtimeType}');
    } finally {
      await connection?.close();
    }
  }
  exitCode = 1;
}
