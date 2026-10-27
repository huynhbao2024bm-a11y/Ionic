import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ionic_server/src/http/api_exception.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:pointycastle/key_derivators/api.dart';
import 'package:pointycastle/key_derivators/scrypt.dart';
import 'package:postgres/postgres.dart';

const _sessionLifetime = Duration(days: 30);
const _passwordSaltLength = 16;
const _passwordHashLength = 64;
final _fakeSalt = Uint8List.fromList(
  List<int>.filled(_passwordSaltLength, 0x69),
);
final _fakeHash = Uint8List.fromList(
  List<int>.filled(_passwordHashLength, 0x6f),
);
final _handlePattern = RegExp(r'^[a-z0-9_]{3,24}$');

class AuthenticatedUser {
  const AuthenticatedUser({
    required this.id,
    required this.handle,
    required this.displayName,
  });

  final String id;
  final String handle;
  final String displayName;

  Map<String, String> toJson() => {
    'id': id,
    'handle': handle,
    'displayName': displayName,
  };
}

class AuthResult {
  const AuthResult({required this.user, required this.token});

  final AuthenticatedUser user;
  final String token;
}

class _AsyncSemaphore {
  _AsyncSemaphore(int capacity, this._maxWaiting) : _available = capacity;

  int _available;
  final int _maxWaiting;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  Future<T> withPermit<T>(Future<T> Function() operation) async {
    if (_available > 0) {
      _available--;
    } else {
      if (_waiters.length >= _maxWaiting) {
        throw const ApiException(
          503,
          'Authentication is busy. Try again shortly.',
        );
      }
      final waiter = Completer<void>();
      _waiters.addLast(waiter);
      await waiter.future;
    }
    try {
      return await operation();
    } finally {
      if (_waiters.isEmpty) {
        _available++;
      } else {
        _waiters.removeFirst().complete();
      }
    }
  }
}

final _passwordWorkSlots = _AsyncSemaphore(2, 16);

Future<Uint8List> _derivePasswordHash(String password, Uint8List salt) =>
    _passwordWorkSlots.withPermit(
      () => Isolate.run(() {
        final result = Uint8List(_passwordHashLength);
        final scrypt = Scrypt()
          ..init(ScryptParameters(16384, 8, 1, _passwordHashLength, salt));
        scrypt.deriveKey(
          Uint8List.fromList(utf8.encode(password)),
          0,
          result,
          0,
        );
        return result;
      }),
    );

String _sessionDigest(String token) =>
    sha256.convert(utf8.encode(token)).toString();

