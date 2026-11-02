import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ionic_client/src/account_controls.dart';
import 'package:ionic_client/src/app.dart';
import 'package:ionic_client/src/home_search.dart';
import 'package:ionic_client/src/ionic_api.dart';
import 'package:ionic_client/src/post_detail.dart';
import 'package:ionic_client/src/profile_editor.dart';
import 'package:ionic_client/src/screens.dart';

http.Response json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);
const user = ApiUser(
  id: 'viewer',
  handle: 'viewer-123',
  displayName: 'Người viết',
);
Map<String, Object?> post(String id, String body) => {
  'id': id,
  'authorId': 'writer',
  'authorHandle': 'writer-123',
  'authorDisplayName': 'Người viết',
  'body': body,
  'createdAt': '2026-11-02T00:00:00Z',
};
void main() {
  testWidgets('Login and signup reveal only their local password field', (
    t,
  ) async {
    final api = IonicApi(client: MockClient((_) async => json({})));
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AuthDialog(api: api, initialMode: 'login'),
        ),
      ),
    );
    await t.pumpAndSettle();
    TextField password() =>
        t.widgetList<TextField>(find.byType(TextField)).last;
    expect(password().obscureText, true);
    await t.tap(find.byTooltip('Xem mật khẩu'));
    await t.pump();
    expect(password().obscureText, false);
    await t.tap(find.byTooltip('Ẩn mật khẩu'));
    await t.pump();
    expect(password().obscureText, true);
    await t.tap(find.text('Tạo tài khoản').first);
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Xem mật khẩu'));
    await t.pump();
    expect(password().obscureText, false);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
    'Change password can reveal new and confirmation, never current',
    (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CredentialActionDialog(api: IonicApi(), action: 'password'),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Xem mật khẩu mới'));
      await t.pump();
      var fields = t.widgetList<TextField>(find.byType(TextField)).toList();
      expect(fields.map((f) => f.obscureText), [true, false, true]);
      await t.tap(find.byTooltip('Xem nhập lại mật khẩu mới'));
      await t.pump();
      fields = t.widgetList<TextField>(find.byType(TextField)).toList();
      expect(fields.map((f) => f.obscureText), [true, false, false]);
      expect(find.byTooltip('Xem mật khẩu hiện tại'), findsNothing);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets('Compact home search returns to the original query field', (
    t,
  ) async {
    final controller = HomeSearchController();
    final api = IonicApi(
      client: MockClient(
        (_) async => json({
          'items': List.generate(15, (i) => post('$i', 'Bài viết $i')),
        }),
      ),
    );
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ListenableBuilder(
                listenable: controller,
                builder: (_, _) => controller.compact
                    ? IconButton(
                        tooltip: 'Tìm nhanh',
                        onPressed: controller.open,
                        icon: const Icon(Icons.search),
                      )
                    : const SizedBox(height: 48),
              ),
              Expanded(
                child: HomeScreen(
                  api: api,
                  user: null,
                  refreshToken: 0,
                  searchController: controller,
                  onAuthenticate: ({required mode}) async {},
                  onCompose: () {},
                  onOpenProfile: (_) {},
                  onToast: (_) {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.drag(find.byType(ListView).first, const Offset(0, -600));
    await t.pumpAndSettle();
    expect(controller.compact, true);
    expect(find.byTooltip('Tìm nhanh'), findsOneWidget);
    await t.tap(find.byTooltip('Tìm nhanh'));
    await t.pumpAndSettle();
    expect(controller.compact, false);
    expect(
      t.widget<TextField>(find.byType(TextField).first).focusNode!.hasFocus,
      true,
    );
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    controller.dispose();
  });
  for (final brightness in Brightness.values) {
    testWidgets(
      'Profile fits narrow large-text ${brightness.name} and avatar contrast',
      (t) async {
        t.view.physicalSize = const Size(320, 720);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        final api = IonicApi(
          client: MockClient(
            (r) async => r.url.path.endsWith('/profiles/viewer-123')
                ? json({
                    'profile': {
                      'handle': user.handle,
                      'displayName': 'Tên hiển thị khá dài',
                      'bio': 'Một phần tiểu sử đủ để đọc.',
                      'isSelf': true,
                      'followerCount': 42,
                      'followingCount': 12,
                    },
                  })
                : json({'items': <Object?>[]}),
          ),
        );
        await t.pumpWidget(
          MaterialApp(
            theme: ionicTheme(brightness),
            builder: (c, child) => MediaQuery(
              data: MediaQuery.of(
                c,
              ).copyWith(textScaler: TextScaler.linear(1.5)),
              child: child!,
            ),
            home: Scaffold(
              body: ProfileScreen(
                api: api,
                user: user,
                handle: null,
                onAuthenticate: ({required mode}) async {},
                onOpenConversation: (_, _) {},
                onToast: (_) {},
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(find.text('Tên hiển thị khá dài'), findsOneWidget);
        expect(t.takeException(), isNull);
        final avatar = t.widget<CircleAvatar>(find.byType(CircleAvatar).first);
        final contrast =
            (avatar.backgroundColor!.computeLuminance() + .05) /
            (avatar.foregroundColor!.computeLuminance() + .05);
        expect(contrast > 1 ? contrast : 1 / contrast, greaterThan(4.5));
        await t.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets('Rejected profile save keeps edits and exposes the error', (
    t,
  ) async {
    final api = IonicApi(
      client: MockClient(
        (_) async =>
            json({'message': 'Rejected', 'code': 'LINK_NOT_ALLOWED'}, 400),
      ),
    );
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileEditor(
            api: api,
            profile: ApiProfile.fromJson({'displayName': 'Name', 'bio': ''}),
            onChanged: (_) {
              throw StateError('not saved');
            },
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).first, 'example.com');
    await t.tap(find.text('Lưu thay đổi'));
    await t.pumpAndSettle();
    expect(find.text('example.com'), findsOneWidget);
    expect(find.textContaining('Không được thêm liên kết'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
    'Comment hearts, threaded replies, deletion and returning preserve post',
    (t) async {
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      var liked = false, removed = false;
      String? parent;
      final root = {
        ...post('root', 'Bình luận gốc'),
        'threadCount': 1,
        'canDelete': true,
      };
      final api = IonicApi(
        client: MockClient((r) async {
          if (r.url.path.endsWith('/like')) {
            liked = r.method == 'POST';
            return json({
              'liked': liked,
              'likeCount': liked ? 1 : 0,
            }, r.method == 'POST' ? 201 : 200);
          }
          if (r.method == 'DELETE') {
            removed = true;
            return json({'deleted': true});
          }
          if (r.url.path.endsWith('/replies/sync')) {
            return json({
              'items': removed
                  ? <Object?>[]
                  : [
                      {...root, 'liked': liked, 'likeCount': liked ? 1 : 0},
                    ],
            });
          }
          if (r.url.path.endsWith('/replies')) {
            if (r.method == 'POST') {
              parent = asJsonMap(jsonDecode(r.body))['parentReplyId'] as String?;
              return json({
                ...post('new', 'Trả lời mới'),
                'parentReplyId': parent,
                'threadRootId': 'root',
              }, 201);
            }
            return json({
              'items': r.url.queryParameters['thread'] == 'root'
                  ? [
                      {
                        ...post('child', 'Trả lời đã có'),
                        'threadRootId': 'root',
                        'parentReplyId': 'root',
                      },
                    ]
                  : [root],
            });
          }
          return json(post('p', 'Bài viết thật'));
        }),
      );
      var lost = false;
      await t.pumpWidget(
        MaterialApp(
          home: PostDetailPage(
            api: api,
            initial: FeedPost.fromJson(post('p', 'Bài viết thật')),
            userId: 'viewer',
            onToast: (_) {},
            onChanged: (p) {
              if (p == null) lost = true;
            },
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Thích'));
      await t.pumpAndSettle();
      expect(liked, true);
      expect(find.text('1'), findsOneWidget);
      await t.tap(find.text('Xem 1 trả lời'));
      await t.pumpAndSettle();
      expect(find.text('Trả lời đã có'), findsOneWidget);
      await t.enterText(find.byType(TextField).first, 'Trả lời mới');
      await t.pump();
      await t.tap(find.byTooltip('Gửi bình luận'));
      await t.pumpAndSettle();
      expect(parent, 'root');
      expect(find.text('Trả lời mới'), findsOneWidget);
      await t.pageBack();
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Tùy chọn bình luận'));
      await t.pumpAndSettle();
      await t.tap(find.text('Xóa bình luận'));
      await t.pumpAndSettle();
      await t.tap(find.text('Xóa'));
      await t.pumpAndSettle();
      expect(removed, true);
      expect(find.text('Bình luận gốc'), findsNothing);
      expect(lost, false);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'Confirmed reply remains successful if follow-up metadata fails',
    (t) async {
      var sent = 0, reads = 0;
      final toasts = <String>[];
      final api = IonicApi(
        client: MockClient((r) async {
          if (r.url.path.endsWith('/replies') && r.method == 'POST') {
            sent++;
            return json(post('r', 'Đã gửi'), 201);
          }
          if (r.url.path.endsWith('/replies')) return json({'items': <Object?>[]});
          if (reads++ > 0) return json({'message': 'Unavailable'}, 503);
          return json(post('p', 'Bài viết'));
        }),
      );
      await t.pumpWidget(
        MaterialApp(
          home: PostDetailPage(
            api: api,
            initial: FeedPost.fromJson(post('p', 'Bài viết')),
            userId: 'viewer',
            onToast: toasts.add,
            onChanged: (_) {},
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).first, 'Đã gửi');
      await t.pump();
      await t.tap(find.byTooltip('Gửi bình luận'));
      await t.pumpAndSettle();
      expect(sent, 1);
      expect(find.text('Đã gửi'), findsOneWidget);
      expect(
        t.widget<TextField>(find.byType(TextField).first).controller!.text,
        isEmpty,
      );
      expect(toasts.single, contains('Bình luận đã gửi'));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets('Unavailable thread does not mark its accessible post deleted', (
    t,
  ) async {
    var lost = false;
    final api = IonicApi(
      client: MockClient(
        (r) async => r.url.path.endsWith('/sync')
            ? json({'items': <Object?>[]})
            : json(post('p', 'Bài còn nguyên')),
      ),
    );
    await t.pumpWidget(
      MaterialApp(
        home: PostDetailPage(
          api: api,
          initial: FeedPost.fromJson(post('p', 'Bài còn nguyên')),
          threadRoot: FeedPost.fromJson(post('r', 'Gốc')),
          userId: null,
          onToast: (_) {},
          onChanged: (p) {
            if (p == null) lost = true;
          },
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Luồng bình luận không còn khả dụng.'), findsOneWidget);
    expect(lost, false);
    await t.pumpWidget(const SizedBox());
  });
}
