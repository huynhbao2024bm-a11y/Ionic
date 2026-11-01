import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'ionic_api.dart';

/// Only accumulated in memory; the API receives a coarse band, never raw time.
class AttentionAccumulator {
  int activeMs = 0;
  bool _previousActive = false;
  String? get band => activeMs >= 20000
      ? 'long'
      : activeMs >= 8000
      ? 'read'
      : activeMs >= 3000
      ? 'short'
      : activeMs >= 1000
      ? 'peek'
      : null;
  void sample({required int elapsedMs, required bool active}) {
    if (active && _previousActive && elapsedMs > 0 && elapsedMs <= 2000) {
      activeMs = math.min(45000, activeMs + elapsedMs);
    }
    _previousActive = active;
  }

  void interrupt() {
    _previousActive = false;
  }
}

double visiblePostFraction(Rect post, Rect viewport) {
  if (post.isEmpty || viewport.isEmpty || !post.overlaps(viewport)) return 0;
  final visible = post.intersect(viewport);
  final denominator =
      math.min(post.width, viewport.width) *
      math.min(post.height, viewport.height);
  return denominator <= 0
      ? 0
      : (visible.width * visible.height / denominator).clamp(0, 1);
}

class _AttentionTarget {
  _AttentionTarget(this.key);
  final GlobalKey key;
  final value = AttentionAccumulator();
  String? queuedBand;
  bool disabled = false;
}

class FeedAttentionController with WidgetsBindingObserver {
  FeedAttentionController({
    required this.viewportKey,
    required this.isActive,
    required this.send,
    this.clockMs,
  }) {
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }
  final GlobalKey viewportKey;
  final bool Function() isActive;
  final Future<bool> Function(List<Map<String, String>>) send;
  final int Function()? clockMs;
  int get _nowMs => clockMs?.call() ?? _clock.elapsedMilliseconds;
  final _targets = <String, _AttentionTarget>{},
      _pending = <String, String>{},
      _attempts = <String, int>{};
  final _clock = Stopwatch()..start();
  Timer? _ticker, _flushTimer;
  int _lastMs = 0, _generation = 0;
  bool _foreground = true, _disposed = false, _sending = false;

  void register(String receiptId, GlobalKey key) {
    if (_disposed) return;
    _targets[receiptId] = _AttentionTarget(key);
    _start();
  }

  void unregister(String receiptId, GlobalKey key) {
    if (_targets[receiptId]?.key == key) _targets.remove(receiptId);
    if (_targets.isEmpty) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  void _start() {
    if (!_foreground || _disposed || _targets.isEmpty || _ticker != null) {
      return;
    }
    _lastMs = _nowMs;
    _ticker = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _sample(),
    );
  }

  Rect? _rect(GlobalKey key) {
    final object = key.currentContext?.findRenderObject();
    if (object is! RenderBox || !object.attached || !object.hasSize) {
      return null;
    }
    return object.localToGlobal(Offset.zero) & object.size;
  }

  void _sample() {
    if (_disposed) return;
    final now = _nowMs, delta = now - _lastMs;
    _lastMs = now;
    final active = _foreground && isActive(),
        viewport = active ? _rect(viewportKey) : null;
    for (final entry in _targets.entries) {
      final t = entry.value, box = active ? _rect(t.key) : null;
      t.value.sample(
        elapsedMs: delta,
        active:
            !t.disabled &&
            box != null &&
            viewport != null &&
            visiblePostFraction(box, viewport) >= .5,
      );
      final band = t.value.band;
      if (!t.disabled && band != null && band != t.queuedBand) {
        t.queuedBand = band;
        if (!_pending.containsKey(entry.key) && _pending.length >= 64) {
          _pending.remove(_pending.keys.first);
        }
        _pending[entry.key] = band;
      }
    }
    if (active) _scheduleFlush();
  }

  void _scheduleFlush() {
    if (_pending.isEmpty ||
        _flushTimer != null ||
        _sending ||
        !_foreground ||
        _disposed) {
      return;
    }
    _flushTimer = Timer(const Duration(seconds: 2), () {
      _flushTimer = null;
      _flush();
    });
  }

  Future<void> _flush() async {
    if (_disposed ||
        !_foreground ||
        !isActive() ||
        _pending.isEmpty ||
        _sending) {
      return;
    }
    final generation = _generation,
        batch = Map<String, String>.fromEntries(_pending.entries.take(20));
    _sending = true;
    try {
      final enabled = await send(
        batch.entries
            .map((e) => {'receiptId': e.key, 'band': e.value})
            .toList(),
      );
      if (_disposed || generation != _generation) return;
      if (!enabled) {
        _pending.clear();
        for (final t in _targets.values) {
          t.disabled = true;
          t.value.interrupt();
        }
      } else {
        for (final entry in batch.entries) {
          if (_pending[entry.key] == entry.value) _pending.remove(entry.key);
          _attempts.remove(entry.key);
        }
      }
    } catch (error) {
      if (_disposed || generation != _generation) return;
      final terminal =
          error is IonicApiException &&
          const [400, 401, 403, 404].contains(error.statusCode);
      for (final id in batch.keys) {
        final attempts = (_attempts[id] ?? 0) + 1;
        _attempts[id] = attempts;
        if (terminal || attempts >= 4) {
          _pending.remove(id);
          _attempts.remove(id);
        }
      }
    } finally {
      if (!_disposed && generation == _generation) {
        _sending = false;
        _scheduleFlush();
      }
    }
  }

  void reset() {
    _generation++;
    _pending.clear();
    _targets.clear();
    _attempts.clear();
    _sending = false;
    _flushTimer?.cancel();
    _flushTimer = null;
    _ticker?.cancel();
    _ticker = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    for (final t in _targets.values) {
      t.value.interrupt();
    }
    if (!_foreground) {
      _ticker?.cancel();
      _ticker = null;
      _flushTimer?.cancel();
      _flushTimer = null;
    } else {
      _start();
      _scheduleFlush();
    }
  }

  void dispose() {
    _disposed = true;
    reset();
    WidgetsBinding.instance.removeObserver(this);
    _clock.stop();
  }
}

class FeedAttentionTarget extends StatefulWidget {
  const FeedAttentionTarget({
    required this.receiptId,
    required this.controller,
    required this.child,
    super.key,
  });
  final String? receiptId;
  final FeedAttentionController controller;
  final Widget child;
  @override
  State<FeedAttentionTarget> createState() => _FeedAttentionTargetState();
}

class _FeedAttentionTargetState extends State<FeedAttentionTarget> {
  final _key = GlobalKey();
  @override
  void initState() {
    super.initState();
    if (widget.receiptId != null) {
      widget.controller.register(widget.receiptId!, _key);
    }
  }

  @override
  void didUpdateWidget(covariant FeedAttentionTarget old) {
    super.didUpdateWidget(old);
    if (old.receiptId != widget.receiptId ||
        old.controller != widget.controller) {
      if (old.receiptId != null) {
        old.controller.unregister(old.receiptId!, _key);
      }
      if (widget.receiptId != null) {
        widget.controller.register(widget.receiptId!, _key);
      }
    }
  }

  @override
  void dispose() {
    if (widget.receiptId != null) {
      widget.controller.unregister(widget.receiptId!, _key);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SizedBox(key: _key, child: widget.child);
}