String _randomToken() {
  final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

String _randomUuid() {
  final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

bool _constantTimeEquals(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

void _requireOnlyKeys(Map<String, Object?> input, List<String> allowed) {
  if (input.keys.any((key) => !allowed.contains(key))) {
    throw const ApiException(400, 'Request contains an unsupported field.');
  }
}

({String handle, String displayName, String password}) _parseRegistration(
  Map<String, Object?> input,
) {
  _requireOnlyKeys(input, ['handle', 'displayName', 'password']);
  final handle = input['handle'] is String
      ? (input['handle'] as String).trim().toLowerCase()
      : '';
  final displayName = input['displayName'] is String
      ? (input['displayName'] as String).trim()
      : '';
  final password = input['password'] is String
      ? input['password'] as String
      : '';
  if (!_handlePattern.hasMatch(handle)) {
    throw const ApiException(
      400,
      'Handle must use 3–24 lowercase letters, numbers, or underscores.',
    );
  }
  if (displayName.isEmpty || displayName.length > 48) {
    throw const ApiException(400, 'Display name must contain 1–48 characters.');
  }
  if (password.length < 12 || password.length > 128) {
    throw const ApiException(400, 'Password must contain 12–128 characters.');
  }
  return (handle: handle, displayName: displayName, password: password);
}

({String handle, String password}) _parseLogin(Map<String, Object?> input) {
  _requireOnlyKeys(input, ['handle', 'password']);
  final handle = input['handle'] is String
      ? (input['handle'] as String).trim().toLowerCase()
      : '';
  final password = input['password'] is String
      ? input['password'] as String
      : '';
  if (!_handlePattern.hasMatch(handle) ||
      password.isEmpty ||
      password.length > 128) {
    throw const ApiException(400, 'Enter a valid handle and password.');
  }
  return (handle: handle, password: password);
}

AuthenticatedUser _toPublicUser(Map<String, dynamic> row) => AuthenticatedUser(
  id: '${row['id']}',
  handle: '${row['handle']}',
  displayName: '${row['display_name']}',
);

class AuthService {
  AuthService(this._database);

  final DatabaseService _database;

  Future<AuthResult> register(Map<String, Object?> input) async {
    if (Platform.environment['APP_ENV'] == 'production' &&
        Platform.environment['ALLOW_SIGNUP'] != 'true') {
      throw const ApiException(503, 'Account registration is disabled.');
    }

    final registration = _parseRegistration(input);
    final id = _randomUuid();
    final salt = Uint8List.fromList(
      List<int>.generate(
        _passwordSaltLength,
        (_) => Random.secure().nextInt(256),
      ),
    );
    final passwordHash = await _derivePasswordHash(registration.password, salt);
    final token = _randomToken();
    final expiresAt = DateTime.now().toUtc().add(_sessionLifetime);

    try {
      final user = await _database.transaction((client) async {
        final account = await client.execute(
          'INSERT INTO app_user (id, handle, handle_normalized, password_salt, password_hash) '
          r'VALUES ($1, $2, $3, $4, $5) RETURNING id, handle',
          parameters: [
            id,
            registration.handle,
            registration.handle,
            salt,
            passwordHash,
          ],
        );
        await client.execute(
          r'INSERT INTO user_profile (user_id, display_name) VALUES ($1, $2)',
          parameters: [id, registration.displayName],
        );
        await client.execute(
          r'INSERT INTO user_session (token_hash, user_id, expires_at) VALUES ($1, $2, $3)',
          parameters: [_sessionDigest(token), id, expiresAt],
        );
        final accountRow = account.first.toColumnMap()
          ..['display_name'] = registration.displayName;
        return _toPublicUser(accountRow);
      });
      return AuthResult(user: user, token: token);
    } on ServerException catch (error) {
      if (error.code == '23505') {
        throw const ApiException(409, 'That handle is already in use.');
      }
      rethrow;
    }
  }

  Future<AuthResult> login(Map<String, Object?> input) async {
    final credentials = _parseLogin(input);
    final result = await _database.query(
      'SELECT u.id, u.handle, u.password_salt, u.password_hash, p.display_name '
      'FROM app_user u JOIN user_profile p ON p.user_id = u.id '
      r"WHERE u.handle_normalized = $1 AND u.state = 'active'",
      parameters: [credentials.handle],
    );
    final account = result.isEmpty ? null : result.first.toColumnMap();
    final rawSalt = account?['password_salt'];
    final rawHash = account?['password_hash'];
    final salt = rawSalt is List<int> ? Uint8List.fromList(rawSalt) : _fakeSalt;
    final expected = rawHash is List<int>
        ? Uint8List.fromList(rawHash)
        : _fakeHash;
    final actual = await _derivePasswordHash(credentials.password, salt);
    if (account == null || !_constantTimeEquals(actual, expected)) {
      throw const ApiException(401, 'Handle or password is incorrect.');
    }

    final token = _randomToken();
    final expiresAt = DateTime.now().toUtc().add(_sessionLifetime);
    await _database.query(
      'INSERT INTO user_session (token_hash, user_id, expires_at) '
      r'VALUES ($1, $2, $3) ON CONFLICT (token_hash) DO NOTHING',
      parameters: [_sessionDigest(token), account['id'], expiresAt],
    );
    return AuthResult(user: _toPublicUser(account), token: token);
  }

  Future<AuthenticatedUser> authenticate(String? token) async {
    if (token == null || !RegExp(r'^[A-Za-z0-9_-]{40,50}$').hasMatch(token)) {
      throw const ApiException(401, 'Sign in to continue.');
    }
    final result = await _database.query(
      'SELECT u.id, u.handle, p.display_name '
      'FROM user_session s '
      'JOIN app_user u ON u.id = s.user_id '
      'JOIN user_profile p ON p.user_id = u.id '
      r"WHERE s.token_hash = $1 AND s.expires_at > now() AND u.state = 'active'",
      parameters: [_sessionDigest(token)],
    );
    if (result.isEmpty) throw const ApiException(401, 'Sign in to continue.');
    return _toPublicUser(result.first.toColumnMap());
  }

  Future<void> logout(String? token) async {
    if (token != null && RegExp(r'^[A-Za-z0-9_-]{40,50}$').hasMatch(token)) {
      await _database.query(
        r'DELETE FROM user_session WHERE token_hash = $1',
        parameters: [_sessionDigest(token)],
      );
    }
  }
}

String? readSessionToken(String? cookieHeader) {
  if (cookieHeader == null) return null;
  for (final part in cookieHeader.split(';')) {
    final separator = part.trim().indexOf('=');
    if (separator < 0) continue;
    final name = part.trim().substring(0, separator);
    if (name == 'ionic_session') return part.trim().substring(separator + 1);
  }
  return null;
}

String sessionCookie(String token) {
  final secure = Platform.environment['APP_ENV'] == 'production'
      ? '; Secure'
      : '';
  return 'ionic_session=$token; Path=/; HttpOnly; SameSite=Strict; Max-Age=${_sessionLifetime.inSeconds}$secure';
}

String clearSessionCookie() {
  final secure = Platform.environment['APP_ENV'] == 'production'
      ? '; Secure'
      : '';
  return 'ionic_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0$secure';
}
