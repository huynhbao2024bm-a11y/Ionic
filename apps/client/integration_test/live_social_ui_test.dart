import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:ionic_client/src/app.dart';
import 'package:ionic_client/src/ionic_api.dart';
import 'package:ionic_client/src/post_detail.dart';
import 'package:ionic_client/src/screens.dart';

/// Two isolated in-memory sessions, never the owner's device credentials.
class FixtureClient extends http.BaseClient {
  final inner = http.Client();
  String? cookie;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (cookie != null) request.headers['cookie'] = cookie!;
    final response = await inner.send(request);
    final value = response.headers['set-cookie'];
    if (value != null) cookie = value.split(';').first;
    return response;
  }

  @override
  void close() => inner.close();
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Real native private cohort edits profile, reads threads and sends messages',
    (t) async {
      const base = 'https://ionic-api.onrender.com/api/v1';
      if (!const bool.fromEnvironment('ALLOW_LIVE_PREVIEW')) {
        throw StateError('Explicit opt-in required.');
      }
      final clients = [FixtureClient(), FixtureClient()];
      final apis = clients
          .map((c) => IonicApi(baseUrl: base, client: c))
          .toList();
      final actors = <({IonicApi api, ApiUser user, String password})>[];
      final suffix = List.generate(
        6,
        (_) => Random.secure().nextInt(16).toRadixString(16),
      ).join();
      Widget surface(Widget child, Brightness brightness) => MaterialApp(
        theme: ionicTheme(brightness),
        home: Scaffold(body: child),
      );
      Future<void> waitFor(Finder f) async {
        final deadline = DateTime.now().add(const Duration(seconds: 50));
        while (f.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
          await t.pump(const Duration(milliseconds: 200));
        }
        expect(f, findsWidgets);
        await t.pumpAndSettle();
      }

      try {
        for (var i = 0; i < 2; i++) {
          final password = 'Fictional-123-$suffix-$i';
          final user = await apis[i].register(
            'native-${suffix}123$i',
            'Kiểm thử Android ${i + 1}',
            password,
          );
          actors.add((api: apis[i], user: user, password: password));
          await apis[i].updateAccountSettings({'discoverable': false});
        }
        final a = actors[0], b = actors[1];
        await a.api.follow(b.user.handle, true);
        await b.api.follow(a.user.handle, true);
        for (final actor in actors) {
          await actor.api.updateAccountSettings({'visibility': 'private'});
        }
        final post = await a.api.createPost(
          'Bài kiểm thử riêng: bản thiết kế mới dễ đọc hơn.',
        );
        final root = await b.api.createReply(
          post.id,
          'Bình luận riêng để kiểm tra trả lời.',
        );
        await a.api.createReply(
          post.id,
          'Trả lời gốc được lưu trên máy chủ.',
          parentReplyId: root.id,
        );
        final conversation = await a.api.startConversation(b.user.handle);
        await b.api.sendMessage(
          conversation.id,
          'Mình đã nhận được tin nhắn kiểm thử.',
          IonicApi.newClientMessageId(),
        );
        await a.api.sendMessage(
          conversation.id,
          'Cảm ơn bạn, đang kiểm tra giao diện.',
          IonicApi.newClientMessageId(),
        );

        await t.pumpWidget(
          surface(
            ProfileScreen(
              api: a.api,
              user: a.user,
              handle: null,
              onAuthenticate: ({required mode}) async {},
              onOpenConversation: (_, _) {},
              onToast: (_) {},
              onProfileChanged: (_) {},
            ),
            Brightness.dark,
          ),
        );
        await waitFor(find.text('Sửa hồ sơ'));
        expect(t.takeException(), isNull);
        await binding.convertFlutterSurfaceToImage();
        await t.pumpAndSettle();
        await binding.takeScreenshot('ionic-ui7-profile-dark');
        await t.tap(find.text('Sửa hồ sơ'));
        await t.pumpAndSettle();
        await t.enterText(
          find.byType(TextField).last,
          'Tiểu sử đã sửa trực tiếp từ Android.',
        );
        await t.pump();
        await t.tap(find.text('Lưu thay đổi'));
        await waitFor(find.text('Sửa hồ sơ'));
        expect(
          (await a.api.profile(a.user.handle)).bio,
          'Tiểu sử đã sửa trực tiếp từ Android.',
        );
        await t.pumpWidget(
          surface(
            ProfileScreen(
              key: UniqueKey(),
              api: a.api,
              user: a.user,
              handle: null,
              onAuthenticate: ({required mode}) async {},
              onOpenConversation: (_, _) {},
              onToast: (_) {},
            ),
            Brightness.light,
          ),
        );
        await waitFor(find.text('Sửa hồ sơ'));
        await binding.takeScreenshot('ionic-ui7-profile-light');

        await t.pumpWidget(
          MaterialApp(
            theme: ionicTheme(Brightness.dark),
            home: PostDetailPage(
              api: a.api,
              initial: post,
              userId: a.user.id,
              onToast: (_) {},
              onChanged: (_) {},
            ),
          ),
        );
        await waitFor(find.text('Bình luận riêng để kiểm tra trả lời.'));
        await t.tap(find.text('Thích').last);
        await t.pumpAndSettle();
        expect(
          (await a.api.syncReplies(post.id, [
            root.id,
          ], threaded: true)).single.liked,
          true,
        );
        await t.tap(find.text('Xem 1 trả lời'));
        await waitFor(find.text('Trả lời gốc được lưu trên máy chủ.'));
        await binding.takeScreenshot('ionic-ui7-comment-thread');
        await t.enterText(
          find.byType(TextField).first,
          'Trả lời mới từ giao diện Android.',
        );
        await t.pump();
        await t.tap(find.byTooltip('Gửi bình luận'));
        await waitFor(find.text('Trả lời mới từ giao diện Android.'));
        expect(
          (await b.api.replies(
            post.id,
            threaded: true,
            thread: root.id,
          )).items.any((r) => r.body == 'Trả lời mới từ giao diện Android.'),
          true,
        );
        await t.pageBack();
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('Tùy chọn bình luận'));
        await t.pumpAndSettle();
        await t.tap(find.text('Xóa bình luận'));
        await t.pumpAndSettle();
        await t.tap(find.text('Xóa'));
        await waitFor(find.text('Bình luận đã được xóa.'));
        expect(
          (await b.api.syncReplies(post.id, [
            root.id,
          ], threaded: true)).single.removed,
          true,
        );

        Widget messages({String? id}) => MessagesScreen(
          api: a.api,
          user: a.user,
          conversationId: id,
          conversationName: b.user.displayName,
          onConversation: (_, _) {},
          onAuthenticate: ({required mode}) async {},
          onToast: (_) {},
        );
        await t.pumpWidget(surface(messages(), Brightness.dark));
        await waitFor(find.text(b.user.displayName));
        await binding.takeScreenshot('ionic-ui7-inbox-dark');
        await t.pumpWidget(
          surface(messages(id: conversation.id), Brightness.dark),
        );
        await waitFor(find.text('Mình đã nhận được tin nhắn kiểm thử.'));
        await binding.takeScreenshot('ionic-ui7-chat-dark');
        await t.enterText(find.byType(TextField).last, 'Gửi thật từ Android.');
        await t.pump();
        await t.tap(find.byTooltip('Gửi tin nhắn'));
        await waitFor(find.text('Gửi thật từ Android.'));
        expect(
          (await b.api.messages(
            conversation.id,
          )).items.any((m) => m.body == 'Gửi thật từ Android.'),
          true,
        );
        await t.enterText(
          find.byType(TextField).last,
          'Bản nháp được giữ khi cập nhật',
        );
        await t.pump(const Duration(seconds: 5));
        expect(
          t.widget<TextField>(find.byType(TextField).last).controller!.text,
          'Bản nháp được giữ khi cập nhật',
        );
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox());
        for (final actor in actors.reversed) {
          await actor.api.deleteAccount(actor.password);
        }
        for (final client in clients) {
          client.close();
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
