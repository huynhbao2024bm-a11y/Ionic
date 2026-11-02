import 'home_search.dart';
import 'password_field.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'ionic_api.dart';
import 'account_avatar.dart';
import 'search_history_store.dart';
import 'dialogs.dart';
import 'media_composer.dart';
import 'screens.dart';
import 'settings_screen.dart';
import 'account_controls.dart';
import 'client_preferences.dart';
import 'draft_store.dart';
import 'app_updates.dart';
import 'preview_heartbeat.dart';

const _brand = Color(0xff4c5fdb);
const _accent = Color(0xff8052e8);
const _darkAction = Color(0xff34383f);
const _themePreferenceKey = 'ionic_appearance_mode';

ThemeData ionicTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  const lightInk = Color(0xff1b2340);
  const lightMuted = Color(0xff526079);
  const lightCanvas = Color(0xfff2f4fb);
  const darkInk = Color(0xffeef0f5);
  const darkMuted = Color(0xffa8afbd);
  const darkCanvas = Color(0xff121418);
  const darkSurface = Color(0xff1a1d23);
  const darkBorder = Color(0xff30343d);
  const darkTextAction = Color(0xffc4c9d1);
  final ink = dark ? darkInk : lightInk;
  final muted = dark ? darkMuted : lightMuted;
  final surface = dark ? darkSurface : Colors.white;
  final border = dark ? darkBorder : const Color(0xffdbe1ef);
  final canvas = dark ? darkCanvas : lightCanvas;
  final scheme = ColorScheme.fromSeed(seedColor: _brand, brightness: brightness)
      .copyWith(
        primary: dark ? darkTextAction : _brand,
        onPrimary: dark ? darkCanvas : Colors.white,
        primaryContainer: dark ? _darkAction : null,
        onPrimaryContainer: dark ? darkInk : null,
        secondary: dark ? darkTextAction : _accent,
        onSecondary: dark ? darkCanvas : Colors.white,
        secondaryContainer: dark
            ? const Color(0xff2b2f36)
            : const Color(0xfff1f3f8),
        onSecondaryContainer: dark ? darkInk : const Color(0xff1b2340),
        tertiary: dark ? darkTextAction : null,
        onTertiary: dark ? darkCanvas : null,
        surface: surface,
        onSurface: ink,
        onSurfaceVariant: muted,
        outline: dark ? darkBorder : null,
        outlineVariant: dark ? const Color(0xff3a3e46) : null,
        surfaceContainerHighest: dark
            ? const Color(0xff242830)
            : const Color(0xfff1f3f8),
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    scaffoldBackgroundColor: canvas,
    textTheme: TextTheme(
      headlineMedium: TextStyle(
        color: ink,
        fontSize: 29,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.7,
      ),
      titleLarge: TextStyle(
        color: ink,
        fontSize: 21,
        fontWeight: FontWeight.w700,
      ),
      titleMedium: TextStyle(
        color: ink,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: TextStyle(color: ink, fontSize: 16, height: 1.55),
      bodyMedium: TextStyle(color: muted, fontSize: 14, height: 1.5),
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(
          color: dark ? darkTextAction : _brand,
          width: 1.5,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: dark ? darkInk : _brand),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: dark ? _darkAction : _brand,
        foregroundColor: Colors.white,
        minimumSize: const Size(44, 46),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 19),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(44, 44),
        shape: const StadiumBorder(),
        foregroundColor: ink,
        side: BorderSide(color: border),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: surface,
      indicatorColor: dark ? const Color(0xff3c4149) : null,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          color: selected ? ink : muted,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        );
      }),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: dark ? darkTextAction : _brand,
      selectionColor: (dark ? darkTextAction : _brand).withValues(alpha: .25),
      selectionHandleColor: dark ? darkTextAction : _brand,
    ),
  );
}

class IonicClientApp extends StatefulWidget {
  const IonicClientApp({super.key});

  @override
  State<IonicClientApp> createState() => _IonicClientAppState();
}

class _IonicClientAppState extends State<IonicClientApp> {
  final _localSettings = const FlutterSecureStorage();
  ThemeMode _themeMode = ThemeMode.dark;

