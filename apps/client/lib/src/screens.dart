// The voice player uses just_audio's current in-memory stream API.
// ignore_for_file: experimental_member_use

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';

import 'ionic_api.dart';
import 'media_composer.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    required this.api,
    required this.user,
    required this.refreshToken,
    required this.onAuthenticate,
    required this.onCompose,
    required this.onOpenProfile,
    required this.onToast,
    super.key,
  });

  final IonicApi api;
  final ApiUser? user;
  final int refreshToken;
  final Future<void> Function({required String mode}) onAuthenticate;
  final VoidCallback onCompose;
  final ValueChanged<String> onOpenProfile;
  final ValueChanged<String> onToast;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _search = TextEditingController();
  Timer? _searchDelay;
  bool _busy = false;
  bool _searchBusy = false;
  int _accountEpoch = 0;
  int _searchEpoch = 0;
  int _feedEpoch = 0;
  String? _error;
  String? _cursor;
  List<FeedPost> _posts = [];
  List<FeedPost> _searchPosts = [];
  List<JsonMap> _searchProfiles = [];
  final Set<String> _actionBusy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.user?.id != widget.user?.id) {
      _accountEpoch++;
      _searchEpoch++;
      _feedEpoch++;
      _searchDelay?.cancel();
      setState(() {
        _posts = [];
        _searchPosts = [];
        _searchProfiles = [];
        _cursor = null;
        _error = null;
        _searchBusy = false;
        _actionBusy.clear();
        _search.clear();
      });
      _load();
    } else if (oldWidget.refreshToken != widget.refreshToken) {
      _load();
    }
  }

  @override
  void dispose() {
    _searchDelay?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({bool append = false}) async {
    final epoch = _accountEpoch;
    if (!append) _feedEpoch++;
    final feedEpoch = _feedEpoch;
    setState(() {
      _busy = true;
      if (!append) _error = null;
    });
    try {
      final page = widget.user == null
          ? await widget.api.publicPosts(cursor: append ? _cursor : null)
          : await widget.api.forYou(cursor: append ? _cursor : null);
      if (!mounted || epoch != _accountEpoch || feedEpoch != _feedEpoch) return;
      setState(() {
        _posts = append ? [..._posts, ...page.items] : page.items;
        _cursor = page.nextCursor;
        _error = null;
      });
    } catch (error) {
      if (mounted && epoch == _accountEpoch && feedEpoch == _feedEpoch) {
        setState(() => _error = apiErrorText(error));
      }
    } finally {
      if (mounted && epoch == _accountEpoch && feedEpoch == _feedEpoch) {
        setState(() => _busy = false);
      }
    }
  }

  void _onSearch(String value) {
    _searchDelay?.cancel();
    _searchEpoch++;
    setState(() {
      _searchPosts = [];
      _searchProfiles = [];
      _searchBusy = value.trim().length >= 2 && widget.user != null;
    });
    if (value.trim().length < 2) {
      return;
    }
    if (widget.user == null) return;
    _searchDelay = Timer(
      const Duration(milliseconds: 350),
      () => _runSearch(value.trim()),
    );
  }

  Future<void> _runSearch(String value) async {
    final epoch = ++_searchEpoch;
    final accountEpoch = _accountEpoch;
    setState(() => _searchBusy = true);
    try {
      final results = await Future.wait<Object>([
        widget.api.searchPosts(value),
        widget.api.searchProfiles(value),
      ]);
      if (!mounted || epoch != _searchEpoch || accountEpoch != _accountEpoch) {
        return;
      }
      setState(() {
        _searchPosts = (results[0] as FeedPage).items;
        _searchProfiles = results[1] as List<JsonMap>;
      });
    } catch (error) {
      if (epoch == _searchEpoch && accountEpoch == _accountEpoch) {
        widget.onToast(apiErrorText(error));
      }
    } finally {
      if (mounted && epoch == _searchEpoch && accountEpoch == _accountEpoch) {
        setState(() => _searchBusy = false);
      }
    }
  }

  Future<void> _toggleLike(FeedPost post) async {
    if (_actionBusy.contains('like:${post.id}')) return;
    if (widget.user == null) {
      await widget.onAuthenticate(mode: 'login');
      return;
    }
    _setActionBusy('like:${post.id}', true);
    try {
      final result = await widget.api.setLike(post.id, !post.liked);
      setState(
        () => _updatePost(
          post.id,
          (item) => _copy(
            item,
            liked: result['liked'] == true,
            likeCount: (result['likeCount'] as num?)?.toInt() ?? item.likeCount,
          ),
        ),
      );
    } catch (error) {
      widget.onToast(apiErrorText(error));
    } finally {
      _setActionBusy('like:${post.id}', false);
    }
  }

  Future<void> _toggleSave(FeedPost post) async {
    if (_actionBusy.contains('save:${post.id}')) return;
    if (widget.user == null) {
      await widget.onAuthenticate(mode: 'login');
      return;
    }
    _setActionBusy('save:${post.id}', true);
    try {
      final result = await widget.api.setSaved(post.id, !post.saved);
      setState(
        () => _updatePost(
          post.id,
          (item) => _copy(item, saved: result['saved'] == true),
        ),
      );
    } catch (error) {
      widget.onToast(apiErrorText(error));
    } finally {
      _setActionBusy('save:${post.id}', false);
    }
  }

  void _setActionBusy(String key, bool value) => setState(() {
    value ? _actionBusy.add(key) : _actionBusy.remove(key);
  });

  void _updatePost(String id, FeedPost Function(FeedPost) update) {
    _posts = _posts
        .map((item) => item.id == id ? update(item) : item)
        .toList(growable: true);
    _searchPosts = _searchPosts
        .map((item) => item.id == id ? update(item) : item)
        .toList(growable: true);
  }

  Future<void> _postMenu(FeedPost post, String action) async {
    if (action == 'profile') {
      widget.onOpenProfile(post.handle);
      return;
    }
    if (action == 'report') {
      await _report(post);
      return;
    }
    if (widget.user == null) {
      await widget.onAuthenticate(mode: 'login');
      return;
    }
    try {
      if (action == 'more' || action == 'less') {
        await widget.api.setPreference(post.id, action);
      }
      if (action == 'hide') {
        await widget.api.hidePost(post.id);
        if (mounted) {
          setState(() {
            _posts.removeWhere((item) => item.id == post.id);
            _searchPosts.removeWhere((item) => item.id == post.id);
          });
        }
      }
      if (action == 'mute') {
        await widget.api.mute(post.handle, true);
        if (mounted) {
          setState(() {
            _posts.removeWhere((item) => item.handle == post.handle);
            _searchPosts.removeWhere((item) => item.handle == post.handle);
          });
        }
      }
      widget.onToast(
        action == 'hide'
            ? 'Bài viết đã được ẩn.'
            : action == 'mute'
            ? 'Đã tắt tiếng tài khoản.'
            : 'Đã cập nhật bảng tin.',
      );
    } catch (error) {
      widget.onToast(apiErrorText(error));
    }
  }

  Future<void> _report(FeedPost post) async {
    if (widget.user == null) {
      await widget.onAuthenticate(mode: 'login');
      return;
    }
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (context) => const _ReportDialog(),
    );
    if (result == null) return;
    try {
      await widget.api.reportPost(post.id, result.$1, result.$2);
      widget.onToast('Báo cáo đã được gửi.');
    } catch (error) {
      widget.onToast(apiErrorText(error));
    }
  }

  Future<void> _openReplies(FeedPost post) async {
    if (widget.user == null) {
      await widget.onAuthenticate(mode: 'login');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) =>
          _RepliesDialog(api: widget.api, post: post, onToast: widget.onToast),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1120),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _search.text.trim().length >= 2
                  ? _runSearch(_search.text.trim())
                  : _load(),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(22, 10, 22, 34),
                children: [
                  TextField(
                    controller: _search,
                    onChanged: _onSearch,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search_rounded),
                      hintText: 'Tìm bài viết hoặc tài khoản',
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              onPressed: () {
                                _search.clear();
                                _onSearch('');
                                setState(() {});
                              },
                              icon: const Icon(Icons.close_rounded),
                            ),
                    ),
                  ),
                  if (_search.text.trim().length >= 2)
                    _searchSection()
                  else ...[
                    const SizedBox(height: 16),
                    _ComposerEntry(onTap: widget.onCompose),
                    if (_error != null)
                      _ErrorCard(message: _error!, onRetry: _load),
                    if (_busy && _posts.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(40),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    if (!_busy && _posts.isEmpty && _error == null)
                      _EmptyFeed(onRefresh: _load),
                    for (final post in _posts) ...[
                      PostCard(
                        post: post,
                        busy:
                            _actionBusy.contains('like:${post.id}') ||
                            _actionBusy.contains('save:${post.id}'),
                        api: widget.api,
                        onOpenProfile: () => widget.onOpenProfile(post.handle),
                        onLike: () => _toggleLike(post),
                        onSave: () => _toggleSave(post),
                        onReply: () => _openReplies(post),
                        onMenu: (action) => _postMenu(post, action),
                      ),
                      const SizedBox(height: 14),
                    ],
                    if (_busy && _posts.isNotEmpty)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(20),
                          child: CircularProgressIndicator(),
                        ),
                      ),
                    if (_cursor != null && !_busy)
                      Center(
                        child: OutlinedButton(
                          onPressed: () => _load(append: true),
                          child: const Text('Tải thêm bài'),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          if (MediaQuery.sizeOf(context).width >= 1120)
            SizedBox(width: 280, child: _rightPanel(context)),
        ],
      ),
    ),
  );

  Widget _searchSection() {
    if (widget.user == null) {
      return _SignInCard(
        onSignIn: () => widget.onAuthenticate(mode: 'login'),
        title: 'Tìm kiếm trong Ionic',
        detail: 'Đăng nhập để tìm bài viết và hồ sơ công khai.',
      );
    }
    if (_searchBusy && _searchPosts.isEmpty && _searchProfiles.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(40),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_searchProfiles.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text('Tài khoản', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          for (final profile in _searchProfiles.take(5))
            Card(
              child: ListTile(
                leading: _Avatar(name: '${profile['displayName'] ?? 'I'}'),
                title: Text('${profile['displayName'] ?? ''}'),
                subtitle: Text('@${profile['handle'] ?? ''}'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => widget.onOpenProfile('${profile['handle'] ?? ''}'),
              ),
            ),
        ],
        const SizedBox(height: 18),
        Text('Bài viết', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 10),
        if (_searchPosts.isEmpty && !_searchBusy)
          const _InlineEmpty(text: 'Không tìm thấy bài viết phù hợp.'),
        for (final post in _searchPosts) ...[
          PostCard(
            post: post,
            busy: false,
            api: widget.api,
            onOpenProfile: () => widget.onOpenProfile(post.handle),
            onLike: () => _toggleLike(post),
            onSave: () => _toggleSave(post),
            onReply: () => _openReplies(post),
            onMenu: (action) => _postMenu(post, action),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  Widget _rightPanel(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 76, 22, 20),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Bắt đầu tại đây',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Đọc bài viết, tìm tài khoản và chia sẻ điều bạn nghĩ.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (widget.user == null) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => widget.onAuthenticate(mode: 'register'),
                icon: const Icon(Icons.person_add_alt_1_rounded),
                label: const Text('Tạo tài khoản'),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

class PostCard extends StatelessWidget {
  const PostCard({
    required this.post,
    required this.busy,
    required this.onOpenProfile,
    required this.onLike,
    required this.onSave,
    required this.onReply,
    required this.onMenu,
    this.api,
    this.showMenu = true,
    super.key,
  });

  final FeedPost post;
  final bool busy;
  final VoidCallback onOpenProfile;
  final VoidCallback onLike;
  final VoidCallback onSave;
  final VoidCallback onReply;
  final ValueChanged<String> onMenu;
  final IonicApi? api;
  final bool showMenu;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 17, 18, 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              InkWell(
                onTap: onOpenProfile,
                borderRadius: BorderRadius.circular(30),
                child: _Avatar(name: post.displayName),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: InkWell(
                  onTap: onOpenProfile,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        post.displayName,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '@${post.handle} · ${_timeAgo(post.createdAt)}',
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
              if (showMenu)
                PopupMenuButton<String>(
                  tooltip: 'Tùy chọn bài viết',
                  onSelected: onMenu,
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'profile',
                      child: Text('Mở hồ sơ'),
                    ),
                    const PopupMenuItem(
                      value: 'more',
                      child: Text('Xem nội dung tương tự'),
                    ),
                    const PopupMenuItem(
                      value: 'less',
                      child: Text('Xem ít nội dung tương tự'),
                    ),
                    const PopupMenuItem(
                      value: 'hide',
                      child: Text('Ẩn bài viết'),
                    ),
                    const PopupMenuItem(
                      value: 'mute',
                      child: Text('Tắt tiếng tài khoản'),
                    ),
                    if (post.kind == 'text')
                      const PopupMenuItem(
                        value: 'report',
                        child: Text('Báo cáo nội dung'),
                      ),
                  ],
                )
              else
                const SizedBox(width: 48),
            ],
          ),
          if (post.kind == 'short_video') ...[
            const SizedBox(height: 14),
            _InlineVideoPreview(api: api, videoId: post.id),
          ],
          if (post.body.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 15, bottom: 13),
              child: SelectableText(
                post.body,
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(fontSize: 16, height: 1.6),
              ),
            ),
          if (post.attachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _PostAttachments(api: api, attachments: post.attachments),
            ),
          const Divider(height: 1),
          Row(
            children: [
              _PostAction(
                icon: Icons.chat_bubble_outline_rounded,
                label: '${post.replyCount} trả lời',
                onPressed: onReply,
              ),
              _PostAction(
                icon: post.liked
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                label: '${post.likeCount} thích',
                active: post.liked,
                onPressed: busy ? null : onLike,
              ),
              _PostAction(
                icon: post.saved
                    ? Icons.bookmark_rounded
                    : Icons.bookmark_border_rounded,
                label: post.saved ? 'Đã lưu' : 'Lưu',
                active: post.saved,
                onPressed: busy ? null : onSave,
              ),
              _PostAction(
                icon: Icons.share_outlined,
                label: 'Chia sẻ',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: post.body));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Đã sao chép nội dung bài viết.'),
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _PostAttachments extends StatelessWidget {
  const _PostAttachments({required this.api, required this.attachments});
  final IonicApi? api;
  final List<ApiAttachment> attachments;

  @override
  Widget build(BuildContext context) {
    final currentApi = api;
    if (currentApi == null) return const SizedBox.shrink();
    final images = attachments
        .where((item) => item.mediaType == 'image')
        .toList();
    final voice = attachments
        .where((item) => item.mediaType == 'audio')
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (images.isNotEmpty)
          LayoutBuilder(
            builder: (context, constraints) {
              final count = images.length;
              final columns = count == 1 ? 1 : 2;
              final gap = 7.0;
              final width =
                  (constraints.maxWidth - gap * (columns - 1)) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final image in images)
                    SizedBox(
                      width: width,
                      child: _AttachmentImage(
                        api: currentApi,
                        attachment: image,
                      ),
                    ),
                ],
              );
            },
          ),
        if (voice != null) _VoiceNotePlayer(api: currentApi, attachment: voice),
      ],
    );
  }
}

