import 'dart:async';
import 'package:flutter/material.dart';
import 'app_update_manifest.dart';
import 'app_update_platform.dart';
import 'client_preferences.dart';

final appUpdates = AppUpdates();

class AppUpdates extends ChangeNotifier {
  AppUpdates() {
    clientPreferences.addListener(_preferencesChanged);
  }
  bool _automatic = false;
  void _preferencesChanged() {
    if (_automatic && clientPreferences.dataSaver) platform.cancel();
  }

  @override
  void dispose() {
    clientPreferences.removeListener(_preferencesChanged);
    platform.cancel();
    super.dispose();
  }

  final platform = AndroidUpdates();
  AndroidRelease? available;
  String? readyPath, error;
  double progress = 0;
  bool checking = false,
      downloading = false,
      installing = false,
      dismissed = false,
      _pendingInstall = false,
      _foreground = true;
  DateTime? _lastCheck;
  Future<void> check({bool force = false}) async {
    if (!platform.supported ||
        checking ||
        downloading ||
        installing ||
        (!force &&
            _lastCheck != null &&
            DateTime.now().difference(_lastCheck!) <
                const Duration(hours: 6))) {
      return;
    }
    checking = true;
    _lastCheck = DateTime.now();
    if (force) dismissed = false;
    notifyListeners();
    try {
      final next = await platform.check();
      if (next?.sha256 != available?.sha256) readyPath = null;
      available = next;
      _lastCheck = DateTime.now();
      error = null;
    } catch (_) {
      if (force) error = 'Chưa kiểm tra được bản cập nhật. Vui lòng thử lại.';
    } finally {
      checking = false;
      notifyListeners();
    }
    await clientPreferences.load();
    if (available != null &&
        clientPreferences.preferencesAvailable &&
        readyPath == null &&
        _foreground &&
        !clientPreferences.dataSaver &&
        await platform.unmetered()) {
      unawaited(download(automatic: true));
    }
  }

  Future<void> download({bool automatic = false}) async {
    final release = available;
    if (release == null || downloading) return;
    downloading = true;
    _automatic = automatic;
    error = null;
    progress = 0;
    notifyListeners();
    try {
      readyPath = await platform.download(release, (p) {
        progress = p;
        notifyListeners();
      });
    } catch (_) {
      if (_foreground && !(_automatic && clientPreferences.dataSaver)) {
        error =
            'Chưa tải được bản cập nhật. Tài khoản và dữ liệu vẫn được giữ nguyên.';
      }
    } finally {
      downloading = false;
      _automatic = false;
      notifyListeners();
    }
  }

  Future<void> install() async {
    if (readyPath == null || installing) return;
    installing = true;
    notifyListeners();
    try {
      _pendingInstall =
          await platform.install(readyPath!) == 'permission_required';
      error = _pendingInstall
          ? 'Cho phép Ionic cài bản cập nhật trong cài đặt Android, rồi quay lại ứng dụng.'
          : null;
    } catch (_) {
      error = 'Không mở được bản cập nhật. Hãy thử tải lại.';
      readyPath = null;
    } finally {
      installing = false;
    }
    notifyListeners();
  }

  Future<void> lifecycle(AppLifecycleState state) async {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      platform.cancel();
      return;
    }
    if (_pendingInstall) {
      _pendingInstall = false;
      if (await platform.canInstall()) {
        await install();
        return;
      }
    }
    await check();
    if (available != null &&
        clientPreferences.preferencesAvailable &&
        readyPath == null &&
        !downloading &&
        !clientPreferences.dataSaver &&
        await platform.unmetered()) {
      unawaited(download(automatic: true));
    }
  }

  void dismiss() {
    dismissed = true;
    notifyListeners();
  }
}

class AppUpdateBanner extends StatefulWidget {
  const AppUpdateBanner({super.key});
  @override
  State<AppUpdateBanner> createState() => _AppUpdateBannerState();
}

class _AppUpdateBannerState extends State<AppUpdateBanner>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(appUpdates.check());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(appUpdates.lifecycle(state));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: appUpdates,
    builder: (context, _) {
      final update = appUpdates.available;
      if (update == null || appUpdates.dismissed) {
        return const SizedBox.shrink();
      }
      return Material(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.system_update_alt_rounded, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      appUpdates.downloading
                          ? 'Đang tải Ionic ${update.version} · ${(appUpdates.progress * 100).round()}%'
                          : appUpdates.readyPath != null
                          ? 'Ionic ${update.version} đã sẵn sàng'
                          : 'Có bản Ionic ${update.version} mới',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  if (!appUpdates.downloading)
                    TextButton(
                      onPressed: appUpdates.readyPath != null
                          ? appUpdates.install
                          : appUpdates.download,
                      child: Text(
                        appUpdates.readyPath != null
                            ? 'Cập nhật'
                            : 'Tải bản mới',
                      ),
                    ),
                  IconButton(
                    tooltip: 'Để sau',
                    onPressed: appUpdates.dismiss,
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              ),
              if (appUpdates.downloading)
                LinearProgressIndicator(value: appUpdates.progress),
              if (appUpdates.error != null)
                Text(
                  appUpdates.error!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
        ),
      );
    },
  );
}

class AppUpdateSettings extends StatelessWidget {
  const AppUpdateSettings({super.key});
  @override
  Widget build(BuildContext context) => !appUpdates.platform.supported
      ? const SizedBox.shrink()
      : AnimatedBuilder(
          animation: appUpdates,
          builder: (context, _) => ListTile(
            leading: const Icon(Icons.system_update_outlined),
            title: const Text('Cập nhật Ionic'),
            subtitle: const Text(
              'Tự kiểm tra khi mở app. Tải tự động trên mạng không giới hạn khi tắt tiết kiệm dữ liệu. Android yêu cầu xác nhận cài đặt.',
            ),
            trailing: TextButton(
              onPressed: appUpdates.checking
                  ? null
                  : () async {
                      await appUpdates.check(force: true);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            appUpdates.error ??
                                (appUpdates.available == null
                                    ? 'Bạn đang dùng phiên bản mới nhất.'
                                    : 'Bản cập nhật đã hiển thị ở đầu ứng dụng.'),
                          ),
                        ),
                      );
                    },
              child: Text(appUpdates.checking ? 'Đang kiểm tra…' : 'Kiểm tra'),
            ),
          ),
        );
}
