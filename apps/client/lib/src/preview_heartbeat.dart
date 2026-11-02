import 'dart:async';
import 'package:flutter/material.dart';
import 'ionic_api.dart';
import 'client_preferences.dart';

/// Technical foreground connectivity only; no synthetic product events.
class PreviewHeartbeat extends StatefulWidget {
  const PreviewHeartbeat({
    required this.api,
    required this.userId,
    this.now,
    super.key,
  });
  final DateTime Function()? now;
  final IonicApi api;
  final String? userId;
  @override
  State<PreviewHeartbeat> createState() => _PreviewHeartbeatState();
}

class _PreviewHeartbeatState extends State<PreviewHeartbeat>
    with WidgetsBindingObserver {
  Timer? _timer;
  int _epoch = 0;
  bool _allowed = false, _busy = false;
  DateTime? _last;
  DateTime _now() => widget.now?.call() ?? DateTime.now();
  String? _token;
  Future<void>? _releaseWork;
  bool _configuring = false, _configureAgain = false;
  late bool _savedDataSaver;
  bool get _foreground =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  @override
  void initState() {
    super.initState();
    _savedDataSaver = clientPreferences.dataSaver;
    WidgetsBinding.instance.addObserver(this);
    clientPreferences.addListener(_preferences);
    _configure();
  }

  @override
  void didUpdateWidget(covariant PreviewHeartbeat oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId) {
      _epoch++;
      _stop();
      _last = null;
      _configure();
    }
  }

  @override
  void dispose() {
    _epoch++;
    _stop();
    WidgetsBinding.instance.removeObserver(this);
    clientPreferences.removeListener(_preferences);
    super.dispose();
  }

  void _stop() {
    _timer?.cancel();
    _allowed = false;
    final token = _token;
    _token = null;
    if (token != null) {
      _releaseWork = widget.api.releaseHeartbeat(token).catchError((_) {});
    }
  }

  void _preferences() {
    if (_savedDataSaver == clientPreferences.dataSaver) return;
    _savedDataSaver = clientPreferences.dataSaver;
    if (clientPreferences.dataSaver) {
      _epoch++;
      _stop();
    } else {
      _configure();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _configure();
    } else {
      _epoch++;
      _stop();
    }
  }

  Future<void> _configure() async {
    if (_configuring) {
      _configureAgain = true;
      return;
    }
    _configuring = true;
    try {
      await _configureOnce();
    } finally {
      _configuring = false;
      if (_configureAgain && mounted) {
        _configureAgain = false;
        unawaited(_configure());
      }
    }
  }

  Future<void> _configureOnce() async {
    final epoch = ++_epoch;
    _timer?.cancel();
    _allowed = false;
    if (widget.userId == null || !_foreground || clientPreferences.dataSaver) {
      return;
    }
    try {
      if (!clientPreferences.preferencesAvailable) {
        await clientPreferences.load();
      }
      if (!mounted ||
          epoch != _epoch ||
          !clientPreferences.preferencesAvailable ||
          clientPreferences.dataSaver ||
          !_foreground ||
          widget.userId == null) {
        return;
      }
      await _releaseWork;
      if (!mounted || epoch != _epoch || !_foreground) return;
      final result = await widget.api.claimHeartbeat(_token);
      if (!mounted || epoch != _epoch || !_foreground) {
        final token = result['leaseToken'] as String?;
        if (token != null) {
          unawaited(widget.api.releaseHeartbeat(token).catchError((_) {}));
        }
        return;
      }
      if (result['enabled'] != true) return;
      _token = result['leaseToken'] as String?;
      _allowed = true;
      // The capability request itself is inbound traffic; no immediate extra ping.
      _last = _now();
      _timer = Timer.periodic(const Duration(minutes: 10), (_) => _ping());
    } catch (_) {
      /* No tight retry loop or background work on preview failures. */
    }
  }

  Future<void> _ping() async {
    if (_busy ||
        !_allowed ||
        !_foreground ||
        widget.userId == null ||
        clientPreferences.dataSaver) {
      return;
    }
    if (_last != null &&
        _now().difference(_last!) < const Duration(minutes: 10)) {
      return;
    }
    _last = _now();
    _busy = true;
    final epoch = _epoch;
    try {
      await widget.api.heartbeat(_token);
    } on IonicApiException catch (e) {
      if (epoch == _epoch && (e.statusCode == 401 || e.statusCode == 403)) {
        _allowed = false;
        _timer?.cancel();
      }
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
