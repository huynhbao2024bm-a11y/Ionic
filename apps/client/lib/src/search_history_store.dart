import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Explicit searches only; device-local, account-scoped and never feed telemetry.
class SearchHistoryStore {
  static const _storage = FlutterSecureStorage();
  static Future<void> _pending = Future.value();
  static const maximumEntries = 20;
  static const retention = Duration(days: 7);
  static String _key(String userId) => 'ionic_search_history_$userId';
  static Future<T> _queue<T>(Future<T> Function() work) {
    final result = _pending.then((_) => work());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  static Future<List<({String query, int at})>> _read(String userId) async {
    final raw = await _storage.read(key: _key(userId));
    if (raw == null) return [];
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      final items = jsonDecode(raw);
      if (items is! List) return [];
      final seen = <String>{};
      return items
          .whereType<Map<String, dynamic>>()
          .where((i) => i['query'] is String && i['at'] is int)
          .map(
            (i) => (query: (i['query'] as String).trim(), at: i['at'] as int),
          )
          .where(
            (i) =>
                i.query.length >= 2 &&
                i.query.length <= 80 &&
                i.at <= now &&
                i.at > now - retention.inMilliseconds &&
                seen.add(i.query.toLowerCase()),
          )
          .take(maximumEntries)
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _write(
    String userId,
    List<({String query, int at})> items,
  ) => items.isEmpty
      ? _storage.delete(key: _key(userId))
      : _storage.write(
          key: _key(userId),
          value: jsonEncode(
            items.map((i) => {'query': i.query, 'at': i.at}).toList(),
          ),
        );
  static Future<List<String>> read(String userId) => _queue(() async {
    final items = await _read(userId);
    await _write(userId, items);
    return items.map((i) => i.query).toList();
  });
  static Future<void> add(String userId, String value) => _queue(() async {
    final query = value.trim();
    if (query.length < 2 || query.length > 80) return;
    final items = await _read(userId);
    await _write(
      userId,
      [
        (query: query, at: DateTime.now().millisecondsSinceEpoch),
        ...items.where((i) => i.query.toLowerCase() != query.toLowerCase()),
      ].take(maximumEntries).toList(),
    );
  });
  static Future<void> remove(String userId, String query) => _queue(
    () async => _write(
      userId,
      (await _read(
        userId,
      )).where((i) => i.query.toLowerCase() != query.toLowerCase()).toList(),
    ),
  );
  static Future<void> clear(String userId) =>
      _queue(() => _storage.delete(key: _key(userId)));
}
