import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'ionic_api.dart';
import 'dialogs.dart';
import 'client_preferences.dart';

class AccountControls extends StatefulWidget {
  const AccountControls({
    required this.api,
    required this.userId,
    required this.onSessionEnded,
    required this.onToast,
    super.key,
  });
  final IonicApi api;
  final String userId;
  final VoidCallback onSessionEnded;
  final ValueChanged<String> onToast;
  @override
  State<AccountControls> createState() => _AccountControlsState();
}

class _AccountControlsState extends State<AccountControls> {
  JsonMap? _settings;
  List<JsonMap> _sessions = [];
  List<JsonMap> _hidden = [];
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final values = await Future.wait<Object>([
        widget.api.accountSettings(),
        widget.api.sessions(),
        widget.api.hiddenPosts(),
      ]);
      if (mounted) {
        setState(() {
          _settings = values[0] as JsonMap;
          _sessions = values[1] as List<JsonMap>;
          _hidden = values[2] as List<JsonMap>;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = apiErrorText(error));
    }
  }

  Future<void> _run(Future<void> Function() work) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await work();
    } catch (error) {
      if (mounted) widget.onToast(apiErrorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _privacy(String key, Object value) => _run(() async {
    final result = await widget.api.updateAccountSettings({key: value});
    if (mounted) setState(() => _settings = result);
  });
  Future<void> _credential(String action) async {
    final result = await showIonicDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CredentialActionDialog(api: widget.api, action: action),
    );
    if (!mounted || result == null) return;
    if (action == 'delete') {
      widget.onSessionEnded();
      return;
    }
    if (action == 'recovery') {
      await showIonicDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Lưu mã khôi phục ở nơi riêng tư'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Mã chỉ xuất hiện lần này, dùng được một lần để đặt lại mật khẩu. Tạo mã mới sẽ vô hiệu mã cũ. Ionic không thể lấy lại mã đã mất.',
                ),
                const SizedBox(height: 16),
                SelectableText(
                  result,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Tôi đã lưu mã'),
            ),
          ],
        ),
      );
    } else {
      widget.onToast('Đã đổi mật khẩu và đăng xuất các phiên khác.');
    }
    if (mounted) await _load();
  }

  Future<void> _logoutAll() async {
    final yes = await showIonicDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Đăng xuất tất cả thiết bị?'),
        content: const Text('Bao gồm thiết bị bạn đang dùng.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Đăng xuất'),
          ),
        ],
      ),
    );
    if (yes == true) {
      await _run(() async {
        await widget.api.logoutAll();
        if (mounted) widget.onSessionEnded();
      });
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_error != null)
        ListTile(
          title: Text(_error!),
          trailing: IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ),
      if (_settings == null && _error == null)
        const Center(child: CircularProgressIndicator()),
      if (_settings != null)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.lock_outline),
                  title: Text(
                    'Quyền riêng tư',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Hồ sơ riêng tư'),
                  subtitle: const Text(
                    'Chỉ bạn và người đã theo dõi xem được bài viết. Chưa nhận người theo dõi mới khi bật chế độ này.',
                  ),
                  value: _settings!['visibility'] == 'private',
                  onChanged: _busy
                      ? null
                      : (v) => _privacy('visibility', v ? 'private' : 'public'),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Xuất hiện trong tìm kiếm tài khoản'),
                  subtitle: const Text(
                    'Tắt để ẩn khỏi tìm kiếm tài khoản; người biết tên tài khoản vẫn có thể mở hồ sơ nếu có quyền.',
                  ),
                  value: _settings!['discoverable'] != false,
                  onChanged: _busy ? null : (v) => _privacy('discoverable', v),
                ),
                DropdownButtonFormField<String>(
                  key: ValueKey('${_settings!['messagePermission']}:$_busy'),
                  initialValue: '${_settings!['messagePermission']}',
                  decoration: const InputDecoration(
                    labelText: 'Ai được gửi tin nhắn cho bạn?',
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'everyone',
                      child: Text('Mọi người'),
                    ),
                    DropdownMenuItem(
                      value: 'following',
                      child: Text('Người bạn theo dõi'),
                    ),
                    DropdownMenuItem(value: 'nobody', child: Text('Không ai')),
                  ],
                  onChanged: _busy
                      ? null
                      : (v) {
                          if (v != null) _privacy('messagePermission', v);
                        },
                ),
                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Text(
                    'Áp dụng cả tin mới trong cuộc trò chuyện có sẵn. Lịch sử vẫn đọc được nếu không bị chặn.',
                  ),
                ),
              ],
            ),
          ),
        ),
      Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.password_rounded),
              title: const Text('Đổi mật khẩu'),
              subtitle: const Text('Đăng xuất các thiết bị khác.'),
              onTap: _busy ? null : () => _credential('password'),
            ),
            ListTile(
              leading: const Icon(Icons.key_outlined),
              title: const Text('Mã khôi phục tài khoản'),
              subtitle: Text(
                _settings?['recoveryEnabled'] == true
                    ? 'Đã bật. Tạo mã mới sẽ thay mã cũ.'
                    : 'Tạo và tự lưu mã để dùng khi quên mật khẩu.',
              ),
              onTap: _busy ? null : () => _credential('recovery'),
            ),
            ExpansionTile(
              leading: const Icon(Icons.devices_outlined),
              title: Text('Phiên đăng nhập (${_sessions.length})'),
              children: [
                for (final session in _sessions)
                  ListTile(
                    title: Text(
                      session['current'] == true
                          ? 'Phiên hiện tại'
                          : 'Phiên đăng nhập khác',
                    ),
                    subtitle: Text(
                      'Bắt đầu: ${_date('${session['createdAt']}')}\nHết hạn: ${_date('${session['expiresAt']}')}',
                    ),
                    trailing: session['current'] == true
                        ? null
                        : TextButton(
                            onPressed: _busy
                                ? null
                                : () => _run(() async {
                                    await widget.api.revokeSession(
                                      '${session['id']}',
                                    );
                                    await _load();
                                  }),
                            child: const Text('Đăng xuất'),
                          ),
                  ),
                ListTile(
                  title: const Text('Đăng xuất tất cả thiết bị'),
                  onTap: _busy ? null : _logoutAll,
                ),
              ],
            ),
            ListTile(
              leading: const Icon(Icons.article_outlined),
              title: const Text('Quản lý bài viết của bạn'),
              onTap: () => _activity(false),
            ),
            ExpansionTile(
              leading: const Icon(Icons.visibility_off_outlined),
              title: Text('Bài viết đã ẩn (${_hidden.length})'),
              children: [
                if (_hidden.isEmpty)
                  const ListTile(
                    title: Text('Chưa có bài viết đã ẩn có thể xem.'),
                  ),
                for (final post in _hidden)
                  ListTile(
                    title: Text(
                      '${post['body']}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text('@${post['handle']}'),
                    trailing: TextButton(
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                              await widget.api.unhidePost('${post['id']}');
                              await _load();
                            }),
                      child: const Text('Bỏ ẩn'),
                    ),
                  ),
              ],
            ),
            ListTile(
              leading: const Icon(Icons.bookmark_outline),
              title: const Text('Bài viết đã lưu'),
              onTap: () => _activity(true),
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('Tải dữ liệu tài khoản'),
              subtitle: const Text(
                'Tệp riêng tư gồm hồ sơ, nội dung và tin nhắn bạn đã gửi.',
              ),
              onTap: _busy
                  ? null
                  : () => _run(() async {
                      final data = await widget.api.exportAccount();
                      await FilePicker.saveFile(
                        dialogTitle: 'Lưu dữ liệu Ionic',
                        fileName: 'ionic-account.json',
                        bytes: Uint8List.fromList(
                          utf8.encode(
                            const JsonEncoder.withIndent('  ').convert(data),
                          ),
                        ),
                      );
                    }),
            ),
            ListTile(
              leading: Icon(
                Icons.delete_forever_outlined,
                color: Theme.of(context).colorScheme.error,
              ),
              title: const Text('Xóa tài khoản'),
              subtitle: const Text(
                'Xóa vĩnh viễn tài khoản và dữ liệu liên quan.',
              ),
              onTap: _busy ? null : () => _credential('delete'),
            ),
          ],
        ),
      ),
    ],
  );
  String _date(String raw) =>
      DateTime.tryParse(raw)?.toLocal().toString().split('.').first ?? raw;
  Future<void> _activity(bool saved) => showIonicDialog<void>(
    context: context,
    builder: (_) => AccountActivityDialog(api: widget.api, saved: saved),
  );
}

