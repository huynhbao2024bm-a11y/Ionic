import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../database/database_service.dart';
import '../../http/api_exception.dart';

String _digest(String token) => sha256.convert(utf8.encode(token)).toString();
bool _valid(String? token) =>
    token != null && RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token);

class PreviewHeartbeatService {
  PreviewHeartbeatService(this.db);
  final DatabaseService db;
  Future<bool> _owner(String userId) async => (await db.query(
    r"""
    SELECT 1 FROM preview_heartbeat_account h JOIN app_user u ON u.id=h.user_id AND u.state='active'
    WHERE h.slot=1 AND h.user_id=$1 AND h.user_id=(SELECT owner_id FROM reserved_handle WHERE handle='admin')
    """,
    parameters: [userId],
  )).isNotEmpty;
  Future<bool> allowed(String userId) async =>
      await _owner(userId) ||
      (await db.query(
        r"""
    SELECT 1 FROM preview_heartbeat_account WHERE slot=2 AND user_id=$1 AND lease_expires_at>now()
    """,
        parameters: [userId],
      )).isNotEmpty;
  Future<Map<String, Object?>> claim(
    String userId, {
    String? previousToken,
  }) async {
    if (await _owner(userId)) return {'enabled': true, 'intervalSeconds': 600};
    final random = Random.secure(),
        token = base64Url
            .encode(List.generate(32, (_) => random.nextInt(256)))
            .replaceAll('=', '');
    final rows = await db.query(
      r"""
      UPDATE preview_heartbeat_account SET user_id=$1,lease_expires_at=now()+interval '15 minutes',lease_token_hash=$2
      WHERE slot=2 AND (user_id IS NULL OR lease_expires_at IS NULL OR lease_expires_at<=now()
        OR (user_id=$1 AND lease_token_hash=$3))
      RETURNING lease_expires_at""",
      parameters: [
        userId,
        _digest(token),
        _valid(previousToken) ? _digest(previousToken!) : null,
      ],
    );
    return {
      'enabled': rows.isNotEmpty,
      'intervalSeconds': 600,
      if (rows.isNotEmpty) 'leaseToken': token,
    };
  }

  Future<void> ping(String userId, {String? leaseToken}) async {
    if (await _owner(userId)) return;
    if (_valid(leaseToken)) {
      final rows = await db.query(
        r"""
        UPDATE preview_heartbeat_account SET lease_expires_at=now()+interval '15 minutes'
        WHERE slot=2 AND user_id=$1 AND lease_token_hash=$2 AND lease_expires_at>now()
        RETURNING slot""",
        parameters: [userId, _digest(leaseToken!)],
      );
      if (rows.isNotEmpty) return;
    }
    throw const ApiException(
      403,
      'Preview connection heartbeat lease is not active.',
    );
  }

  Future<void> release(String userId, String? leaseToken) async {
    if (!_valid(leaseToken)) return;
    await db.query(
      r"""
      UPDATE preview_heartbeat_account SET user_id=NULL,lease_expires_at=NULL,lease_token_hash=NULL
      WHERE slot=2 AND user_id=$1 AND lease_token_hash=$2
      """,
      parameters: [userId, _digest(leaseToken!)],
    );
  }

  Future<void> expire() async {
    await db.query("""UPDATE preview_heartbeat_account SET user_id=NULL,lease_expires_at=NULL,lease_token_hash=NULL
      WHERE slot=2 AND lease_expires_at<=now()""");
  }
}
