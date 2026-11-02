import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:ionic_server/src/http/api_exception.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;
import 'package:postgres/postgres.dart';

final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
);
final _handlePattern = RegExp(r'^[a-z0-9_]{3,24}$');

class _MessageCursor {
  const _MessageCursor({required this.createdAt, required this.id});

  final DateTime createdAt;
  final String id;
}

class MessagesService {
  MessagesService(this._database);

  final DatabaseService _database;

  Future<Map<String, Object?>> listConversations(String viewerId) async {
    final result = await _database.query(
      r'''SELECT c.id,
                partner.id AS partner_id,
                partner.handle,
                p.display_name, p.avatar_media_id,
                COALESCE(latest.body, '') AS body,
                (SELECT count(*)::int FROM direct_message unread
                 WHERE unread.conversation_id = c.id AND unread.sender_id <> $1
                   AND (read_state.last_read_at IS NULL OR
                     (unread.created_at, unread.id) > (read_state.last_read_at, read_state.last_read_message_id))) AS unread_count,
                COALESCE(c.last_message_at, c.created_at) AS updated_at
         FROM direct_conversation c
         JOIN app_user partner ON partner.id = CASE
           WHEN c.participant_low = $1 THEN c.participant_high
           ELSE c.participant_low END
         JOIN user_profile p ON p.user_id = partner.id
         LEFT JOIN direct_conversation_read read_state ON read_state.conversation_id = c.id AND read_state.user_id = $1
         LEFT JOIN LATERAL (
           SELECT m.body FROM direct_message m
           WHERE m.conversation_id = c.id
           ORDER BY m.created_at DESC, m.id DESC LIMIT 1
         ) latest ON true
         WHERE ($1 = c.participant_low OR $1 = c.participant_high)
           AND partner.state = 'active'
           AND NOT EXISTS (
             SELECT 1 FROM account_block b WHERE
               (b.blocker_id = c.participant_low AND b.blocked_id = c.participant_high)
                OR (b.blocker_id = c.participant_high AND b.blocked_id = c.participant_low)
           )
         ORDER BY c.last_message_at DESC NULLS LAST, c.created_at DESC
         LIMIT 100''',
      parameters: [viewerId],
    );
    return {
      'items': result.map((row) {
        final value = row.toColumnMap();
        return <String, Object?>{
          'id': '${value['id']}',
          'partnerId': '${value['partner_id']}',
          'partnerHandle': '${value['handle']}',
          'partnerDisplayName': '${value['display_name']}',
          'partnerAvatarId': value['avatar_media_id'],
          'lastMessage': '${value['body']}',
          'unreadCount': value['unread_count'],
          'updatedAt': _dateTime(value['updated_at']).toUtc().toIso8601String(),
        };
      }).toList(),
    };
  }

  Future<Map<String, Object?>> startConversation(
    String viewerId,
    Map<String, Object?> input,
  ) async {
    if (input.length != 1 || input['handle'] is! String) {
      throw const ApiException(400, 'Handle is invalid.');
    }
    final handle = _parseHandle(input['handle'] as String);
    final targetResult = await _database.query(
      r'''SELECT u.id, u.handle, p.display_name, p.avatar_media_id FROM app_user u
          JOIN user_profile p ON p.user_id = u.id
          WHERE u.handle_normalized = $1 AND u.state = 'active' ''',
      parameters: [handle],
    );
    if (targetResult.isEmpty) {
      throw const ApiException(404, 'Account was not found.');
    }
    final target = targetResult.first.toColumnMap();
    final targetId = '${target['id']}';
    if (targetId == viewerId) {
      throw const ApiException(400, 'You cannot message your own account.');
    }
    final ids = [viewerId, targetId]..sort();
    final result = await _database.transaction((tx) async {
      await _lockAndCheckRecipient(tx, viewerId, targetId);
      return tx.execute(
        r'''INSERT INTO direct_conversation(id, participant_low, participant_high)
          SELECT $1, $2, $3
          WHERE NOT EXISTS (
            SELECT 1 FROM account_block WHERE
              (blocker_id = $2 AND blocked_id = $3)
               OR (blocker_id = $3 AND blocked_id = $2)
          )
          ON CONFLICT (participant_low, participant_high)
          DO UPDATE SET participant_low = EXCLUDED.participant_low
          RETURNING id, created_at, last_message_at''',
        parameters: [_randomUuid(), ids[0], ids[1]],
      );
    });
    if (result.isEmpty) {
      throw const ApiException(
        403,
        'Messaging is unavailable for this account.',
      );
    }
    final conversation = result.first.toColumnMap();
    return {
      'conversation': <String, Object?>{
        'id': '${conversation['id']}',
        'partnerId': targetId,
        'partnerHandle': '${target['handle']}',
        'partnerDisplayName': '${target['display_name']}',
        'partnerAvatarId': target['avatar_media_id'],
        'lastMessage': '',
        'updatedAt': _dateTime(
          conversation['last_message_at'] ?? conversation['created_at'],
        ).toUtc().toIso8601String(),
      },
    };
  }

