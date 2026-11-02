import 'dart:convert';
import 'dart:io';
import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  responseDataCallback: (data) async {
    await File(
      '../../.data/native-ui7-report.json',
    ).writeAsString(jsonEncode(data));
  },
  onScreenshot: (name, bytes, [args]) async {
    if (!RegExp(r'^ionic-ui7-[a-z-]+$').hasMatch(name)) return false;
    final file = File('../../.data/$name.png');
    await file.writeAsBytes(bytes, flush: true);
    return true;
  },
);
