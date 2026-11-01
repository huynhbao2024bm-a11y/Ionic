part of 'auth_service.dart';

String _requiredPassword(Object? input) {
  if (input is! String || input.length < 12 || input.length > 128) {
    throw const ApiException(400, 'Password must contain 12–128 characters.');
  }
  return input;
}

extension AccountOperations on AuthService {
  Future<Map<String, Object?>> exportAccount(
    String userId,
  ) async => _database.transaction((tx) async {
    await tx.execute(
      'SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY',
    );
    final tables = <String, String>{
      'account': r'SELECT id, handle, created_at FROM app_user WHERE id = $1',
      'profile': r'SELECT display_name, bio, visibility FROM user_profile WHERE user_id = $1',
      'settings': r'SELECT message_permission, discoverable FROM account_setting WHERE user_id = $1',
      'posts': r'SELECT id, body, created_at, updated_at FROM content WHERE author_id = $1',
      'replies': r'SELECT id, content_id, body, created_at FROM content_reply WHERE author_id = $1',
      'sentMessages': r'SELECT id, conversation_id, body, created_at FROM direct_message WHERE sender_id = $1',
      'following': r'SELECT followed_id, created_at FROM account_follow WHERE follower_id = $1',
      'blocked': r'SELECT blocked_id, created_at FROM account_block WHERE blocker_id = $1',
      'muted':
          r'SELECT muted_id, created_at FROM account_mute WHERE muter_id = $1',
      'saved': r'SELECT content_id, created_at FROM content_bookmark WHERE user_id = $1',
      'recommendationSettings': r'SELECT learning_paused,updated_at FROM user_recommendation_setting WHERE user_id=$1',
      'recommendationFeedback': r'SELECT content_id,preference,updated_at FROM recommendation_item_feedback WHERE user_id=$1',
      'recommendationEvidence': r'SELECT content_id,kind,taxonomy_version,dimension,label_id,contribution,confidence,occurred_at,expires_at FROM user_preference_evidence WHERE user_id=$1',
      'recommendationFeatures': r'SELECT taxonomy_version,dimension,label_id,score,confidence,source_summary,updated_at,expires_at FROM user_preference_feature WHERE user_id=$1',
      'recommendationBaseline': r'SELECT taxonomy_version,dimension,label_id,score,confidence,source_summary,updated_at,expires_at FROM user_preference_baseline WHERE user_id=$1',
      'attentionDetails': r'SELECT content_id,attention_band,observed_at,issued_at,expires_at FROM recommendation_delivery_receipt WHERE user_id=$1 AND expires_at>now()',
      'attentionSummaries': r'SELECT content_id,summary_day,topic_ids,reward,updated_at,expires_at FROM recommendation_attention_summary WHERE user_id=$1 AND expires_at>now()',
      'recommendationControls': r'SELECT taxonomy_version,dimension,label_id,control,updated_at FROM user_preference_control WHERE user_id=$1',
      'attachments': r'SELECT id, media_type, byte_size, created_at FROM media_asset WHERE owner_id = $1',
    };
    final data = <String, Object?>{
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'formatVersion': 1,
      'scope': 'Account records and authored text; attachment metadata only. No received-message bodies, credentials, session tokens or recovery codes.',
    };
    var total = 0;
    for (final entry in tables.entries) {
      final rows = await tx.execute(
        '${entry.value} LIMIT 10001',
        parameters: [userId],
      );
      total += rows.length;
      if (total > 10000) {
        throw const ApiException(
          413,
          'Account export exceeds the synchronous limit.',
        );
      }
      data[entry.key] = rows
          .map(
            (r) => r.toColumnMap().map(
              (k, v) =>
                  MapEntry(k, v is DateTime ? v.toUtc().toIso8601String() : v),
            ),
          )
          .toList();
    }
    return data;
  });
  Future<Map<String, dynamic>> _verifyPassword(
    String userId,
    Object? password,
  ) async {
    if (password is! String || password.isEmpty || password.length > 128) {
      throw const ApiException(400, 'Enter your current password.');
    }
    final rows = await _database.query(
      r"SELECT password_salt, password_hash FROM app_user WHERE id = $1 AND state = 'active'",
      parameters: [userId],
    );
    if (rows.isEmpty) throw const ApiException(401, 'Sign in to continue.');
    final row = rows.first.toColumnMap();
    final actual = await _derivePasswordHash(
      password,
      Uint8List.fromList(row['password_salt'] as List<int>),
    );
    if (!_constantTimeEquals(actual, row['password_hash'] as List<int>)) {
      throw const ApiException(403, 'Current password is incorrect.');
    }
    return row;
  }