class _AttachmentImage extends StatefulWidget {
  const _AttachmentImage({required this.api, required this.attachment});
  final IonicApi api;
  final ApiAttachment attachment;

  @override
  State<_AttachmentImage> createState() => _AttachmentImageState();
}

class _AttachmentImageState extends State<_AttachmentImage> {
  late Future<Uint8List> _bytes = widget.api.mediaBytes(widget.attachment.id);

  @override
  void didUpdateWidget(covariant _AttachmentImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.id != widget.attachment.id) {
      _bytes = widget.api.mediaBytes(widget.attachment.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ratio =
        widget.attachment.width != null && widget.attachment.height != null
        ? (widget.attachment.width! / widget.attachment.height!).clamp(.65, 1.8)
        : 1.25;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: AspectRatio(
        aspectRatio: ratio,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final cacheWidth = constraints.maxWidth.isFinite
                ? (constraints.maxWidth *
                          MediaQuery.devicePixelRatioOf(context))
                      .ceil()
                      .clamp(1, 2048)
                      .toInt()
                : null;
            return FutureBuilder<Uint8List>(
              future: _bytes,
              builder: (context, snapshot) {
                if (snapshot.hasData) {
                  return Image.memory(
                    snapshot.data!,
                    cacheWidth: cacheWidth,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) =>
                        _imagePlaceholder(context, failed: true),
                  );
                }
                return _imagePlaceholder(context, failed: snapshot.hasError);
              },
            );
          },
        ),
      ),
    );
  }

  Widget _imagePlaceholder(BuildContext context, {required bool failed}) =>
      ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Center(
          child: failed
              ? Icon(
                  Icons.broken_image_outlined,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                )
              : const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
        ),
      );
}

