import 'package:ionic_server/src/modules/trust/text_policy.dart';

import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ionic_server/src/http/api_exception.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/media/media_attachment_service.dart';
import 'package:ionic_server/src/modules/media/media_cleanup_service.dart';
import 'package:ionic_server/src/modules/recommendation/content_labeler.dart';
import 'package:ionic_server/src/modules/recommendation/recommendation_signals.dart';
import 'package:ionic_server/src/modules/recommendation/text_label_rules.dart';
import 'package:ionic_server/src/modules/recommendation/types.dart';
import 'package:postgres/postgres.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

part 'post_comments.dart';

final _postUuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
);
final _handlePattern = RegExp(r'^[a-z0-9_-]{3,24}$');

class _PostsCursor {
  const _PostsCursor({required this.createdAt, required this.id});

  final DateTime createdAt;
  final String id;
}

Future<void> _checkPublishRetry(
  TxSession tx,
  Map<String, dynamic> row,
  String authorId,
  String body,
  String id,
  bool reply,
  List<String> attachmentIds,
) async {
  if ('${row['author_id']}' != authorId || '${row['body']}' != body) {
    throw const ApiException(409, 'Publish ID has already been used.');
  }
  final rows = await tx.execute(
    reply
        ? r'SELECT media_asset_id FROM content_attachment WHERE reply_id = $1 ORDER BY position'
        : r'SELECT media_asset_id FROM content_attachment WHERE content_id = $1 ORDER BY position',
    parameters: [id],
  );
  if (jsonEncode(rows.map((r) => '${r.first}').toList()) !=
      jsonEncode(attachmentIds)) {
    throw const ApiException(409, 'Publish ID has already been used.');
  }
}

class PostsService {
  PostsService(this._database) : _signals = RecommendationSignalsService();

  final DatabaseService _database;
  final RecommendationSignalsService _signals;

  Future<Map<String, Object?>> readVisible(
    String? viewerId,
    Object? input, {
    bool feedControls = false,
  }) async {
    if (input is! List ||
        input.isEmpty ||
        input.length > 50 ||
        input.any((id) => id is! String || !_postUuidPattern.hasMatch(id))) {
      throw const ApiException(400, 'Expected one to fifty post IDs.');
    }
    final rows = await _database.query(
      r'''
      SELECT c.id,c.author_id,c.body,c.created_at,u.handle AS author_handle,
        p.display_name AS author_display_name,p.avatar_media_id AS author_avatar_id,
        (SELECT count(*)::int FROM content_reaction r WHERE r.content_id=c.id) AS like_count,
        (SELECT count(*)::int FROM content_reply r WHERE r.content_id=c.id AND r.status='published') AS reply_count,
        EXISTS(SELECT 1 FROM content_reaction r WHERE r.content_id=c.id AND r.user_id=$2) AS liked,
        EXISTS(SELECT 1 FROM content_bookmark b WHERE b.content_id=c.id AND b.user_id=$2) AS saved
      FROM content c JOIN app_user u ON u.id=c.author_id AND u.state='active'
      JOIN user_profile p ON p.user_id=u.id
      WHERE c.id=ANY($1::uuid[]) AND c.kind='text' AND c.status='published' AND c.deleted_at IS NULL
        AND (p.visibility='public' OR u.id=$2 OR EXISTS(SELECT 1 FROM account_follow f WHERE f.follower_id=$2 AND f.followed_id=u.id))
        AND NOT EXISTS(SELECT 1 FROM account_block b WHERE (b.blocker_id=$2 AND b.blocked_id=u.id) OR (b.blocker_id=u.id AND b.blocked_id=$2))
        AND (NOT $3 OR (NOT EXISTS(SELECT 1 FROM account_mute m WHERE m.muter_id=$2 AND m.muted_id=u.id)
          AND NOT EXISTS(SELECT 1 FROM feed_content_hide h WHERE h.user_id=$2 AND h.content_id=c.id)))
      ORDER BY array_position($1::uuid[],c.id)''',
      parameters: [
        input.cast<String>().toSet().toList(),
        viewerId,
        feedControls,
      ],
    );
    return _postPage(rows, 50, includeAuthor: true, database: _database);
  }

