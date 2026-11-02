part of 'posts_service.dart';

/// Comment domain state never produces recommendation evidence from hearts.
extension PostComments on PostsService {
  Future<Map<String, dynamic>> _replyTarget(
    TxSession tx,
    String? viewer,
    String post,
    String reply, {
    bool allowRemoved = false,
  }) async {
    final rows = await tx.execute(
      r'''SELECT r.* FROM content_reply r
      JOIN app_user u ON u.id=r.author_id AND u.state='active'
      WHERE r.id=$1 AND r.content_id=$2
        AND (r.status='published' OR ($4 AND r.status='removed'))
        AND NOT EXISTS(SELECT 1 FROM account_block b WHERE
          (b.blocker_id=$3 AND b.blocked_id=r.author_id) OR
          (b.blocker_id=r.author_id AND b.blocked_id=$3))
      FOR SHARE OF r''',
      parameters: [reply, post, viewer, allowRemoved],
    );
    if (rows.isEmpty) throw const ApiException(404, 'Comment was not found.');
    return rows.first.toColumnMap();
  }

  Future<Map<String, Object?>> addReply(
    String viewerId,
    String inputContentId,
    Map<String, Object?> input,
  ) async {
    final contentId = _parseContentId(inputContentId);
    if (input.keys.any(
          (k) => ![
            'body',
            'attachmentIds',
            'clientPublishId',
            'parentReplyId',
          ].contains(k),
        ) ||
        input['body'] is! String) {
      throw const ApiException(400, 'Reply body is invalid.');
    }
    final body = unorm.nfc((input['body'] as String).trim());
    requireLinkFree(body);
    if (body.isEmpty || body.length > 500) {
      throw const ApiException(400, 'Reply must contain 1–500 characters.');
    }
    final attachments = parseAttachmentIds(input['attachmentIds']);
    final parent = input['parentReplyId'] == null
        ? null
        : _parseContentId('${input['parentReplyId']}');
    final id = input.containsKey('clientPublishId')
        ? _parseContentId('${input['clientPublishId']}')
        : _randomUuid();
    await _database.transaction((tx) async {
      await _assertCanInteract(tx, viewerId, contentId);
      await tx.execute(
        r'SELECT pg_advisory_xact_lock(hashtextextended($1,0))',
        parameters: ['reply:$id'],
      );
      final previous = await tx.execute(
        r'SELECT * FROM content_reply WHERE id=$1',
        parameters: [id],
      );
      if (previous.isNotEmpty) {
        final row = previous.first.toColumnMap();
        if ('${row['content_id']}' != contentId ||
            row['parent_reply_id']?.toString() != parent ||
            row['status'] != 'published') {
          throw const ApiException(409, 'Publish ID has already been used.');
        }
        await _checkPublishRetry(
          tx,
          row,
          viewerId,
          body,
          id,
          true,
          attachments,
        );
        return;
      }
      String? root;
      if (parent != null) {
        final target = await _replyTarget(tx, viewerId, contentId, parent);
        root = target['thread_root_id']?.toString() ?? parent;
        if (root != parent) {
          await _replyTarget(tx, viewerId, contentId, root, allowRemoved: true);
        }
      }
      final inserted = await tx.execute(
        r'''INSERT INTO content_reply
        (id,content_id,author_id,body,parent_reply_id,thread_root_id)
        SELECT $1,$2,u.id,$4,$5,$6 FROM app_user u WHERE u.id=$3 AND u.state='active'
        RETURNING id''',
        parameters: [id, contentId, viewerId, body, parent, root],
      );
      if (inserted.isEmpty) {
        throw const ApiException(404, 'Account was not found.');
      }
      await attachStagedMedia(
        transaction: tx,
        ownerId: viewerId,
        parentId: id,
        isReply: true,
        attachmentIds: attachments,
      );
      await _signals.recordContentAction(
        transaction: tx,
        userId: viewerId,
        contentId: contentId,
        actionId: id,
        kind: PreferenceSignalKind.comment,
      );
    });
    final result = await listReplies(
      viewerId,
      contentId,
      1,
      null,
      ids: [id],
      threaded: true,
    );
    final items = result['items'] as List;
    if (items.isEmpty) {
      throw const ApiException(409, 'Comment is no longer available.');
    }
    return items.single as Map<String, Object?>;
  }