  @override
  void initState() {
    super.initState();
    _restoreTheme();
    clientPreferences.load();
  }

  Future<void> _restoreTheme() async {
    try {
      final saved = await _localSettings.read(key: _themePreferenceKey);
      if (mounted && saved != null) {
        setState(
          () =>
              _themeMode = saved == 'light' ? ThemeMode.light : ThemeMode.dark,
        );
      }
    } catch (_) {
      // Keep the default dark appearance if local preference storage is unavailable.
    }
  }

  Future<void> _setThemeMode(ThemeMode value) async {
    try {
      await _localSettings.write(
        key: _themePreferenceKey,
        value: value == ThemeMode.light ? 'light' : 'dark',
      );
      if (mounted) setState(() => _themeMode = value);
    } catch (_) {
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: clientPreferences,
    builder: (_, _) => MaterialApp(
      title: 'Ionic',
      debugShowCheckedModeBanner: false,
      theme: ionicTheme(Brightness.light),
      darkTheme: ionicTheme(Brightness.dark),
      themeMode: _themeMode,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: IonicTextScaler(
              media.textScaler,
              clientPreferences.textScale,
            ),
            disableAnimations:
                media.disableAnimations || clientPreferences.reducedMotion,
            accessibleNavigation:
                media.accessibleNavigation || clientPreferences.reducedMotion,
          ),
          child: child!,
        );
      },
      home: IonicShell(
        onThemeModeChanged: _setThemeMode,
        themeMode: _themeMode,
      ),
    ),
  );
}

enum _Page { home, messages, profile, settings }

class IonicShell extends StatefulWidget {
  const IonicShell({
    required this.onThemeModeChanged,
    required this.themeMode,
    super.key,
  });

  final Future<void> Function(ThemeMode mode) onThemeModeChanged;
  final ThemeMode themeMode;

  @override
  State<IonicShell> createState() => _IonicShellState();
}

class _IonicShellState extends State<IonicShell> {
  final IonicApi _api = IonicApi();
  ApiUser? _user;
  _Page _page = _Page.home;
  String? _profileHandle;
  String? _openConversationId;
  String? _openConversationName;
  final _homeSearch = HomeSearchController();
  int _homeRefreshToken = 0;
  bool _checkingSession = true;
  String? _sessionError;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  @override
  void dispose() {
    _homeSearch.dispose();
    super.dispose();
  }

  Future<void> _restoreSession() async {
    try {
      _user = await _api.currentUser();
    } on IonicApiException catch (error) {
      if (error.statusCode != 401 && error.statusCode != 403) {
        _sessionError = apiErrorText(error);
      }
    } catch (_) {
      _sessionError = 'Không kết nối được máy chủ. Bạn vẫn có thể mở ứng dụng.';
    } finally {
      if (mounted) setState(() => _checkingSession = false);
    }
  }

