import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ionic_client/src/ionic_api.dart';
import 'package:ionic_client/src/post_detail.dart';
import 'package:ionic_client/src/screens.dart';
import 'package:ionic_client/src/account_controls.dart';
import 'package:ionic_client/src/moderation_page.dart';

http.Response json(Object data, [int status = 200]) => http.Response(
  jsonEncode(data),
  status,
  headers: {'content-type': 'application/json'},
);
Map<String, Object?> post(String id, String body) => {
  'id': id,
  'authorId': 'author',
  'authorHandle': 'writer123',
  'authorDisplayName': 'Writer',
  'body': body,
  'createdAt': '2026-11-02T00:00:00Z',
  'replyCount': 1,
};
void main() {
  testWidgets('Tapping feed body opens current post and paginated comments', (
    t,
  ) async {
    final api = IonicApi(
      baseUrl: 'http://local/api/v1',
      client: MockClient((r) async {
        if (r.url.path.endsWith('/feed/for-you')) {
          return json({
            'items': [post('p', 'Old body')],
          });
        }
        if (r.url.path.endsWith('/posts/p')) {
          return json(post('p', 'Current body'));
        }
        if (r.url.path.endsWith('/replies')) {
          return json({
            'items': [post('r', 'Existing comment')],
            'nextCursor': r.url.queryParameters.containsKey('cursor')
                ? null
                : 'next',
          });
        }
        return json({'items': <Object?>[]});
      }),
    );
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeScreen(
            api: api,
            user: const ApiUser(
              id: 'reader',
              handle: 'reader123',
              displayName: 'Reader',
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
    await t.pumpAndSettle();
    await t.tap(find.text('Old body'));
    await t.pumpAndSettle();
    expect(find.byType(PostDetailPage), findsOneWidget);
    expect(find.text('Current body'), findsOneWidget);
    expect(find.text('Existing comment'), findsOneWidget);
    expect(find.text('Xem thêm bình luận'), findsOneWidget);
    await t.tap(find.text('Xem thêm bình luận'));
    await t.pumpAndSettle();
    expect(find.text('Existing comment'), findsOneWidget);
    expect(find.text('Xem thêm bình luận'), findsNothing);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('Guest detail reads comments and has no composer', (t) async {
    final api = IonicApi(
      baseUrl: 'http://local/api/v1',
      client: MockClient(
        (r) async => r.url.path.endsWith('/replies')
            ? json({
                'items': [post('r', 'Public reply')],
              })
            : json(post('p', 'Public post')),
      ),
    );
    await t.pumpWidget(
      MaterialApp(
        home: PostDetailPage(
          api: api,
          initial: FeedPost.fromJson(post('p', 'Public post')),
          userId: null,
          onToast: (_) {},
          onChanged: (_) {},
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Public reply'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Đăng nhập để viết bình luận.'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
    'Rejected edit keeps the new text available and exposes link error',
    (t) async {
      var calls = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) => TextButton(
              onPressed: () => showDialog<bool>(
                context: c,
                builder: (_) => EditPostDialog(
                  body: 'Original',
                  save: (body) async {
                    calls++;
                    throw const IonicApiException(
                      400,
                      'Rejected',
                      code: 'LINK_NOT_ALLOWED',
                    );
                  },
                ),
              ),
              child: const Text('Edit'),
            ),
          ),
        ),
      );
      await t.tap(find.text('Edit'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 'example.com');
      await t.tap(find.text('Lưu'));
      await t.pumpAndSettle();
      expect(calls, 1);
      expect(find.text('example.com'), findsOneWidget);
      expect(find.textContaining('Không được thêm liên kết'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'Silent detail sync replaces changed text and removes revoked replies without clearing draft',
    (t) async {
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      var changed = false;
      final api = IonicApi(
        baseUrl: 'http://local/api/v1',
        client: MockClient((r) async {
          if (r.url.path.endsWith('/replies/sync')) return json({'items': <Object?>[]});
          if (r.url.path.endsWith('/replies')) {
            return json({
              'items': [post('r', 'Will disappear')],
            });
          }
          return json(post('p', changed ? 'Edited elsewhere' : 'Original'));
        }),
      );
      await t.pumpWidget(
        MaterialApp(
          home: PostDetailPage(
            api: api,
            initial: FeedPost.fromJson(post('p', 'Original')),
            userId: 'reader',
            onToast: (_) {},
            onChanged: (_) {},
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 'Draft stays');
      changed = true;
      await t.pump(const Duration(seconds: 31));
      await t.pumpAndSettle();
      expect(find.text('Edited elsewhere'), findsOneWidget);
      expect(find.text('Will disappear'), findsNothing);
      expect(find.text('Draft stays'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'Reviewer decision persists through the API and clears resolved queue',
    (t) async {
      var resolved = false;
      Map<String,dynamic>? submitted;
      final api = IonicApi(
        baseUrl: 'http://local/api/v1',
        client: MockClient((r) async {
          if (r.method == 'POST') {
            submitted = jsonDecode(r.body) as Map<String,dynamic>;
            resolved = true;
            return json({'status': 'resolved'});
          }
          return json({
            'items': resolved ? <Object?>[]
                : [
                    {
                      'id': 'q',
                      'contentId': 'p',
                      'body': 'Reported text',
                      'reason': 'spam',
                      'details': '',
                    },
                  ],
          });
        }),
      );
      await t.pumpWidget(MaterialApp(home: ModerationPage(api: api)));
      await t.pumpAndSettle();
      await t.tap(find.text('Gỡ nội dung'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 'Confirmed violation');
      await t.pump();
      await t.tap(find.text('Xác nhận'));
      await t.pumpAndSettle();
      expect(submitted, {'action': 'remove', 'reason': 'Confirmed violation'});
      expect(resolved, true);
      expect(find.text('Chưa có báo cáo cần xử lý.'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    },
  );
  test(
    'Concurrent media loads share a request but later reads reauthorize',
    () async {
      var calls = 0;
      final pending = Completer<http.Response>();
      final api = IonicApi(
        baseUrl: 'http://local/api/v1',
        client: MockClient((r) {
          calls++;
          return pending.future;
        }),
      );
      final loads = List.generate(20, (_) => api.mediaBytes('image'));
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      pending.complete(http.Response.bytes([1, 2, 3], 200));
      await Future.wait(loads);
      await api.mediaBytes('image');
      expect(calls, 2);
    },
  );
  testWidgets(
    'Readiness retries GET only; failed auth write is never automatically repeated',
    (t) async {
      var reads = 0, writes = 0;
      final api = IonicApi(
        baseUrl: 'http://local/api/v1',
        client: MockClient((r) async {
          if (r.method == 'GET') {
            reads++;
            return reads == 1
                ? json({'status': 'not_ready'}, 503)
                : json({'status': 'ready'});
          }
          writes++;
          return json({'message': 'Request failed.'}, 500);
        }),
      );
      final ready = api.prepareAuthentication();
      await t.pump();
      await t.pump(const Duration(seconds: 2));
      await ready;
      expect(reads, 2);
      expect(writes, 0);
      await expectLater(
        api.register('writer123', 'Writer', 'LongEnoughPassword'),
        throwsA(isA<IonicApiException>()),
      );
      expect(writes, 1);
    },
  );
}