class _VoiceNotePlayer extends StatefulWidget {
  const _VoiceNotePlayer({required this.api, required this.attachment});
  final IonicApi api;
  final ApiAttachment attachment;

  @override
  State<_VoiceNotePlayer> createState() => _VoiceNotePlayerState();
}

class _VoiceNotePlayerState extends State<_VoiceNotePlayer> {
  final AudioPlayer _player = AudioPlayer();
  bool _loading = false;
  bool _loaded = false;
  String? _error;

  Future<void> _toggle() async {
    if (_loading) return;
    setState(() {
      _error = null;
      _loading = true;
    });
    try {
      if (!_loaded) {
        final bytes = await widget.api.mediaBytes(widget.attachment.id);
        await _player.setAudioSource(_MemoryWaveSource(bytes));
        _loaded = true;
      }
      if (_player.playing) {
        await _player.pause();
      } else {
        if (_player.processingState == ProcessingState.completed) {
          await _player.seek(Duration.zero);
        }
        unawaited(_player.play());
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Không phát được voice.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(top: 8),
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          StreamBuilder<PlayerState>(
            stream: _player.playerStateStream,
            builder: (context, snapshot) => IconButton.filledTonal(
              tooltip: snapshot.data?.playing == true
                  ? 'Tạm dừng voice'
                  : 'Phát voice',
              onPressed: _toggle,
              icon: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      snapshot.data?.playing == true
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
            ),
          ),
          const SizedBox(width: 6),
          const Icon(Icons.graphic_eq_rounded, size: 20),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              _error ??
                  'Voice · ${((widget.attachment.durationMs ?? 0) / 1000).ceil()} giây',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          StreamBuilder<Duration?>(
            stream: _player.durationStream,
            builder: (context, snapshot) => Text(
              snapshot.data == null ? '' : _formatVoiceTime(snapshot.data!),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
    ),
  );
}

class _MemoryWaveSource extends StreamAudioSource {
  _MemoryWaveSource(this._bytes);
  final Uint8List _bytes;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final from = start ?? 0;
    final to = end ?? _bytes.length;
    return StreamAudioResponse(
      sourceLength: _bytes.length,
      contentLength: to - from,
      offset: from,
      stream: Stream.value(_bytes.sublist(from, to)),
      contentType: 'audio/wav',
      rangeRequestsSupported: true,
    );
  }
}

String _formatVoiceTime(Duration duration) {
  final seconds = duration.inSeconds;
  return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}

class _VideoSignalTracker extends StatefulWidget {
  const _VideoSignalTracker({
    required this.api,
    required this.videoId,
    required this.controller,
    required this.child,
  });
  final IonicApi api;
  final String videoId;
  final VideoPlayerController controller;
  final Widget child;
  @override
  State<_VideoSignalTracker> createState() => _VideoSignalTrackerState();
}

class _VideoSignalTrackerState extends State<_VideoSignalTracker>
    with WidgetsBindingObserver {
  static const _activeThreshold = Duration(seconds: 3);
  static const _minimumSkip = Duration(milliseconds: 800);
  Duration _played = Duration.zero;
  Stopwatch? _activeSince;
  Timer? _visibilityTimer;
  Timer? _activeTimer;
  bool _visible = false;
  bool _foreground = true;
  bool _signalSent = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    widget.controller.addListener(_onPlayerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  @override
  void didUpdateWidget(covariant _VideoSignalTracker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onPlayerChanged);
      _stopClock();
      widget.controller.addListener(_onPlayerChanged);
      _sync();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onPlayerChanged);
    WidgetsBinding.instance.removeObserver(this);
    _visibilityTimer?.cancel();
    _stopClock();
    super.dispose();
  }

  void _onPlayerChanged() => _sync();

  bool _isHalfVisible() {
    final player = context.findRenderObject();
    final scrollable = Scrollable.maybeOf(context);
    final viewport = scrollable?.context.findRenderObject();
    if (player is! RenderBox ||
        !player.hasSize ||
        viewport is! RenderBox ||
        !viewport.hasSize) {
      return false;
    }
    final playerRect = player.localToGlobal(Offset.zero) & player.size;
    final viewportRect = viewport.localToGlobal(Offset.zero) & viewport.size;
    final intersection = playerRect.intersect(viewportRect);
    final playerArea = playerRect.width * playerRect.height;
    if (playerArea <= 0 || intersection.isEmpty) return false;
    return (intersection.width * intersection.height) / playerArea >= 0.5;
  }

  void _sync() {
    if (!mounted || _signalSent) return;
    final wasVisible = _visible;
    _visible = _isHalfVisible();
    if (wasVisible && !_visible) {
      _stopClock();
      if (_played >= _activeThreshold) {
        _send('active_view');
      } else if (_played >= _minimumSkip) {
        _send('skip');
      }
    }

    final value = widget.controller.value;
    if (value.isCompleted) {
      _stopClock();
      final durationMs = value.duration.inMilliseconds;
      final thresholdMs = durationMs > 0
          ? (durationMs * 0.75).round().clamp(
              1,
              _activeThreshold.inMilliseconds,
            )
          : _activeThreshold.inMilliseconds;
      if (_played.inMilliseconds >= thresholdMs) _send('active_view');
      return;
    }

    final counting =
        _visible && _foreground && value.isPlaying && !value.isBuffering;
    if (!counting) {
      _stopClock();
      if (_played >= _activeThreshold) _send('active_view');
      return;
    }
    _startClock();
    _visibilityTimer ??= Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _sync(),
    );
  }

  void _startClock() {
    if (_activeSince != null) return;
    final watch = Stopwatch()..start();
    _activeSince = watch;
    final remaining = _activeThreshold - _played;
    _activeTimer?.cancel();
    _activeTimer = Timer(remaining.isNegative ? Duration.zero : remaining, () {
      _stopClock();
      if (_played >= _activeThreshold) {
        _send('active_view');
      } else {
        _sync();
      }
    });
  }

  void _stopClock() {
    _activeTimer?.cancel();
    _activeTimer = null;
    final watch = _activeSince;
    if (watch != null) {
      watch.stop();
      _played += watch.elapsed;
      _activeSince = null;
    }
    if (!_visible ||
        !_foreground ||
        !widget.controller.value.isPlaying ||
        widget.controller.value.isBuffering) {
      _visibilityTimer?.cancel();
      _visibilityTimer = null;
    }
  }

