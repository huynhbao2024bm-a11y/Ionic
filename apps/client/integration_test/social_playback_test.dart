import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ionic_client/src/voice_player.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Native WAV loads, advances, pauses and replays under release network policy',
    (tester) async {
      // Debug's permissive development override must never hide this regression.
      expect(
        kDebugMode,
        false,
        reason: 'Run --profile with the strict main manifest.',
      );
      final wave = tone();
      var attempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VoicePlayer(
              durationMs: 2500,
              load: () async {
                if (++attempts == 1) {
                  throw StateError('Simulated temporary download failure');
                }
                return wave;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Phát âm thanh'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Không tải được'), findsOneWidget);
      await tester.tap(find.byTooltip('Phát âm thanh'));
      Future<void> waitFor(bool Function() condition) async {
        final deadline = DateTime.now().add(const Duration(seconds: 25));
        while (!condition() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 150));
        }
        expect(condition(), true);
      }

      await waitFor(
        () =>
            find.byType(Slider).evaluate().isNotEmpty &&
            tester.widget<Slider>(find.byType(Slider)).value > 150,
      );
      expect(attempts, 2);
      expect(find.textContaining('Không phát được'), findsNothing);
      await tester.tap(find.byTooltip('Tạm dừng âm thanh'));
      await tester.pump();
      expect(find.byTooltip('Phát âm thanh'), findsOneWidget);
      await tester.tap(find.byTooltip('Phát âm thanh'));
      await waitFor(
        () => tester.widget<Slider>(find.byType(Slider)).value >= 2400,
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byTooltip('Phát âm thanh'));
      await waitFor(() {
        final value = tester.widget<Slider>(find.byType(Slider)).value;
        return value > 100 && value < 2200;
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

Uint8List tone() {
  const frames = 16000 * 2500 ~/ 1000;
  final bytes = Uint8List(44 + frames * 2), data = ByteData(44 + frames * 2);
  void text(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, value.codeUnits);
  text(0, 'RIFF');
  text(8, 'WAVE');
  text(12, 'fmt ');
  text(36, 'data');
  data.setUint32(4, bytes.length - 8, Endian.little);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  data.setUint32(40, frames * 2, Endian.little);
  for (var i = 0; i < frames; i++) {
    data.setInt16(
      44 + i * 2,
      (sin(2 * pi * 440 * i / 16000) * 3000).round(),
      Endian.little,
    );
  }
  bytes.setRange(4, 8, data.buffer.asUint8List(4, 4));
  bytes.setRange(16, 36, data.buffer.asUint8List(16, 20));
  bytes.setRange(40, bytes.length, data.buffer.asUint8List(40));
  return bytes;
}
