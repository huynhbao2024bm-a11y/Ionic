import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ionic_client/src/ionic_api.dart';
import 'package:ionic_client/src/screens.dart';
import 'package:ionic_client/src/account_avatar.dart';
import 'package:image/image.dart' as img;
import 'dart:typed_data';

http.Response json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);
const user = ApiUser(id: 'viewer', handle: 'viewer', displayName: 'Viewer');
Map<String, Object?> post(String id) => {
  'id': id,
  'authorId': 'viewer',
  'authorHandle': 'viewer',
  'authorDisplayName': 'Viewer',
  'body': 'Body $id',
  'createdAt': '2026-11-01T00:00:00Z',
  'replyCount': 1,
};

void main() {
  test('Avatar is a bounded square JPEG; invalid input is rejected', () {
    final portrait = img.Image(width: 600, height: 900);
    final output = optimizeAvatar(Uint8List.fromList(img.encodePng(portrait)));
    final decoded = img.decodeJpg(output)!;
    expect(decoded.width, 512);
    expect(decoded.height, 512);
    expect(output.length, lessThan(256 * 1024));
    expect(
      () => optimizeAvatar(Uint8List.fromList([1, 2, 3])),
      throwsStateError,
    );
  });
  testWidgets('Comments render on a phone with an existing reply', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = IonicApi(
      baseUrl: 'http://local/api/v1',
      client: MockClient((r) async {
        if (r.url.path.endsWith('/replies')) {
          return json({
            'items': [post('reply')],
          });
        }
        return json({
          'items': [post('root')],
        });
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeScreen(
            api: api,
            user: user,
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
    await tester.tap(find.text('1 trả lời'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Body reply'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('An empty inbox polls without reintroducing a loading screen', (
    tester,
  ) async {
    var requests = 0;
    final pending = Completer<http.Response>();
    final api = IonicApi(
      baseUrl: 'http://local/api/v1',
      client: MockClient((_) async {
        requests++;
        return requests == 1 ? json({'items': <Object>[]}) : pending.future;
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessagesScreen(
            api: api,
            user: user,
            conversationId: null,
            conversationName: null,
            onConversation: (_, _) {},
            onAuthenticate: ({required mode}) async {},
            onToast: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    expect(requests, 2);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Chưa có cuộc trò chuyện'), findsOneWidget);
    pending.complete(json({'items': <Object>[]}));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Empty chat stays usable while polling and preserves a typed draft',
    (tester) async {
      var reads = 0;
      final api = IonicApi(
        baseUrl: 'http://local/api/v1',
        client: MockClient((r) async {
          if (r.url.path.endsWith('/thread')) reads++;
          return json({'items': <Object>[]});
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessagesScreen(
              api: api,
              user: user,
              conversationId: 'thread',
              conversationName: 'Partner',
              onConversation: (_, _) {},
              onAuthenticate: ({required mode}) async {},
              onToast: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Draft stays here');
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Draft stays here'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Unchanged message polling writes read state once and retains scroll',
    (tester) async {
      var receipts = 0;
      final items = List.generate(
        50,
        (i) => {
          'id': '$i',
          'senderId': 'partner',
          'body': 'History $i',
          'createdAt': DateTime.utc(2026, 11, 1, 10, 0, i).toIso8601String(),
        },
      );
      final api = IonicApi(
        baseUrl: 'http://local/api/v1',
        client: MockClient((r) async {
          if (r.url.path.endsWith('/read')) {
            receipts++;
            return json({});
          }
          return json({
            'items': r.url.path.endsWith('/thread') ? items : <Object>[],
          });
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessagesScreen(
              api: api,
              user: user,
              conversationId: 'thread',
              conversationName: 'Partner',
              onConversation: (_, _) {},
              onAuthenticate: ({required mode}) async {},
              onToast: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final list = find.byKey(const ValueKey('message-history'));
      await tester.drag(list, const Offset(0, 350));
      await tester.pumpAndSettle();
      final controller = tester.widget<ListView>(list).controller!;
      final offset = controller.offset;
      expect(offset, greaterThan(0));
      await tester.pump(const Duration(seconds: 12));
      await tester.pumpAndSettle();
      expect(receipts, 1);
      expect(controller.offset, offset);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Comments paginate, survive a failed send and fit above keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      var sent = 0;
      final api = IonicApi(
        baseUrl: 'http://local/api/v1',
        client: MockClient((r) async {
          if (r.method == 'POST') {
            sent++;
            return sent == 1 ? json({}, 503) : json(post('new reply'), 201);
          }
          if (r.url.queryParameters['cursor'] == 'older') {
            return json({
              'items': [post('older reply')],
            });
          }
          return json({
            'items': [post('reply')],
            'nextCursor': 'older',
          });
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RepliesDialog(
              api: api,
              post: FeedPost.fromJson(post('root')),
              onToast: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xem thêm bình luận'));
      await tester.pumpAndSettle();
      expect(find.text('Body older reply'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Retain comment');
      tester.view.viewInsets = const FakeViewPadding(bottom: 340);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Gửi bình luận'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Gửi bình luận'));
      await tester.pumpAndSettle();
      expect(find.text('Retain comment'), findsOneWidget);
      expect(find.text('Body reply'), findsOneWidget);
      await tester.tap(find.byTooltip('Gửi bình luận'));
      await tester.pumpAndSettle();
      expect(find.text('Body new reply'), findsOneWidget);
      expect(sent, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