  void _send(String kind) {
    if (_signalSent) return;
    _signalSent = true;
    _visibilityTimer?.cancel();
    _visibilityTimer = null;
    _stopClock();
    unawaited(
      widget.api.recordVideoSignal(widget.videoId, kind).catchError((_) {}),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _InlineVideoPreview extends StatefulWidget {
  const _InlineVideoPreview({required this.api, required this.videoId});
  final IonicApi? api;
  final String videoId;
  @override
  State<_InlineVideoPreview> createState() => _InlineVideoPreviewState();
}

class _InlineVideoPreviewState extends State<_InlineVideoPreview> {
  VideoPlayerController? _controller;
  bool _loading = false;
  String? _error;
  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_controller != null) {
      final player = _controller!;
      if (player.value.isPlaying) {
        await player.pause();
      } else {
        await player.play();
      }
      if (mounted) setState(() {});
      return;
    }
    final api = widget.api;
    if (api == null) {
      setState(() => _error = 'Đăng nhập để xem video này.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final player = VideoPlayerController.networkUrl(
      api.videoUrl(widget.videoId),
    );
    try {
      await player.initialize();
      if (!mounted) {
        await player.dispose();
        return;
      }
      setState(() {
        _controller = player;
        _loading = false;
      });
      await player.play();
    } catch (_) {
      await player.dispose();
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Video chưa sẵn sàng để phát.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      AspectRatio(
        aspectRatio: 9 / 14,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_controller != null && _controller!.value.isInitialized)
                _VideoSignalTracker(
                  api: widget.api!,
                  videoId: widget.videoId,
                  controller: _controller!,
                  child: VideoPlayer(_controller!),
                )
              else
                Container(
                  color: const Color(0xff171a28),
                  child: const Center(
                    child: Icon(
                      Icons.movie_outlined,
                      color: Colors.white70,
                      size: 48,
                    ),
                  ),
                ),
              Center(
                child: IconButton.filledTonal(
                  onPressed: _loading ? null : _toggle,
                  tooltip: _loading
                      ? 'Đang tải video'
                      : (_controller?.value.isPlaying ?? false)
                      ? 'Tạm dừng video'
                      : 'Phát video',
                  iconSize: 30,
                  icon: _loading
                      ? const SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          (_controller?.value.isPlaying ?? false)
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
      if (_controller != null && _controller!.value.isInitialized)
        VideoProgressIndicator(_controller!, allowScrubbing: true),
      if (_error != null)
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ),
    ],
  );
}

class _PostAction extends StatelessWidget {
  const _PostAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.active = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) => Expanded(
    child: TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 7),
        minimumSize: const Size(48, 54),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 20,
            color: active
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 3),
          Text(
            label,
            maxLines: 1,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              height: 1.2,
              color: active
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.name, this.size = 44});
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) => CircleAvatar(
    radius: size / 2,
    backgroundColor: Theme.of(context).brightness == Brightness.dark
        ? const Color(0xff34383f)
        : Theme.of(context).colorScheme.primary,
    foregroundColor: Colors.white,
    child: Text(
      name.isEmpty ? 'I' : name.characters.first.toUpperCase(),
      style: TextStyle(fontSize: size * .38, fontWeight: FontWeight.w700),
    ),
  );
}

class _ComposerEntry extends StatelessWidget {
  const _ComposerEntry({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Card(
    child: InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            const _Avatar(name: 'I', size: 42),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Chia sẻ điều bạn đang nghĩ...',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            IconButton.filled(
              style: IconButton.styleFrom(
                backgroundColor: Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xff34383f)
                    : Theme.of(context).colorScheme.primary,
                foregroundColor: Colors.white,
              ),
              tooltip: 'Tạo bài viết',
              onPressed: onTap,
              icon: const Icon(Icons.add_rounded),
            ),
          ],
        ),
      ),
    ),
  );
}

class _EmptyFeed extends StatelessWidget {
  const _EmptyFeed({required this.onRefresh});
  final VoidCallback onRefresh;
  @override
  Widget build(BuildContext context) => _emptyCard(
    context,
    'Chưa có bài viết nào.',
    'Tải lại để kiểm tra nội dung mới.',
    onRefresh,
  );
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).colorScheme.errorContainer,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Text(
            message,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
          ),
          TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Thử lại'),
          ),
        ],
      ),
    ),
  );
}

class _InlineEmpty extends StatelessWidget {
  const _InlineEmpty({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(18),
    child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
  );
}

class _SignInCard extends StatelessWidget {
  const _SignInCard({
    required this.onSignIn,
    required this.title,
    required this.detail,
  });
  final VoidCallback onSignIn;
  final String title;
  final String detail;
  @override
  Widget build(BuildContext context) => _emptyCard(
    context,
    title,
    detail,
    onSignIn,
    actionLabel: 'Đăng nhập',
    compact: true,
  );
}

Widget _emptyCard(
  BuildContext context,
  String title,
  String detail,
  VoidCallback onPressed, {
  String actionLabel = 'Tải lại',
  bool compact = false,
}) => Card(
  child: Padding(
    padding: const EdgeInsets.all(26),
    child: Column(
      mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 6),
        Text(
          detail,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 14),
        FilledButton(onPressed: onPressed, child: Text(actionLabel)),
      ],
    ),
  ),
);

FeedPost _copy(FeedPost post, {bool? liked, bool? saved, int? likeCount}) =>
    FeedPost(
      id: post.id,
      authorId: post.authorId,
      handle: post.handle,
      displayName: post.displayName,
      body: post.body,
      createdAt: post.createdAt,
      likeCount: likeCount ?? post.likeCount,
      replyCount: post.replyCount,
      liked: liked ?? post.liked,
      saved: saved ?? post.saved,
      attachments: post.attachments,
      kind: post.kind,
      mimeType: post.mimeType,
    );

String _timeAgo(String timestamp) {
  final date = DateTime.tryParse(timestamp)?.toLocal();
  if (date == null) return 'mới đây';
  final elapsed = DateTime.now().difference(date);
  if (elapsed.inMinutes < 1) return 'vừa xong';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes} phút';
  if (elapsed.inDays < 1) return '${elapsed.inHours} giờ';
  return '${elapsed.inDays} ngày';
}

class _RepliesDialog extends StatefulWidget {
  const _RepliesDialog({
    required this.api,
    required this.post,
    required this.onToast,
  });
  final IonicApi api;
  final FeedPost post;
  final ValueChanged<String> onToast;

  @override
  State<_RepliesDialog> createState() => _RepliesDialogState();
}

