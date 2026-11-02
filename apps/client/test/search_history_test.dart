import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ionic_client/src/ionic_api.dart';
import 'package:ionic_client/src/screens.dart';
import 'package:ionic_client/src/search_history_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test('Search history is account scoped, deduplicated and bounded', () async {
    await SearchHistoryStore.add('a', 'Mèo');
    await SearchHistoryStore.add('b', 'Riêng tư');
    await SearchHistoryStore.add('a', 'mèo');
    expect(await SearchHistoryStore.read('a'), ['mèo']);
    expect(await SearchHistoryStore.read('b'), ['Riêng tư']);
    for (var i = 0; i < 25; i++) {
      await SearchHistoryStore.add('a', 'Tìm $i');
    }
    final items = await SearchHistoryStore.read('a');
    expect(items.length, 20);
    expect(items.first, 'Tìm 24');
    await SearchHistoryStore.remove('a', 'Tìm 24');
    expect(await SearchHistoryStore.read('a'), isNot(contains('Tìm 24')));
    expect(await SearchHistoryStore.read('b'), ['Riêng tư']);
  });
  test(
    'Expired, future and invalid entries are physically removed on read',
    () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      FlutterSecureStorage.setMockInitialValues({
        'ionic_search_history_a': jsonEncode([
          {
            'query': 'Hết hạn',
            'at': now - const Duration(days: 8).inMilliseconds,
          },
          {'query': 'Tương lai', 'at': now + 100000},
          {'query': 'x', 'at': now},
          {'query': 'Hợp lệ', 'at': now},
        ]),
      });
      expect(await SearchHistoryStore.read('a'), ['Hợp lệ']);
      final saved = await const FlutterSecureStorage().read(
        key: 'ionic_search_history_a',
      );
      expect(saved, isNot(contains('Hết hạn')));
      final pending = SearchHistoryStore.add('a', 'Chờ lưu');
      await SearchHistoryStore.clear('a');
      await pending;
      expect(await SearchHistoryStore.read('a'), isEmpty);
    },
  );
  testWidgets('Typing is not saved; submitting and deleting history work', (
    tester,
  ) async {
    final api = IonicApi(
      baseUrl: 'http://local/api/v1',
      client: MockClient(
        (_) async => http.Response(
          '{"items":[]}',
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeScreen(
            api: api,
            user: const ApiUser(
              id: 'a',
              handle: 'user123',
              displayName: 'Viewer',
            ),
            refreshToken: 0,
            onAuthenticate: ({required mode}) async {},
            onCompose: () {},
            onOpenProfile: (_) {},
            onToast: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Mèo dễ thương');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(
      await tester.runAsync(
        () => const FlutterSecureStorage().read(key: 'ionic_search_history_a'),
      ),
      isNull,
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(
      await tester.runAsync(
        () => const FlutterSecureStorage().read(key: 'ionic_search_history_a'),
      ),
      contains('Mèo dễ thương'),
    );
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.text('Tìm kiếm gần đây'), findsOneWidget);
    await tester.tap(find.byTooltip('Xóa tìm kiếm Mèo dễ thương'));
    await tester.pumpAndSettle();
    expect(await tester.runAsync(() => SearchHistoryStore.read('a')), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
