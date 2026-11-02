import 'dart:convert';

import 'package:ionic_server/src/http/api_exception.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/media/media_attachment_service.dart';
import 'package:postgres/postgres.dart';

import 'text_policy.dart';

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
);

class ModerationService {
  ModerationService(this.db);
  final DatabaseService db;
  Future<bool> isReviewer(String userId) async => (await db.query(
    r"SELECT 1 FROM moderation_reviewer m JOIN app_user u ON u.id=m.user_id AND u.state='active' WHERE m.user_id=$1",
    parameters: [userId],
  )).isNotEmpty;
  Future<void> _authorize(TxSession tx, String userId) async {
    if ((await tx.execute(
      r"SELECT m.user_id FROM moderation_reviewer m JOIN app_user u ON u.id=m.user_id AND u.state='active' WHERE m.user_id=$1 FOR SHARE OF m,u",
      parameters: [userId],
    )).isEmpty) {
      throw const ApiException(403, 'Reviewer permission is required.');
    }
  }

  Future<Map<String, Object?>> queue(String userId, String? cursor) async {
    DateTime? before;
    String? beforeId;
    if (cursor != null) {
      try {
        if (cursor.length > 256) throw const FormatException();
        final v = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(cursor))),
        ) as Map;
        before = DateTime.parse(v['at'] as String);
        beforeId = v['id'] as String;
        if (!_uuid.hasMatch(beforeId)) throw const FormatException();
      } catch (_) {
        throw const ApiException(400, 'Review cursor is invalid.');
      }
    }
    final rows = await db.transaction((tx) async {
      await _authorize(tx, userId);
      return tx.execute(
        r'''
        SELECT q.id,q.content_id,q.reply_id,q.reason,q.details,q.created_at,
          COALESCE(r.body,c.body) AS body,COALESCE(r.author_id,c.author_id) AS author_id
        FROM content_report q JOIN content c ON c.id=q.content_id AND c.status='published' AND c.deleted_at IS NULL
        LEFT JOIN content_reply r ON r.id=q.reply_id AND r.status='published'
        WHERE q.status IN ('received','reviewing') AND q.created_at>now()-interval '30 days'
          AND (q.reply_id IS NULL OR r.id IS NOT NULL)
          AND ($1::timestamptz IS NULL OR (q.created_at,q.id)<($1::timestamptz,$2::uuid))
        ORDER BY q.created_at DESC,q.id DESC LIMIT 31''',
        parameters: [before, beforeId],
      );
    });
    final page = rows.take(30).map((r) => r.toColumnMap()).toList();
    final postMedia = await contentAttachmentViews(
      db,
      page
          .where((r) => r['reply_id'] == null)
          .map((r) => '${r['content_id']}')
          .toList(),
    );
    final replyMedia = await replyAttachmentViews(
      db,
      page
          .where((r) => r['reply_id'] != null)
          .map((r) => '${r['reply_id']}')
          .toList(),
    );
    String? next;
    if (rows.length > 30) {
      final last = page.last;
      next = base64Url
          .encode(
            utf8.encode(
              jsonEncode({
                'at': (last['created_at'] as DateTime)
                    .toUtc()
                    .toIso8601String(),
                'id': '${last['id']}',
              }),
            ),
          )
          .replaceAll('=', '');
    }
    return {
      'items': page
          .map(
            (r) => {
              'id': r['id'],
              'contentId': r['content_id'],
              'replyId': r['reply_id'],
              'reason': r['reason'],
              'details': r['details'],
              'body': r['body'],
              'createdAt': (r['created_at'] as DateTime)
                  .toUtc()
                  .toIso8601String(),
              'attachments': r['reply_id'] == null
                  ? (postMedia['${r['content_id']}'] ?? [])
                  : (replyMedia['${r['reply_id']}'] ?? []),
            },
          )
          .toList(),
      'nextCursor': next,
    };
  }

  Future<void> resolve(
    String userId,
    String id,
    Map<String, Object?> input,
  ) async {
    final action = input['action'], reason = input['reason'];
    if (!_uuid.hasMatch(id) ||
        input.length != 2 ||
        !{'remove', 'dismiss'}.contains(action) ||
        reason is! String ||
        reason.trim().isEmpty ||
        reason.length > 500) {
      throw const ApiException(400, 'Choose a decision and enter a reason.');
    }
    requireLinkFree(reason);
    await db.transaction((tx) async {
      await _authorize(tx, userId);
      // Target lock first, shared by all reports on that item. No count-based removal.
      final lookup = await tx.execute(
        r"SELECT content_id,reply_id FROM content_report WHERE id=$1 AND created_at>now()-interval '30 days'",
        parameters: [id],
      );
      if (lookup.isEmpty) {
        throw const ApiException(404, 'Report was not found.');
      }
      final target = lookup.first.toColumnMap(),
          postId = target['content_id'],
          replyId = target['reply_id'];
      await tx.execute(
        r'SELECT id FROM content WHERE id=$1 FOR UPDATE',
        parameters: [postId],
      );
      final rows = await tx.execute(
        r'SELECT status FROM content_report WHERE id=$1 FOR UPDATE',
        parameters: [id],
      );
      if (rows.isEmpty) throw const ApiException(404, 'Report was not found.');
      if (!{'received', 'reviewing'}.contains(rows.first.first)) return;
      if (action == 'remove') {
        if (replyId == null) {
          await tx.execute(
            r"UPDATE content SET status='removed',updated_at=now() WHERE id=$1",
            parameters: [postId],
          );
        } else {
          await tx.execute(
            r"UPDATE content_reply SET status='removed' WHERE id=$1 AND content_id=$2",
            parameters: [replyId, postId],
          );
        }
      }
      await tx.execute(
        r"""UPDATE content_report SET status=$3 WHERE content_id=$1
        AND reply_id IS NOT DISTINCT FROM $2::uuid AND status IN ('received','reviewing')""",
        parameters: [
          postId,
          replyId,
          action == 'remove' ? 'actioned' : 'dismissed',
        ],
      );
      await tx.execute(
        r'INSERT INTO moderation_audit(reviewer_id,content_id,reply_id,action,reason) VALUES($1,$2,$3,$4,$5)',
        parameters: [userId, postId, replyId, action, reason.trim()],
      );
    });
  }

  Future<Result> reportedMedia(String inputId, String viewerId) async {
    return db.query(
      r"""
        SELECT a.storage_key,a.media_type,a.mime_type,a.byte_size
        FROM moderation_reviewer mr JOIN content_report q ON q.status IN ('received','reviewing')
          AND q.created_at>now()-interval '30 days'
        JOIN content_attachment ca ON (q.reply_id IS NULL AND ca.content_id=q.content_id)
          OR (q.reply_id IS NOT NULL AND ca.reply_id=q.reply_id)
        JOIN content c ON c.id=q.content_id AND c.status='published' AND c.deleted_at IS NULL
        JOIN media_asset a ON a.id=ca.media_asset_id AND a.processing_state='ready'
        LEFT JOIN content_reply r ON r.id=q.reply_id AND r.status='published'
        JOIN app_user reviewer ON reviewer.id=mr.user_id AND reviewer.state='active'
        WHERE mr.user_id=$2 AND a.id=$1 AND (q.reply_id IS NULL OR r.id IS NOT NULL)
        LIMIT 1""",
      parameters: [inputId, viewerId],
    );
  }

  Future<void> cleanupExpired() async {
    for (final table in ['content_report', 'moderation_audit']) {
      await db.query(
        "DELETE FROM $table WHERE ctid IN(SELECT ctid FROM $table WHERE created_at<=now()-interval '30 days' ORDER BY created_at LIMIT 2000)",
      );
    }
  }
}