  Future<void> _authenticate({String mode = 'register'}) async {
    final user = await showIonicDialog<ApiUser>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AuthDialog(api: _api, initialMode: mode),
    );
    if (user != null && mounted) {
      setState(() {
        _user = user;
        _sessionError = null;
      });
    }
  }

  Future<void> _signOut() async {
    try {
      await _api.logout();
    } catch (error) {
      _toast(apiErrorText(error));
      return;
    }
    if (!mounted) return;
    _accountEnded();
  }

  void _accountEnded() {
    if (!mounted) return;
    final oldId = _user?.id;
    if (oldId != null) {
      unawaited(DraftStore.clear(oldId).catchError((Object _) {}));
      unawaited(SearchHistoryStore.clear(oldId).catchError((Object _) {}));
    }
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    setState(() {
      _user = null;
      _profileHandle = null;
      _openConversationId = null;
      _openConversationName = null;
      _page = _Page.home;
    });
  }

  Future<void> _compose() async {
    if (_user == null) {
      await _authenticate(mode: 'login');
      if (_user == null || !mounted) return;
    }
    final post = await showIonicDialog<FeedPost>(
      context: context,
      builder: (context) => _ComposeDialog(api: _api, userId: _user!.id),
    );
    if (post == null || !mounted) return;
    _toast('Bài viết đã được lưu.');
    setState(() {
      _page = _Page.home;
      _homeRefreshToken++;
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  void _selectPage(_Page page) {
    if (_page == page && page == _Page.messages) return;
    setState(() {
      _page = page;
      _profileHandle = null;
      _openConversationId = null;
    });
  }

  void _openProfile(String handle) {
    setState(() {
      _page = _Page.profile;
      _profileHandle = handle;
    });
  }

  void _openConversation(String id, String name) {
    setState(() {
      _page = _Page.messages;
      _openConversationId = id;
      _openConversationName = name;
    });
  }

  void _openSettings() => _selectPage(_Page.settings);

  void _profileChanged(ApiUser user) {
    if (!mounted || _user?.id != user.id) return;
    setState(() => _user = user);
  }

  int get _destination => switch (_page) {
    _Page.home => 0,
    _Page.messages => 2,
    _Page.profile => 3,
    _Page.settings => 4,
  };

  Widget _screen() => switch (_page) {
    _Page.home => HomeScreen(
      api: _api,
      user: _user,
      refreshToken: _homeRefreshToken,
      searchController: _homeSearch,
      onAuthenticate: _authenticate,
      onCompose: _compose,
      onOpenProfile: _openProfile,
      onToast: _toast,
    ),
    _Page.messages => MessagesScreen(
      api: _api,
      user: _user,
      conversationId: _openConversationId,
      conversationName: _openConversationName,
      onConversation: _openConversation,
      onAuthenticate: _authenticate,
      onToast: _toast,
    ),
    _Page.profile => ProfileScreen(
      api: _api,
      user: _user,
      handle: _profileHandle,
      onOpenConversation: _openConversation,
      onOpenProfile: _openProfile,
      onProfileChanged: _profileChanged,
      onAuthenticate: _authenticate,
      onToast: _toast,
    ),
    _Page.settings => SettingsScreen(
      key: ValueKey(_user?.id),
      api: _api,
      user: _user,
      onAuthenticate: _authenticate,
      onProfileChanged: _profileChanged,
      themeMode: widget.themeMode,
      onThemeModeChanged: widget.onThemeModeChanged,
      onSignOut: _signOut,
      onSessionEnded: _accountEnded,
      onToast: _toast,
    ),
  };

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final nav = <NavigationDestination>[
          const NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'Trang chủ',
          ),
          const NavigationDestination(
            icon: Icon(Icons.add_circle_outline_rounded),
            selectedIcon: Icon(Icons.add_circle_rounded),
            label: 'Tạo',
          ),
          const NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline_rounded),
            selectedIcon: Icon(Icons.chat_bubble_rounded),
            label: 'Tin nhắn',
          ),
          const NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded),
            label: 'Hồ sơ',
          ),
          const NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings_rounded),
            label: 'Cài đặt',
          ),
        ];
        return Scaffold(
          body: SafeArea(
            child: Row(
              children: [
                if (wide)
                  SizedBox(
                    width: 238,
                    child: _DesktopRail(
                      selectedIndex: _destination,
                      user: _user,
                      onSelect: (index) => _onDestination(index),
                      onCompose: _compose,
                      onSignIn: () => _authenticate(mode: 'login'),
                      onSignOut: _signOut,
                    ),
                  ),
                Expanded(
                  child: Column(
                    children: [
                      const AppUpdateBanner(),
                      PreviewHeartbeat(api: _api, userId: _user?.id),
                      if (_page != _Page.messages ||
                          _openConversationId == null ||
                          _openConversationId!.isEmpty)
                        _TopBar(
                          api: _api,
                          user: _user,
                          busy: _checkingSession,
                          searchController: _page == _Page.home
                              ? _homeSearch
                              : null,
                          onSignIn: () => _authenticate(mode: 'login'),
                          onOpenSettings: _openSettings,
                          onSignOut: _signOut,
                        ),
                      if (_sessionError != null && _user == null)
                        MaterialBanner(
                          content: Text(_sessionError!),
                          leading: const Icon(Icons.cloud_off_outlined),
                          actions: [
                            TextButton(
                              onPressed: _restoreSession,
                              child: const Text('Thử lại'),
                            ),
                          ],
                        ),
                      Expanded(child: _screen()),
                    ],
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar:
              wide ||
                  (_page == _Page.messages &&
                      (_openConversationId?.isNotEmpty ?? false))
              ? null
              : NavigationBar(
                  selectedIndex: _destination,
                  destinations: nav,
                  onDestinationSelected: _onDestination,
                ),
        );
      },
    );
  }

  void _onDestination(int index) {
    if (index == 1) {
      _compose();
      return;
    }
    final page = switch (index) {
      0 => _Page.home,
      2 => _Page.messages,
      3 => _Page.profile,
      _ => _Page.settings,
    };
    _selectPage(page);
  }
}

class _TopBar extends StatelessWidget {
  final IonicApi api;
  const _TopBar({
    required this.api,
    required this.user,
    required this.busy,
    required this.onSignIn,
    required this.onOpenSettings,
    required this.onSignOut,
    this.searchController,
  });

  final HomeSearchController? searchController;
  final ApiUser? user;
  final bool busy;
  final VoidCallback onSignIn;
  final VoidCallback onOpenSettings;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(22, 12, 22, 8),
    child: Row(
      children: [
        if (MediaQuery.sizeOf(context).width < 900) ...[
          Image.asset(
            'assets/ionic-mark.png',
            width: 34,
            height: 34,
            fit: BoxFit.contain,
          ),
          const SizedBox(width: 9),
          Text('Ionic', style: Theme.of(context).textTheme.titleLarge),
        ],
        const Spacer(),
        if (searchController != null)
          ListenableBuilder(
            listenable: searchController!,
            builder: (context, _) => searchController!.compact
                ? IconButton(
                    tooltip: 'Tìm bài viết hoặc tài khoản',
                    onPressed: searchController!.open,
                    icon: const Icon(Icons.search_rounded),
                  )
                : const SizedBox.shrink(),
          ),
        if (busy)
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else if (user == null)
          OutlinedButton.icon(
            onPressed: onSignIn,
            icon: const Icon(Icons.login_rounded),
            label: const Text('Đăng nhập'),
          )
        else
          PopupMenuButton<String>(
            tooltip: 'Tài khoản',
            onSelected: (value) {
              if (value == 'settings') onOpenSettings();
              if (value == 'logout') onSignOut();
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                enabled: false,
                child: Text('@${user!.handle}'),
              ),
              const PopupMenuItem<String>(
                value: 'settings',
                child: Text('Cài đặt'),
              ),
              const PopupMenuItem<String>(
                value: 'logout',
                child: Text('Đăng xuất'),
              ),
            ],
            child: AccountAvatar(
              api: api,
              name: user!.displayName,
              mediaId: user!.avatarMediaId,
            ),
          ),
      ],
    ),
  );
}