class CredentialActionDialog extends StatefulWidget {
  const CredentialActionDialog({
    required this.api,
    required this.action,
    super.key,
  });
  final IonicApi api;
  final String action;
  @override
  State<CredentialActionDialog> createState() => _CredentialActionDialogState();
}

class _CredentialActionDialogState extends State<CredentialActionDialog> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController(),
      _newPassword = TextEditingController(),
      _confirm = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _password.dispose();
    _newPassword.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var result = 'done';
      if (widget.action == 'password') {
        await widget.api.changePassword(_password.text, _newPassword.text);
      } else if (widget.action == 'recovery') {
        result = await widget.api.recoveryCode(_password.text);
      } else {
        await widget.api.deleteAccount(_password.text);
      }
      if (mounted) Navigator.pop(context, result);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is IonicApiException && error.statusCode == 403
              ? 'Mật khẩu hiện tại không đúng hoặc đã thay đổi.'
              : apiErrorText(error),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(switch (widget.action) {
        'password' => 'Đổi mật khẩu',
        'recovery' => 'Tạo mã khôi phục',
        _ => 'Xóa tài khoản vĩnh viễn',
      }),
      content: SizedBox(
        width: 430,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.action == 'delete')
                  const Text(
                    'Bài viết, bình luận, tệp đính kèm và các cuộc trò chuyện của tài khoản này sẽ bị xóa cho cả hai bên. Thao tác không thể hoàn tác.',
                  ),
                TextFormField(
                  controller: _password,
                  enabled: !_busy,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Mật khẩu hiện tại',
                  ),
                  validator: (v) =>
                      (v ?? '').isEmpty ? 'Nhập mật khẩu hiện tại.' : null,
                ),
                if (widget.action == 'password') ...[
                  TextFormField(
                    controller: _newPassword,
                    enabled: !_busy,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    maxLength: 128,
                    decoration: const InputDecoration(
                      labelText: 'Mật khẩu mới',
                    ),
                    validator: (v) =>
                        (v ?? '').length < 12 ? 'Cần ít nhất 12 ký tự.' : null,
                  ),
                  TextFormField(
                    controller: _confirm,
                    enabled: !_busy,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Nhập lại mật khẩu mới',
                    ),
                    validator: (v) => v != _newPassword.text
                        ? 'Hai mật khẩu chưa khớp.'
                        : null,
                  ),
                ],
                if (widget.action == 'delete')
                  TextFormField(
                    controller: _confirm,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      labelText: 'Nhập XÓA để xác nhận',
                    ),
                    validator: (v) => v != 'XÓA' ? 'Nhập đúng XÓA.' : null,
                  ),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Hủy'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? 'Đang xử lý…' : 'Xác nhận'),
        ),
      ],
    ),
  );
}

