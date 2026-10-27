import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

const _sessionCookieName = 'ionic_session';
const _sessionStorageKey = 'ionic_session_token';
final _validSessionToken = RegExp(r'^[A-Za-z0-9_-]{40,50}$');

http.Client createHttpClient() => _SecureSessionClient();

class _SecureSessionClient extends http.BaseClient {
  _SecureSessionClient({
    FlutterSecureStorage? storage,
    http.Client? innerClient,
  }) : _storage = storage ?? FlutterSecureStorage(),
       _innerClient = innerClient ?? http.Client();

  final FlutterSecureStorage _storage;
  final http.Client _innerClient;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final token = await _storage.read(key: _sessionStorageKey);
    if (token != null && _validSessionToken.hasMatch(token)) {
      String? cookieHeader;
      for (final name in request.headers.keys) {
        if (name.toLowerCase() == 'cookie') {
          cookieHeader = name;
          break;
        }
      }
      if (cookieHeader == null) {
        request.headers['Cookie'] = '$_sessionCookieName=$token';
      } else if (!_containsSessionCookie(request.headers[cookieHeader] ?? '')) {
        request.headers[cookieHeader] =
            '${request.headers[cookieHeader]}; $_sessionCookieName=$token';
      }
    }

    final response = await _innerClient.send(request);
    await _persistSessionCookie(response.headers['set-cookie']);
    if (response.statusCode == 401 &&
        token != null &&
        !_isCredentialAttempt(request.url)) {
      await _storage.delete(key: _sessionStorageKey);
    }
    return response;
  }

  bool _isCredentialAttempt(Uri uri) =>
      uri.path.endsWith('/auth/login') || uri.path.endsWith('/auth/register');

  bool _containsSessionCookie(String header) => RegExp(
    '(?:^|;)\\s*${RegExp.escape(_sessionCookieName)}=',
    caseSensitive: false,
  ).hasMatch(header);

  Future<void> _persistSessionCookie(String? header) async {
    if (header == null) return;
    final match = RegExp(
      '(?:^|,\\s*)${RegExp.escape(_sessionCookieName)}=([^;,\\s]*)',
      caseSensitive: false,
    ).firstMatch(header);
    final token = match?.group(1) ?? '';
    if (match == null) return;
    final maxAge = RegExp(
      r'(?:^|;)\s*max-age=(-?\d+)',
      caseSensitive: false,
    ).firstMatch(header)?.group(1);
    if (token.isEmpty || (maxAge != null && (int.tryParse(maxAge) ?? 0) <= 0)) {
      await _storage.delete(key: _sessionStorageKey);
      return;
    }
    if (_validSessionToken.hasMatch(token)) {
      await _storage.write(key: _sessionStorageKey, value: token);
    }
  }

  @override
  void close() {
    _innerClient.close();
    super.close();
  }
}
