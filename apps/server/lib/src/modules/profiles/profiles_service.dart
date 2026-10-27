import 'package:ionic_server/src/http/api_exception.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:postgres/postgres.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

final _handlePattern = RegExp(r'^[a-z0-9_]{3,24}$');

class ProfilesService {
  ProfilesService(this._database);

  final DatabaseService _database;

  Future<Map<String, String>> updateMe(
    String viewerId,
    Map<String, Object?> input,
  ) async {
    if (input.length != 2 ||
        input.keys.any((key) => !const ['displayName', 'bio'].contains(key)) ||
        input['displayName'] is! String ||
        input['bio'] is! String) {
      throw const ApiException(400, 'Profile details are invalid.');
    }
    final displayName = unorm.nfc((input['displayName'] as String).trim());
    final bio = unorm.nfc((input['bio'] as String).trim());
    if (displayName.isEmpty || displayName.runes.length > 48) {
      throw const ApiException(
        400,
        'Display name must contain 1–48 characters.',
      );
    }
    if (bio.runes.length > 160) {
      throw const ApiException(
        400,
        'Biography must contain at most 160 characters.',
      );
    }
    final result = await _database.query(
      r'''UPDATE user_profile
          SET display_name = $2, bio = $3, updated_at = now()
          WHERE user_id = $1
          RETURNING display_name, bio''',
      parameters: [viewerId, displayName, bio],
    );
    if (result.isEmpty) throw const ApiException(404, 'Profile was not found.');
    final row = result.first.toColumnMap();
    return {'displayName': '${row['display_name']}', 'bio': '${row['bio']}'};
  }

  Future<Map<String, Object?>> search(String viewerId, String? input) async {
    if (input == null) return {'items': const <Object>[]};
    final query = unorm
        .nfc(input.trim().replaceFirst(RegExp(r'^@'), ''))
        .toLowerCase();
    if (query.length < 2 || query.length > 48) {
      return {'items': const <Object>[]};
    }
    final prefix = '${_escapeLike(query)}%';
    final result = await _database.query(
      r'''SELECT u.handle, p.display_name, p.bio,
                EXISTS (SELECT 1 FROM account_follow f
                        WHERE f.follower_id = $1 AND f.followed_id = u.id) AS is_following
         FROM app_user u
         JOIN user_profile p ON p.user_id = u.id
         WHERE u.state = 'active' AND p.visibility = 'public' AND u.id <> $1
           AND (lower(u.handle) LIKE $2 ESCAPE '\' OR lower(p.display_name) LIKE $2 ESCAPE '\')
           AND NOT EXISTS (
             SELECT 1 FROM account_block b
             WHERE (b.blocker_id = $1 AND b.blocked_id = u.id)
                OR (b.blocker_id = u.id AND b.blocked_id = $1)
           )
         ORDER BY lower(p.display_name), u.handle
         LIMIT 20''',
      parameters: [viewerId, prefix],
    );
    return {
      'items': result.map((row) {
        final value = row.toColumnMap();
        return <String, Object?>{
          'handle': '${value['handle']}',
          'displayName': '${value['display_name']}',
          'bio': '${value['bio']}',
          'isFollowing': value['is_following'] == true,
        };
      }).toList(),
    };
  }

  Future<Map<String, Object?>> getProfile(
    String viewerId,
    String inputHandle,
  ) async {
    final handle = _parseHandle(inputHandle);
    final result = await _database.query(
      r'''SELECT u.id, u.handle, p.display_name, p.bio, p.visibility,
                (SELECT count(*) FROM account_follow f WHERE f.followed_id = u.id) AS follower_count,
                (SELECT count(*) FROM account_follow f WHERE f.follower_id = u.id) AS following_count,
                (SELECT count(*) FROM content c WHERE c.author_id = u.id AND c.status = 'published' AND c.deleted_at IS NULL) AS post_count,
                EXISTS (SELECT 1 FROM account_follow f
                        WHERE f.follower_id = $1 AND f.followed_id = u.id) AS is_following,
                EXISTS (SELECT 1 FROM account_mute m
                        WHERE m.muter_id = $1 AND m.muted_id = u.id) AS is_muted
         FROM app_user u
         JOIN user_profile p ON p.user_id = u.id
         WHERE u.handle_normalized = $2 AND u.state = 'active'
           AND NOT EXISTS (
             SELECT 1 FROM account_block b
             WHERE (b.blocker_id = $1 AND b.blocked_id = u.id)
                OR (b.blocker_id = u.id AND b.blocked_id = $1)
           )''',
      parameters: [viewerId, handle],
    );
    if (result.isEmpty) {
      throw const ApiException(404, 'Profile was not found.');
    }
    final row = result.first.toColumnMap();
    final id = '${row['id']}';
    final isFollowing = row['is_following'] == true;
    final visibility = '${row['visibility']}';
    if (visibility == 'private' && id != viewerId && !isFollowing) {
      throw const ApiException(404, 'Profile was not found.');
    }
    return {
      'profile': <String, Object?>{
        'handle': '${row['handle']}',
        'displayName': '${row['display_name']}',
        'bio': '${row['bio']}',
        'visibility': visibility,
        'followerCount': _number(row['follower_count']),
        'followingCount': _number(row['following_count']),
        'postCount': _number(row['post_count']),
        'isFollowing': isFollowing,
        'isMuted': row['is_muted'] == true,
        'isSelf': id == viewerId,
      },
    };
  }

