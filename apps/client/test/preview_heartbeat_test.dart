import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ionic_client/src/ionic_api.dart';
import 'package:ionic_client/src/preview_heartbeat.dart';
import 'package:ionic_client/src/client_preferences.dart';

void main() {
  testWidgets(
    'One leased foreground sender pings at ten minutes and releases in background',
    (t) async {
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      clientPreferences.dataSaver = false;
      var time = DateTime(2026, 11, 2), claims = 0, pings = 0, releases = 0;
      final api = IonicApi(
        baseUrl: 'http://local/api/v1',
        client: MockClient((r) async {
          if (r.url.path.endsWith('heartbeat-lease')) {
            claims++;
            return http.Response(
              jsonEncode({
                'enabled': true,
                'leaseToken': 'lease-$claims',
                'intervalSeconds': 600,
              }),
              200,
            );
          }
          if (r.url.path.endsWith('heartbeat-release')) {
            releases++;
            return http.Response('{}', 200);
          }
          pings++;
          expect(jsonDecode(r.body)['leaseToken'], 'lease-1');
          return http.Response('{}', 200);
        }),
      );
      await t.pumpWidget(
        MaterialApp(
          home: PreviewHeartbeat(api: api, userId: 'second', now: () => time),
        ),
      );
      await t.pumpAndSettle();
      expect(claims, 1);
      expect(pings, 0);
      time = time.add(const Duration(minutes: 10));
      await t.pump(const Duration(minutes: 10));
      await t.pumpAndSettle();
      expect(pings, 1);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await t.pumpAndSettle();
      expect(releases, 1);
      time = time.add(const Duration(minutes: 30));
      await t.pump(const Duration(minutes: 30));
      expect(pings, 1);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpAndSettle();
      expect(claims, 2);
      await t.pumpWidget(const SizedBox());
      await t.pumpAndSettle();
    },
  );
  testWidgets('A denied third sender never starts a periodic heartbeat', (
    t,
  ) async {
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    clientPreferences.dataSaver = false;
    var calls = 0;
    final api = IonicApi(
      baseUrl: 'http://local/api/v1',
      client: MockClient((r) async {
        calls++;
        expect(r.url.path.endsWith('heartbeat-lease'), true);
        return http.Response('{"enabled":false}', 200);
      }),
    );
    await t.pumpWidget(
      MaterialApp(
        home: PreviewHeartbeat(api: api, userId: 'third'),
      ),
    );
    await t.pumpAndSettle();
    await t.pump(const Duration(hours: 1));
    expect(calls, 1);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('Data saver and signed-out state create no heartbeat lease', (
    t,
  ) async {
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    var calls = 0;
    final api = IonicApi(
      baseUrl: 'http://local/api/v1',
      client: MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    clientPreferences.dataSaver = true;
    await t.pumpWidget(
      MaterialApp(
        home: PreviewHeartbeat(api: api, userId: 'owner'),
      ),
    );
    await t.pumpAndSettle();
    expect(calls, 0);
    await t.pumpWidget(const SizedBox());
    clientPreferences.dataSaver = false;
    await t.pumpWidget(
      MaterialApp(home: PreviewHeartbeat(api: api, userId: null)),
    );
    await t.pumpAndSettle();
    expect(calls, 0);
    await t.pumpWidget(const SizedBox());
  });
}