  Future<Map<String, Object?>> listMessages(
    String viewerId,
    String conversationInput,
    int limit,
    String? cursorInput,
  ) async {
    final conversationId = _parseUuid(conversationInput, 'Conversation ID');
    final cursor = _parseCursor(cursorInput);
    await _requireConversation(viewerId, conversationId);
    final result = await _database.query(
      r'''SELECT m.id, m.sender_id, m.body, m.created_at
         FROM direct_message m
         JOIN direct_conversation c ON c.id = m.conversation_id
         JOIN app_user low_user ON low_user.id = c.participant_low AND low_user.state = 'active'
         JOIN app_user high_user ON high_user.id = c.participant_high AND high_user.state = 'active'
         WHERE m.conversation_id = $1
           AND ($2 = c.participant_low OR $2 = c.participant_high)
           AND NOT EXISTS (
             SELECT 1 FROM account_block b WHERE
               (b.blocker_id = c.participant_low AND b.blocked_id = c.participant_high)
                OR (b.blocker_id = c.participant_high AND b.blocked_id = c.participant_low)
           )
           AND ($3::timestamptz IS NULL OR (m.created_at, m.id) < ($3, $4::uuid))
         ORDER BY m.created_at DESC, m.id DESC
         LIMIT $5''',
      parameters: [
        conversationId,
        viewerId,
        cursor?.createdAt,
        cursor?.id,
        limit + 1,
      ],
    );
    final hasMore = result.length > limit;
    final rows = result.take(limit).toList().reversed.toList();
    final items = rows.map((row) {
      final value = row.toColumnMap();
      return <String, Object?>{
        'id': '${value['id']}',
        'senderId': '${value['sender_id']}',
        'body': '${value['body']}',
        'createdAt': _dateTime(value['created_at']).toUtc().toIso8601String(),
      };
    }).toList();
    final nextCursor = hasMore && items.isNotEmpty
        ? _encodeCursor(
            _MessageCursor(
              createdAt: DateTime.parse('${items.first['createdAt']}'),
              id: '${items.first['id']}',
            ),
          )
        : null;
    final partnerRead = await _database.query(
      r'''SELECT r.last_read_at, r.last_read_message_id
      FROM direct_conversation_read r JOIN direct_conversation c ON c.id = r.conversation_id
      WHERE r.conversation_id = $1 AND r.user_id <> $2 AND ($2 = c.participant_low OR $2 = c.participant_high)
        AND NOT EXISTS (SELECT 1 FROM account_block b
          WHERE (b.blocker_id = c.participant_low AND b.blocked_id = c.participant_high)
             OR (b.blocker_id = c.participant_high AND b.blocked_id = c.participant_low))''',
      parameters: [conversationId, viewerId],
    );
    return {
      'items': items,
      'nextCursor': nextCursor,
      'partnerReadAt': partnerRead.isEmpty
          ? null
          : _dateTime(partnerRead.first[0]).toUtc().toIso8601String(),
      'partnerReadMessageId': partnerRead.isEmpty
          ? null
          : '${partnerRead.first[1]}',
    };
  }