  Future<Map<String, Object?>> listFollowing(String viewerId) async {
    final result = await _database.query(
      r'''SELECT u.handle, p.display_name, p.bio
         FROM account_follow f
         JOIN app_user u ON u.id = f.followed_id AND u.state = 'active'
         JOIN user_profile p ON p.user_id = u.id
         WHERE f.follower_id = $1
           AND NOT EXISTS (
             SELECT 1 FROM account_block b
             WHERE (b.blocker_id = $1 AND b.blocked_id = u.id)
                OR (b.blocker_id = u.id AND b.blocked_id = $1)
           )
         ORDER BY f.created_at DESC, u.handle''',
      parameters: [viewerId],
    );
    return {
      'items': result
          .map((row) => _managedProfile(row, isFollowing: true))
          .toList(),
    };
  }

  Future<Map<String, Object?>> listBlocked(String viewerId) async {
    final result = await _database.query(
      r'''SELECT u.handle, p.display_name, p.bio
         FROM account_block b
         JOIN app_user u ON u.id = b.blocked_id
         JOIN user_profile p ON p.user_id = u.id
         WHERE b.blocker_id = $1
         ORDER BY b.created_at DESC, u.handle''',
      parameters: [viewerId],
    );
    return {
      'items': result
          .map((row) => _managedProfile(row, isFollowing: false))
          .toList(),
    };
  }

  Future<Map<String, Object?>> listMuted(String viewerId) async {
    final result = await _database.query(
      r'''SELECT u.handle, p.display_name, p.bio
         FROM account_mute m
         JOIN app_user u ON u.id = m.muted_id AND u.state = 'active'
         JOIN user_profile p ON p.user_id = u.id
         WHERE m.muter_id = $1
         ORDER BY m.created_at DESC, u.handle''',
      parameters: [viewerId],
    );
    return {'items': result.map(_managedProfile).toList()};
  }

  Future<Map<String, String>> follow(
    String viewerId,
    String inputHandle,
  ) async {
    final target = await _target(inputHandle);
    final targetId = '${target['id']}';
    if (targetId == viewerId) {
      throw const ApiException(400, 'You cannot follow your own account.');
    }
    if (target['visibility'] == 'private') {
      throw const ApiException(
        403,
        'Private profile follow requests are not available yet.',
      );
    }
    await _database.transaction((transaction) async {
      await _lockAccounts(transaction, viewerId, targetId);
      final block = await transaction.execute(
        r'''SELECT 1 FROM account_block
            WHERE (blocker_id = $1 AND blocked_id = $2)
               OR (blocker_id = $2 AND blocked_id = $1)''',
        parameters: [viewerId, targetId],
      );
      if (block.isNotEmpty) {
        throw const ApiException(
          403,
          'Following is unavailable for this account.',
        );
      }
      await transaction.execute(
        r'''INSERT INTO account_follow(follower_id, followed_id)
            VALUES ($1, $2) ON CONFLICT DO NOTHING''',
        parameters: [viewerId, targetId],
      );
    });
    return {'status': 'following'};
  }

  Future<Map<String, String>> unfollow(
    String viewerId,
    String inputHandle,
  ) async {
    final targetId = await _targetId(inputHandle);
    await _database.query(
      r'DELETE FROM account_follow WHERE follower_id = $1 AND followed_id = $2',
      parameters: [viewerId, targetId],
    );
    return {'status': 'not_following'};
  }