  Future<void> _lockVerifiedAccount(
    TxSession tx,
    String id,
    Map<String, dynamic> verified,
  ) async {
    final rows = await tx.execute(
      r"SELECT password_hash FROM app_user WHERE id = $1 AND state = 'active' FOR UPDATE",
      parameters: [id],
    );
    if (rows.isEmpty ||
        !_constantTimeEquals(
          rows.first.first as List<int>,
          verified['password_hash'] as List<int>,
        )) {
      throw const ApiException(403, 'Credentials changed; sign in again.');
    }
  }

  Future<Map<String, Object?>> settings(String userId) async {
    final rows = await _database.query(
      r'''SELECT p.visibility, COALESCE(s.message_permission, 'everyone') AS message_permission,
          COALESCE(s.discoverable, true) AS discoverable,
          EXISTS (SELECT 1 FROM account_recovery_code r WHERE r.user_id = p.user_id) AS recovery_enabled
          FROM user_profile p LEFT JOIN account_setting s ON s.user_id = p.user_id
          WHERE p.user_id = $1''',
      parameters: [userId],
    );
    final row = rows.first.toColumnMap();
    return {
      'visibility': row['visibility'],
      'messagePermission': row['message_permission'],
      'discoverable': row['discoverable'],
      'recoveryEnabled': row['recovery_enabled'],
    };
  }

  Future<Map<String, Object?>> updateSettings(
    String userId,
    Map<String, Object?> input,
  ) async {
    _requireOnlyKeys(input, [
      'visibility',
      'messagePermission',
      'discoverable',
    ]);
    if (input.isEmpty ||
        (input.containsKey('visibility') &&
            !['public', 'private'].contains(input['visibility'])) ||
        (input.containsKey('messagePermission') &&
            ![
              'everyone',
              'following',
              'nobody',
            ].contains(input['messagePermission'])) ||
        (input.containsKey('discoverable') && input['discoverable'] is! bool)) {
      throw const ApiException(400, 'Privacy settings are invalid.');
    }
    await _database.transaction((tx) async {
      await tx.execute(
        r'SELECT id FROM app_user WHERE id = $1 FOR UPDATE',
        parameters: [userId],
      );
      if (input.containsKey('visibility')) {
        await tx.execute(
          r'UPDATE user_profile SET visibility = $2, updated_at = now() WHERE user_id = $1',
          parameters: [userId, input['visibility']],
        );
      }
      await tx.execute(
        r'INSERT INTO account_setting(user_id) VALUES ($1) ON CONFLICT DO NOTHING',
        parameters: [userId],
      );
      if (input.containsKey('messagePermission')) {
        await tx.execute(
          r'UPDATE account_setting SET message_permission = $2, updated_at = now() WHERE user_id = $1',
          parameters: [userId, input['messagePermission']],
        );
      }
      if (input.containsKey('discoverable')) {
        await tx.execute(
          r'UPDATE account_setting SET discoverable = $2, updated_at = now() WHERE user_id = $1',
          parameters: [userId, input['discoverable']],
        );
      }
    });
    return settings(userId);
  }

  Future<Map<String, Object?>> sessions(String userId, String token) async {
    final rows = await _database.query(
      r'''SELECT id, created_at, expires_at, token_hash = $2 AS current
      FROM user_session WHERE user_id = $1 AND expires_at > now() ORDER BY created_at DESC LIMIT 100''',
      parameters: [userId, _sessionDigest(token)],
    );
    return {
      'items': rows.map((r) {
        final v = r.toColumnMap();
        return {
          'id': '${v['id']}',
          'createdAt': (v['created_at'] as DateTime).toUtc().toIso8601String(),
          'expiresAt': (v['expires_at'] as DateTime).toUtc().toIso8601String(),
          'current': v['current'] == true,
        };
      }).toList(),
    };
  }