class _RepliesDialogState extends State<_RepliesDialog> {
  final _text = TextEditingController();
  List<FeedPost> _items = [];
  IonicMediaDraft _media = const IonicMediaDraft();
  Key _mediaComposerKey = UniqueKey();
  bool _mediaBusy = false;
  bool _loading = true;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.api.replies(widget.post.id);
      if (mounted) setState(() => _items = page.items);
    } catch (error) {
      if (mounted) setState(() => _error = apiErrorText(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    final body = _text.text.trim();
    if (body.isEmpty || body.length > 500 || _sending || _mediaBusy) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final staged = <String>[];
    try {
      for (final image in _media.images) {
        staged.add(
          (await widget.api.uploadAttachment(image, mediaType: 'image')).id,
        );
      }
      final voice = _media.voice;
      if (voice != null) {
        staged.add(
          (await widget.api.uploadAttachment(voice, mediaType: 'audio')).id,
        );
      }
      await widget.api.createReply(widget.post.id, body, attachmentIds: staged);
      if (mounted) {
        setState(() {
          _text.clear();
          _media = const IonicMediaDraft();
          _mediaComposerKey = UniqueKey();
        });
      }
      await _load();
    } catch (error) {
      for (final id in staged) {
        try {
          await widget.api.deleteStagedAttachment(id);
        } catch (_) {
          // Expired unattached records are cleaned up by the server.
        }
      }
      if (mounted) setState(() => _error = apiErrorText(error));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Trả lời bài viết'),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? _ErrorCard(message: _error!, onRetry: _load)
                : _items.isEmpty
                ? const _InlineEmpty(
                    text: 'Chưa có trả lời. Hãy mở đầu cuộc trò chuyện.',
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: _items.length,
                    itemBuilder: (context, index) {
                      final reply = _items[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: _Avatar(name: reply.displayName, size: 38),
                        title: Text(
                          '@${reply.handle} · ${_timeAgo(reply.createdAt)}',
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(reply.body),
                              if (reply.attachments.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: _PostAttachments(
                                    api: widget.api,
                                    attachments: reply.attachments,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _text,
            maxLength: 500,
            minLines: 2,
            maxLines: 4,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: 'Viết trả lời',
              counterText: '',
            ),
          ),
          MediaComposerControls(
            key: _mediaComposerKey,
            onChanged: (value) => setState(() => _media = value),
            onBusyChanged: (value) => setState(() => _mediaBusy = value),
          ),
          if (_error != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Đóng'),
      ),
      FilledButton(
        onPressed: _sending || _mediaBusy || _text.text.trim().isEmpty
            ? null
            : _send,
        child: _sending
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('Gửi'),
      ),
    ],
  );
}

class _ReportDialog extends StatefulWidget {
  const _ReportDialog();
  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  String _reason = 'spam';
  final _details = TextEditingController();
  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Báo cáo bài viết'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _reason,
            decoration: const InputDecoration(labelText: 'Lý do'),
            items: const [
              DropdownMenuItem(value: 'spam', child: Text('Spam')),
              DropdownMenuItem(value: 'harassment', child: Text('Quấy rối')),
              DropdownMenuItem(
                value: 'harmful',
                child: Text('Nội dung gây hại'),
              ),
              DropdownMenuItem(value: 'impersonation', child: Text('Mạo danh')),
              DropdownMenuItem(value: 'other', child: Text('Lý do khác')),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _reason = value);
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _details,
            maxLength: 500,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Thông tin bổ sung (không bắt buộc)',
              alignLabelWithHint: true,
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Hủy'),
      ),
      FilledButton(
        onPressed: () =>
            Navigator.pop(context, (_reason, _details.text.trim())),
        child: const Text('Gửi báo cáo'),
      ),
    ],
  );
}

class VideoScreen extends StatefulWidget {
  const VideoScreen({
    required this.api,
    required this.user,
    required this.onAuthenticate,
    required this.onToast,
    super.key,
  });
  final IonicApi api;
  final ApiUser? user;
  final Future<void> Function({required String mode}) onAuthenticate;
  final ValueChanged<String> onToast;
  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  List<ApiVideo> _videos = [];
  bool _loading = false;
  bool _uploading = false;
  int _userEpoch = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant VideoScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.user?.id != widget.user?.id) {
      _userEpoch++;
      setState(() {
        _videos = [];
        _error = null;
        _uploading = false;
      });
      _load();
    }
  }

  Future<void> _load() async {
    final epoch = _userEpoch;
    if (widget.user == null) {
      if (mounted) {
        setState(() {
          _videos = [];
          _loading = false;
        });
      }
      return;
    }
    final userId = widget.user!.id;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await widget.api.videos();
      if (mounted && epoch == _userEpoch && widget.user?.id == userId) {
        setState(() => _videos = items);
      }
    } catch (error) {
      if (mounted && epoch == _userEpoch && widget.user?.id == userId) {
        setState(() => _error = apiErrorText(error));
      }
    } finally {
      if (mounted && epoch == _userEpoch && widget.user?.id == userId) {
        setState(() => _loading = false);
      }
    }
  }

  Future<String?> _caption() async => showDialog<String>(
    context: context,
    builder: (context) => const _VideoCaptionDialog(),
  );

  Future<void> _chooseFile() async {
    if (widget.user == null) {
      await widget.onAuthenticate(mode: 'login');
      return;
    }
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['mp4', 'webm'],
      );
      if (files.isEmpty) return;
      final file = files.single;
      final length = file.lengthSync() ?? await file.length();
      if (length == null || length <= 0) {
        widget.onToast('Không đọc được video trên thiết bị này.');
        return;
      }
      if (length > 60 * 1024 * 1024) {
        widget.onToast('Video vượt quá giới hạn tải lên 60 MB.');
        return;
      }
      final bytes = await file.readAsBytes();
      await _upload(bytes, file.name);
    } catch (error) {
      widget.onToast('Không mở được thư viện video: $error');
    }
  }

  Future<void> _recordVideo() async {
    if (widget.user == null) {
      await widget.onAuthenticate(mode: 'login');
      return;
    }
    final draft = await showDialog<_VideoDraft>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const _CameraCaptureDialog(),
    );
    if (draft != null) await _upload(draft.bytes, draft.fileName);
  }

  Future<void> _upload(Uint8List bytes, String name) async {
    if (widget.user == null) {
      await widget.onAuthenticate(mode: 'login');
      return;
    }
    final ownerId = widget.user!.id;
    if (bytes.lengthInBytes > 60 * 1024 * 1024) {
      widget.onToast('Video vượt quá giới hạn tải lên 60 MB.');
      return;
    }
    final extension = name.toLowerCase().split('.').last;
    final mimeType = extension == 'webm'
        ? 'video/webm'
        : extension == 'mp4'
        ? 'video/mp4'
        : null;
    if (mimeType == null) {
      widget.onToast('Chọn video MP4 hoặc WebM.');
      return;
    }
    final caption = await _caption();
    if (caption == null) return;
    setState(() => _uploading = true);
    try {
      await widget.api.uploadVideo(bytes, mimeType, caption);
      if (mounted && widget.user?.id == ownerId) {
        widget.onToast(
          'Video đã tải lên. Hiện video chỉ hiển thị trong thư viện riêng của bạn.',
        );
        await _load();
      }
    } catch (error) {
      if (mounted && widget.user?.id == ownerId) {
        widget.onToast(apiErrorText(error));
      }
    } finally {
      if (mounted && widget.user?.id == ownerId) {
        setState(() => _uploading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 920),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(22, 10, 22, 34),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Video',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
              IconButton(
                tooltip: 'Làm mới',
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Quay hoặc tải video lên để xem lại trong thư viện của bạn.',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 18),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.video_library_outlined,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Thư viện video',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Video mới tải lên được giữ riêng tư trong khi chờ xử lý và duyệt.',
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton.icon(
                        onPressed: _uploading ? null : _recordVideo,
                        icon: const Icon(Icons.videocam_outlined),
                        label: const Text('Quay video'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _uploading ? null : _chooseFile,
                        icon: const Icon(Icons.upload_file_rounded),
                        label: const Text('Chọn video'),
                      ),
                    ],
                  ),
                  if (_uploading)
                    const Padding(
                      padding: EdgeInsets.only(top: 14),
                      child: LinearProgressIndicator(),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          if (widget.user == null)
            _SignInCard(
              onSignIn: () => widget.onAuthenticate(mode: 'login'),
              title: 'Lưu video vào tài khoản',
              detail: 'Đăng nhập để quay, tải lên và quản lý video của bạn.',
            )
          else if (_loading && _videos.isEmpty)
            const Padding(
              padding: EdgeInsets.all(34),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            _ErrorCard(message: _error!, onRetry: _load)
          else if (_videos.isEmpty)
            _emptyCard(
              context,
              'Chưa có video',
              'Video bạn tải lên sẽ xuất hiện ở đây.',
              _chooseFile,
              actionLabel: 'Chọn video',
            )
          else ...[
            Text(
              'Video của bạn',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            for (final video in _videos) ...[
              _VideoItem(api: widget.api, video: video),
              const SizedBox(height: 12),
            ],
          ],
        ],
      ),
    ),
  );
}

class _VideoCaptionDialog extends StatefulWidget {
  const _VideoCaptionDialog();
  @override
  State<_VideoCaptionDialog> createState() => _VideoCaptionDialogState();
}

class _VideoCaptionDialogState extends State<_VideoCaptionDialog> {
  final _caption = TextEditingController();
  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Thêm mô tả video'),
    content: SizedBox(
      width: 440,
      child: TextField(
        controller: _caption,
        autofocus: true,
        maxLength: 280,
        minLines: 2,
        maxLines: 4,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(
          hintText: 'Viết một câu ngắn về video',
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Hủy'),
      ),
      FilledButton(
        onPressed: _caption.text.trim().isEmpty
            ? null
            : () => Navigator.pop(context, _caption.text.trim()),
        child: const Text('Tiếp tục'),
      ),
    ],
  );
}

class _VideoDraft {
  const _VideoDraft(this.bytes, this.fileName);
  final Uint8List bytes;
  final String fileName;
}

class _CameraCaptureDialog extends StatefulWidget {
  const _CameraCaptureDialog();
  @override
  State<_CameraCaptureDialog> createState() => _CameraCaptureDialogState();
}

class _CameraCaptureDialogState extends State<_CameraCaptureDialog> {
  CameraController? _camera;
  Timer? _limitTimer;
  bool _initializing = true;
  bool _recording = false;
  bool _stopping = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _limitTimer?.cancel();
    _camera?.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw StateError('Không tìm thấy camera.');
      final chosen = cameras.firstWhere(
        (item) => item.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final camera = CameraController(
        chosen,
        ResolutionPreset.medium,
        enableAudio: true,
      );
      await camera.initialize();
      if (!mounted) {
        await camera.dispose();
        return;
      }
      setState(() {
        _camera = camera;
        _initializing = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error =
              'Không thể mở camera. Hãy kiểm tra quyền camera và micro trên thiết bị.';
          _initializing = false;
        });
      }
    }
  }

  Future<void> _start() async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized || _recording) return;
    try {
      await camera.startVideoRecording();
      if (!mounted) return;
      setState(() => _recording = true);
      _limitTimer = Timer(const Duration(seconds: 60), _stop);
    } catch (_) {
      if (mounted) setState(() => _error = 'Không thể bắt đầu quay video.');
    }
  }

  Future<void> _stop() async {
    final camera = _camera;
    if (camera == null || !_recording || _stopping) return;
    _limitTimer?.cancel();
    if (mounted) {
      setState(() {
        _recording = false;
        _stopping = true;
      });
    }
    try {
      final file = await camera.stopVideoRecording();
      final bytes = await file.readAsBytes();
      final extension = file.name.toLowerCase().endsWith('.webm')
          ? 'webm'
          : 'mp4';
      if (mounted) {
        Navigator.pop(context, _VideoDraft(bytes, 'ionic-capture.$extension'));
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _recording = false;
          _stopping = false;
          _error = 'Không thể lưu video đã quay.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('Quay video')),
          if (_recording)
            const Chip(
              avatar: Icon(Icons.circle, size: 10, color: Colors.red),
              label: Text('Tối đa 60 giây'),
            ),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.55,
          ),
          child: AspectRatio(
            aspectRatio: 9 / 16,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: _initializing
                  ? const Center(child: CircularProgressIndicator())
                  : _camera != null && _camera!.value.isInitialized
                  ? CameraPreview(_camera!)
                  : Center(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          _error ?? 'Camera không khả dụng.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _recording || _stopping
              ? null
              : () => Navigator.pop(context),
          child: const Text('Hủy'),
        ),
        if (_camera != null)
          FilledButton.icon(
            onPressed: _initializing || _stopping
                ? null
                : (_recording ? _stop : _start),
            icon: Icon(
              _recording
                  ? Icons.stop_rounded
                  : Icons.fiber_manual_record_rounded,
            ),
            label: Text(
              _stopping
                  ? 'Đang lưu…'
                  : _recording
                  ? 'Dừng và dùng video'
                  : 'Bắt đầu quay',
            ),
          ),
      ],
    );
  }
}

