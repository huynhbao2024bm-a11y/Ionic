import 'package:flutter/material.dart';

import 'ionic_api.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    required this.api,
    required this.user,
    required this.onAuthenticate,
    required this.onProfileChanged,
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.onSignOut,
    required this.onToast,
    super.key,
  });

  final IonicApi api;
  final ApiUser? user;
  final Future<void> Function({required String mode}) onAuthenticate;
  final ValueChanged<ApiUser> onProfileChanged;
  final ThemeMode themeMode;
  final Future<void> Function(ThemeMode mode) onThemeModeChanged;
  final VoidCallback onSignOut;
  final ValueChanged<String> onToast;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  ApiProfile? _profile;
  List<JsonMap> _blocked = [];
  List<JsonMap> _muted = [];
  final Set<String> _busyAccounts = {};
  bool _loading = true;
  bool _paused = false;
  bool _savingPause = false;
  bool _savingTheme = false;
  bool _resetting = false;
  String? _error;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.user?.id != widget.user?.id) {
      _epoch++;
      _profile = null;
      _blocked = [];
      _muted = [];
      _busyAccounts.clear();
      _paused = false;
      _load();
    }
  }

  Future<void> _load() async {
    final epoch = ++_epoch;
    final userId = widget.user?.id;
    setState(() {
      _loading = true;
      _error = null;
    });
    if (widget.user == null) {
      if (mounted && epoch == _epoch) setState(() => _loading = false);
      return;
    }
    try {
      final values = await Future.wait<Object>([
        widget.api.profile(widget.user!.handle),
        widget.api.feedPaused(),
        widget.api.mutedProfiles(),
        widget.api.blockedProfiles(),
      ]);
      if (!mounted || epoch != _epoch || widget.user?.id != userId) return;
      setState(() {
        _profile = values[0] as ApiProfile;
        _paused = values[1] as bool;
        _muted = values[2] as List<JsonMap>;
        _blocked = values[3] as List<JsonMap>;
      });
    } catch (error) {
      if (mounted && epoch == _epoch) {
        setState(() => _error = apiErrorText(error));
      }
    } finally {
      if (mounted && epoch == _epoch) setState(() => _loading = false);
    }
  }

  Future<void> _saveProfile() async {
    final current = _profile;
    if (current == null) return;
    final draft = await showDialog<_ProfileDraft>(
      context: context,
      builder: (context) => _ProfileEditDialog(profile: current),
    );
    if (draft == null || !mounted) return;
    try {
      final user = await widget.api.updateProfile(draft.displayName, draft.bio);
      if (!mounted) return;
      setState(() {
        _profile = ApiProfile(
          handle: current.handle,
          displayName: draft.displayName,
          bio: draft.bio,
          followerCount: current.followerCount,
          followingCount: current.followingCount,
          postCount: current.postCount,
          isFollowing: current.isFollowing,
          isMuted: current.isMuted,
          isSelf: current.isSelf,
        );
      });
      widget.onProfileChanged(user);
      widget.onToast('Đã lưu hồ sơ.');
    } catch (error) {
      widget.onToast(apiErrorText(error));
    }
  }

  Future<void> _setPaused(bool value) async {
    if (_savingPause) return;
    setState(() => _savingPause = true);
    try {
      await widget.api.pauseFeed(value);
      if (mounted) setState(() => _paused = value);
    } catch (error) {
      widget.onToast(apiErrorText(error));
    } finally {
      if (mounted) setState(() => _savingPause = false);
    }
  }

  Future<void> _resetPersonalization() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Đặt lại bảng tin?'),
        content: const Text(
          'Các tùy chỉnh và dữ liệu cá nhân hóa đã tích lũy sẽ bị xóa. Bài viết, tin nhắn và tài khoản của bạn không bị ảnh hưởng.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Đặt lại'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _resetting = true);
    try {
      await widget.api.resetFeed();
      if (mounted) {
        setState(() => _paused = false);
        widget.onToast('Đã đặt lại bảng tin.');
      }
    } catch (error) {
      widget.onToast(apiErrorText(error));
    } finally {
      if (mounted) setState(() => _resetting = false);
    }
  }

  Future<void> _removeManagedAccount(
    String handle, {
    required bool blocked,
  }) async {
    final key = '${blocked ? 'block' : 'mute'}:$handle';
    if (_busyAccounts.contains(key)) return;
    setState(() => _busyAccounts.add(key));
    try {
      if (blocked) {
        await widget.api.block(handle, false);
      } else {
        await widget.api.mute(handle, false);
      }
      if (!mounted) return;
      setState(() {
        if (blocked) {
          _blocked = _blocked
              .where((item) => item['handle'] != handle)
              .toList();
        } else {
          _muted = _muted.where((item) => item['handle'] != handle).toList();
        }
      });
      widget.onToast(
        blocked ? 'Đã bỏ chặn @$handle.' : 'Đã bật lại bài viết của @$handle.',
      );
    } catch (error) {
      widget.onToast(apiErrorText(error));
    } finally {
      if (mounted) setState(() => _busyAccounts.remove(key));
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.user;
    return RefreshIndicator(
      onRefresh: _load,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 850),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 30),
            children: [
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      Icons.tune_rounded,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Cài đặt',
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        Text(
                          'Tài khoản, bảng tin và an toàn',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  if (user != null)
                    IconButton(
                      tooltip: 'Tải lại cài đặt',
                      onPressed: _loading ? null : _load,
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                ],
              ),
              const SizedBox(height: 22),
              if (user == null) ...[
                _guestCard(context),
                const SizedBox(height: 14),
                _appearanceSection(context),
              ]
              else ...[
                if (_error != null) _errorCard(context),
                if (_loading && _profile == null)
                  const Padding(
                    padding: EdgeInsets.all(30),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else ...[
                  _accountSection(context),
                  const SizedBox(height: 14),
                  _feedSection(context),
                  const SizedBox(height: 14),
                  _appearanceSection(context),
                  const SizedBox(height: 14),
                  _safetySection(context),
                  const SizedBox(height: 14),
                  _sessionSection(context),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _guestCard(BuildContext context) => _section(
    context,
    icon: Icons.person_outline_rounded,
    title: 'Tài khoản Ionic',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Đăng nhập để chỉnh sửa hồ sơ và quản lý bảng tin, quyền riêng tư.',
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: () => widget.onAuthenticate(mode: 'login'),
          icon: const Icon(Icons.login_rounded),
          label: const Text('Đăng nhập'),
        ),
      ],
    ),
  );

  Widget _accountSection(BuildContext context) {
    final user = widget.user!;
    final profile = _profile;
    return _section(
      context,
      icon: Icons.person_outline_rounded,
      title: 'Tài khoản',
      trailing: TextButton.icon(
        onPressed: profile == null || _loading ? null : _saveProfile,
        icon: const Icon(Icons.edit_outlined, size: 18),
        label: const Text('Sửa hồ sơ'),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 25,
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            foregroundColor: Theme.of(context).colorScheme.primary,
            child: Text(
              user.displayName.characters.first.toUpperCase(),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user.displayName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  '@${user.handle}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if ((profile?.bio ?? '').isNotEmpty) ...[
                  const SizedBox(height: 7),
                  Text(
                    profile!.bio,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _feedSection(BuildContext context) => _section(
    context,
    icon: Icons.view_stream_outlined,
    title: 'Bảng tin',
    child: Column(
      children: [
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          value: _paused,
          onChanged: _loading || _profile == null || _savingPause
              ? null
              : _setPaused,
          title: const Text('Cá nhân hóa bảng tin'),
          subtitle: Text(
            _paused
                ? 'Đang tạm dừng cập nhật theo hoạt động của bạn.'
                : 'Sắp xếp nội dung dựa trên tùy chỉnh và hoạt động trong Ionic.',
          ),
          secondary: _savingPause
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.auto_awesome_outlined),
        ),
        const Divider(height: 18),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.restart_alt_rounded),
          title: const Text('Đặt lại bảng tin'),
          subtitle: const Text(
            'Xóa tùy chỉnh và dữ liệu cá nhân hóa đã tích lũy.',
          ),
          trailing: _resetting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.chevron_right_rounded),
          onTap: _resetting ? null : _resetPersonalization,
        ),
      ],
    ),
  );

  Future<void> _setTheme(ThemeMode mode) async {
    if (_savingTheme || mode == widget.themeMode) return;
    setState(() => _savingTheme = true);
    try {
      await widget.onThemeModeChanged(mode);
    } catch (_) {
      widget.onToast('Không lưu được chế độ hiển thị trên thiết bị này.');
    } finally {
      if (mounted) setState(() => _savingTheme = false);
    }
  }

  Widget _appearanceSection(BuildContext context) => _section(
    context,
    icon: Icons.contrast_rounded,
    title: 'Giao diện',
    child: SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      value: widget.themeMode == ThemeMode.dark,
      onChanged: _savingTheme
          ? null
          : (value) => _setTheme(value ? ThemeMode.dark : ThemeMode.light),
      title: Text(
        widget.themeMode == ThemeMode.dark ? 'Chế độ tối' : 'Chế độ sáng',
      ),
      subtitle: const Text('Lưu trên thiết bị này.'),
      secondary: _savingTheme
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              widget.themeMode == ThemeMode.dark
                  ? Icons.dark_mode_outlined
                  : Icons.light_mode_outlined,
            ),
    ),
  );

  Widget _safetySection(BuildContext context) => _section(
    context,
    icon: Icons.shield_outlined,
    title: 'Quyền riêng tư và an toàn',
    child: Column(
      children: [
        _managedList(
          context,
          title: 'Tài khoản đã tắt tiếng',
          items: _muted,
          blocked: false,
        ),
        const Divider(height: 22),
        _managedList(
          context,
          title: 'Tài khoản đã chặn',
          items: _blocked,
          blocked: true,
        ),
      ],
    ),
  );

  Widget _managedList(
    BuildContext context, {
    required String title,
    required List<JsonMap> items,
    required bool blocked,
  }) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    childrenPadding: const EdgeInsets.only(bottom: 2),
    title: Text(title),
    subtitle: Text('${items.length} tài khoản'),
    children: items.isEmpty
        ? [
            ListTile(
              title: Text(
                'Danh sách đang trống.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ]
        : items.map((item) {
            final handle = '${item['handle'] ?? ''}';
            final busy = _busyAccounts.contains(
              '${blocked ? 'block' : 'mute'}:$handle',
            );
            return ListTile(
              contentPadding: const EdgeInsets.only(left: 8, right: 4),
              title: Text('${item['displayName'] ?? handle}'),
              subtitle: Text('@$handle'),
              trailing: busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : TextButton(
                      onPressed: () =>
                          _removeManagedAccount(handle, blocked: blocked),
                      child: Text(blocked ? 'Bỏ chặn' : 'Bật lại'),
                    ),
            );
          }).toList(),
  );

  Widget _sessionSection(BuildContext context) => _section(
    context,
    icon: Icons.logout_rounded,
    title: 'Phiên đăng nhập',
    child: Row(
      children: [
        const Expanded(child: Text('Bạn đang đăng nhập trên thiết bị này.')),
        OutlinedButton(
          onPressed: widget.onSignOut,
          child: const Text('Đăng xuất'),
        ),
      ],
    ),
  );

  Widget _errorCard(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Material(
      color: Theme.of(context).colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(16),
      child: ListTile(
        leading: Icon(
          Icons.cloud_off_outlined,
          color: Theme.of(context).colorScheme.onErrorContainer,
        ),
        title: const Text('Không tải được một số cài đặt'),
        subtitle: Text(_error!),
        trailing: IconButton(
          tooltip: 'Thử lại',
          onPressed: _load,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ),
    ),
  );

  Widget _section(
    BuildContext context, {
    required IconData icon,
    required String title,
    required Widget child,
    Widget? trailing,
  }) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 21,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    ),
  );
}

