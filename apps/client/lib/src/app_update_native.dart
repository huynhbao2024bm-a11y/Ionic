import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'app_update_manifest.dart';

class AndroidUpdates {
  static const channel = MethodChannel('app.ionic/update');
  bool get supported => Platform.isAndroid;
  HttpClient? _downloadClient;
  Future<Map<Object?, Object?>> info() async =>
      (await channel.invokeMapMethod<Object?, Object?>('info'))!;
  bool _trusted(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      uri.port == 443 &&
      const [
        'api.github.com',
        'github.com',
        'release-assets.githubusercontent.com',
        'objects.githubusercontent.com',
      ].contains(uri.host);
  Future<HttpClientResponse> _get(HttpClient client, Uri uri) async {
    for (var redirects = 0; redirects < 6; redirects++) {
      if (!_trusted(uri)) {
        throw const FormatException('Untrusted update redirect.');
      }
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 25));
      request.followRedirects = false;
      request.headers.set(
        'accept',
        'application/json, application/octet-stream',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value('location');
        await response.drain<void>();
        if (location == null) throw const FormatException('Missing redirect.');
        uri = uri.resolve(location);
        continue;
      }
      return response;
    }
    throw const FormatException('Too many update redirects.');
  }

  Future<Object?> _json(HttpClient client, Uri uri) async {
    final response = await _get(client, uri);
    if (response.statusCode == 404) {
      await response.drain<void>();
      return null;
    }
    if (response.statusCode != 200) {
      throw const HttpException('Update service unavailable.');
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      if (bytes.length + chunk.length > 256 * 1024) {
        throw const FormatException('Update metadata too large.');
      }
      bytes.addAll(chunk);
    }
    return jsonDecode(utf8.decode(bytes));
  }

  Future<AndroidRelease?> check() async {
    if (!supported) return null;
    final installed = await info();
    if (installed['storeManaged'] == true) return null;
    final client = HttpClient()..userAgent = 'Ionic-Android-Update/1';
    try {
      final releases = await _json(
        client,
        Uri.parse(
          'https://api.github.com/repos/huynhbao2024bm-a11y/Ionic/releases?per_page=5',
        ),
      );
      if (releases is! List) return null;
      for (final release in releases.whereType<Map<String, dynamic>>()) {
        if (release['draft'] != false || release['assets'] is! List) continue;
        for (final asset
            in (release['assets'] as List).whereType<Map<String, dynamic>>()) {
          if (asset['name'] != 'ionic-android-update.json') continue;
          final url = Uri.tryParse('${asset['browser_download_url']}');
          if (url == null ||
              !url.toString().startsWith(updateRepository) ||
              url.hasQuery ||
              url.hasFragment) {
            throw const FormatException('Invalid manifest source.');
          }
          final next = AndroidRelease.parse(
            await _json(client, url),
            (installed['abis'] as List).cast<String>(),
          );
          return next != null &&
                  next.versionCode > (installed['versionCode'] as int)
              ? next
              : null;
        }
      }
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> unmetered() async {
    try {
      return supported && await channel.invokeMethod<bool>('unmetered') == true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> canInstall() async {
    try {
      return supported &&
          await channel.invokeMethod<bool>('canInstall') == true;
    } catch (_) {
      return false;
    }
  }

  Future<String> download(
    AndroidRelease release,
    void Function(double) progress,
  ) async {
    if (_downloadClient != null) {
      throw StateError('Another update is downloading.');
    }
    final installed = await info();
    final dir = Directory(installed['updateDirectory'] as String);
    final target = File('${dir.path}/update-${release.sha256}.apk'),
        part = File('${target.path}.part');
    if (await target.exists() &&
        await target.length() == release.bytes &&
        (await crypto.sha256.bind(target.openRead()).first).toString() ==
            release.sha256) {
      try {
        if (await channel.invokeMethod<bool>('verify', {'path': target.path}) ==
            true) {
          return target.path;
        }
      } catch (_) {
        /* Discard an invalid or superseded cached APK. */
      }
      await target.delete();
    }
    // Delete only this app's known previous update artifacts, never user media.
    await for (final file in dir.list()) {
      if (file is File &&
          RegExp(
            r'^update-[a-f0-9]{64}\.apk(?:\.part)?$',
          ).hasMatch(file.uri.pathSegments.last)) {
        await file.delete();
      }
    }
    final client = HttpClient()..userAgent = 'Ionic-Android-Update/1';
    _downloadClient = client;
    IOSink? sink;
    try {
      if (release.versionCode <= (installed['versionCode'] as int)) {
        throw StateError('Update is no longer newer.');
      }
      final response = await _get(client, release.url);
      if (response.statusCode != 200 ||
          (response.contentLength >= 0 &&
              response.contentLength != release.bytes)) {
        throw const HttpException('Invalid update response.');
      }
      sink = part.openWrite();
      var received = 0, percent = -1;
      await for (final chunk in response.timeout(const Duration(seconds: 45))) {
        received += chunk.length;
        if (received > release.bytes) {
          throw const FormatException('Update size exceeded.');
        }
        sink.add(chunk);
        final next = received * 100 ~/ release.bytes;
        if (next != percent) {
          percent = next;
          progress(received / release.bytes);
        }
      }
      await sink.close();
      sink = null;
      if (received != release.bytes ||
          (await crypto.sha256.bind(part.openRead()).first).toString() !=
              release.sha256) {
        throw const FormatException('Update integrity mismatch.');
      }
      await part.rename(target.path);
      final verified = await channel.invokeMethod<bool>('verify', {
        'path': target.path,
      });
      if (verified != true) {
        throw const FormatException('APK identity or signature mismatch.');
      }
      return target.path;
    } catch (_) {
      if (await part.exists()) await part.delete();
      if (await target.exists()) await target.delete();
      rethrow;
    } finally {
      await sink?.close();
      client.close(force: true);
      _downloadClient = null;
    }
  }

  Future<String> install(String path) async =>
      (await channel.invokeMethod<String>('install', {'path': path}))!;
  void cancel() => _downloadClient?.close(force: true);
}