  Future<Map<String, String>> deleteOwn(String viewerId, String inputId) async {
    final id = _parseContentId(inputId);
    await _database.query(
      r'DELETE FROM content WHERE id = $1 AND author_id = $2',
      parameters: [id, viewerId],
    );
    await MediaCleanupService(_database).drainBestEffort();
    return {'status': 'deleted'};
  }

  Future<Map<String, String>> editOwn(
    String viewerId,
    String inputId,
    Map<String, Object?> input,
  ) async {
    final id = _parseContentId(inputId);
    if (input.length != 1 || input['body'] is! String) {
      throw const ApiException(400, 'Post body is invalid.');
    }
    final body = unorm.nfc((input['body'] as String).trim());
    requireLinkFree(body);
    if (body.isEmpty || body.length > 280) {
      throw const ApiException(400, 'Post body must contain 1–280 characters.');
    }
    final version = _activeTaxonomyVersion();
    final labels = labelContent(
      LabelContentInput(
        taxonomyVersion: version,
        kind: ContentKind.text,
        text: body,
        formatLabelIds: const {ContentKind.text: 'format.text'},
        keywordRules: textLabelRules,
      ),
    );
    await _database.transaction((tx) async {
      final changed = await tx.execute(
        r'''UPDATE content SET body = $3, updated_at = now()
        WHERE id = $1 AND author_id = $2 AND kind = 'text' AND status = 'published' AND deleted_at IS NULL RETURNING id''',
        parameters: [id, viewerId, body],
      );
      if (changed.isEmpty) throw const ApiException(404, 'Post was not found.');
      await tx.execute(
        r'DELETE FROM content_label WHERE content_id = $1',
        parameters: [id],
      );
      for (final label in labels) {
        await tx.execute(
          r'''INSERT INTO content_label(content_id, taxonomy_version, dimension, label_id, confidence, source)
          VALUES ($1, $2, $3, $4, $5, $6)''',
          parameters: [
            id,
            version,
            label.dimension.name,
            label.labelId,
            label.confidence,
            label.source.name,
          ],
        );
      }
    });
    return {'status': 'updated'};
  }

  Future<Map<String, Object?>> listSaved(
    String viewerId,
    int limit,
    String? cursorInput,
  ) async {
    final cursor = _parsePostsCursor(cursorInput);
    final rows = await _database.query(
      r'''SELECT c.id, c.author_id, c.body, c.created_at, u.handle AS author_handle, p.display_name AS author_display_name, p.avatar_media_id AS author_avatar_id,
      (SELECT count(*)::int FROM content_reaction r WHERE r.content_id = c.id) AS like_count,
      (SELECT count(*)::int FROM content_reply r WHERE r.content_id = c.id AND r.status = 'published') AS reply_count,
      EXISTS (SELECT 1 FROM content_reaction r WHERE r.content_id = c.id AND r.user_id = $1) AS liked, true AS saved
      FROM content_bookmark b JOIN content c ON c.id = b.content_id
      JOIN app_user u ON u.id = c.author_id AND u.state = 'active' JOIN user_profile p ON p.user_id = u.id
      WHERE b.user_id = $1 AND c.kind = 'text' AND c.status = 'published' AND c.deleted_at IS NULL
        AND (p.visibility = 'public' OR u.id = $1 OR EXISTS (SELECT 1 FROM account_follow f WHERE f.follower_id = $1 AND f.followed_id = u.id))
        AND NOT EXISTS (SELECT 1 FROM account_block bl WHERE (bl.blocker_id = $1 AND bl.blocked_id = u.id) OR (bl.blocker_id = u.id AND bl.blocked_id = $1))
        AND ($2::timestamptz IS NULL OR (c.created_at, c.id) < ($2, $3::uuid))
      ORDER BY c.created_at DESC, c.id DESC LIMIT $4''',
      parameters: [viewerId, cursor?.createdAt, cursor?.id, limit + 1],
    );
    return _postPage(rows, limit, includeAuthor: true, database: _database);
  }

