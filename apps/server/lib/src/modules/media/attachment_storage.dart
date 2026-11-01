import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../http/api_exception.dart';

/// Private storage transport only. MediaService must authorize the parent first.
abstract class AttachmentStorage {
  factory AttachmentStorage.fromEnvironment() {
    final kind = Platform.environment['IONIC_ATTACHMENT_STORAGE'] ?? 'local';
    if (kind == 'supabase') {
      final url = Uri.tryParse(Platform.environment['SUPABASE_URL'] ?? '');
      final key = Platform.environment['SUPABASE_SECRET_KEY'] ?? '';
      if (url == null ||
          url.scheme != 'https' ||
          url.host.isEmpty ||
          url.userInfo.isNotEmpty ||
          url.hasQuery ||
          url.hasFragment ||
          key.isEmpty) {
        throw StateError(
          'Supabase private storage configuration is incomplete.',
        );
      }
      return SupabaseAttachmentStorage(
        url,
        key,
        Platform.environment['IONIC_STORAGE_BUCKET'] ?? 'ionic-media',
      );
    }
    if (kind != 'local' || Platform.environment['APP_ENV'] == 'production') {
      throw StateError(
        'Production requires configured private object storage.',
      );
    }
    return LocalAttachmentStorage(
      Directory(
        Platform.environment['IONIC_ATTACHMENT_DIR'] ?? '.data/attachments',
      ).absolute,
    );
  }
  Future<void> write(String key, Uint8List bytes, String mimeType);
  Future<Stream<List<int>>> read(String key, int expectedBytes);
  Future<void> delete(String key);
}

void _checkKey(String key) {
  if (!RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  ).hasMatch(key)) {
    throw ArgumentError('Invalid opaque object key.');
  }
}

class LocalAttachmentStorage implements AttachmentStorage {
  LocalAttachmentStorage(this.root);
  final Directory root;
  File _file(String key) {
    _checkKey(key);
    return File('${root.path}${Platform.pathSeparator}$key');
  }

  @override
  Future<void> write(String key, Uint8List bytes, String mimeType) async {
    final target = _file(key), temporary = File('${_file(key).path}.part');
    await root.create(recursive: true);
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  @override
  Future<Stream<List<int>>> read(String key, int expectedBytes) async {
    final file = _file(key);
    if (!await file.exists() || await file.length() != expectedBytes) {
      throw const ApiException(404, 'Attachment was not found.');
    }
    return file.openRead();
  }

  @override
  Future<void> delete(String key) async {
    for (final file in [_file(key), File('${_file(key).path}.part')]) {
      if (await file.exists()) await file.delete();
    }
  }
}

class SupabaseAttachmentStorage implements AttachmentStorage {
  SupabaseAttachmentStorage(this.origin, this.secret, this.bucket) {
    if (!RegExp(r'^[a-z0-9][a-z0-9-]{1,62}$').hasMatch(bucket)) {
      throw ArgumentError('Invalid private bucket.');
    }
  }
  final Uri origin;
  final String secret, bucket;
  Uri _uri(List<String> path) =>
      origin.replace(pathSegments: ['storage', 'v1', ...path]);
  Future<({HttpClient client, HttpClientResponse response})> _request(
    String method,
    List<String> path, {
    List<int>? body,
    String? mimeType,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client
          .openUrl(method, _uri(path))
          .timeout(const Duration(seconds: 10));
      request.followRedirects = false;
      request.headers.set('apikey', secret);
      // Modern sb_secret keys are authenticated by the gateway via apikey.
      if (!secret.startsWith('sb_secret_')) {
        request.headers.set('authorization', 'Bearer $secret');
      }
      if (mimeType != null) request.headers.set('content-type', mimeType);
      if (body != null) {
        request.contentLength = body.length;
        request.add(body);
      }
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final missing = response.statusCode == 404;
        client.close(force: true);
        if (method == 'GET' && missing) {
          throw const ApiException(404, 'Attachment was not found.');
        }
        throw const ApiException(503, 'Attachment storage is unavailable.');
      }
      return (client: client, response: response);
    } on ApiException {
      client.close(force: true);
      rethrow;
    } catch (_) {
      client.close(force: true);
      throw const ApiException(503, 'Attachment storage is unavailable.');
    }
  }

  @override
  Future<void> write(String key, Uint8List bytes, String mimeType) async {
    _checkKey(key);
    if (bytes.isEmpty ||
        bytes.length > 8 * 1024 * 1024 ||
        !['image/jpeg', 'audio/wav'].contains(mimeType)) {
      throw ArgumentError('Invalid sanitized object.');
    }
    final result = await _request(
      'POST',
      ['object', bucket, key],
      body: bytes,
      mimeType: mimeType,
    );
    result.client.close(force: true);
  }

  @override
  Future<Stream<List<int>>> read(String key, int expectedBytes) async {
    _checkKey(key);
    if (expectedBytes < 1 || expectedBytes > 8 * 1024 * 1024) {
      throw ArgumentError('Invalid object size.');
    }
    final result = await _request('GET', ['object', bucket, key]);
    final length = result.response.contentLength;
    if (length >= 0 && length != expectedBytes) {
      result.client.close(force: true);
      throw const ApiException(
        503,
        'Attachment storage returned an invalid object.',
      );
    }
    return _boundedStream(result, expectedBytes);
  }

  Stream<List<int>> _boundedStream(
    ({HttpClient client, HttpClientResponse response}) result,
    int expected,
  ) async* {
    var bytes = 0;
    try {
      await for (final chunk in result.response.timeout(
        const Duration(seconds: 20),
      )) {
        bytes += chunk.length;
        if (bytes > expected) throw StateError('Object exceeds expected size.');
        yield chunk;
      }
      if (bytes != expected) throw StateError('Object is incomplete.');
    } finally {
      result.client.close(force: true);
    }
  }

  @override
  Future<void> delete(String key) async {
    _checkKey(key);
    final result = await _request(
      'DELETE',
      ['object', bucket],
      body: utf8.encode(
        jsonEncode({
          'prefixes': [key],
        }),
      ),
      mimeType: 'application/json',
    );
    result.client.close(force: true);
  }
}
