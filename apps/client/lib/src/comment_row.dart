import 'package:flutter/material.dart';
import 'account_avatar.dart';
import 'ionic_api.dart';
import 'screens.dart' show PostAttachments;

class CommentRow extends StatelessWidget {
  const CommentRow({
    required this.api,
    required this.reply,
    required this.signedIn,
    required this.busy,
    required this.onReply,
    required this.onHeart,
    required this.onDelete,
    required this.onReport,
    this.onThread,
    this.onProfile,
    super.key,
  });
  final IonicApi api;
  final FeedPost reply;
  final bool signedIn, busy;
  final VoidCallback onReply, onHeart, onDelete, onReport;
  final VoidCallback? onThread, onProfile;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!reply.removed) ...[
          InkWell(
            onTap: onProfile,
            borderRadius: BorderRadius.circular(24),
            child: AccountAvatar(
              api: api,
              name: reply.displayName,
              mediaId: reply.authorAvatarId,
              size: 36,
            ),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!reply.removed)
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    InkWell(
                      onTap: onProfile,
                      child: Text(
                        reply.displayName,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Text(
                      '@${reply.handle}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              if (reply.inReplyToHandle != null && !reply.removed)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Trả lời @${reply.inReplyToHandle}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: SelectableText(
                  reply.body,
                  style: reply.removed
                      ? Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontStyle: FontStyle.italic,
                        )
                      : null,
                ),
              ),
              if (!reply.removed && reply.attachments.isNotEmpty)
                PostAttachments(api: api, attachments: reply.attachments),
              if (!reply.removed)
                Wrap(
                  spacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    TextButton.icon(
                      onPressed: signedIn && !busy ? onHeart : null,
                      icon: Icon(
                        reply.liked
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        size: 19,
                      ),
                      label: Text(
                        reply.likeCount > 0 ? '${reply.likeCount}' : 'Thích',
                      ),
                    ),
                    TextButton(
                      onPressed: signedIn && !busy ? onReply : null,
                      child: const Text('Trả lời'),
                    ),
                    if (signedIn)
                      PopupMenuButton<String>(
                        tooltip: 'Tùy chọn bình luận',
                        enabled: !busy,
                        onSelected: (v) =>
                            v == 'delete' ? onDelete() : onReport(),
                        itemBuilder: (_) => [
                          if (reply.canDelete)
                            const PopupMenuItem(
                              value: 'delete',
                              child: Text('Xóa bình luận'),
                            ),
                          const PopupMenuItem(
                            value: 'report',
                            child: Text('Báo cáo bình luận'),
                          ),
                        ],
                      ),
                  ],
                ),
              if (onThread != null && reply.threadCount > 0)
                TextButton.icon(
                  onPressed: busy ? null : onThread,
                  icon: const Icon(
                    Icons.subdirectory_arrow_right_rounded,
                    size: 18,
                  ),
                  label: Text('Xem ${reply.threadCount} trả lời'),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
