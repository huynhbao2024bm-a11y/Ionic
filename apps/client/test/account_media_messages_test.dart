import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ionic_client/src/ionic_api.dart';
import 'package:ionic_client/src/media_composer.dart';
import 'package:ionic_client/src/screens.dart';
import 'package:ionic_client/src/settings_screen.dart';
import 'package:ionic_client/src/client_preferences.dart';
import 'package:ionic_client/src/draft_store.dart';
import 'package:ionic_client/src/account_controls.dart';
import 'package:ionic_client/src/http_client_factory_io.dart' as native;

http.Response json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);
const user = ApiUser(id: 'viewer', handle: 'viewer', displayName: 'Viewer');
const profile = {
  'handle': 'viewer',
  'displayName': 'Viewer',
  'bio': '',
  'isSelf': true,
};
Widget messages(IonicApi api) => MaterialApp(
  home: Scaffold(
    body: MessagesScreen(
      api: api,
      user: user,
      conversationId: 'conversation',
      conversationName: 'Partner',
      onConversation: (_, _) {},
      onAuthenticate: ({required mode}) async {},
      onToast: (_) {},
    ),
  ),
);
Map<String, Object> message(String id) => {
  'id': id,
  'senderId': 'viewer',
  'body': 'Message $id',
  'createdAt': '2026-11-01T10:00:00.000Z',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Late unauthorized/logout responses cannot clear a newer session',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'ionic_session_token': 'A' * 43,
      });
      const storage = FlutterSecureStorage();
      var response = Completer<http.Response>();
      var started = Completer<void>();
      final client = native.createHttpClient(
        storage: storage,
        innerClient: MockClient((_) {
          started.complete();
          return response.future;
        }),
      );
      final request = client.get(Uri.parse('http://local/posts'));
      await started.future;
      await storage.write(key: 'ionic_session_token', value: 'B' * 43);
      response.complete(json({'message': 'Expired'}, 401));
      await request;
      expect(await storage.read(key: 'ionic_session_token'), 'B' * 43);
      response = Completer();
      started = Completer();
      final logout = client.post(Uri.parse('http://local/auth/logout'));
      await started.future;
      await storage.write(key: 'ionic_session_token', value: 'C' * 43);
      response.complete(
        http.Response(
          '{}',
          200,
          headers: {'set-cookie': 'ionic_session=; Max-Age=0'},
        ),
      );
      await logout;
      expect(await storage.read(key: 'ionic_session_token'), 'C' * 43);
      client.close();
    },
  );

  test(
    'Drafts are account-scoped and clear without racing pending writes',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final first = DraftStore.save('a', 'Private draft A');
      final second = DraftStore.save('b', 'Private draft B');
      await DraftStore.clear('a');
      await Future.wait([first, second]);
      expect(await DraftStore.read('a'), isNull);
      expect(await DraftStore.read('b'), 'Private draft B');
    },
  );

  test('Display updates serialize and remain persisted together', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = ClientPreferences();
    await Future.wait([
      prefs.update(scale: 1.4),
      prefs.update(motion: true),
      prefs.update(saver: true),
    ]);
    final restored = ClientPreferences();
    await restored.load();
    expect(restored.textScale, 1.4);
    expect(restored.reducedMotion, true);
    expect(restored.dataSaver, true);
    prefs.dispose();
    restored.dispose();
  });

  testWidgets('Failed privacy save restores the persisted dropdown value', (
    tester,
  ) async {
    final errors = <String>[];
    final api = IonicApi(
      baseUrl: 'http://local/api/v1',
      client: MockClient((request) async {
        if (request.method == 'PATCH') return json({'message': 'Failed'}, 503);
        if (request.url.path.endsWith('/auth/settings')) {
          return json({
            'visibility': 'public',
            'discoverable': true,
            'messagePermission': 'everyone',
          });
        }
        return json({'items': <Object?>[]});
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AccountControls(
              api: api,
              userId: 'viewer',
              onSessionEnded: () {},
              onToast: errors.add,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final dropdown = find.byType(DropdownButtonFormField<String>);
    await tester.ensureVisible(dropdown);
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Không ai').last);
    await tester.pumpAndSettle();
    expect(
      tester.widget<DropdownButtonFormField<String>>(dropdown).initialValue,
      'everyone',
    );
    expect(errors, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'Retry after lost send response reuses message ID and preserves draft',
    (tester) async {
      final sent = <Map<String, dynamic>>[];
      final api = IonicApi(
        baseUrl: 'http://local/api/v1',
        client: MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/conversation')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            sent.add(body);
            if (sent.length == 1) {
              throw http.ClientException(
                'Simulated response lost after commit',
              );
            }
            return json({
              'id': body['clientMessageId'],
              'senderId': 'viewer',
              'body': body['body'],
              'createdAt': '2026-11-01T10:00:00Z',
            }, 201);
          }
          return json({'items': <Object?>[], 'nextCursor': null});
        }),
      );
      await tester.pumpWidget(messages(api));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Keep this draft');
      await tester.pump();
      await tester.tap(find.byTooltip('Gửi tin nhắn'));
      await tester.pumpAndSettle();
      expect(find.text('Keep this draft'), findsOneWidget);
      await tester.tap(find.byTooltip('Gửi tin nhắn'));
      await tester.pumpAndSettle();
      expect(sent.length, 2);
      expect(sent[0]['clientMessageId'], sent[1]['clientMessageId']);
      expect(find.textContaining('Đã gửi'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('Loading older messages retains them across polling', (
    tester,
  ) async {
    var polled = false;
    final api = IonicApi(
      baseUrl: 'http://local/api/v1',
      client: MockClient((request) async {
        if (request.url.path.endsWith('/conversation') &&
            request.method == 'GET') {
          if (request.url.queryParameters['cursor'] == 'older') {
            return json({
              'items': [message('old')],
              'nextCursor': null,
            });
          }
          return json({
            'items': [message('recent'), if (polled) message('new')],
            'nextCursor': 'older',
          });
        }
        return json({'items': <Object?>[]});
      }),
    );
    await tester.pumpWidget(messages(api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tin nhắn trước đó'));
    await tester.pumpAndSettle();
    expect(find.text('Message old'), findsOneWidget);
    polled = true;
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('Message old'), findsOneWidget);
    expect(find.text('Message new'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Personalization switch enabled means learning is not paused', (
    tester,
  ) async {
    final writes = <Map<String, dynamic>>[];
    final api = IonicApi(
      baseUrl: 'http://local/api/v1',
      client: MockClient((request) async {
        if (request.url.path.endsWith('/feed/settings')) {
          if (request.method == 'PATCH') {
            writes.add(jsonDecode(request.body) as Map<String, dynamic>);
          }
          return json({'paused': writes.isNotEmpty});
        }
        if (request.url.path.endsWith('/profiles/viewer')) {
          return json({'profile': profile});
        }
        if (request.url.path.endsWith('/auth/settings')) {
          return json({
            'visibility': 'public',
            'messagePermission': 'everyone',
            'discoverable': true,
          });
        }
        return json({'items': <Object?>[]});
      }),
    );
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsScreen(
            api: api,
            user: user,
            onAuthenticate: ({required mode}) async {},
            onProfileChanged: (_) {},
            themeMode: ThemeMode.dark,
            onThemeModeChanged: (_) async {},
            onSignOut: () {},
            onSessionEnded: () {},
            onToast: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.byWidgetPredicate(
      (w) =>
          w is SwitchListTile &&
          w.title is Text &&
          (w.title as Text).data == 'Cá nhân hóa bảng tin',
    );
    await tester.ensureVisible(toggle);
    expect(tester.widget<SwitchListTile>(toggle).value, true);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(writes.single['paused'], true);
    expect(tester.widget<SwitchListTile>(toggle).value, false);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('Publication retry reuses staged uploads and publication ID', () async {
    var uploads = 0;
    final api = IonicApi(
      baseUrl: 'http://local/api/v1',
      client: MockClient((request) async {
        if (request.method == 'POST') {
          uploads++;
          return json({
            'id': 'asset-$uploads',
            'mediaType': 'image',
            'mimeType': 'image/jpeg',
            'byteSize': 3,
          }, 201);
        }
        return json({'status': 'deleted'});
      }),
    );
    final publication = MediaPublication(api);
    final draft = IonicMediaDraft(
      images: [
        Uint8List.fromList([1, 2, 3]),
      ],
    );
    final ids = await publication.prepare('Draft', draft, (_) {});
    final id = publication.id;
    expect(await publication.prepare('Draft', draft, (_) {}), ids);
    expect(publication.id, id);
    expect(uploads, 1);
    await publication.dispose();
  });

  testWidgets('Data saver prevents automatic image fetch and offers retry', (
    tester,
  ) async {
    var requests = 0;
    clientPreferences.dataSaver = true;
    addTearDown(() => clientPreferences.dataSaver = false);
    final api = IonicApi(
      baseUrl: 'http://local/api/v1',
      client: MockClient((_) async {
        requests++;
        return json({'message': 'Temporary failure'}, 503);
      }),
    );
    const post = FeedPost(
      id: 'post',
      authorId: 'viewer',
      handle: 'viewer',
      displayName: 'Viewer',
      body: 'Photo',
      createdAt: '2026-11-01T00:00:00Z',
      likeCount: 0,
      replyCount: 0,
      liked: false,
      saved: false,
      attachments: [
        ApiAttachment(
          id: 'image',
          mediaType: 'image',
          mimeType: 'image/jpeg',
          byteSize: 20,
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PostCard(
              post: post,
              busy: false,
              api: api,
              onOpenProfile: () {},
              onLike: () {},
              onSave: () {},
              onReply: () {},
              onMenu: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, 0);
    await tester.tap(find.text('Tải ảnh'));
    await tester.pumpAndSettle();
    expect(requests, 1);
    await tester.tap(find.byTooltip('Tải lại ảnh'));
    await tester.pumpAndSettle();
    expect(requests, 2);
    await tester.pumpWidget(const SizedBox());
  });
}
