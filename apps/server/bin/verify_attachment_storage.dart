import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ionic_server/src/modules/media/attachment_storage.dart';
import 'package:ionic_server/src/http/api_exception.dart';

Future<void> main() async {
  var checks = 0;
  void check(bool ok, String label) {
    if (!ok) throw StateError(label);
    checks++;
  }

  final root = await Directory.systemTemp.createTemp('ionic-storage-verify-');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final bytes = Uint8List.fromList([1, 2, 3, 4]);
  const key = '10000000-0000-4000-8000-000000000001';
  var mode = 'ok';
  final requests = <Map<String, Object?>>[];
  final subscription = server.listen((r) async {
    final body = await r.fold<List<int>>([], (a, b) => a..addAll(b));
    requests.add({
      'method': r.method,
      'path': r.uri.path,
      'apikey': r.headers.value('apikey'),
      'authorization': r.headers.value('authorization'),
      'body': body,
    });
    if (mode == 'error') {
      r.response.statusCode = 500;
      r.response.write('Private upstream detail');
    } else if (mode == 'redirect') {
      r.response.statusCode = 307;
      r.response.headers.set('location', 'http://127.0.0.1:1/forbidden');
    } else if (r.method == 'GET') {
      r.response.contentLength = mode == 'oversize' ? 5 : 4;
      r.response.add(mode == 'oversize' ? [1, 2, 3, 4, 5] : bytes);
    } else {
      r.response.write('{}');
    }
    await r.response.close();
  });
  try {
    final local = LocalAttachmentStorage(root);
    await local.write(key, bytes, 'image/jpeg');
    check(
      (await (await local.read(key, 4)).expand((b) => b).toList()).join(',') ==
          '1,2,3,4',
      'Local bytes persist',
    );
    await local.delete(key);
    await local.delete(key);
    check(
      !await File('${root.path}/$key').exists(),
      'Local deletion idempotent',
    );
    try {
      await local.write('../escape', bytes, 'image/jpeg');
      throw StateError('Expected key rejection');
    } on ArgumentError {
      checks++;
    }
    final cloud = SupabaseAttachmentStorage(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'sb_secret_synthetic-verification-only',
      'ionic-media',
    );
    await cloud.write(key, bytes, 'image/jpeg');
    check(
      requests.last['method'] == 'POST' &&
          requests.last['path'] == '/storage/v1/object/ionic-media/$key',
      'Cloud private upload path',
    );
    check(
      requests.last['authorization'] == null &&
          requests.last['apikey'] == 'sb_secret_synthetic-verification-only',
      'Modern server key never used as user JWT',
    );
    check(
      (await (await cloud.read(key, 4)).expand((b) => b).toList()).length == 4,
      'Cloud private stream bounded',
    );
    check(
      requests.last['path'] == '/storage/v1/object/ionic-media/$key',
      'Cloud private read uses the official authenticated transport',
    );
    await cloud.delete(key);
    check(
      (jsonDecode(
            utf8.decode(requests.last['body'] as List<int>),
          ) as Map)['prefixes'].single ==
          key,
      'Cloud deletion targets only the owned key',
    );
    final legacy = SupabaseAttachmentStorage(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'synthetic.legacy.jwt',
      'ionic-media',
    );
    await legacy.write(key, bytes, 'audio/wav');
    check(
      requests.last['authorization'] == 'Bearer synthetic.legacy.jwt',
      'Legacy server JWT remains backend-only',
    );
    for (final bad in ['error', 'redirect', 'oversize']) {
      mode = bad;
      try {
        await cloud.read(key, 4);
        throw StateError('Expected storage rejection');
      } on ApiException catch (e) {
        check(
          e.statusCode == 503 && !e.message.contains('Private'),
          'Storage failure is stable and redacted',
        );
      }
    }
    check(
      requests.every((r) => !(r['path'] as String).contains('public')),
      'No public object URL',
    );
    stdout.writeln(
      'PASS: $checks private attachment storage checks; mock HTTP transport, not provider confirmation.',
    );
  } finally {
    await subscription.cancel();
    await server.close(force: true);
    // This test owns this exact temporary directory and every file it contains.
    final resolved = await root.resolveSymbolicLinks(),
        tempRoot = await Directory.systemTemp.resolveSymbolicLinks();
    if (!resolved.startsWith(
      '$tempRoot${Platform.pathSeparator}ionic-storage-verify-',
    )) {
      throw StateError('Unexpected cleanup path.');
    }
    await Directory(resolved).delete(recursive: true);
  }
}