  Future<Map<String, Object?>> setReplyLike(
    String viewerId,
    String inputPost,
    String inputReply,
    bool liked,
  ) async {
    final post = _parseContentId(inputPost),
        reply = _parseContentId(inputReply);
    return _database.transaction((tx) async {
      await _assertCanInteract(tx, viewerId, post);
      final target = await _replyTarget(tx, viewerId, post, reply);
      final root = target['thread_root_id']?.toString();
      if (root != null) {
        await _replyTarget(tx, viewerId, post, root, allowRemoved: true);
      }
      // Serializes same-account like/unlike without locking unrelated readers.
      await tx.execute(
        r'SELECT pg_advisory_xact_lock(hashtextextended($1,0))',
        parameters: ['reply-heart:$reply:$viewerId'],
      );
      if (liked) {
        await tx.execute(
          r'INSERT INTO content_reply_reaction(reply_id,user_id) VALUES($1,$2) ON CONFLICT DO NOTHING',
          parameters: [reply, viewerId],
        );
      } else {
        await tx.execute(
          r'DELETE FROM content_reply_reaction WHERE reply_id=$1 AND user_id=$2',
          parameters: [reply, viewerId],
        );
      }
      final count = await tx.execute(
        r'SELECT count(*)::int FROM content_reply_reaction WHERE reply_id=$1',
        parameters: [reply],
      );
      return {'liked': liked, 'likeCount': count.first.first};
    });
  }

  Future<Map<String, Object?>> deleteReply(
    String viewerId,
    String inputPost,
    String inputReply,
  ) async {
    final post = _parseContentId(inputPost),
        reply = _parseContentId(inputReply);
    await _database.transaction((tx) async {
      // Own-data removal remains possible after a block or visibility change.
      final parent = await tx.execute(
        r'SELECT author_id FROM content WHERE id=$1 FOR SHARE',
        parameters: [post],
      );
      if (parent.isEmpty) throw const ApiException(404, 'Post was not found.');
      final rows = await tx.execute(
        r'SELECT author_id FROM content_reply WHERE id=$1 AND content_id=$2 FOR UPDATE',
        parameters: [reply, post],
      );
      if (rows.isEmpty ||
          ('${rows.first.first}' != viewerId &&
              '${parent.first.first}' != viewerId)) {
        throw const ApiException(404, 'Comment was not found.');
      }
      await removeReplyMedia(tx, reply);
      await tx.execute(
        r'DELETE FROM content_reply_reaction WHERE reply_id=$1',
        parameters: [reply],
      );
      await tx.execute(
        r"UPDATE content_reply SET status='removed',body='Comment removed.' WHERE id=$1",
        parameters: [reply],
      );
    });
    unawaited(MediaCleanupService(_database).drainBestEffort());
    return {'deleted': true};
  }