class _VideoItem extends StatefulWidget {
  const _VideoItem({required this.api, required this.video});
  final IonicApi api;
  final ApiVideo video;
  @override
  State<_VideoItem> createState() => _VideoItemState();
}

class _VideoItemState extends State<_VideoItem> {
  VideoPlayerController? _controller;
  bool _loading = false;
  String? _error;
  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _play() async {
    if (_controller != null) {
      final controller = _controller!;
      if (controller.value.isPlaying) {
        await controller.pause();
      } else {
        await controller.play();
      }
      if (mounted) setState(() {});
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final controller = VideoPlayerController.networkUrl(
      widget.api.videoUrl(widget.video.id),
    );
    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _loading = false;
      });
      await controller.play();
    } catch (_) {
      await controller.dispose();
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Video chưa thể phát trên thiết bị này.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.movie_outlined,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  widget.video.caption,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(width: 8),
              Chip(
                label: Text(
                  widget.video.state == 'ready' ? 'Sẵn sàng' : 'Đang chờ duyệt',
                ),
              ),
            ],
          ),
          Text(
            widget.video.state == 'ready'
                ? 'Video đã xử lý.'
                : 'Riêng tư: chỉ bạn có thể xem trong lúc video chờ xử lý và duyệt.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (_controller != null && _controller!.value.isInitialized) ...[
            const SizedBox(height: 12),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 520),
                child: AspectRatio(
                  aspectRatio: _controller!.value.aspectRatio,
                  child: widget.video.state == 'ready'
                      ? _VideoSignalTracker(
                          api: widget.api,
                          videoId: widget.video.id,
                          controller: _controller!,
                          child: VideoPlayer(_controller!),
                        )
                      : VideoPlayer(_controller!),
                ),
              ),
            ),
            VideoProgressIndicator(_controller!, allowScrubbing: true),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _loading ? null : _play,
              icon: Icon(
                _loading
                    ? Icons.hourglass_top_rounded
                    : (_controller?.value.isPlaying ?? false)
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
              ),
              label: Text(
                _loading
                    ? 'Đang mở…'
                    : (_controller?.value.isPlaying ?? false)
                    ? 'Tạm dừng'
                    : 'Phát video',
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class MessagesScreen extends StatefulWidget {
  const MessagesScreen({
    required this.api,
    required this.user,
    required this.conversationId,
    required this.conversationName,
    required this.onConversation,
    required this.onAuthenticate,
    required this.onToast,
    super.key,
  });
  final IonicApi api;
  final ApiUser? user;
  final String? conversationId;
  final String? conversationName;
  final void Function(String id, String name) onConversation;
  final Future<void> Function({required String mode}) onAuthenticate;
  final ValueChanged<String> onToast;
  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  final _message = TextEditingController();
  final _scroll = ScrollController();
  List<ApiConversation> _conversations = [];
  List<ApiMessage> _messages = [];
  Timer? _poll;
  bool _loadingInbox = false;
  bool _loadingMessages = false;
  bool _sending = false;
  bool _starting = false;
  int _sessionEpoch = 0;
  int _messageRequest = 0;
  String? _error;

  bool get _chatOpen =>
      widget.conversationId != null && widget.conversationId!.isNotEmpty;
  @override
  void initState() {
    super.initState();
    _loadConversations();
    _configurePoll();
  }

  @override
  void didUpdateWidget(covariant MessagesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.user?.id != widget.user?.id) {
      _sessionEpoch++;
      _messageRequest++;
      setState(() {
        _messages = [];
        _conversations = [];
        _error = null;
        _message.clear();
        _loadingInbox = false;
        _loadingMessages = false;
      });
      _loadConversations();
    }
    if (oldWidget.conversationId != widget.conversationId ||
        oldWidget.user?.id != widget.user?.id) {
      _messageRequest++;
      setState(() {
        _messages = [];
        _loadingMessages = false;
        _error = null;
      });
      if (_chatOpen && widget.user != null) _loadMessages();
      _configurePoll();
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _message.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _configurePoll() {
    _poll?.cancel();
    if (_chatOpen && widget.user != null) {
      _poll = Timer.periodic(
        const Duration(seconds: 4),
        (_) => _loadMessages(silent: true),
      );
    }
  }

  Future<void> _loadConversations() async {
    if (widget.user == null) return;
    final epoch = _sessionEpoch;
    final userId = widget.user!.id;
    setState(() {
      _loadingInbox = true;
      _error = null;
    });
    try {
      final result = await widget.api.conversations();
      if (mounted && epoch == _sessionEpoch && widget.user?.id == userId) {
        setState(() => _conversations = result);
      }
    } catch (error) {
      if (mounted && epoch == _sessionEpoch && widget.user?.id == userId) {
        setState(() => _error = apiErrorText(error));
      }
    } finally {
      if (mounted && epoch == _sessionEpoch && widget.user?.id == userId) {
        setState(() => _loadingInbox = false);
      }
    }
  }

  Future<void> _loadMessages({bool silent = false}) async {
    final id = widget.conversationId;
    if (id == null || id.isEmpty || widget.user == null || _loadingMessages) {
      return;
    }
    final epoch = _sessionEpoch;
    final userId = widget.user!.id;
    final request = ++_messageRequest;
    _loadingMessages = true;
    if (!silent) {
      setState(() {
        _loadingMessages = true;
        _error = null;
      });
    }
    try {
      final result = await widget.api.messages(id);
      if (!mounted ||
          epoch != _sessionEpoch ||
          widget.user?.id != userId ||
          widget.conversationId != id) {
        return;
      }
      setState(() {
        _messages = result.items;
        if (silent) _error = null;
      });
      if (!silent && _scroll.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) {
            _scroll.jumpTo(_scroll.position.maxScrollExtent);
          }
        });
      }
    } catch (error) {
      if (mounted &&
          epoch == _sessionEpoch &&
          widget.user?.id == userId &&
          !silent) {
        setState(() => _error = apiErrorText(error));
      }
    } finally {
      if (request == _messageRequest) {
        _loadingMessages = false;
        if (mounted &&
            epoch == _sessionEpoch &&
            widget.user?.id == userId &&
            !silent) {
          setState(() {});
        }
      }
    }
  }

  Future<void> _newConversation() async {
    if (widget.user == null) {
      await widget.onAuthenticate(mode: 'login');
      return;
    }
    final handle = await showDialog<String>(
      context: context,
      builder: (context) => const _HandleDialog(),
    );
    if (handle == null) return;
    final epoch = _sessionEpoch;
    final userId = widget.user!.id;
    setState(() => _starting = true);
    try {
      final conversation = await widget.api.startConversation(handle);
      if (!mounted || epoch != _sessionEpoch || widget.user?.id != userId) {
        return;
      }
      widget.onConversation(conversation.id, conversation.partnerDisplayName);
      await _loadConversations();
    } catch (error) {
      if (mounted && epoch == _sessionEpoch && widget.user?.id == userId) {
        widget.onToast(apiErrorText(error));
      }
    } finally {
      if (mounted && epoch == _sessionEpoch && widget.user?.id == userId) {
        setState(() => _starting = false);
      }
    }
  }

  Future<void> _send() async {
    final id = widget.conversationId;
    final body = _message.text.trim();
    if (id == null || id.isEmpty || body.isEmpty || _sending) return;
    final epoch = _sessionEpoch;
    final userId = widget.user!.id;
    setState(() => _sending = true);
    try {
      final message = await widget.api.sendMessage(
        id,
        body,
        IonicApi.newClientMessageId(),
      );
      if (!mounted ||
          epoch != _sessionEpoch ||
          widget.user?.id != userId ||
          widget.conversationId != id) {
        return;
      }
      _message.clear();
      setState(() => _messages = [..._messages, message]);
      await _loadConversations();
      if (_scroll.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) {
            _scroll.jumpTo(_scroll.position.maxScrollExtent);
          }
        });
      }
    } catch (error) {
      if (mounted && epoch == _sessionEpoch && widget.user?.id == userId) {
        widget.onToast(apiErrorText(error));
      }
    } finally {
      if (mounted && epoch == _sessionEpoch && widget.user?.id == userId) {
        setState(() => _sending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.user == null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: _SignInCard(
              onSignIn: () => widget.onAuthenticate(mode: 'login'),
              title: 'Tin nhắn riêng tư',
              detail: 'Đăng nhập để bắt đầu và tiếp tục các cuộc trò chuyện.',
            ),
          ),
        ),
      );
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1080),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 10, 22, 24),
          child: Card(child: _chatOpen ? _chatView() : _inboxView()),
        ),
      ),
    );
  }

  Widget _inboxView() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 10, 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Tin nhắn',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton(
              tooltip: 'Làm mới',
              onPressed: _loadConversations,
              icon: const Icon(Icons.refresh_rounded),
            ),
            FilledButton.icon(
              onPressed: _starting ? null : _newConversation,
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Tin nhắn mới'),
            ),
          ],
        ),
      ),
      const Divider(height: 1),
      if (_loadingInbox && _conversations.isEmpty)
        const Expanded(child: Center(child: CircularProgressIndicator()))
      else if (_error != null)
        Expanded(
          child: _ErrorCard(message: _error!, onRetry: _loadConversations),
        )
      else if (_conversations.isEmpty)
        Expanded(
          child: _emptyCard(
            context,
            'Chưa có cuộc trò chuyện',
            'Bắt đầu trò chuyện với một tài khoản Ionic.',
            _newConversation,
            actionLabel: 'Tin nhắn mới',
          ),
        )
      else
        Expanded(
          child: ListView.separated(
            itemCount: _conversations.length,
            separatorBuilder: (_, _) => const Divider(height: 1, indent: 76),
            itemBuilder: (context, index) {
              final conversation = _conversations[index];
              return ListTile(
                leading: _Avatar(
                  name: conversation.partnerDisplayName,
                  size: 48,
                ),
                title: Text(
                  conversation.partnerDisplayName,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  conversation.lastMessage.isEmpty
                      ? '@${conversation.partnerHandle}'
                      : conversation.lastMessage,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => widget.onConversation(
                  conversation.id,
                  conversation.partnerDisplayName,
                ),
              );
            },
          ),
        ),
    ],
  );

  Widget _chatView() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 14, 8),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Quay lại danh sách',
              onPressed: () {
                widget.onConversation('', '');
                _loadConversations();
              },
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            _Avatar(name: widget.conversationName ?? 'I', size: 40),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.conversationName ?? 'Trò chuyện',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: 'Tải lại tin nhắn',
              onPressed: _loadMessages,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
      ),
      const Divider(height: 1),
      if (_loadingMessages && _messages.isEmpty)
        const Expanded(child: Center(child: CircularProgressIndicator()))
      else if (_error != null && _messages.isEmpty)
        Expanded(
          child: _ErrorCard(message: _error!, onRetry: _loadMessages),
        )
      else
        Expanded(
          child: _messages.isEmpty
              ? const Center(child: Text('Hãy gửi lời chào để bắt đầu.'))
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 14,
                  ),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    final item = _messages[index];
                    final own = item.senderId == widget.user!.id;
                    return Align(
                      alignment: own
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 9),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        constraints: const BoxConstraints(maxWidth: 520),
                        decoration: BoxDecoration(
                          color: own
                              ? Theme.of(context).colorScheme.primaryContainer
                              : Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          item.body,
                          style: Theme.of(
                            context,
                          ).textTheme.bodyLarge?.copyWith(fontSize: 15),
                        ),
                      ),
                    );
                  },
                ),
        ),
      if (_error != null && _messages.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      const Divider(height: 1),
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _message,
                maxLength: 2000,
                minLines: 1,
                maxLines: 5,
                decoration: const InputDecoration(
                  hintText: 'Viết tin nhắn',
                  counterText: '',
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _sending ? null : _send,
              tooltip: 'Gửi tin nhắn',
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_rounded),
            ),
          ],
        ),
      ),
    ],
  );
}