class _DesktopRail extends StatelessWidget {
  const _DesktopRail({
    required this.selectedIndex,
    required this.user,
    required this.onSelect,
    required this.onCompose,
    required this.onSignIn,
    required this.onSignOut,
  });

  final int selectedIndex;
  final ApiUser? user;
  final ValueChanged<int> onSelect;
  final VoidCallback onCompose;
  final VoidCallback onSignIn;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 22, 12, 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 14, 30),
          child: Image.asset(
            'assets/ionic-logo-lockup.png',
            width: 155,
            alignment: Alignment.centerLeft,
          ),
        ),
        _railItem(
          context,
          0,
          Icons.home_outlined,
          Icons.home_rounded,
          'Trang chủ',
        ),
        Padding(
          padding: const EdgeInsets.only(top: 17, bottom: 12),
          child: FilledButton.icon(
            onPressed: onCompose,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Đăng bài'),
          ),
        ),
        _railItem(
          context,
          2,
          Icons.chat_bubble_outline_rounded,
          Icons.chat_bubble_rounded,
          'Tin nhắn',
        ),
        _railItem(
          context,
          3,
          Icons.person_outline_rounded,
          Icons.person_rounded,
          'Hồ sơ',
        ),
        _railItem(
          context,
          4,
          Icons.settings_outlined,
          Icons.settings_rounded,
          'Cài đặt',
        ),
        const Spacer(),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user == null ? 'Bản xem thử' : user!.displayName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  user == null
                      ? 'Đăng nhập để lưu bài và trò chuyện.'
                      : '@${user!.handle}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                TextButton(
                  onPressed: user == null ? onSignIn : onSignOut,
                  child: Text(user == null ? 'Đăng nhập' : 'Đăng xuất'),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _railItem(
    BuildContext context,
    int index,
    IconData icon,
    IconData selected,
    String label,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: ListTile(
      selected: selectedIndex == index,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
      leading: Icon(selectedIndex == index ? selected : icon),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      onTap: () => onSelect(index),
    ),
  );
}

