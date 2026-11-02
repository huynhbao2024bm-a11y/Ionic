import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ionic_client/src/app_update_native.dart';
import 'social_playback_test.dart' as voice;

void main() {
  voice.main();
  testWidgets(
    'Published preview downloads and passes native package/signature checks',
    (tester) async {
      final service = AndroidUpdates();
      final release = await service.check();
      expect(
        release,
        isNotNull,
        reason:
            'Run the non-split profile harness after publishing the intended split-ABI preview.',
      );
      const expectedVersion = String.fromEnvironment('EXPECTED_UPDATE_VERSION');
      if (expectedVersion.isNotEmpty) expect(release!.version, expectedVersion);
      var progress = 0.0;
      final path = await service.download(
        release!,
        (value) => progress = value,
      );
      final file = File(path);
      expect(await file.length(), release.bytes);
      expect(
        await AndroidUpdates.channel.invokeMethod<bool>('verify', {
          'path': path,
        }),
        true,
      );
      expect(
        progress,
        anyOf(1.0, 0.0),
        reason: 'A validated cache hit does not need a new transfer.',
      );
      await expectLater(
        AndroidUpdates.channel.invokeMethod<bool>('verify', {
          'path': '/sdcard/Download/foreign.apk',
        }),
        throwsA(isA<PlatformException>()),
      );
      final corrupt = File('${file.parent.path}/update-${'0' * 64}.apk');
      try {
        await corrupt.writeAsBytes(List<int>.filled(2048, 0), flush: true);
        await expectLater(
          AndroidUpdates.channel.invokeMethod<bool>('verify', {
            'path': corrupt.path,
          }),
          throwsA(isA<PlatformException>()),
        );
      } finally {
        if (await corrupt.exists()) {
          await corrupt.delete();
        }
      }
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
