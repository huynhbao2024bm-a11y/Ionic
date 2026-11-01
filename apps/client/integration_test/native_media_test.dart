import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:record/record.dart';
import 'package:ionic_client/src/voice_player.dart';
import 'package:ionic_client/src/media_composer.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android PCM recording and voice playback use real plugins', (
    tester,
  ) async {
    final recorder = AudioRecorder();
    try {
      expect(
        await recorder
            .hasPermission(request: false)
            .timeout(const Duration(seconds: 10)),
        isTrue,
        reason: 'Grant microphone permission to the test app first.',
      );
      expect(await recorder.isEncoderSupported(AudioEncoder.pcm16bits), isTrue);
      final pcm = BytesBuilder();
      final stream = await recorder
          .startStream(
            const RecordConfig(
              encoder: AudioEncoder.pcm16bits,
              sampleRate: 16000,
              numChannels: 1,
            ),
          )
          .timeout(const Duration(seconds: 15));
      final subscription = stream.listen(pcm.add);
      await Future<void>.delayed(const Duration(seconds: 2));
      await recorder.stop();
      await subscription.cancel();
      final raw = pcm.takeBytes();
      expect(raw.length, greaterThanOrEqualTo(32000));
      final clip = _wave(raw);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VoicePlayer(
              load: () async => clip,
              durationMs: (raw.length / 32).round(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Phát âm thanh'));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('Không phát được'), findsNothing);
      expect(find.textContaining('Không tải được'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    } finally {
      await recorder.dispose();
    }
  });
  testWidgets('Android protected storage can persist and remove a secret', (
    _,
  ) async {
    const storage = FlutterSecureStorage();
    final key = 'ionic_verification_${DateTime.now().microsecondsSinceEpoch}';
    try {
      await storage.write(key: key, value: 'fictional-secret');
      expect(await storage.read(key: key), 'fictional-secret');
    } finally {
      await storage.delete(key: key);
    }
    expect(await storage.read(key: key), isNull);
  });
  testWidgets(
    'Voice composer finishes recording when Android app is backgrounded',
    (tester) async {
      final permissionCheck = AudioRecorder();
      expect(await permissionCheck.hasPermission(request: false), isTrue);
      await permissionCheck.dispose();
      IonicMediaDraft? draft;
      var busy = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaComposerControls(
              onChanged: (value) => draft = value,
              onBusyChanged: (value) => busy = value,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Ghi voice'));
      await tester.pump(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(busy, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await Future<void>.delayed(const Duration(seconds: 1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(busy, isFalse);
      expect(draft?.voice?.length, greaterThan(32000));
      expect(find.byType(VoicePlayer), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

Uint8List _wave(Uint8List pcm) {
  final bytes = Uint8List(44 + pcm.length), data = ByteData(44);
  void text(int start, String s) =>
      bytes.setRange(start, start + s.length, s.codeUnits);
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
  data.setUint32(40, pcm.length, Endian.little);
  for (final range in [(4, 8), (16, 36), (40, 44)]) {
    bytes.setRange(
      range.$1,
      range.$2,
      data.buffer.asUint8List(range.$1, range.$2 - range.$1),
    );
  }
  bytes.setRange(44, bytes.length, pcm);
  return bytes;
}