  Future<Map<String, Object?>> create(
    String authorId,
    Map<String, Object?> input,
  ) async {
    if (input.keys.any(
      (key) => !['body', 'attachmentIds', 'clientPublishId'].contains(key),
    )) {
      throw const ApiException(400, 'Request contains an unsupported field.');
    }
    final attachmentIds = parseAttachmentIds(input['attachmentIds']);
    if (input['body'] is! String) {
      throw const ApiException(400, 'Post body must be text.');
    }
    final body = unorm.nfc((input['body'] as String).trim());
    requireLinkFree(body);
    if (body.isEmpty || body.length > 280) {
      throw const ApiException(400, 'Post body must contain 1–280 characters.');
    }
    final id = input.containsKey('clientPublishId')
        ? _parseContentId('${input['clientPublishId']}')
        : _randomUuid();
    final version = _activeTaxonomyVersion();
    final labels = labelContent(
      LabelContentInput(
        taxonomyVersion: version,
        kind: ContentKind.text,
        text: body,
        formatLabelIds: const {
          ContentKind.text: 'format.text',
          ContentKind.short_video: 'format.short_video',
        },
        keywordRules: textLabelRules,
      ),
    );

    final created = await _database.transaction((transaction) async {
      await transaction.execute(
        r'SELECT pg_advisory_xact_lock(hashtextextended($1, 0))',
        parameters: ['post:$id'],
      );
      final previous = await transaction.execute(
        r'SELECT id, author_id, body, created_at FROM content WHERE id = $1',
        parameters: [id],
      );
      if (previous.isNotEmpty) {
        final row = previous.first.toColumnMap();
        await _checkPublishRetry(
          transaction,
          row,
          authorId,
          body,
          id,
          false,
          attachmentIds,
        );
        return row;
      }
      final inserted = await transaction.execute(
        r'''INSERT INTO content (id, author_id, body)
            VALUES ($1, $2, $3) RETURNING id, author_id, body, created_at''',
        parameters: [id, authorId, body],
      );
      for (final label in labels) {
        await transaction.execute(
          r'''INSERT INTO content_label
               (content_id, taxonomy_version, dimension, label_id, confidence, source)
             VALUES ($1, $2, $3, $4, $5, $6)''',
          parameters: [
            id,
            label.taxonomyVersion,
            label.dimension.name,
            label.labelId,
            label.confidence,
            label.source.name,
          ],
        );
      }
      await attachStagedMedia(
        transaction: transaction,
        ownerId: authorId,
        parentId: id,
        isReply: false,
        attachmentIds: attachmentIds,
      );
      return inserted.first.toColumnMap();
    });
    return _postView(
      created,
      likeCount: 0,
      replyCount: 0,
      liked: false,
      saved: false,
    )..['attachments'] = await attachmentsForContent(_database, id);
  }

  Future<Map<String, Object?>> listMine(
    String authorId,
    int limit,
    String? cursorInput,
  ) async {
    final cursor = _parsePostsCursor(cursorInput);
    final result = await _database.query(
      r'''SELECT c.id, c.author_id, c.body, c.created_at,
                (SELECT count(*)::int FROM content_reaction r WHERE r.content_id = c.id) AS like_count,
                (SELECT count(*)::int FROM content_reply r WHERE r.content_id = c.id AND r.status = 'published') AS reply_count,
                EXISTS (SELECT 1 FROM content_reaction r WHERE r.content_id = c.id AND r.user_id = $1) AS liked,
                EXISTS (SELECT 1 FROM content_bookmark b WHERE b.content_id = c.id AND b.user_id = $1) AS saved
         FROM content c
          WHERE c.author_id = $1 AND c.kind = 'text' AND c.status = 'published' AND c.deleted_at IS NULL
           AND ($2::timestamptz IS NULL OR (c.created_at, c.id) < ($2::timestamptz, $3::uuid))
         ORDER BY c.created_at DESC, c.id DESC LIMIT $4''',
      parameters: [authorId, cursor?.createdAt, cursor?.id, limit + 1],
    );
    return _postPage(result, limit, database: _database);
  }

