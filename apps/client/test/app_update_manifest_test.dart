import 'package:flutter_test/flutter_test.dart';
import 'package:ionic_client/src/app_update_manifest.dart';

void main() {
  Map<String, Object?> manifest({
    String? url,
    String? hash,
    int size = 22000000,
  }) => {
    'schemaVersion': 1,
    'version': '0.1.1',
    'assets': {
      'arm64-v8a': {
        'url': url ?? '${updateRepository}v0.1.1-preview.3/ionic-arm64.apk',
        'sha256': hash ?? 'a' * 64,
        'bytes': size,
        'versionCode': 2003,
      },
    },
  };
  test('Update selects supported ABI and actual APK versionCode', () {
    final release = AndroidRelease.parse(manifest(), [
      'arm64-v8a',
      'armeabi-v7a',
    ])!;
    expect(release.versionCode, 2003);
    expect(release.bytes, 22000000);
    expect(AndroidRelease.parse(manifest(), ['x86_64']), isNull);
  });
  test(
    'Update rejects untrusted sources, query URLs, bad digests and sizes',
    () {
      for (final url in [
        'http://github.com/a.apk',
        'https://evil.example/a.apk',
        'https://github.com/another/repo/releases/download/v1/a.apk',
        '${updateRepository}v1/a.apk?changed=1',
        '${updateRepository}v1/a.apk#fragment',
      ]) {
        expect(
          () => AndroidRelease.parse(manifest(url: url), ['arm64-v8a']),
          throwsFormatException,
        );
      }
      for (final size in [0, 65 * 1024 * 1024]) {
        expect(
          () => AndroidRelease.parse(manifest(size: size), ['arm64-v8a']),
          throwsFormatException,
        );
      }
      expect(
        () => AndroidRelease.parse(manifest(hash: 'wrong'), ['arm64-v8a']),
        throwsFormatException,
      );
      expect(
        () => AndroidRelease.parse({'schemaVersion': 2}, ['arm64-v8a']),
        throwsFormatException,
      );
    },
  );
}
