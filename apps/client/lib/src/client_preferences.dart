import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

final clientPreferences = ClientPreferences();

class IonicTextScaler extends TextScaler {
  const IonicTextScaler(this.system, this.factor);
  final TextScaler system;
  final double factor;
  @override
  double scale(double fontSize) => system.scale(fontSize) * factor;
  @override
  double get textScaleFactor => scale(14) / 14;
}

class ClientPreferences extends ChangeNotifier {
  final _storage = const FlutterSecureStorage();
  double textScale = 1;
  bool reducedMotion = false;
  bool dataSaver = false;
  bool preferencesAvailable = false;
  Future<void>? _loadFuture;
  Future<void> _pending = Future.value();
  Future<void> load() => _loadFuture ??= _load();
  Future<void> _load() async {
    try {
      final raw = await _storage.read(key: 'ionic_display_preferences');
      preferencesAvailable = true;
      if (raw == null) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      textScale = ((data['textScale'] as num?)?.toDouble() ?? 1).clamp(.9, 1.5);
      reducedMotion = data['reducedMotion'] == true;
      dataSaver = data['dataSaver'] == true;
      notifyListeners();
    } catch (_) {
      preferencesAvailable = false;
      /* Keep usable device defaults if storage is unavailable. */
    }
  }

  Future<void> update({double? scale, bool? motion, bool? saver}) async {
    final operation = _pending.then((_) async {
      await load();
      await _write(scale: scale, motion: motion, saver: saver);
    });
    _pending = operation.catchError((Object _) {});
    await operation;
  }

  Future<void> _write({double? scale, bool? motion, bool? saver}) async {
    final nextScale = (scale ?? textScale).clamp(.9, 1.5);
    final nextMotion = motion ?? reducedMotion, nextSaver = saver ?? dataSaver;
    await _storage.write(
      key: 'ionic_display_preferences',
      value: jsonEncode({
        'textScale': nextScale,
        'reducedMotion': nextMotion,
        'dataSaver': nextSaver,
      }),
    );
    textScale = nextScale;
    reducedMotion = nextMotion;
    dataSaver = nextSaver;
    preferencesAvailable = true;
    notifyListeners();
  }
}