  Future<Map<String, Object?>> listPublic(
    int limit,
    String? cursorInput,
  ) async {
    final cursor = _parsePostsCursor(cursorInput);
    final result = await _database.query(
      r'''SELECT c.id, c.author_id, c.body, c.created_at,
                u.handle AS author_handle, p.display_name AS author_display_name, p.avatar_media_id AS author_avatar_id,
                (SELECT count(*)::int FROM content_reaction r WHERE r.content_id = c.id) AS like_count,
                (SELECT count(*)::int FROM content_reply r WHERE r.content_id = c.id AND r.status = 'published') AS reply_count,
                false AS liked, false AS saved
         FROM content c
         JOIN app_user u ON u.id = c.author_id AND u.state = 'active'
         JOIN user_profile p ON p.user_id = u.id
         WHERE c.kind = 'text' AND c.visibility = 'public'
           AND c.status = 'published' AND c.deleted_at IS NULL
           AND p.visibility = 'public'
           AND ($1::timestamptz IS NULL OR (c.created_at, c.id) < ($1::timestamptz, $2::uuid))
         ORDER BY c.created_at DESC, c.id DESC LIMIT $3''',
      parameters: [cursor?.createdAt, cursor?.id, limit + 1],
    );
    return _postPage(result, limit, includeAuthor: true, database: _database);
  }

  Future<Map<String, Object?>> listFollowing(
    String viewerId,
    int limit,
    String? cursorInput,
  ) async {
    final cursor = _parsePostsCursor(cursorInput);
    final result = await _database.query(
      r'''SELECT c.id, c.author_id, c.body, c.created_at,
                u.handle AS author_handle, p.display_name AS author_display_name, p.avatar_media_id AS author_avatar_id,
                (SELECT count(*)::int FROM content_reaction r WHERE r.content_id = c.id) AS like_count,
                (SELECT count(*)::int FROM content_reply r WHERE r.content_id = c.id AND r.status = 'published') AS reply_count,
                EXISTS (SELECT 1 FROM content_reaction r WHERE r.content_id = c.id AND r.user_id = $1) AS liked,
                EXISTS (SELECT 1 FROM content_bookmark b WHERE b.content_id = c.id AND b.user_id = $1) AS saved
         FROM account_follow f
         JOIN app_user u ON u.id = f.followed_id AND u.state = 'active'
         JOIN user_profile p ON p.user_id = u.id
         JOIN content c ON c.author_id = u.id
         WHERE f.follower_id = $1 AND c.kind = 'text' AND c.status = 'published' AND c.deleted_at IS NULL
           AND ($2::timestamptz IS NULL OR (c.created_at, c.id) < ($2::timestamptz, $3::uuid))
           AND NOT EXISTS (SELECT 1 FROM feed_content_hide h WHERE h.user_id = $1 AND h.content_id = c.id)
           AND NOT EXISTS (SELECT 1 FROM account_block b
             WHERE (b.blocker_id = $1 AND b.blocked_id = u.id) OR (b.blocker_id = u.id AND b.blocked_id = $1))
           AND NOT EXISTS (SELECT 1 FROM account_mute m WHERE m.muter_id = $1 AND m.muted_id = u.id)
         ORDER BY c.created_at DESC, c.id DESC LIMIT $4''',
      parameters: [viewerId, cursor?.createdAt, cursor?.id, limit + 1],
    );
    return _postPage(result, limit, includeAuthor: true, database: _database);
  }

