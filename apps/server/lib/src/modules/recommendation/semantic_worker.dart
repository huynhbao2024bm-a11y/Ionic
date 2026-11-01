import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../database/database_service.dart';
import 'semantic_config.dart';

/// Only the worker loads the model. Serving never waits for inference.
class LocalTextEmbedder {
  LocalTextEmbedder._(this._process, this._lines);
  final Process _process;
  final StreamIterator<String> _lines;

  static Future<LocalTextEmbedder> start() async {
    final root = Directory.current.parent.parent.absolute.path;
    final python = Platform.environment['IONIC_PYTHON'];
    if (python == null || !File(python).existsSync()) {
      throw StateError('IONIC_PYTHON must point to the local Python runtime.');
    }
    final process = await Process.start(
      python,
      ['tool/semantic/embed.py'],
      environment: {
        'PYTHONPATH': '$root${Platform.pathSeparator}.ml-runtime',
        'IONIC_MODEL_DIR':
            Platform.environment['IONIC_MODEL_DIR'] ??
            '$root${Platform.pathSeparator}.models${Platform.pathSeparator}e5-small',
        'HF_HUB_OFFLINE': '1',
        'PYTHONUTF8': '1',
        'PYTHONIOENCODING': 'utf-8',
      },
    );
    // Never print a provider/runtime traceback containing input.
    process.stderr.drain<void>();
    final lines = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    final embedder = LocalTextEmbedder._(process, lines);
    try {
      final ready = await embedder._read();
      if (ready['ready'] != semanticModelVersion ||
          ready['dimensions'] != 384) {
        throw StateError('Model identity mismatch.');
      }
      return embedder;
    } on Object {
      await embedder.close();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _read() async {
    if (!await _lines.moveNext().timeout(const Duration(seconds: 30))) {
      throw StateError('Embedding process closed.');
    }
    if (_lines.current.length > 400000) {
      throw StateError('Embedding output too large.');
    }
    return jsonDecode(_lines.current) as Map<String, dynamic>;
  }

  Future<List<List<double>>> embed(List<String> texts) async {
    if (texts.isEmpty ||
        texts.length > 16 ||
        texts.any((s) => s.trim().isEmpty || s.runes.length > 1024)) {
      throw ArgumentError('Invalid embedding batch.');
    }
    _process.stdin.writeln(jsonEncode({'texts': texts}));
    final result = await _read();
    if (result['version'] != semanticModelVersion ||
        result['vectors'] is! List) {
      throw StateError('Invalid model response.');
    }
    final vectors = (result['vectors'] as List)
        .map((v) => (v as List).map((n) => (n as num).toDouble()).toList())
        .toList();
    if (vectors.length != texts.length ||
        vectors.any((v) => v.length != 384 || v.any((n) => !n.isFinite))) {
      throw StateError('Invalid embedding shape.');
    }
    return vectors;
  }

  Future<void> close() async {
    _process.kill();
    await _lines.cancel();
  }
}

class SemanticWorker {
  SemanticWorker(this.database, this.embedder);
  final DatabaseService database;
  final LocalTextEmbedder embedder;

  Future<int> runBatch() => database.transaction((tx) async {
    final lease = await tx.execute(
      "SELECT pg_try_advisory_xact_lock(hashtext('ionic:semantic-worker'))",
    );
    if (lease.first.first != true) return 0;
    await tx.execute('''DELETE FROM content_semantic_feature s USING content c, app_user u, user_profile p
      WHERE s.content_id=c.id AND u.id=c.author_id AND p.user_id=u.id
        AND (c.visibility<>'public' OR c.status<>'published' OR c.deleted_at IS NOT NULL
          OR u.state<>'active' OR p.visibility<>'public')''');
    final rows = await tx.execute(
      r'''SELECT c.id,left(c.body,1024) AS body,c.updated_at
      FROM content c JOIN app_user u ON u.id=c.author_id JOIN user_profile p ON p.user_id=u.id
      LEFT JOIN content_semantic_feature s ON s.content_id=c.id
      WHERE c.kind='text' AND c.visibility='public' AND c.status='published' AND c.deleted_at IS NULL
        AND u.state='active' AND p.visibility='public' AND length(trim(c.body))>0
        AND (s.content_id IS NULL OR s.source_updated_at<>c.updated_at OR s.model_version<>$1)
      ORDER BY c.created_at DESC,c.id LIMIT 16''',
      parameters: [semanticModelVersion],
    );
    if (rows.isEmpty) return 0;
    final vectors = await embedder.embed(rows.map((r) => '${r[1]}').toList());
    var count = 0;
    for (var i = 0; i < rows.length; i++) {
      final saved = await tx.execute(
        r'''INSERT INTO content_semantic_feature(content_id,model_version,source_updated_at,embedding)
        SELECT c.id,$2,c.updated_at,l2_normalize($3::vector) FROM content c
        JOIN app_user u ON u.id=c.author_id JOIN user_profile p ON p.user_id=u.id
        WHERE c.id=$1 AND c.updated_at=$4 AND c.kind='text' AND c.visibility='public'
          AND c.status='published' AND c.deleted_at IS NULL AND u.state='active' AND p.visibility='public'
        ON CONFLICT(content_id) DO UPDATE SET model_version=EXCLUDED.model_version,
          source_updated_at=EXCLUDED.source_updated_at,embedding=EXCLUDED.embedding,created_at=now()
        RETURNING content_id''',
        parameters: [
          rows[i][0],
          semanticModelVersion,
          jsonEncode(vectors[i]),
          rows[i][2],
        ],
      );
      count += saved.length;
    }
    return count;
  });
}