class RecoveryDialog extends StatefulWidget {
  const RecoveryDialog({required this.api, super.key});
  final IonicApi api;
  @override
  State<RecoveryDialog> createState() => _RecoveryDialogState();
}

class _RecoveryDialogState extends State<RecoveryDialog> {
  final _form = GlobalKey<FormState>();
  final _handle = TextEditingController(),
      _code = TextEditingController(),
      _password = TextEditingController(),
      _confirm = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    for (final c in [_handle, _code, _password, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _recover() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.recover(_handle.text, _code.text, _password.text);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Không khôi phục được. Kiểm tra kết nối, tên tài khoản và mã chưa dùng.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('Khôi phục tài khoản'),
      content: SizedBox(
        width: 430,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Dùng mã đã tạo trong Cài đặt. Sau khi đặt lại mật khẩu, mã bị vô hiệu và tất cả phiên được đăng xuất.',
                ),
                TextFormField(
                  controller: _handle,
                  enabled: !_busy,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Tên tài khoản'),
                  validator: (v) =>
                      RegExp(r'^[a-zA-Z0-9_]{3,24}$').hasMatch(v?.trim() ?? '')
                      ? null
                      : 'Nhập tên tài khoản.',
                ),
                TextFormField(
                  controller: _code,
                  enabled: !_busy,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: 'Mã khôi phục'),
                  validator: (v) => (v?.trim().length ?? 0) == 43
                      ? null
                      : 'Nhập mã khôi phục 43 ký tự.',
                ),
                TextFormField(
                  controller: _password,
                  enabled: !_busy,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLength: 128,
                  decoration: const InputDecoration(labelText: 'Mật khẩu mới'),
                  validator: (v) =>
                      (v ?? '').length >= 12 ? null : 'Cần ít nhất 12 ký tự.',
                ),
                TextFormField(
                  controller: _confirm,
                  enabled: !_busy,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Nhập lại mật khẩu mới',
                  ),
                  validator: (v) =>
                      v == _password.text ? null : 'Hai mật khẩu chưa khớp.',
                ),
                if (_error != null) Text(_error!),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Hủy'),
        ),
        FilledButton(
          onPressed: _busy ? null : _recover,
          child: Text(_busy ? 'Đang xử lý…' : 'Đặt lại mật khẩu'),
        ),
      ],
    ),
  );
}

