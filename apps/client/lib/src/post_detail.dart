import 'dart:async';
import 'package:flutter/material.dart';
import 'ionic_api.dart';
import 'screens.dart' show PostCard, PostAttachments, ReportDialog;
import 'account_controls.dart' show EditPostDialog;
import 'account_avatar.dart';
import 'dialogs.dart';
import 'media_composer.dart';

Future<bool> mutateOwnPost(
  BuildContext context,
  IonicApi api,
  FeedPost post,
  String action,
  ValueChanged<String> toast,
) async {
  if (action == 'edit') {
    // Save inside the dialog: keep text available if the server rejects it.
    return await showIonicDialog<bool>(
          context: context,
          builder: (_) => EditPostDialog(
            body: post.body,
            save: (body) => api.editPost(post.id, body),
          ),
        ) ==
        true;
  }
  final yes = await showIonicDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Xóa bài viết?'),
      content: const Text('Bài viết, bình luận và tệp đính kèm sẽ bị xóa.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Hủy'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c, true),
          child: const Text('Xóa'),
        ),
      ],
    ),
  );
  if (yes != true) return false;
  try {
    await api.deletePost(post.id);
    toast('Đã xóa bài viết.');
    return true;
  } catch (e) {
    toast(apiErrorText(e));
    return false;
  }
}

class PostDetailPage extends StatefulWidget {
  const PostDetailPage({
    required this.api,
    required this.initial,
    required this.userId,
    required this.onToast,
    required this.onChanged,
    this.onOpenProfile,
    super.key,
  });
  final IonicApi api;
  final FeedPost initial;
  final String? userId;
  final ValueChanged<String> onToast;
  final ValueChanged<FeedPost?> onChanged;
  final ValueChanged<String>? onOpenProfile;
  @override
  State<PostDetailPage> createState() => _PostDetailPageState();
}