  Future<void> revokeSession(String userId, String id) async {
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      caseSensitive: false,
    ).hasMatch(id)) {
      throw const ApiException(400, 'Session ID is invalid.');
    }
    await _database.query(
      r'DELETE FROM user_session WHERE user_id = $1 AND id = $2',
      parameters: [userId, id],
    );
  }

  Future<void> logoutAll(String userId) async {
    await _database.query(
      r'DELETE FROM user_session WHERE user_id = $1',
      parameters: [userId],
    );
  }

  Future<void> changePassword(
    String userId,
    String token,
    Map<String, Object?> input,
  ) async {
    _requireOnlyKeys(input, ['currentPassword', 'newPassword']);
    final password = _requiredPassword(input['newPassword']);
    final verified = await _verifyPassword(userId, input['currentPassword']);
    final salt = Uint8List.fromList(
      List.generate(16, (_) => Random.secure().nextInt(256)),
    );
    final hash = await _derivePasswordHash(password, salt);
    await _database.transaction((tx) async {
      await _lockVerifiedAccount(tx, userId, verified);
      await tx.execute(
        r'UPDATE app_user SET password_salt = $2, password_hash = $3 WHERE id = $1',
        parameters: [userId, salt, hash],
      );
      await tx.execute(
        r'DELETE FROM user_session WHERE user_id = $1 AND token_hash <> $2',
        parameters: [userId, _sessionDigest(token)],
      );
    });
  }

  Future<String> rotateRecoveryCode(
    String userId,
    Map<String, Object?> input,
  ) async {
    _requireOnlyKeys(input, ['currentPassword']);
    final verified = await _verifyPassword(userId, input['currentPassword']);
    final code = _randomToken();
    await _database.transaction((tx) async {
      await _lockVerifiedAccount(tx, userId, verified);
      await tx.execute(
        r'''INSERT INTO account_recovery_code(user_id, code_hash) VALUES ($1, $2)
        ON CONFLICT (user_id) DO UPDATE SET code_hash = EXCLUDED.code_hash, created_at = now()''',
        parameters: [userId, _sessionDigest(code)],
      );
    });
    return code;
  }

  Future<void> recover(Map<String, Object?> input) async {
    _requireOnlyKeys(input, ['handle', 'recoveryCode', 'newPassword']);
    final password = _requiredPassword(input['newPassword']);
    final handle = input['handle'];
    final code = input['recoveryCode'];
    if (handle is! String ||
        !_handlePattern.hasMatch(handle.trim().toLowerCase()) ||
        code is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(code.trim())) {
      throw const ApiException(400, 'Recovery details are invalid.');
    }
    final salt = Uint8List.fromList(
      List.generate(16, (_) => Random.secure().nextInt(256)),
    );
    final hash = await _derivePasswordHash(password, salt);
    await _database.transaction((tx) async {
      final users = await tx.execute(
        r"SELECT id FROM app_user WHERE handle_normalized = $1 AND state = 'active' FOR UPDATE",
        parameters: [handle.trim().toLowerCase()],
      );
      if (users.isEmpty) {
        throw const ApiException(403, 'Recovery details are incorrect.');
      }
      final id = users.first.first;
      final used = await tx.execute(
        r'DELETE FROM account_recovery_code WHERE user_id = $1 AND code_hash = $2 RETURNING user_id',
        parameters: [id, _sessionDigest(code.trim())],
      );
      if (used.isEmpty) {
        throw const ApiException(403, 'Recovery details are incorrect.');
      }
      await tx.execute(
        r'UPDATE app_user SET password_salt = $2, password_hash = $3 WHERE id = $1',
        parameters: [id, salt, hash],
      );
      await tx.execute(
        r'DELETE FROM user_session WHERE user_id = $1',
        parameters: [id],
      );
    });
  }

  Future<void> deleteAccount(String userId, Map<String, Object?> input) async {
    _requireOnlyKeys(input, ['currentPassword', 'confirmation']);
    if (input['confirmation'] != 'DELETE') {
      throw const ApiException(400, 'Confirm account deletion.');
    }
    final verified = await _verifyPassword(userId, input['currentPassword']);
    await _database.transaction((tx) async {
      await _lockVerifiedAccount(tx, userId, verified);
      await tx.execute(
        r'DELETE FROM app_user WHERE id = $1',
        parameters: [userId],
      );
    });
  }
}