  Future<Map<String, Object?>> listReplies(
    String? viewerId,
    String inputContentId,
    int limit,
    String? cursorInput, {
    List<String>? ids,
    bool threaded = false,
    String? thread,
  }) async {
    final post = _parseContentId(inputContentId),
        cursor = _parsePostsCursor(cursorInput);
    final root = thread == null ? null : _parseContentId(thread);
    if (limit < 1 || limit > 50 || (root != null && !threaded)) {
      throw const ApiException(400, 'Comment page is invalid.');
    }
    return _database.transaction((tx) async {
      await _assertCanInteract(tx, viewerId, post);
      if (root != null) {
        final target = await _replyTarget(
          tx,
          viewerId,
          post,
          root,
          allowRemoved: true,
        );
        if (target['thread_root_id'] != null) {
          throw const ApiException(400, 'Expected a root comment.');
        }
      }
      final result = await tx.execute(
        r'''SELECT r.*,u.handle AS author_handle,
        p.display_name AS author_display_name,p.avatar_media_id AS author_avatar_id,
        c.author_id AS post_author_id,
        (SELECT count(*)::int FROM content_reply_reaction x WHERE x.reply_id=r.id) AS like_count,
        EXISTS(SELECT 1 FROM content_reply_reaction x WHERE x.reply_id=r.id AND x.user_id=$5) AS liked,
        (SELECT count(*)::int FROM content_reply ch JOIN app_user cu ON cu.id=ch.author_id AND cu.state='active'
          WHERE ch.thread_root_id=r.id AND ch.status='published' AND NOT EXISTS(
            SELECT 1 FROM account_block b WHERE (b.blocker_id=$5 AND b.blocked_id=ch.author_id) OR
              (b.blocker_id=ch.author_id AND b.blocked_id=$5))) AS thread_count,
        CASE WHEN pr.status='published' AND NOT EXISTS(SELECT 1 FROM account_block b WHERE
          (b.blocker_id=$5 AND b.blocked_id=pr.author_id) OR (b.blocker_id=pr.author_id AND b.blocked_id=$5))
          THEN pu.handle END AS parent_handle
        FROM content_reply r JOIN content c ON c.id=r.content_id
        JOIN app_user u ON u.id=r.author_id AND u.state='active'
        JOIN user_profile p ON p.user_id=u.id
        LEFT JOIN content_reply pr ON pr.id=r.parent_reply_id
        LEFT JOIN app_user pu ON pu.id=pr.author_id AND pu.state='active'
        WHERE r.content_id=$1 AND ($6::uuid[] IS NULL OR r.id=ANY($6::uuid[]))
          AND ($6::uuid[] IS NOT NULL OR NOT $7 OR
            ($8::uuid IS NULL AND r.thread_root_id IS NULL) OR r.thread_root_id=$8)
          AND (r.status='published' OR ($7 AND r.status='removed' AND r.thread_root_id IS NULL AND EXISTS(
            SELECT 1 FROM content_reply ch JOIN app_user cu ON cu.id=ch.author_id AND cu.state='active'
            WHERE ch.thread_root_id=r.id AND ch.status='published' AND NOT EXISTS(
              SELECT 1 FROM account_block b WHERE (b.blocker_id=$5 AND b.blocked_id=ch.author_id) OR
                (b.blocker_id=ch.author_id AND b.blocked_id=$5)))))
          AND NOT EXISTS(SELECT 1 FROM account_block b WHERE
            (b.blocker_id=$5 AND b.blocked_id=r.author_id) OR (b.blocker_id=r.author_id AND b.blocked_id=$5))
          AND (r.thread_root_id IS NULL OR EXISTS(SELECT 1 FROM content_reply rt
            JOIN app_user ru ON ru.id=rt.author_id AND ru.state='active'
            WHERE rt.id=r.thread_root_id AND NOT EXISTS(SELECT 1 FROM account_block b WHERE
              (b.blocker_id=$5 AND b.blocked_id=rt.author_id) OR (b.blocker_id=rt.author_id AND b.blocked_id=$5))))
          AND ($2::timestamptz IS NULL OR (r.created_at,r.id)<($2::timestamptz,$3::uuid))
        ORDER BY r.created_at DESC,r.id DESC LIMIT $4''',
        parameters: [
          post,
          cursor?.createdAt,
          cursor?.id,
          limit + 1,
          viewerId,
          ids,
          threaded,
          root,
        ],
      );
      final page = _pageRows(result, limit);
      final attachments = await replyAttachmentViews(
        _database,
        page.rows.map((r) => '${r.toColumnMap()['id']}').toList(),
        transaction: tx,
      );
      return {
        'items': page.rows.map((row) {
          final v = row.toColumnMap(), removed = v['status'] == 'removed';
          return <String, Object?>{
            'id': '${v['id']}',
            'authorId': removed ? '' : '${v['author_id']}',
            'authorHandle': removed ? '' : '${v['author_handle']}',
            'authorDisplayName': removed ? '' : '${v['author_display_name']}',
            'authorAvatarId': removed ? null : v['author_avatar_id'],
            'body': removed ? 'Bình luận đã được xóa.' : '${v['body']}',
            'createdAt': _dateTime(v['created_at']).toUtc().toIso8601String(),
            'attachments': removed
                ? const []
                : attachments['${v['id']}'] ?? const [],
            'parentReplyId': v['parent_reply_id']?.toString(),
            'threadRootId': v['thread_root_id']?.toString(),
            'inReplyToHandle': removed ? null : v['parent_handle'],
            'threadCount': v['thread_count'],
            'likeCount': removed ? 0 : v['like_count'],
            'liked': !removed && v['liked'] == true,
            'removed': removed,
            'canDelete':
                !removed &&
                viewerId != null &&
                (viewerId == '${v['author_id']}' ||
                    viewerId == '${v['post_author_id']}'),
          };
        }).toList(),
        'nextCursor': _nextCursor(page.rows, page.hasMore),
      };
    });
  }
}