class _PostDetailPageState extends State<PostDetailPage>
    with WidgetsBindingObserver {
  late FeedPost _post = widget.initial;
  late MediaPublication _publication = MediaPublication(widget.api);
  final _text = TextEditingController(), _focus = FocusNode();
  final _scroll = ScrollController();
  List<FeedPost> _replies = [];
  String? _cursor, _error, _sendError, _progress;
  bool _loading = true,
      _busy = false,
      _sending = false,
      _mediaBusy = false,
      _gone = false,
      _syncing = false,
      _newReplies = false;
  IonicMediaDraft _media = const IonicMediaDraft();
  Key _mediaKey = UniqueKey();
  Timer? _timer;
  int _revision = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _sync());
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    unawaited(_publication.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_sync());
  }

  Future<void> _load({bool append = false}) async {
    if (append && (_loading || _cursor == null)) return;
    _revision++;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (!append) {
        final fresh = await widget.api.post(_post.id);
        if (!mounted) return;
        _post = mergePostSnapshot(_post, fresh);
        widget.onChanged(_post);
      }
      final page = await widget.api.replies(
        _post.id,
        cursor: append ? _cursor : null,
      );
      if (!mounted) return;
      setState(() {
        _replies = {
          for (final p in [
            ...(append ? _replies : <FeedPost>[]),
            ...page.items,
          ])
            p.id: p,
        }.values.toList();
        _cursor = page.nextCursor;
        _newReplies = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = apiErrorText(e);
          if (e is IonicApiException && e.statusCode == 404) {
            _gone = true;
            widget.onChanged(null);
          }
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _sync() async {
    if (!mounted ||
        _syncing ||
        _loading ||
        _busy ||
        _sending ||
        _gone ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
        !(ModalRoute.of(context)?.isCurrent ?? false)) {
      return;
    }
    _syncing = true;
    final revision = _revision;
    final ids = _replies.take(50).map((p) => p.id).toList();
    try {
      final fresh = await widget.api.post(_post.id);
      final replies = await widget.api.syncReplies(_post.id, ids);
      if (!mounted || _loading || _busy || _sending || revision != _revision) {
        return;
      }
      final byId = {for (final p in replies) p.id: p}, requested = ids.toSet();
      final changed =
          !samePostSnapshot(_post, fresh) ||
          ids.any(
            (id) =>
                !byId.containsKey(id) ||
                !samePostSnapshot(
                  _replies.firstWhere((p) => p.id == id),
                  byId[id]!,
                ),
          );
      if (changed) {
        setState(() {
          _newReplies = _newReplies || fresh.replyCount > _post.replyCount;
          _post = mergePostSnapshot(_post, fresh);
          _replies = _replies
              .where((p) => !requested.contains(p.id) || byId.containsKey(p.id))
              .map((p) => byId[p.id] ?? p)
              .toList();
        });
      }
      widget.onChanged(_post);
    } catch (e) {
      if (mounted && e is IonicApiException && e.statusCode == 404) {
        setState(() {
          _gone = true;
          widget.onChanged(null);
        });
      }
    } finally {
      _syncing = false;
    }
  }

  Future<void> _menu(String action) async {
    if (_busy) return;
    _revision++;
    if (action == 'edit' || action == 'delete') {
      if (await mutateOwnPost(
        context,
        widget.api,
        _post,
        action,
        widget.onToast,
      )) {
        if (!mounted) return;
        if (action == 'delete') {
          widget.onChanged(null);
          Navigator.pop(context);
        } else {
          await _load();
        }
      }
      return;
    }
    if (action == 'profile') {
      widget.onOpenProfile?.call(_post.handle);
      if (mounted) Navigator.pop(context);
      return;
    }
    if (action == 'report') await _report();
  }

  Future<void> _report({FeedPost? reply}) async {
    if (widget.userId == null) {
      widget.onToast('Đăng nhập để gửi báo cáo.');
      return;
    }
    final result = await showIonicDialog<(String, String)>(
      context: context,
      builder: (_) => const ReportDialog(),
    );
    if (result == null) return;
    try {
      if (reply == null) {
        await widget.api.reportPost(_post.id, result.$1, result.$2);
      } else {
        await widget.api.reportReply(_post.id, reply.id, result.$1, result.$2);
      }
      widget.onToast('Báo cáo đã được gửi để xem xét.');
    } catch (e) {
      widget.onToast(apiErrorText(e));
    }
  }

  Future<void> _react(bool like) async {
    _revision++;
    if (_busy || widget.userId == null) {
      if (widget.userId == null) widget.onToast('Đăng nhập để tương tác.');
      return;
    }
    setState(() => _busy = true);
    try {
      if (like) {
        await widget.api.setLike(_post.id, !_post.liked);
      } else {
        await widget.api.setSaved(_post.id, !_post.saved);
      }
      final fresh = await widget.api.post(_post.id);
      if (!mounted) return;
      setState(() => _post = mergePostSnapshot(_post, fresh));
      widget.onChanged(_post);
    } catch (e) {
      widget.onToast(apiErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    _revision++;
    final body = _text.text.trim();
    if (_sending || _mediaBusy || body.isEmpty || body.length > 500) return;
    setState(() {
      _sending = true;
      _sendError = null;
    });
    try {
      final ids = await _publication.prepare(body, _media, (v) {
        if (mounted) setState(() => _progress = v);
      });
      final reply = await widget.api.createReply(
        _post.id,
        body,
        attachmentIds: ids,
        clientPublishId: _publication.id,
      );
      if (!mounted) return;
      unawaited(_publication.dispose());
      _publication = MediaPublication(widget.api);
      setState(() {
        _replies = [reply, ..._replies.where((p) => p.id != reply.id)];
        _text.clear();
        _media = const IonicMediaDraft();
        _mediaKey = UniqueKey();
      });
      _focus.unfocus();
      final fresh = await widget.api.post(_post.id);
      if (mounted) {
        setState(() => _post = mergePostSnapshot(_post, fresh));
        widget.onChanged(_post);
      }
    } catch (e) {
      if (mounted) setState(() => _sendError = apiErrorText(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Bài viết')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          children: [
            Expanded(
              child: _gone
                  ? const Center(child: Text('Bài viết không còn khả dụng.'))
                  : RefreshIndicator(
                      onRefresh: () => _load(),
                      child: ListView.builder(
                        controller: _scroll,
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount: _replies.length + 2,
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                PostCard(
                                  recommendationControls: false,
                                  post: _post,
                                  api: widget.api,
                                  isOwn: _post.authorId == widget.userId,
                                  busy: _busy,
                                  onOpen: () {},
                                  onOpenProfile: widget.onOpenProfile == null
                                      ? null
                                      : () {
                                          if (widget.onOpenProfile != null) {
                                            widget.onOpenProfile!(_post.handle);
                                            Navigator.pop(context);
                                          }
                                        },
                                  onLike: () => _react(true),
                                  onSave: () => _react(false),
                                  onReply: () => _focus.requestFocus(),
                                  onMenu: _menu,
                                ),
                                if (_loading) const LinearProgressIndicator(),
                                if (_error != null)
                                  ListTile(
                                    title: Text(_error!),
                                    trailing: TextButton(
                                      onPressed: () => _load(),
                                      child: const Text('Thử lại'),
                                    ),
                                  ),
                                Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Text(
                                    'Bình luận',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                ),
                                if (_newReplies)
                                  TextButton(
                                    onPressed: () => _load(),
                                    child: const Text('Xem bình luận mới'),
                                  ),
                              ],
                            );
                          }
                          if (index == _replies.length + 1) {
                            return _cursor != null
                                ? TextButton(
                                    onPressed: _loading
                                        ? null
                                        : () => _load(append: true),
                                    child: const Text('Xem thêm bình luận'),
                                  )
                                : Padding(
                                    padding: const EdgeInsets.all(20),
                                    child: Text(
                                      _replies.isEmpty && !_loading
                                          ? 'Chưa có bình luận.'
                                          : '',
                                    ),
                                  );
                          }
                          final reply = _replies[index - 1];
                          return Padding(
                            key: ValueKey(reply.id),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 14,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                AccountAvatar(
                                  api: widget.api,
                                  name: reply.displayName,
                                  mediaId: reply.authorAvatarId,
                                  size: 36,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        reply.displayName,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      Text(
                                        '@${reply.handle}',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                      ),
                                      const SizedBox(height: 6),
                                      SelectableText(reply.body),
                                      if (reply.attachments.isNotEmpty)
                                        PostAttachments(
                                          api: widget.api,
                                          attachments: reply.attachments,
                                        ),
                                    ],
                                  ),
                                ),
                                if (widget.userId != null &&
                                    reply.authorId != widget.userId)
                                  IconButton(
                                    tooltip: 'Báo cáo bình luận',
                                    onPressed: () => _report(reply: reply),
                                    icon: const Icon(Icons.more_horiz),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
            ),
            if (!_gone && widget.userId == null)
              const SafeArea(
                top: false,
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Đăng nhập để viết bình luận.'),
                ),
              ),
            if (!_gone && widget.userId != null)
              SafeArea(
                top: false,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * .40,
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _text,
                                focusNode: _focus,
                                readOnly: _sending,
                                maxLength: 500,
                                minLines: 1,
                                maxLines: 3,
                                onChanged: (_) => setState(() {}),
                                decoration: const InputDecoration(
                                  hintText: 'Viết bình luận…',
                                  counterText: '',
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Gửi bình luận',
                              onPressed:
                                  _sending ||
                                      _mediaBusy ||
                                      _text.text.trim().isEmpty
                                  ? null
                                  : _send,
                              icon: _sending
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.send_rounded),
                            ),
                          ],
                        ),
                        MediaComposerControls(
                          key: _mediaKey,
                          enabled: !_sending,
                          onChanged: (v) => setState(() => _media = v),
                          onBusyChanged: (v) => setState(() => _mediaBusy = v),
                        ),
                        if (_sending && _progress != null) Text(_progress!),
                        if (_sendError != null)
                          Text(
                            _sendError!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
