import 'package:flutter/material.dart';
import 'account_avatar.dart';
import 'dialogs.dart';
import 'ionic_api.dart';

class ConnectionsDialog extends StatefulWidget {
  const ConnectionsDialog({
    required this.api,
    required this.handle,
    required this.isSelf,
    required this.initialKind,
    required this.onOpenProfile,
    required this.onConversation,
    super.key,
  });
  final IonicApi api;
  final String handle, initialKind;
  final bool isSelf;
  final ValueChanged<String> onOpenProfile;
  final void Function(String, String) onConversation;
  @override
  State<ConnectionsDialog> createState() => _ConnectionsDialogState();
}

class _ConnectionsDialogState extends State<ConnectionsDialog> {
  late String _kind = widget.initialKind;
  List<JsonMap> _items = [];
  final _busy = <String>{};
  bool _loading = true;
  String? _cursor, _error;
  int _epoch = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool append = false}) async {
    final epoch = ++_epoch;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.api.connections(
        widget.handle,
        _kind,
        cursor: append ? _cursor : null,
      );
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _items = {
          for (final item in [
            ...(append ? _items : <JsonMap>[]),
            ...jsonItems(page),
          ])
            item['handle']: item,
        }.values.toList();
        _cursor = jsonCursor(page);
      });
    } catch (e) {
      if (mounted && epoch == _epoch) setState(() => _error = apiErrorText(e));
    } finally {
      if (mounted && epoch == _epoch) setState(() => _loading = false);
    }
  }

  Future<bool> _confirm(String title, String detail) async =>
      await showIonicDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(detail),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Hủy'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Xác nhận'),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> _action(JsonMap item, String action) async {
    final handle = item['handle'] as String;
    if (_busy.contains(handle)) return;
    final following = item['isFollowing'] == true,
        muted = item['isMuted'] == true,
        epoch = _epoch;
    if (action == 'block' &&
        !await _confirm(
          'Chặn @$handle?',
          'Hai tài khoản sẽ không thể tương tác hoặc nhắn tin với nhau.',
        )) {
      return;
    }
    if (action == 'remove' &&
        !await _confirm(
          'Bỏ @$handle khỏi người theo dõi?',
          'Tài khoản này có thể theo dõi lại nếu hồ sơ của bạn công khai.',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => _busy.add(handle));
    try {
      if (action == 'follow') {
        await widget.api.follow(handle, !following);
      } else if (action == 'mute') {
        await widget.api.mute(handle, !muted);
      } else if (action == 'remove') {
        await widget.api.removeFollower(handle);
      } else if (action == 'block') {
        await widget.api.block(handle, true);
      } else if (action == 'message') {
        final c = await widget.api.startConversation(handle);
        if (!mounted) return;
        Navigator.pop(context);
        widget.onConversation(c.id, c.partnerDisplayName);
        return;
      }
      if (!mounted || epoch != _epoch) return;
      setState(() {
        if (action == 'block' ||
            action == 'remove' ||
            (action == 'follow' &&
                following &&
                widget.isSelf &&
                _kind == 'following')) {
          _items.removeWhere((i) => i['handle'] == handle);
        } else {
          final i = _items.indexWhere((i) => i['handle'] == handle);
          if (i >= 0) {
            _items[i] = {
              ..._items[i],
              if (action == 'follow') 'isFollowing': !following,
              if (action == 'mute') 'isMuted': !muted,
            };
          }
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(apiErrorText(e))));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(handle));
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
    clipBehavior: Clip.antiAlias,
    child: SizedBox(
      width: 600,
      height: MediaQuery.sizeOf(context).height * .8,
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  '@${widget.handle}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: 'Đóng danh sách',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'followers', label: Text('Người theo dõi')),
              ButtonSegment(value: 'following', label: Text('Đang theo dõi')),
            ],
            selected: {_kind},
            showSelectedIcon: false,
            onSelectionChanged: (value) {
              setState(() {
                _kind = value.first;
                _items = [];
                _cursor = null;
              });
              _load();
            },
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),
          Expanded(
            child: _loading && _items.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      itemCount: _items.length + 1,
                      itemBuilder: (context, index) {
                        if (index == _items.length) {
                          return Column(
                            children: [
                              if (_error != null) Text(_error!),
                              if (_error != null || _cursor != null)
                                TextButton(
                                  onPressed: _loading
                                      ? null
                                      : () => _load(append: _cursor != null),
                                  child: Text(
                                    _loading
                                        ? 'Đang tải…'
                                        : _error != null
                                        ? 'Thử lại'
                                        : 'Tải thêm',
                                  ),
                                ),
                              if (_items.isEmpty && _error == null)
                                const Padding(
                                  padding: EdgeInsets.all(24),
                                  child: Text(
                                    'Chưa có tài khoản trong danh sách.',
                                  ),
                                ),
                            ],
                          );
                        }
                        final item = _items[index],
                            handle = item['handle'] as String,
                            own = item['isSelf'] == true,
                            following = item['isFollowing'] == true;
                        return Padding(
                          key: ValueKey(handle),
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            children: [
                              AccountAvatar(
                                api: widget.api,
                                name: item['displayName'] as String,
                                mediaId: item['avatarMediaId'] as String?,
                                size: 44,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: InkWell(
                                  onTap: () {
                                    Navigator.pop(context);
                                    widget.onOpenProfile(handle);
                                  },
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item['displayName'] as String,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      Text(
                                        '@$handle',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (!own &&
                                  (item['canFollow'] == true || following))
                                TextButton(
                                  onPressed: _busy.contains(handle)
                                      ? null
                                      : () => _action(item, 'follow'),
                                  child: Text(
                                    following ? 'Hủy theo dõi' : 'Theo dõi',
                                  ),
                                ),
                              if (!own)
                                PopupMenuButton<String>(
                                  tooltip: 'Tùy chọn @$handle',
                                  enabled: !_busy.contains(handle),
                                  onSelected: (a) => _action(item, a),
                                  itemBuilder: (context) => [
                                    const PopupMenuItem(
                                      value: 'message',
                                      child: Text('Nhắn tin'),
                                    ),
                                    PopupMenuItem(
                                      value: 'mute',
                                      child: Text(
                                        item['isMuted'] == true
                                            ? 'Bỏ tắt tiếng'
                                            : 'Tắt tiếng',
                                      ),
                                    ),
                                    if (widget.isSelf && _kind == 'followers')
                                      const PopupMenuItem(
                                        value: 'remove',
                                        child: Text('Bỏ người theo dõi'),
                                      ),
                                    const PopupMenuItem(
                                      value: 'block',
                                      child: Text('Chặn tài khoản'),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    ),
  );
}
