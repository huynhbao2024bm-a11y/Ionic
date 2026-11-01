import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:ionic_server/src/app.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/recommendation/candidate_retrieval.dart';
import 'package:ionic_server/src/modules/recommendation/ranker_config.dart';
import 'package:ionic_server/src/modules/recommendation/recommendation_service.dart';
import 'package:ionic_server/src/modules/recommendation/semantic_worker.dart';

String id(int n) => 'e0000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

/// Real encoder and owned delivery receipts; mechanics, not relevance judgments.
Future<void> main() async {
  final url = Platform.environment['DATABASE_URL'];
  if (url == null ||
      !Uri.parse(url).pathSegments.last
          .startsWith('ionic_recommendation_verify_') ||
      Platform.environment['RECOMMENDATION_ADAPTIVE_ENABLED'] != 'true' ||
      Platform.environment['RECOMMENDATION_SEMANTIC_ENABLED'] != 'true') {
    throw StateError(
      'Use empty dedicated verification DB and enable adaptive/semantics.',
    );
  }
  final db = DatabaseService.fromEnvironment();
  final feed = RecommendationService(db);
  final viewer = id(1), authors = [id(1), id(2), id(3)];
  LocalTextEmbedder? model;
  var seeded = false, checks = 0;
  void check(bool ok, String name) {
    if (!ok) throw StateError(name);
    checks++;
  }

  final cases =
      (jsonDecode(
            await File('data/recommendation/semantic-challenge-v1.json')
                .readAsString(),
          ) as Map)['cases']
          as List;
  // Already-read items must be absent from candidates without disappearing as seeds.
  Future<List<Map<String, dynamic>>> retrieve() async => (await db.query(
    candidateRetrievalSql,
    parameters: candidateRetrievalParameters(
      viewerId: viewer,
      config: buildRankerConfig(
        DateTime.now().millisecondsSinceEpoch.toDouble(),
      ),
      candidateLimit: 500,
      excludedIds: [id(100), id(103)],
    ),
  )).map((r) => r.toColumnMap()).toList();
  bool hasSemantic(List<Map<String, dynamic>> rows) =>
      rows.any((r) => r['semantic_positive'] != null);
  try {
    check(
      (await db.query('SELECT count(*) FROM app_user')).first.first == 0,
      'Dedicated DB empty',
    );
    await db.transaction((tx) async {
      for (var i = 0; i < authors.length; i++) {
        await tx.execute(
          r"INSERT INTO app_user(id,handle,handle_normalized,password_salt,password_hash) VALUES($1,$2,$2,decode(repeat('00',16),'hex'),decode(repeat('00',64),'hex'))",
          parameters: [authors[i], 'attention_semantic_$i'],
        );
        await tx.execute(
          r'INSERT INTO user_profile(user_id,display_name) VALUES($1,$2)',
          parameters: [authors[i], 'Synthetic $i'],
        );
      }
      for (var i = 0; i < 6; i++) {
        final c = cases[i ~/ 3] as Map;
        await tx.execute(
          r"INSERT INTO content(id,author_id,body,created_at) VALUES($1,$2,$3,now()-interval '1 minute')",
          parameters: [
            id(100 + i),
            authors[1 + (i ~/ 3)],
            c[['seed', 'related', 'unrelated'][i % 3]],
          ],
        );
        await tx.execute(
          r"INSERT INTO content_label(content_id,taxonomy_version,dimension,label_id,confidence,source) VALUES($1,'ionic-taxonomy-v1','format','format.text',1,'rule')",
          parameters: [id(100 + i)],
        );
      }
    });
    seeded = true;
    model = await LocalTextEmbedder.start();
    final worker = SemanticWorker(db, model);
    check(
      await worker.runBatch() == 6,
      'Actual model embeds six public fixture bodies',
    );
    final page = await feed.forYou(viewer, 20, null);
    final items = (page['items'] as List).cast<Map<String, dynamic>>();
    check(
      items.length == 6 && !hasSemantic(await retrieve()),
      'Delivery alone creates no semantic seed',
    );
    final receipts = {
      for (final item in items) '${item['id']}': '${item['receiptId']}',
    };
    await db.query(
      r"UPDATE recommendation_delivery_receipt SET issued_at=now()-interval '1 minute',expires_at=now()+interval '6 days' WHERE user_id=$1",
      parameters: [viewer],
    );
    Future<void> read(String post) async {
      final result = await feed.recordAttention(viewer, {
        'items': [
          {'receiptId': receipts[post]!, 'band': 'long'},
        ],
      });
      check(result['accepted'] == 1, 'Owned foreground band accepted once');
    }

    await read(id(100));
    check(!hasSemantic(await retrieve()), 'One implicit seed is insufficient');
    await read(id(103));
    final rows = await retrieve();
    check(
      hasSemantic(rows),
      'Two distinct observations inform unseen candidates',
    );
    check(
      rows.every((r) => r['id'] != id(100) && r['id'] != id(103)),
      'Seen source excluded as candidate, retained as evidence',
    );
    await db.query(
      r'INSERT INTO account_block(blocker_id,blocked_id) VALUES($1,$2)',
      parameters: [authors[1], viewer],
    );
    check(
      !hasSemantic(await retrieve()),
      'Reverse block removes a source before minimum-seed qualification',
    );
    await db.query(
      r'DELETE FROM account_block WHERE blocker_id=$1',
      parameters: [authors[1]],
    );
    await db.query(
      r"UPDATE content SET updated_at=updated_at+interval '1 second' WHERE id=$1",
      parameters: [id(100)],
    );
    check(
      !hasSemantic(await retrieve()),
      'Edited source cannot keep stale attention or vector influence',
    );
    // Authenticated HTTP boundary: unknown/foreign receipt receives no existence detail.
    const token = 'synthetic-attention-session-0000000000000000';
    await db.query(
      r"INSERT INTO user_session(token_hash,user_id,expires_at) VALUES($1,$2,now()+interval '1 hour')",
      parameters: [sha256.convert(utf8.encode(token)).toString(), viewer],
    );
    final app = createApp(database: db, allowedOrigins: {'http://localhost'});
    Future<Response> call(Object body, {bool auth = true}) async => app(
      Request(
        'POST',
        Uri.parse('http://localhost/api/v1/feed/attention'),
        headers: {
          'content-type': 'application/json',
          if (auth) 'cookie': 'ionic_session=$token',
        },
        body: jsonEncode(body),
      ),
    );
    check(
      (await call({'items': <Object?>[]}, auth: false)).statusCode == 401,
      'Attention requires session',
    );
    final invalidResponse = await call({
      'items': [
        {'receiptId': id(9999), 'band': 'long'},
      ],
      'rawDwell': 123,
    });
    check(
      invalidResponse.statusCode == 400,
      'Undocumented raw input rejected: ${invalidResponse.statusCode} ${await invalidResponse.readAsString()}',
    );
    final response = await call({
      'items': [
        {'receiptId': id(9999), 'band': 'long'},
      ],
    });
    check(
      response.statusCode == 200 &&
          response.headers['cache-control'] == 'no-store',
      'Attention HTTP metadata is never cached',
    );
    check(
      (jsonDecode(await response.readAsString()) as Map)['accepted'] == 0,
      'Unknown receipt creates no evidence or existence detail',
    );
    await feed.reset(viewer);
    check(
      !hasSemantic(await retrieve()),
      'Reset withdraws implicit semantic influence',
    );
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'checks': checks,
        'realEmbeddedBodies': 6,
        'kind': 'Synthetic semantics/HTTP mechanics, not judged relevance',
      }),
    );
  } finally {
    await model?.close();
    if (seeded) {
      await db.query(
        r'DELETE FROM app_user WHERE id=ANY($1::uuid[])',
        parameters: [authors],
      );
    }
    await db.close();
  }
}
