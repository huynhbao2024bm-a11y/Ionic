import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ionic_client/main.dart' as app;
import 'package:ionic_client/src/screens.dart';
import 'package:ionic_client/src/post_detail.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Native guest opens a real public post and its comments without publishing or learning events',
    (tester) async {
      app.main();
      final deadline = DateTime.now().add(const Duration(seconds: 100));
      while (find.byType(PostCard).evaluate().isEmpty &&
          DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(
        find.byType(PostCard),
        findsWidgets,
        reason:
            'Requires at least one real public post in the intended preview catalogue.',
      );
      final card = tester.widget<PostCard>(find.byType(PostCard).first);
      await tester.tap(find.text(card.post.body).first);
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      expect(find.byType(PostDetailPage), findsOneWidget);
      final detailDeadline = DateTime.now().add(const Duration(seconds: 40));
      while (find.byType(LinearProgressIndicator).evaluate().isNotEmpty &&
          DateTime.now().isBefore(detailDeadline)) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(find.text('Bình luận'), findsOneWidget);
      expect(find.text('Bài viết không còn khả dụng.'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(PostDetailPage), findsNothing);
      expect(find.byType(PostCard), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
