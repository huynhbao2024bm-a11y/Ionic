import 'package:shelf/shelf.dart';

import 'dart:io';

import 'package:ionic_server/src/http/preview_rate_limit.dart';

Future<void> main() async {
  var now = 1000, checks = 0;
  final app = previewRateLimit(clockSeconds: () => now)(
    (r) => Response.ok('accepted'),
  );
  Future<Response> call(String path, {String method = 'POST'}) async =>
      await app(
        Request(method, Uri.parse('https://example.test/api/v1/$path')),
      );
  for (var i = 0; i < 10; i++) {
    if ((await call('auth/register')).statusCode != 200) {
      throw StateError('Registration allowance');
    }
    checks++;
  }
  final blocked = await call('auth/register');
  if (blocked.statusCode != 429 || blocked.headers['retry-after'] != '600') {
    throw StateError('Registration cap');
  }
  checks++;
  if ((await call('health/ready', method: 'GET')).statusCode != 200 ||
      (await call('posts')).statusCode != 200) {
    throw StateError('Independent budgets');
  }
  checks += 2;
  now += 600;
  if ((await call('auth/register')).statusCode != 200) {
    throw StateError('Expiry reset');
  }
  checks++;
  stdout.writeln('PASS: $checks single-instance preview limit checks.');
}
