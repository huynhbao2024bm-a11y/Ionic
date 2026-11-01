import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ionic_client/src/feed_attention.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Native geometry and timer collect foreground bands and stop on lifecycle interruption',
    (tester) async {
      final viewport = GlobalKey();
      final calls = <List<Map<String, String>>>[];
      final controller = FeedAttentionController(
        viewportKey: viewport,
        isActive: () => true,
        send: (items) async {
          calls.add(items);
          return true;
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              key: viewport,
              width: 300,
              height: 250,
              child: FeedAttentionTarget(
                receiptId: 'synthetic-native-receipt',
                controller: controller,
                child: const SizedBox(
                  width: 280,
                  height: 180,
                  child: Text('Foreground public content'),
                ),
              ),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(seconds: 6));
      await tester.pump();
      expect(calls, isNotEmpty);
      expect(
        calls
            .expand((e) => e)
            .every(
              (e) =>
                  e.length == 2 && e['receiptId'] == 'synthetic-native-receipt',
            ),
        isTrue,
      );
      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      final before = calls.length;
      await Future<void>.delayed(const Duration(seconds: 3));
      await tester.pump();
      expect(calls.length, before);
      controller.dispose();
      await tester.pumpWidget(const SizedBox());
    },
  );
}