  Future<Map<String, Object?>> search(
    String viewerId,
    String? inputQuery,
    int limit,
    String? cursorInput,
  ) async {
    if (inputQuery == null) {
      throw const ApiException(400, 'Search query is invalid.');
    }
    final query = unorm.nfc(inputQuery.trim());
    if (query.length < 2 || query.length > 48) {
      throw const ApiException(
        400,
        'Search query must contain 2–48 characters.',
      );
    }
    final cursor = _parsePostsCursor(cursorInput);
    final result = await _database.query(
      r'''WITH search_term AS (SELECT websearch_to_tsquery('simple', $2) AS value)
         SELECT c.id, c.author_id, c.body, c.created_at,
                u.handle AS author_handle, p.display_name AS author_display_name, p.avatar_media_id AS author_avatar_id,
                (SELECT count(*)::int FROM content_reaction r WHERE r.content_id = c.id) AS like_count,
                (SELECT count(*)::int FROM content_reply r WHERE r.content_id = c.id AND r.status = 'published') AS reply_count,
                EXISTS (SELECT 1 FROM content_reaction r WHERE r.content_id = c.id AND r.user_id = $1) AS liked,
                EXISTS (SELECT 1 FROM content_bookmark b WHERE b.content_id = c.id AND b.user_id = $1) AS saved
         FROM content c
         JOIN app_user u ON u.id = c.author_id AND u.state = 'active'
         JOIN user_profile p ON p.user_id = u.id
         CROSS JOIN search_term term
         WHERE c.kind = 'text' AND c.status = 'published' AND c.deleted_at IS NULL
           AND to_tsvector('simple', c.body::text) @@ term.value
           AND (u.id = $1 OR p.visibility = 'public' OR EXISTS (
             SELECT 1 FROM account_follow f WHERE f.follower_id = $1 AND f.followed_id = u.id))
           AND NOT EXISTS (SELECT 1 FROM account_block b
             WHERE (b.blocker_id = $1 AND b.blocked_id = u.id) OR (b.blocker_id = u.id AND b.blocked_id = $1))
           AND ($3::timestamptz IS NULL OR (c.created_at, c.id) < ($3::timestamptz, $4::uuid))
         ORDER BY c.created_at DESC, c.id DESC LIMIT $5''',
      parameters: [viewerId, query, cursor?.createdAt, cursor?.id, limit + 1],
    );
    return _postPage(result, limit, includeAuthor: true, database: _database);
  }

  Future<Map<String, Object?>> listAuthor(
    String viewerId,
    String inputHandle,
    int limit,
    String? cursorInput,
  ) async {
    final handle = inputHandle.startsWith('@')
        ? inputHandle.substring(1)
        : inputHandle;
    final normalizedHandle = handle.toLowerCase();
    if (!_handlePattern.hasMatch(normalizedHandle)) {
      throw const ApiException(400, 'Handle is invalid.');
    }
    final access = await _database.query(
      r'''SELECT u.id AS author_id,
                (u.id = $1 OR p.visibility = 'public' OR EXISTS (
                  SELECT 1 FROM account_follow f WHERE f.follower_id = $1 AND f.followed_id = u.id))
                AND NOT EXISTS (SELECT 1 FROM account_block b
                  WHERE (b.blocker_id = $1 AND b.blocked_id = u.id)
                     OR (b.blocker_id = u.id AND b.blocked_id = $1)) AS allowed
         FROM app_user u JOIN user_profile p ON p.user_id = u.id
         WHERE u.handle_normalized = $2 AND u.state = 'active' ''',
      parameters: [viewerId, normalizedHandle],
    );
    if (access.isEmpty || access.first.toColumnMap()['allowed'] != true) {
      throw const ApiException(404, 'Profile was not found.');
    }
    final authorId = '${access.first.toColumnMap()['author_id']}';
    final cursor = _parsePostsCursor(cursorInput);
    final result = await _database.query(
      r'''SELECT c.id, c.author_id, c.body, c.created_at,
                (SELECT count(*)::int FROM content_reaction r WHERE r.content_id = c.id) AS like_count,
                (SELECT count(*)::int FROM content_reply r WHERE r.content_id = c.id AND r.status = 'published') AS reply_count,
                EXISTS (SELECT 1 FROM content_reaction r WHERE r.content_id = c.id AND r.user_id = $2) AS liked,
                EXISTS (SELECT 1 FROM content_bookmark b WHERE b.content_id = c.id AND b.user_id = $2) AS saved
         FROM content c
          WHERE c.author_id = $1 AND c.kind = 'text' AND c.status = 'published' AND c.deleted_at IS NULL
           AND ($3::timestamptz IS NULL OR (c.created_at, c.id) < ($3::timestamptz, $4::uuid))
         ORDER BY c.created_at DESC, c.id DESC LIMIT $5''',
      parameters: [
        authorId,
        viewerId,
        cursor?.createdAt,
        cursor?.id,
        limit + 1,
      ],
    );
    return _postPage(result, limit, database: _database);
  }