class _HandleDialog extends StatefulWidget {
  const _HandleDialog();
  @override
  State<_HandleDialog> createState() => _HandleDialogState();
}

class _HandleDialogState extends State<_HandleDialog> {
  final _handle = TextEditingController();
  @override
  void dispose() {
    _handle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Tin nhắn mới'),
    content: SizedBox(
      width: 400,
      child: TextField(
        controller: _handle,
        autofocus: true,
        autocorrect: false,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(
          labelText: 'Tên tài khoản',
          prefixText: '@',
        ),
        onSubmitted: (_) {
          if (_handle.text.trim().isNotEmpty) {
            Navigator.pop(context, _handle.text.trim());
          }
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Hủy'),
      ),
      FilledButton(
        onPressed: _handle.text.trim().isEmpty
            ? null
            : () => Navigator.pop(context, _handle.text.trim()),
        child: const Text('Tiếp tục'),
      ),
    ],
  );
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    required this.api,
    required this.user,
    required this.handle,
    required this.onOpenConversation,
    required this.onAuthenticate,
    required this.onToast,
    super.key,
  });
  final IonicApi api;
  final ApiUser? user;
  final String? handle;
  final void Function(String id, String name) onOpenConversation;
  final Future<void> Function({required String mode}) onAuthenticate;
  final ValueChanged<String> onToast;
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  ApiProfile? _profile;
  List<FeedPost> _posts = [];
  List<JsonMap> _muted = [];
  List<JsonMap> _blocked = [];
  bool _loading = false;
  bool _working = false;
  String? _error;
  String get _target => widget.handle ?? widget.user?.handle ?? '';
  int _loadEpoch = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ProfileScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.handle != widget.handle ||
        oldWidget.user?.id != widget.user?.id) {
      _loadEpoch++;
      setState(() {
        _profile = null;
        _posts = [];
        _muted = [];
        _blocked = [];
        _error = null;
        _loading = false;
      });
      _load();
    }
  }

  Future<void> _load() async {
    if (widget.user == null || _target.isEmpty) return;
    final epoch = ++_loadEpoch;
    final userId = widget.user!.id;
    final handle = _target;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final profile = await widget.api.profile(handle);
      if (!mounted || epoch != _loadEpoch || widget.user?.id != userId) return;
      final postsFuture = profile.isSelf
          ? widget.api.myPosts()
          : widget.api.profilePosts(profile.handle);
      final extraFuture = profile.isSelf
          ? Future.wait<List<JsonMap>>([
              widget.api.mutedProfiles(),
              widget.api.blockedProfiles(),
            ])
          : Future.value(const <List<JsonMap>>[]);
      final result = await Future.wait<Object>([postsFuture, extraFuture]);
      final page = result[0] as FeedPage;
      final entries = page.items
          .map(
            (item) => FeedPost(
              id: item.id,
              authorId: item.authorId,
              handle: item.handle.isEmpty ? profile.handle : item.handle,
              displayName: item.displayName == 'Tài khoản'
                  ? profile.displayName
                  : item.displayName,
              body: item.body,
              createdAt: item.createdAt,
              likeCount: item.likeCount,
              replyCount: item.replyCount,
              liked: item.liked,
              saved: item.saved,
              kind: item.kind,
              mimeType: item.mimeType,
            ),
          )
          .toList(growable: false);
      final lists = result[1] as List<List<JsonMap>>;
      if (mounted && epoch == _loadEpoch && widget.user?.id == userId) {
        setState(() {
          _profile = profile;
          _posts = entries;
          _muted = lists.isEmpty ? [] : lists[0];
          _blocked = lists.isEmpty ? [] : lists[1];
        });
      }
    } catch (error) {
      if (mounted && epoch == _loadEpoch && widget.user?.id == userId) {
        setState(() => _error = apiErrorText(error));
      }
    } finally {
      if (mounted && epoch == _loadEpoch && widget.user?.id == userId) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _follow() async {
    final profile = _profile;
    if (profile == null) return;
    setState(() => _working = true);
    try {
      await widget.api.follow(profile.handle, !profile.isFollowing);
      await _load();
    } catch (error) {
      widget.onToast(apiErrorText(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _mute() async {
    final profile = _profile;
    if (profile == null) return;
    setState(() => _working = true);
    try {
      await widget.api.mute(profile.handle, !profile.isMuted);
      await _load();
      widget.onToast(
        profile.isMuted
            ? 'Đã bật lại nội dung từ tài khoản.'
            : 'Đã tắt tiếng tài khoản.',
      );
    } catch (error) {
      widget.onToast(apiErrorText(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _block() async {
    final profile = _profile;
    if (profile == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Chặn @${profile.handle}?'),
        content: const Text(
          'Tài khoản này sẽ không thể xem nội dung hoặc bắt đầu cuộc trò chuyện với bạn.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Chặn'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.api.block(profile.handle, true);
      if (mounted) {
        setState(() {
          _profile = null;
          _posts = [];
        });
      }
      widget.onToast('Đã chặn tài khoản.');
      await _load();
    } catch (error) {
      widget.onToast(apiErrorText(error));
    }
  }

  Future<void> _message() async {
    final profile = _profile;
    if (profile == null) return;
    try {
      final conversation = await widget.api.startConversation(profile.handle);
      widget.onOpenConversation(
        conversation.id,
        conversation.partnerDisplayName,
      );
    } catch (error) {
      widget.onToast(apiErrorText(error));
    }
  }

  Future<void> _togglePost(FeedPost post, {required bool like}) async {
    setState(() => _working = true);
    try {
      final result = like
          ? await widget.api.setLike(post.id, !post.liked)
          : await widget.api.setSaved(post.id, !post.saved);
      if (!mounted) return;
      setState(
        () => _posts = _posts
            .map((item) {
              if (item.id != post.id) return item;
              if (like) {
                return _copy(
                  item,
                  liked: result['liked'] == true,
                  likeCount:
                      (result['likeCount'] as num?)?.toInt() ?? item.likeCount,
                );
              }
              return _copy(item, saved: result['saved'] == true);
            })
            .toList(growable: false),
      );
    } catch (error) {
      widget.onToast(apiErrorText(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _reply(FeedPost post) async {
    await showDialog<void>(
      context: context,
      builder: (context) =>
          _RepliesDialog(api: widget.api, post: post, onToast: widget.onToast),
    );
    await _load();
  }

  Future<void> _removeManagedAccount(
    String handle, {
    required bool muted,
  }) async {
    setState(() => _working = true);
    try {
      if (muted) {
        await widget.api.mute(handle, false);
      } else {
        await widget.api.block(handle, false);
      }
      await _load();
      widget.onToast(
        muted ? 'Đã bật lại nội dung từ tài khoản.' : 'Đã bỏ chặn tài khoản.',
      );
    } catch (error) {
      widget.onToast(apiErrorText(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.user == null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: _SignInCard(
              onSignIn: () => widget.onAuthenticate(mode: 'login'),
              title: 'Hồ sơ của bạn',
              detail: 'Đăng nhập để xem và quản lý hồ sơ.',
            ),
          ),
        ),
      );
    }
    if (_loading && _profile == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _profile == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: _ErrorCard(message: _error!, onRetry: _load),
        ),
      );
    }
    final profile = _profile;
    if (profile == null) return const SizedBox.shrink();
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 10, 22, 34),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _Avatar(name: profile.displayName, size: 76),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                profile.displayName,
                                style: Theme.of(
                                  context,
                                ).textTheme.headlineMedium,
                              ),
                              Text(
                                '@${profile.handle}',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ],
                          ),
                        ),
                        if (profile.isSelf)
                          IconButton(
                            tooltip: 'Làm mới hồ sơ',
                            onPressed: _load,
                            icon: const Icon(Icons.refresh_rounded),
                          ),
                      ],
                    ),
                    if (profile.bio.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(
                          profile.bio,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                      ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 20,
                      runSpacing: 8,
                      children: [
                        Text('${profile.postCount} bài viết'),
                        Text('${profile.followerCount} người theo dõi'),
                        Text('${profile.followingCount} đang theo dõi'),
                      ],
                    ),
                    if (!profile.isSelf) ...[
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 9,
                        runSpacing: 9,
                        children: [
                          FilledButton(
                            onPressed: _working ? null : _follow,
                            child: Text(
                              profile.isFollowing
                                  ? 'Đang theo dõi'
                                  : 'Theo dõi',
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: _working ? null : _message,
                            icon: const Icon(Icons.chat_bubble_outline_rounded),
                            label: const Text('Nhắn tin'),
                          ),
                          PopupMenuButton<String>(
                            tooltip: 'Tùy chọn tài khoản',
                            onSelected: (value) {
                              if (value == 'mute') _mute();
                              if (value == 'block') _block();
                            },
                            itemBuilder: (_) => [
                              PopupMenuItem(
                                value: 'mute',
                                child: Text(
                                  profile.isMuted
                                      ? 'Bật lại nội dung'
                                      : 'Tắt tiếng',
                                ),
                              ),
                              const PopupMenuItem(
                                value: 'block',
                                child: Text('Chặn tài khoản'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (_error != null) _ErrorCard(message: _error!, onRetry: _load),
            const SizedBox(height: 16),
            Text('Bài viết', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 10),
            if (_posts.isEmpty) const _InlineEmpty(text: 'Chưa có bài viết.'),
            for (final post in _posts) ...[
              PostCard(
                post: post,
                busy: _working,
                api: widget.api,
                showMenu: false,
                onOpenProfile: () {},
                onLike: () => _togglePost(post, like: true),
                onSave: () => _togglePost(post, like: false),
                onReply: () => _reply(post),
                onMenu: (_) {},
              ),
              const SizedBox(height: 12),
            ],
            if (profile.isSelf && _muted.isNotEmpty) ...[
              const SizedBox(height: 12),
              Card(
                child: ExpansionTile(
                  leading: const Icon(Icons.volume_off_outlined),
                  title: Text('${_muted.length} tài khoản đã tắt tiếng'),
                  children: [
                    for (final account in _muted)
                      ListTile(
                        leading: _Avatar(
                          name:
                              '${account['displayName'] ?? account['handle'] ?? 'I'}',
                          size: 38,
                        ),
                        title: Text(
                          '${account['displayName'] ?? account['handle'] ?? 'Tài khoản'}',
                        ),
                        subtitle: Text('@${account['handle'] ?? ''}'),
                        trailing: TextButton(
                          onPressed: _working
                              ? null
                              : () => _removeManagedAccount(
                                  '${account['handle'] ?? ''}',
                                  muted: true,
                                ),
                          child: const Text('Bật lại'),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            if (profile.isSelf && _blocked.isNotEmpty)
              Card(
                child: ExpansionTile(
                  leading: const Icon(Icons.block_outlined),
                  title: Text('${_blocked.length} tài khoản đã chặn'),
                  children: [
                    for (final account in _blocked)
                      ListTile(
                        leading: _Avatar(
                          name:
                              '${account['displayName'] ?? account['handle'] ?? 'I'}',
                          size: 38,
                        ),
                        title: Text(
                          '${account['displayName'] ?? account['handle'] ?? 'Tài khoản'}',
                        ),
                        subtitle: Text('@${account['handle'] ?? ''}'),
                        trailing: TextButton(
                          onPressed: _working
                              ? null
                              : () => _removeManagedAccount(
                                  '${account['handle'] ?? ''}',
                                  muted: false,
                                ),
                          child: const Text('Bỏ chặn'),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