class AuthDialog extends StatefulWidget {
  const AuthDialog({required this.api, required this.initialMode, super.key});

  final IonicApi api;
  final String initialMode;

  @override
  State<AuthDialog> createState() => _AuthDialogState();
}

class _AuthDialogState extends State<AuthDialog> {
  final _formKey = GlobalKey<FormState>();
  final _handle = TextEditingController();
  final _name = TextEditingController();
  final _password = TextEditingController();
  late bool _register = widget.initialMode != 'login';
  bool _busy = false;
  bool _connecting = false;
  String? _error;

  @override
  void dispose() {
    _handle.dispose();
    _name.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      setState(() => _connecting = true);
      await widget.api.prepareAuthentication();
      if (!mounted) return;
      setState(() => _connecting = false);
      final user = _register
          ? await widget.api.register(
              _handle.text.trim(),
              _name.text.trim(),
              _password.text,
            )
          : await widget.api.login(_handle.text.trim(), _password.text);
      if (mounted) Navigator.of(context).pop(user);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error =
              _register &&
                  error is IonicApiException &&
                  error.statusCode == 0 &&
                  error.code != 'SERVER_WAKING'
              ? 'Chưa nhận được xác nhận tạo tài khoản. Thông tin vẫn được giữ; bạn có thể thử đăng nhập bằng tên và mật khẩu vừa nhập.'
              : apiErrorText(error),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _connecting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(18),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 470),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _register ? 'Tạo tài khoản' : 'Đăng nhập',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Đóng',
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _register
                    ? 'Tạo tài khoản để đăng bài, theo dõi và nhắn tin.'
                    : 'Đăng nhập để tiếp tục.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 18),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Tạo tài khoản')),
                  ButtonSegment(value: false, label: Text('Đăng nhập')),
                ],
                selected: {_register},
                onSelectionChanged: _busy
                    ? null
                    : (values) => setState(() {
                        _register = values.first;
                        _error = null;
                      }),
              ),
              if (_register) ...[
                const SizedBox(height: 15),
                TextFormField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Tên hiển thị'),
                  validator: (value) => (value?.trim().isNotEmpty ?? false)
                      ? null
                      : 'Nhập tên hiển thị.',
                ),
              ],
              const SizedBox(height: 12),
              TextFormField(
                controller: _handle,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Tên tài khoản',
                  prefixText: '@',
                ),
                validator: (value) {
                  final handle = (value ?? '').trim().toLowerCase();
                  if (!RegExp(r'^[a-z0-9_-]{3,24}$').hasMatch(handle)) {
                    return 'Dùng 3–24 ký tự: chữ không dấu, số, - hoặc _.';
                  }
                  if (_register && handle.contains('admin')) {
                    return 'Tên này được dành riêng.';
                  }
                  if (_register &&
                      RegExp(r'[0-9]').allMatches(handle).length < 3) {
                    return 'Tên tài khoản cần ít nhất 3 chữ số.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              PasswordField(
                controller: _password,
                label: 'Mật khẩu',
                validator: (value) =>
                    (value?.length ?? 0) >= (_register ? 12 : 1)
                    ? null
                    : 'Mật khẩu cần ít nhất 12 ký tự.',
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              if (!_register)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          final recovered = await showIonicDialog<bool>(
                            context: context,
                            barrierDismissible: false,
                            builder: (_) => RecoveryDialog(api: widget.api),
                          );
                          if (recovered == true && mounted) {
                            setState(
                              () => _error =
                                  'Đã đặt lại mật khẩu. Đăng nhập bằng mật khẩu mới.',
                            );
                          }
                        },
                  child: const Text('Quên mật khẩu?'),
                ),
              const SizedBox(height: 17),
              if (_busy)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    _connecting
                        ? 'Đang kết nối máy chủ, có thể mất khoảng một phút…'
                        : 'Đang xử lý yêu cầu…',
                  ),
                ),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(_register ? 'Tạo tài khoản' : 'Đăng nhập'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ComposeDialog extends StatefulWidget {
  const _ComposeDialog({required this.api, required this.userId});
  final IonicApi api;
  final String userId;

  @override
  State<_ComposeDialog> createState() => _ComposeDialogState();
}

class _ComposeDialogState extends State<_ComposeDialog> {
  late final _publication = MediaPublication(widget.api);
  String? _progress;
  final _text = TextEditingController();
  IonicMediaDraft _media = const IonicMediaDraft();
  bool _mediaBusy = false;
  bool _publishing = false;
  String? _error;
  Timer? _draftDelay;
  bool _published = false;
  String? _draftNotice;

  @override
  void initState() {
    super.initState();
    _restoreDraft();
    _text.addListener(_saveDraftSoon);
  }

  Future<void> _restoreDraft() async {
    try {
      final text = await DraftStore.read(widget.userId);
      if (mounted && _text.text.isEmpty && text != null) {
        _text.text = text;
        setState(
          () => _draftNotice =
              'Đã khôi phục phần chữ của bản nháp. Ảnh và voice cần chọn lại.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _draftNotice = 'Không tải được bản nháp trên thiết bị này.',
        );
      }
    }
  }

  void _saveDraftSoon() {
    _draftDelay?.cancel();
    _draftDelay = Timer(const Duration(milliseconds: 500), () async {
      try {
        await DraftStore.save(widget.userId, _text.text);
      } catch (_) {
        if (mounted) {
          setState(
            () => _draftNotice = 'Không lưu được bản nháp trên thiết bị này.',
          );
        }
      }
    });
  }

  @override
  void dispose() {
    _draftDelay?.cancel();
    if (!_published) {
      unawaited(
        DraftStore.save(widget.userId, _text.text).catchError((Object _) {}),
      );
    }
    unawaited(_publication.dispose());
    _text.dispose();
    super.dispose();
  }

  Future<void> _publish() async {
    final body = _text.text.trim();
    if (_publishing || _mediaBusy || body.isEmpty || body.length > 280) return;
    setState(() {
      _publishing = true;
      _error = null;
    });
    try {
      final staged = await _publication.prepare(body, _media, (value) {
        if (mounted) setState(() => _progress = value);
      });
      final post = await widget.api.createPost(
        body,
        attachmentIds: staged,
        clientPublishId: _publication.id,
      );
      _published = true;
      _draftDelay?.cancel();
      try {
        await DraftStore.clear(widget.userId);
      } catch (_) {
        /* Publication already committed. */
      }
      if (mounted) Navigator.of(context).pop(post);
    } catch (error) {
      if (mounted) setState(() => _error = apiErrorText(error));
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_publishing,
    child: AlertDialog(
      title: const Text('Tạo bài viết'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_draftNotice != null)
                Text(
                  _draftNotice!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              TextField(
                controller: _text,
                readOnly: _publishing,
                autofocus: true,
                maxLength: 280,
                onChanged: (_) => setState(() {}),
                maxLines: 7,
                minLines: 4,
                decoration: const InputDecoration(
                  hintText: 'Bạn đang nghĩ gì?',
                  border: InputBorder.none,
                  counterText: '',
                ),
              ),
              if (_publishing && _progress != null) Text(_progress!),
              MediaComposerControls(
                enabled: !_publishing,
                onChanged: (value) => setState(() => _media = value),
                onBusyChanged: (value) => setState(() => _mediaBusy = value),
              ),
              if (_error != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        Text(
          '${_text.text.length}/280',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        TextButton(
          onPressed: _publishing || _mediaBusy
              ? null
              : () => Navigator.of(context).pop(),
          child: const Text('Hủy'),
        ),
        FilledButton(
          onPressed:
              _publishing ||
                  _mediaBusy ||
                  _text.text.trim().isEmpty ||
                  _text.text.length > 280
              ? null
              : _publish,
          child: _publishing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Đăng bài'),
        ),
      ],
    ),
  );
}
