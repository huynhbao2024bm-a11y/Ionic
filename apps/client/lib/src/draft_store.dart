import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class DraftStore {
  static const _storage = FlutterSecureStorage();
  static Future<void> _pending = Future.value();
  static Future<String?> read(String userId) async {
    await _pending;
    return _storage.read(key: 'ionic_post_draft_$userId');
  }

  static Future<void> save(String userId, String text) {
    final operation = _pending.then((_) async {
      if (text.trim().isEmpty) {
        await _storage.delete(key: 'ionic_post_draft_$userId');
      } else {
        await _storage.write(key: 'ionic_post_draft_$userId', value: text);
      }
    });
    _pending = operation.catchError((Object _) {});
    return operation;
  }

  static Future<void> clear(String userId) => save(userId, '');
}
