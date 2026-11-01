import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ionic_client/src/ionic_api.dart';
import 'package:ionic_client/src/screens.dart';

void main() {
  for (final stale in [true, false]) {
    testWidgets(
      stale
          ? 'Stale ranking cursor refreshes once without stale content'
          : 'Other bad requests do not silently refresh the feed',
      (tester) async {
        var freshRequests = 0;
        http.Response json(Object body, [int status = 200]) => http.Response(
          jsonEncode(body),
          status,
          headers: {'content-type': 'application/json'},
        );
        final api = IonicApi(
          baseUrl: 'http://local/api/v1',
          client: MockClient((request) async {
            if (request.url.queryParameters.containsKey('cursor')) {
              return json({
                'message': 'Cursor rejected',
                if (stale) 'code': 'FEED_CURSOR_STALE',
              }, 400);
            }
            freshRequests++;
            final id = freshRequests == 1 ? 'old' : 'new';
            return json({
              'items': [
                {
                  'id': id,
                  'authorId': 'author',
                  'authorHandle': 'author',
                  'authorDisplayName': 'Author',
                  'body': '$id post',
                  'createdAt': '2026-11-01T00:00:00Z',
                },
              ],
              'nextCursor': freshRequests == 1 ? 'cursor' : null,
            });
          }),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: HomeScreen(
                api: api,
                user: const ApiUser(
                  id: 'viewer',
                  handle: 'viewer',
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
        await tester.ensureVisible(find.text('Tải thêm bài'));
        await tester.tap(find.text('Tải thêm bài'));
        await tester.pumpAndSettle();
        expect(freshRequests, stale ? 2 : 1);
        expect(find.text('old post'), stale ? findsNothing : findsOneWidget);
        if (stale) expect(find.text('new post'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