  Future<Map<String, String>> block(String viewerId, String inputHandle) async {
    final targetId = await _targetId(inputHandle);
    if (targetId == viewerId) {
      throw const ApiException(400, 'You cannot block your own account.');
    }
    await _database.transaction((transaction) async {
      await _lockAccounts(transaction, viewerId, targetId);
      await transaction.execute(
        r'''INSERT INTO account_block(blocker_id, blocked_id)
            VALUES ($1, $2) ON CONFLICT DO NOTHING''',
        parameters: [viewerId, targetId],
      );
      await transaction.execute(
        r'''DELETE FROM account_follow
            WHERE (follower_id = $1 AND followed_id = $2)
               OR (follower_id = $2 AND followed_id = $1)''',
        parameters: [viewerId, targetId],
      );
    });
    return {'status': 'blocked'};
  }

  Future<Map<String, String>> unblock(
    String viewerId,
    String inputHandle,
  ) async {
    final targetId = await _targetId(inputHandle);
    await _database.query(
      r'DELETE FROM account_block WHERE blocker_id = $1 AND blocked_id = $2',
      parameters: [viewerId, targetId],
    );
    return {'status': 'unblocked'};
  }

  Future<Map<String, String>> mute(String viewerId, String inputHandle) async {
    final targetId = await _targetId(inputHandle);
    if (targetId == viewerId) {
      throw const ApiException(400, 'You cannot mute your own account.');
    }
    await _database.query(
      r'''INSERT INTO account_mute(muter_id, muted_id)
          VALUES ($1, $2) ON CONFLICT DO NOTHING''',
      parameters: [viewerId, targetId],
    );
    return {'status': 'muted'};
  }

  Future<Map<String, String>> unmute(
    String viewerId,
    String inputHandle,
  ) async {
    final targetId = await _targetId(inputHandle);
    await _database.query(
      r'DELETE FROM account_mute WHERE muter_id = $1 AND muted_id = $2',
      parameters: [viewerId, targetId],
    );
    return {'status': 'unmuted'};
  }

  Future<String> _targetId(String inputHandle) async {
    final handle = _parseHandle(inputHandle);
    final result = await _database.query(
      r'''SELECT id FROM app_user
          WHERE handle_normalized = $1 AND state = 'active' ''',
      parameters: [handle],
    );
    if (result.isEmpty) {
      throw const ApiException(404, 'Account was not found.');
    }
    return '${result.first.first}';
  }

  Future<Map<String, Object?>> _target(String inputHandle) async {
    final handle = _parseHandle(inputHandle);
    final result = await _database.query(
      r'''SELECT u.id, p.visibility FROM app_user u
          JOIN user_profile p ON p.user_id = u.id
          WHERE u.handle_normalized = $1 AND u.state = 'active' ''',
      parameters: [handle],
    );
    if (result.isEmpty) {
      throw const ApiException(404, 'Account was not found.');
    }
    return result.first.toColumnMap();
  }

  Future<void> _lockAccounts(
    TxSession transaction,
    String viewerId,
    String targetId,
  ) async {
    final ids = [viewerId, targetId]..sort();
    final result = await transaction.execute(
      r'''SELECT id FROM app_user
          WHERE id = ANY($1::uuid[]) ORDER BY id FOR UPDATE''',
      parameters: [ids],
    );
    if (result.length != 2) {
      throw const ApiException(404, 'Account was not found.');
    }
  }
}

Map<String, Object?> _managedProfile(ResultRow row, {bool? isFollowing}) {
  final value = row.toColumnMap();
  return {
    'handle': '${value['handle']}',
    'displayName': '${value['display_name']}',
    'bio': '${value['bio']}',
    'isFollowing': ?isFollowing,
  };
}

String _parseHandle(String input) {
  final withoutAt = input.startsWith('@') ? input.substring(1) : input;
  final handle = withoutAt.toLowerCase();
  if (!_handlePattern.hasMatch(handle)) {
    throw const ApiException(400, 'Handle is invalid.');
  }
  return handle;
}

String _escapeLike(String value) =>
    value.replaceAllMapped(RegExp(r'[\\%_]'), (match) => '\\${match[0]}');

int _number(Object? value) =>
    value is num ? value.toInt() : int.parse('$value');