class _ProfileDraft {
  const _ProfileDraft(this.displayName, this.bio);
  final String displayName;
  final String bio;
}

class _ProfileEditDialog extends StatefulWidget {
  const _ProfileEditDialog({required this.profile});
  final ApiProfile profile;

  @override
  State<_ProfileEditDialog> createState() => _ProfileEditDialogState();
}

class _ProfileEditDialogState extends State<_ProfileEditDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.profile.displayName,
  );
  late final TextEditingController _bio = TextEditingController(
    text: widget.profile.bio,
  );

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    super.dispose();
  }

  void _refresh() => setState(() {});

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Sửa hồ sơ'),
    content: SizedBox(
      width: 460,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: 48,
            onChanged: (_) => _refresh(),
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Tên hiển thị'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _bio,
            maxLength: 160,
            onChanged: (_) => _refresh(),
            maxLines: 3,
            minLines: 2,
            decoration: const InputDecoration(
              labelText: 'Tiểu sử',
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
        onPressed:
            _name.text.trim().isEmpty ||
                _name.text.runes.length > 48 ||
                _bio.text.runes.length > 160
            ? null
            : () => Navigator.pop(
                context,
                _ProfileDraft(_name.text.trim(), _bio.text.trim()),
              ),
        child: const Text('Lưu'),
      ),
    ],
  );
}