class DeviceDisplayControls extends StatelessWidget {
  const DeviceDisplayControls({required this.onToast, super.key});
  final ValueChanged<String> onToast;
  Future<void> _save(Future<void> Function() work) async {
    try {
      await work();
    } catch (_) {
      onToast('Không lưu được tùy chọn trên thiết bị này.');
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: clientPreferences,
    builder: (_, _) => Column(
      children: [
        ListTile(
          title: const Text('Cỡ chữ'),
          subtitle: Text(
            'Theo cỡ chữ hệ thống × ${clientPreferences.textScale.toStringAsFixed(1)}',
          ),
        ),
        Slider(
          value: clientPreferences.textScale,
          min: .9,
          max: 1.5,
          divisions: 6,
          label: '${(clientPreferences.textScale * 100).round()}%',
          onChanged: (v) => _save(() => clientPreferences.update(scale: v)),
        ),
        SwitchListTile.adaptive(
          value: clientPreferences.reducedMotion,
          title: const Text('Giảm chuyển động'),
          onChanged: (v) => _save(() => clientPreferences.update(motion: v)),
        ),
        SwitchListTile.adaptive(
          value: clientPreferences.dataSaver,
          title: const Text('Tiết kiệm dữ liệu'),
          subtitle: const Text(
            'Chỉ tải ảnh khi bạn nhấn vào ảnh. Âm thanh luôn cần nhấn phát.',
          ),
          onChanged: (v) => _save(() => clientPreferences.update(saver: v)),
        ),
      ],
    ),
  );
}

class AccountActivityDialog extends StatefulWidget {
  const AccountActivityDialog({
    required this.api,
    required this.saved,
    super.key,
  });
  final IonicApi api;
  final bool saved;
  @override
  State<AccountActivityDialog> createState() => _AccountActivityDialogState();
}

class _AccountActivityDialogState extends State<AccountActivityDialog> {
  List<FeedPost> _items = [];
  String? _cursor;
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final page = widget.saved
          ? await widget.api.savedPosts(cursor: more ? _cursor : null)
          : await widget.api.myPosts(cursor: more ? _cursor : null);
      if (mounted) {
        setState(() {
          _items = more ? [..._items, ...page.items] : page.items;
          _cursor = page.nextCursor;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = apiErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _action(FeedPost post, String action) async {
    if (_busy) return;
    String? body;
    if (action == 'edit') {
      body = await showIonicDialog<String>(
        context: context,
        builder: (_) => _EditPostDialog(body: post.body),
      );
      if (body == null) return;
    }
    if (!mounted) return;
    if (action == 'delete') {
      final yes = await showIonicDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Xóa bài viết?'),
          content: const Text('Bài viết, bình luận và tệp đính kèm sẽ bị xóa.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Hủy'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Xóa'),
            ),
          ],
        ),
      );
      if (yes != true) return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    var succeeded = false;
    try {
      if (action == 'edit') {
        await widget.api.editPost(post.id, body!);
      } else if (action == 'delete') {
        await widget.api.deletePost(post.id);
      } else {
        await widget.api.setSaved(post.id, false);
      }
      succeeded = true;
    } catch (e) {
      if (mounted) setState(() => _error = apiErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && succeeded) await _load();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.saved ? 'Bài viết đã lưu' : 'Bài viết của bạn'),
    content: SizedBox(
      width: 560,
      height: 450,
      child: Column(
        children: [
          if (_error != null) Text(_error!),
          if (_busy) const LinearProgressIndicator(),
          Expanded(
            child: ListView(
              children: [
                if (!_busy && _items.isEmpty)
                  const ListTile(title: Text('Chưa có bài viết.')),
                for (final post in _items)
                  ListTile(
                    title: Text(post.body),
                    subtitle: Text('@${post.handle}'),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) => _action(post, v),
                      itemBuilder: (_) => widget.saved
                          ? [
                              const PopupMenuItem(
                                value: 'unsave',
                                child: Text('Bỏ lưu'),
                              ),
                            ]
                          : [
                              const PopupMenuItem(
                                value: 'edit',
                                child: Text('Sửa bài'),
                              ),
                              const PopupMenuItem(
                                value: 'delete',
                                child: Text('Xóa bài'),
                              ),
                            ],
                    ),
                  ),
                if (_cursor != null)
                  TextButton(
                    onPressed: _busy ? null : () => _load(more: true),
                    child: const Text('Tải thêm'),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Đóng'),
      ),
    ],
  );
}

class _EditPostDialog extends StatefulWidget {
  const _EditPostDialog({required this.body});
  final String body;
  @override
  State<_EditPostDialog> createState() => _EditPostDialogState();
}

class _EditPostDialogState extends State<_EditPostDialog> {
  late final _text = TextEditingController(text: widget.body);
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Sửa bài viết'),
    content: SizedBox(
      width: 450,
      child: TextField(
        controller: _text,
        maxLength: 280,
        minLines: 3,
        maxLines: 8,
        onChanged: (_) => setState(() {}),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Hủy'),
      ),
      FilledButton(
        onPressed: _text.text.trim().isEmpty
            ? null
            : () => Navigator.pop(context, _text.text.trim()),
        child: const Text('Lưu'),
      ),
    ],
  );
}