  Future<Map<String, Object?>> setLike(
    String viewerId,
    String inputContentId,
    bool liked,
  ) async {
    final contentId = _parseContentId(inputContentId);
    return _database.transaction((transaction) async {
      await _assertCanInteract(transaction, viewerId, contentId);
      if (liked) {
        final id = _randomUuid();
        final inserted = await transaction.execute(
          r'''INSERT INTO content_reaction(id, content_id, user_id)
              VALUES ($1, $2, $3) ON CONFLICT (content_id, user_id) DO NOTHING RETURNING id''',
          parameters: [id, contentId, viewerId],
        );
        if (inserted.isNotEmpty) {
          await _signals.recordContentAction(
            transaction: transaction,
            userId: viewerId,
            contentId: contentId,
            actionId: id,
            kind: PreferenceSignalKind.like,
          );
        }
      } else {
        final removed = await transaction.execute(
          r'DELETE FROM content_reaction WHERE content_id = $1 AND user_id = $2 RETURNING id',
          parameters: [contentId, viewerId],
        );
        if (removed.isNotEmpty) {
          await _signals.recordContentAction(
            transaction: transaction,
            userId: viewerId,
            contentId: contentId,
            actionId: '${removed.first.first}',
            kind: PreferenceSignalKind.unlike,
          );
        }
      }
      final count = await transaction.execute(
        r'SELECT count(*)::int AS like_count FROM content_reaction WHERE content_id = $1',
        parameters: [contentId],
      );
      final likeCount = (count.first.toColumnMap()['like_count'] as num)
          .toInt();
      return {'liked': liked, 'likeCount': likeCount};
    });
  }

  Future<Map<String, bool>> setSaved(
    String viewerId,
    String inputContentId,
    bool saved,
  ) async {
    final contentId = _parseContentId(inputContentId);
    return _database.transaction((transaction) async {
      await _assertCanInteract(transaction, viewerId, contentId);
      if (saved) {
        final id = _randomUuid();
        final inserted = await transaction.execute(
          r'''INSERT INTO content_bookmark(id, content_id, user_id)
              VALUES ($1, $2, $3) ON CONFLICT (content_id, user_id) DO NOTHING RETURNING id''',
          parameters: [id, contentId, viewerId],
        );
        if (inserted.isNotEmpty) {
          await _signals.recordContentAction(
            transaction: transaction,
            userId: viewerId,
            contentId: contentId,
            actionId: id,
            kind: PreferenceSignalKind.save,
          );
        }
      } else {
        final removed = await transaction.execute(
          r'DELETE FROM content_bookmark WHERE content_id = $1 AND user_id = $2 RETURNING id',
          parameters: [contentId, viewerId],
        );
        if (removed.isNotEmpty) {
          await _signals.recordContentAction(
            transaction: transaction,
            userId: viewerId,
            contentId: contentId,
            actionId: '${removed.first.first}',
            kind: PreferenceSignalKind.unsave,
          );
        }
      }
      return {'saved': saved};
    });
  }

  Future<void> _assertCanInteract(
    TxSession transaction,
    String? viewerId,
    String contentId,
  ) async {
    final result = await transaction.execute(
      r'''SELECT c.id FROM content c
          JOIN app_user u ON u.id = c.author_id AND u.state = 'active'
          JOIN user_profile p ON p.user_id = u.id
          WHERE c.id = $1 AND c.status = 'published' AND c.deleted_at IS NULL
            AND (u.id = $2 OR p.visibility = 'public' OR EXISTS (
              SELECT 1 FROM account_follow f WHERE f.follower_id = $2 AND f.followed_id = u.id))
            AND NOT EXISTS (SELECT 1 FROM account_block b
              WHERE (b.blocker_id = $2 AND b.blocked_id = u.id)
                 OR (b.blocker_id = u.id AND b.blocked_id = $2))
          FOR SHARE OF c, u, p''',
      parameters: [contentId, viewerId],
    );
    if (result.length != 1) {
      throw const ApiException(404, 'Content was not found.');
    }
  }
}