  Future<Map<String, Object?>> sendMessage(
    String viewerId,
    String conversationInput,
    Map<String, Object?> input,
  ) async {
    final conversationId = _parseUuid(conversationInput, 'Conversation ID');
    final parsed = _parseBody(input);
    return _database.transaction((transaction) async {
      final conversation = await transaction.execute(
        r'''SELECT participant_low, participant_high
        FROM direct_conversation WHERE id = $1 AND ($2 = participant_low OR $2 = participant_high)''',
        parameters: [conversationId, viewerId],
      );
      if (conversation.isEmpty) {
        throw const ApiException(404, 'Conversation was not found.');
      }
      final partnerId = '${conversation.first[0]}' == viewerId
          ? '${conversation.first[1]}'
          : '${conversation.first[0]}';
      // Use the same ordered account locks as block/privacy changes.
      await _lockAndCheckRecipient(transaction, viewerId, partnerId);
      final access = await transaction.execute(
        r'''SELECT CASE WHEN participant_low = $2 THEN participant_high
                        ELSE participant_low END AS partner_id
            FROM direct_conversation c
            WHERE c.id = $1 AND ($2 = participant_low OR $2 = participant_high)
              AND NOT EXISTS (
                SELECT 1 FROM account_block b WHERE
                  (b.blocker_id = c.participant_low AND b.blocked_id = c.participant_high)
                   OR (b.blocker_id = c.participant_high AND b.blocked_id = c.participant_low)
              )
            FOR UPDATE''',
        parameters: [conversationId, viewerId],
      );
      if (access.isEmpty) {
        throw const ApiException(404, 'Conversation was not found.');
      }
      final inserted = await transaction.execute(
        r'''INSERT INTO direct_message(id, conversation_id, sender_id, body)
            VALUES ($1, $2, $3, $4)
            ON CONFLICT (id) DO NOTHING
            RETURNING id, sender_id, body, created_at, conversation_id''',
        parameters: [parsed.id, conversationId, viewerId, parsed.body],
      );
      Map<String, dynamic> message;
      if (inserted.isEmpty) {
        final existing = await transaction.execute(
          r'''SELECT id, sender_id, body, created_at, conversation_id
              FROM direct_message WHERE id = $1''',
          parameters: [parsed.id],
        );
        if (existing.isEmpty) {
          throw const ApiException(403, 'Message ID has already been used.');
        }
        message = existing.first.toColumnMap();
        if ('${message['sender_id']}' != viewerId ||
            '${message['conversation_id']}' != conversationId ||
            '${message['body']}' != parsed.body) {
          throw const ApiException(403, 'Message ID has already been used.');
        }
      } else {
        message = inserted.first.toColumnMap();
        await transaction.execute(
          r'UPDATE direct_conversation SET last_message_at = $2 WHERE id = $1',
          parameters: [conversationId, message['created_at']],
        );
      }
      return <String, Object?>{
        'id': '${message['id']}',
        'senderId': '${message['sender_id']}',
        'body': '${message['body']}',
        'createdAt': _dateTime(message['created_at']).toUtc().toIso8601String(),
      };
    });
  }

  Future<void> _lockAndCheckRecipient(
    TxSession tx,
    String viewerId,
    String recipientId,
  ) async {
    final ids = [viewerId, recipientId]..sort();
    final accounts = await tx.execute(
      r"SELECT id FROM app_user WHERE id = ANY($1::uuid[]) AND state = 'active' ORDER BY id FOR UPDATE",
      parameters: [ids],
    );
    if (accounts.length != 2) {
      throw const ApiException(404, 'Account was not found.');
    }
    final allowed = await tx.execute(
      r'''SELECT 1 FROM app_user recipient
      LEFT JOIN account_setting s ON s.user_id = recipient.id
      WHERE recipient.id = $2
        AND NOT EXISTS (SELECT 1 FROM account_block b
          WHERE (b.blocker_id = $1 AND b.blocked_id = $2) OR (b.blocker_id = $2 AND b.blocked_id = $1))
        AND (COALESCE(s.message_permission, 'everyone') = 'everyone'
          OR (s.message_permission = 'following' AND EXISTS (
            SELECT 1 FROM account_follow f WHERE f.follower_id = $2 AND f.followed_id = $1)))''',
      parameters: [viewerId, recipientId],
    );
    if (allowed.isEmpty) {
      throw const ApiException(403, 'Recipient does not allow this message.');
    }
  }

  Future<void> _requireConversation(
    String viewerId,
    String conversationId,
  ) async {
    final access = await _database.query(
      r'''SELECT c.id FROM direct_conversation c
      JOIN app_user low_user ON low_user.id = c.participant_low AND low_user.state = 'active'
      JOIN app_user high_user ON high_user.id = c.participant_high AND high_user.state = 'active'
      WHERE c.id = $1 AND ($2 = c.participant_low OR $2 = c.participant_high)
        AND NOT EXISTS (SELECT 1 FROM account_block b
          WHERE (b.blocker_id = c.participant_low AND b.blocked_id = c.participant_high)
             OR (b.blocker_id = c.participant_high AND b.blocked_id = c.participant_low))''',
      parameters: [conversationId, viewerId],
    );
    if (access.isEmpty) {
      throw const ApiException(404, 'Conversation was not found.');
    }
  }

