import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ionic_client/src/feed_attention.dart';

void main() {
  test('Foreground attention is coarse, bounded and interrupted', () {
    final a = AttentionAccumulator();
    a.sample(elapsedMs: 1000, active: false);
    expect(a.band, isNull);
    a.sample(elapsedMs: 500, active: true);
    expect(a.activeMs, 0);
    a.sample(elapsedMs: 1000, active: true);
    expect(a.band, 'peek');
    a.sample(elapsedMs: 60000, active: true);
    expect(a.activeMs, 1000);
    a.interrupt();
    a.sample(elapsedMs: 1000, active: true);
    expect(a.activeMs, 1000);
    for (var i = 0; i < 100; i++) {
      a.sample(elapsedMs: 1000, active: true);
    }
    expect(a.activeMs, 45000);
    expect(a.band, 'long');
  });
  test('Oversized cards qualify by visible viewport, not total card size', () {
    expect(
      visiblePostFraction(
        const Rect.fromLTWH(0, 0, 300, 1000),
        const Rect.fromLTWH(0, 0, 300, 400),
      ),
      1,
    );
    expect(
      visiblePostFraction(
        const Rect.fromLTWH(0, 500, 300, 200),
        const Rect.fromLTWH(0, 0, 300, 400),
      ),
      0,
    );
    expect(
      visiblePostFraction(
        const Rect.fromLTWH(0, 300, 300, 200),
        const Rect.fromLTWH(0, 0, 300, 400),
      ),
      .5,
    );
  });
  testWidgets(
    'Only foreground visible receipts emit; route/background/account interruptions stop collection',
    (tester) async {
      final viewport = GlobalKey();
      var now = 0, active = true;
      final sent = <List<Map<String, String>>>[];
      final controller = FeedAttentionController(
        viewportKey: viewport,
        isActive: () => active,
        clockMs: () => now,
        send: (batch) async {
          sent.add(batch);
          return true;
        },
      );
      Widget page(String receipt) => MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            height: 200,
            child: ListView(
              key: viewport,
              children: [
                FeedAttentionTarget(
                  receiptId: receipt,
                  controller: controller,
                  child: const SizedBox(
                    height: 160,
                    child: Text('Public post'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      Future<void> tick(int steps) async {
        for (var i = 0; i < steps; i++) {
          now += 500;
          await tester.pump(const Duration(milliseconds: 500));
        }
      }

      await tester.pumpWidget(page('receipt-one'));
      await tick(12);
      expect(sent, isNotEmpty);
      expect(
        sent
            .expand((e) => e)
            .every(
              (e) =>
                  e.keys.toSet().containsAll({'receiptId', 'band'}) &&
                  e.length == 2,
            ),
        isTrue,
      );
      expect(
        sent.expand((e) => e).every((e) => e['receiptId'] == 'receipt-one'),
        isTrue,
      );
      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      final before = sent.length;
      await tick(60);
      expect(sent.length, before);
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      active = false;
      await tick(30);
      expect(sent.length, before);
      controller.reset();
      active = true;
      await tester.pumpWidget(page('receipt-two'));
      await tick(12);
      expect(
        sent
            .skip(before)
            .expand((e) => e)
            .every((e) => e['receiptId'] == 'receipt-two'),
        isTrue,
      );
      controller.dispose();
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('A paused server disables old receipt collection', (
    tester,
  ) async {
    final viewport = GlobalKey();
    var now = 0, calls = 0;
    final controller = FeedAttentionController(
      viewportKey: viewport,
      isActive: () => true,
      clockMs: () => now,
      send: (batch) async {
        calls++;
        return false;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          key: viewport,
          child: FeedAttentionTarget(
            receiptId: 'owned-receipt',
            controller: controller,
            child: const SizedBox(width: 200, height: 200),
          ),
        ),
      ),
    );
    for (var i = 0; i < 60; i++) {
      now += 500;
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(calls, 1);
    controller.dispose();
    await tester.pumpWidget(const SizedBox());
  });
}
