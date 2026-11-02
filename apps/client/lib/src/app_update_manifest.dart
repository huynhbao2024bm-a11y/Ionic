const updateRepository =
    'https://github.com/huynhbao2024bm-a11y/Ionic/releases/download/';

class AndroidRelease {
  const AndroidRelease({
    required this.version,
    required this.versionCode,
    required this.url,
    required this.sha256,
    required this.bytes,
  });
  final String version, sha256;
  final int versionCode, bytes;
  final Uri url;
  static AndroidRelease? parse(Object? input, List<String> abis) {
    if (input is! Map ||
        input['schemaVersion'] != 1 ||
        input['version'] is! String ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(input['version'] as String) ||
        input['assets'] is! Map) {
      throw const FormatException('Invalid Android update manifest.');
    }
    for (final abi in abis) {
      final asset = (input['assets'] as Map)[abi];
      if (asset == null) continue;
      if (asset is! Map ||
          asset['url'] is! String ||
          asset['sha256'] is! String ||
          asset['bytes'] is! int ||
          asset['versionCode'] is! int) {
        throw const FormatException('Invalid update asset.');
      }
      final url = Uri.tryParse(asset['url'] as String),
          hash = asset['sha256'] as String,
          bytes = asset['bytes'] as int,
          versionCode = asset['versionCode'] as int;
      if (url == null ||
          !url.toString().startsWith(updateRepository) ||
          url.userInfo.isNotEmpty ||
          url.hasQuery ||
          url.hasFragment ||
          !url.path.endsWith('.apk') ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
          bytes < 1024 ||
          bytes > 64 * 1024 * 1024 ||
          versionCode < 1) {
        throw const FormatException('Untrusted Android update asset.');
      }
      return AndroidRelease(
        version: input['version'] as String,
        versionCode: versionCode,
        url: url,
        sha256: hash,
        bytes: bytes,
      );
    }
    return null;
  }
}