  Future<void> markRead(
    String viewerId,
    String conversationInput,
    Map<String, Object?> input,
  ) async {
    final id = _parseUuid(conversationInput, 'Conversation ID');
    if (input.length != 1) {
      throw const ApiException(400, 'Read receipt is invalid.');
    }
    final messageId = _parseUuid(input['lastMessageId'], 'Message ID');
    await _requireConversation(viewerId, id);
    // Bind the receipt to a message actually returned to the client, not now(),
    // so an incoming message during the request cannot be marked read unseen.
    await _database.query(
      r'''INSERT INTO direct_conversation_read(conversation_id, user_id, last_read_at, last_read_message_id)
      SELECT $1, $2, m.created_at, m.id FROM direct_message m JOIN direct_conversation c ON c.id = m.conversation_id
      WHERE m.id = $3 AND m.conversation_id = $1 AND ($2 = c.participant_low OR $2 = c.participant_high)
        AND NOT EXISTS (SELECT 1 FROM account_block b
          WHERE (b.blocker_id = c.participant_low AND b.blocked_id = c.participant_high)
             OR (b.blocker_id = c.participant_high AND b.blocked_id = c.participant_low))
      ON CONFLICT (conversation_id, user_id) DO UPDATE
      SET last_read_at = EXCLUDED.last_read_at, last_read_message_id = EXCLUDED.last_read_message_id
      WHERE (direct_conversation_read.last_read_at, direct_conversation_read.last_read_message_id)
          < (EXCLUDED.last_read_at, EXCLUDED.last_read_message_id)''',
      parameters: [id, viewerId, messageId],
    );
  }
}

class _ParsedMessage {
  const _ParsedMessage({required this.body, required this.id});

  final String body;
  final String id;
}

_ParsedMessage _parseBody(Map<String, Object?> input) {
  if (input.keys.any((key) => key != 'body' && key != 'clientMessageId')) {
    throw const ApiException(400, 'Request contains an unsupported field.');
  }
  if (input['body'] is! String) {
    throw const ApiException(400, 'Message body must be text.');
  }
  final body = unorm.nfc((input['body'] as String).trim());
  if (body.isEmpty || body.length > 2000) {
    throw const ApiException(400, 'Message must contain 1–2000 characters.');
  }
  final id = input.containsKey('clientMessageId')
      ? _parseUuid(input['clientMessageId'], 'Message ID')
      : _randomUuid();
  return _ParsedMessage(body: body, id: id);
}

_MessageCursor? _parseCursor(String? input) {
  if (input == null) return null;
  if (input.length > 256 || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(input)) {
    throw const ApiException(400, 'Cursor is invalid.');
  }
  try {
    final decoded = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(input))),
    );
    if (decoded is! List ||
        decoded.length != 2 ||
        decoded[0] is! String ||
        decoded[1] is! String) {
      throw const FormatException();
    }
    final createdAt = DateTime.tryParse(decoded[0] as String);
    if (createdAt == null) throw const FormatException();
    return _MessageCursor(
      createdAt: createdAt,
      id: _parseUuid(decoded[1], 'Cursor'),
    );
  } on Object {
    throw const ApiException(400, 'Cursor is invalid.');
  }
}

String _encodeCursor(_MessageCursor cursor) => base64Url
    .encode(
      utf8.encode(
        jsonEncode([cursor.createdAt.toUtc().toIso8601String(), cursor.id]),
      ),
    )
    .replaceAll('=', '');

String _parseUuid(Object? input, String name) {
  if (input is! String || !_uuidPattern.hasMatch(input)) {
    throw ApiException(400, '$name is invalid.');
  }
  return input;
}

String _parseHandle(String input) {
  final handle = (input.startsWith('@') ? input.substring(1) : input)
      .trim()
      .toLowerCase();
  if (!_handlePattern.hasMatch(handle)) {
    throw const ApiException(400, 'Handle is invalid.');
  }
  return handle;
}

String _randomUuid() {
  final random = Random.secure();
  final bytes = Uint8List.fromList(
    List<int>.generate(16, (_) => random.nextInt(256)),
  );
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

DateTime _dateTime(Object? value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.parse(value);
  throw StateError('Database returned an invalid timestamp.');
}