({List<ResultRow> rows, bool hasMore}) _pageRows(Result result, int limit) {
  final hasMore = result.length > limit;
  return (rows: result.take(limit).toList(), hasMore: hasMore);
}

Future<Map<String, Object?>> _postPage(
  Result result,
  int limit, {
  bool includeAuthor = false,
  required DatabaseService database,
}) async {
  final page = _pageRows(result, limit);
  final attachmentViews = await contentAttachmentViews(
    database,
    page.rows.map((row) => '${row.toColumnMap()['id']}').toList(),
  );
  final items = page.rows.map((row) {
    final value = row.toColumnMap();
    return _postView(
      value,
      likeCount: (value['like_count'] as num).toInt(),
      replyCount: (value['reply_count'] as num).toInt(),
      liked: value['liked'] == true,
      saved: value['saved'] == true,
      includeAuthor: includeAuthor,
    )..['attachments'] = attachmentViews['${value['id']}'] ?? const [];
  }).toList();
  return {'items': items, 'nextCursor': _nextCursor(page.rows, page.hasMore)};
}

Map<String, Object?> _postView(
  Map<String, dynamic> row, {
  required int likeCount,
  required int replyCount,
  required bool liked,
  required bool saved,
  bool includeAuthor = false,
}) => {
  'id': '${row['id']}',
  'authorId': '${row['author_id']}',
  'body': '${row['body']}',
  'createdAt': _dateTime(row['created_at']).toUtc().toIso8601String(),
  if (includeAuthor) 'authorHandle': '${row['author_handle']}',
  if (includeAuthor) 'authorDisplayName': '${row['author_display_name']}',
  if (includeAuthor) 'authorAvatarId': row['author_avatar_id'],
  'likeCount': likeCount,
  'replyCount': replyCount,
  'liked': liked,
  'saved': saved,
};

String? _nextCursor(List<ResultRow> rows, bool hasMore) {
  if (!hasMore || rows.isEmpty) return null;
  final last = rows.last.toColumnMap();
  final cursor = {
    'createdAt': _dateTime(last['created_at']).toUtc().toIso8601String(),
    'id': '${last['id']}',
  };
  return base64Url.encode(utf8.encode(jsonEncode(cursor))).replaceAll('=', '');
}

_PostsCursor? _parsePostsCursor(String? input) {
  if (input == null) return null;
  if (input.length > 256 || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(input)) {
    throw const ApiException(400, 'Cursor is invalid.');
  }
  try {
    final value = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(input))),
    );
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid cursor shape.');
    }
    final createdAt = value['createdAt'];
    final id = value['id'];
    if (createdAt is! String ||
        DateTime.tryParse(createdAt) == null ||
        id is! String ||
        !_postUuidPattern.hasMatch(id)) {
      throw const FormatException('Invalid cursor values.');
    }
    return _PostsCursor(createdAt: DateTime.parse(createdAt).toUtc(), id: id);
  } on Object {
    throw const ApiException(400, 'Cursor is invalid.');
  }
}

String _parseContentId(String input) {
  if (!_postUuidPattern.hasMatch(input)) {
    throw const ApiException(400, 'Content ID is invalid.');
  }
  return input;
}

String _activeTaxonomyVersion() {
  final version = Platform.environment['RECOMMENDATION_TAXONOMY_VERSION']
      ?.trim();
  if (version == null || version.isEmpty) return 'ionic-taxonomy-v1';
  if (version.length > 64) {
    throw StateError(
      'RECOMMENDATION_TAXONOMY_VERSION cannot exceed 64 characters.',
    );
  }
  return version;
}

DateTime _dateTime(Object? value) {
  if (value is DateTime) return value;
  throw StateError('Database returned an invalid timestamp.');
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
