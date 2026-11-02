import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ionic_client/src/connections_dialog.dart';
import 'package:ionic_client/src/ionic_api.dart';

void main() {
  testWidgets('Follower controls persist unfollow and explicit removal', (
    tester,
  ) async {
    final writes = <String>[];
    final api = IonicApi(
      baseUrl: 'http://local/api/v1',
      client: MockClient((r) async {
        if (r.method == 'DELETE') {
          writes.add(r.url.path);
          return http.Response('{}', 200);
        }
        return http.Response(
          jsonEncode({
            'items': [
              {
                'handle': 'friend123',
                'displayName': 'Friend',
                'isFollowing': true,
                'canFollow': true,
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConnectionsDialog(
            api: api,
            handle: 'viewer123',
            isSelf: true,
            initialKind: 'followers',
            onOpenProfile: (_) {},
            onConversation: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hủy theo dõi'));
    await tester.pumpAndSettle();
    expect(writes, contains('/api/v1/profiles/friend123/follow'));
    expect(find.text('Theo dõi'), findsOneWidget);
    await tester.tap(find.byTooltip('Tùy chọn @friend123'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bỏ người theo dõi'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Xác nhận'));
    await tester.pumpAndSettle();
    expect(writes, contains('/api/v1/profiles/me/followers/friend123'));
    expect(find.text('Friend'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
