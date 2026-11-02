import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:ionic_server/src/http/api_exception.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/media/media_attachment_service.dart';
import 'package:ionic_server/src/modules/recommendation/ranker.dart';

import 'candidate_retrieval.dart';
import 'preference_evidence.dart';
import 'semantic_config.dart';
import 'text_duplicates.dart';
import 'feed_distribution.dart';
import 'adaptive_feedback.dart';
import 'adaptive_policy.dart';
import 'adaptive_mixer.dart';

import 'package:ionic_server/src/modules/recommendation/ranker_config.dart';
import 'package:ionic_server/src/modules/recommendation/recommendation_signals.dart';
import 'package:ionic_server/src/modules/recommendation/types.dart';
import 'package:postgres/postgres.dart';

part 'adaptive_feed_service.dart';

final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
);

class _FeedCursor {
  const _FeedCursor({
    required this.asOfMs,
    required this.afterId,
    required this.snapshotKey,
    required this.randomSeed,
    required this.pageSize,
  });

  final int asOfMs;
  final String afterId;
  final String snapshotKey;
  final String randomSeed;
  final int pageSize;
}

class _CandidateEntry {
  _CandidateEntry({required this.candidate, required this.post});

  FeedCandidate candidate;
  final Map<String, dynamic> post;
}

class RecommendationService {
  RecommendationService(this._database)
    : _signals = RecommendationSignalsService();

  final DatabaseService _database;
  final RecommendationSignalsService _signals;

  Future<Map<String, Object?>> recordAttention(
    String viewerId,
    Map<String, Object?> input,
  ) {
    if (Platform.environment['RECOMMENDATION_ADAPTIVE_ENABLED'] != 'true') {
      throw const ApiException(404, 'Attention collection is unavailable.');
    }
    return AdaptiveFeedbackService(_database).record(viewerId, input);
  }

  Future<Map<String, Object?>> forYou(
    String viewerId,
    int limit,
    String? cursorInput, {
    bool retryFreshProfile = true,
  }) async {
    if (limit < 1 || limit > 50) {
      throw const ApiException(
        400,
        'Limit must be an integer between 1 and 50.',
      );
    }
    if (Platform.environment['RECOMMENDATION_ADAPTIVE_ENABLED'] == 'true') {
      return _forYouAdaptive(viewerId, limit, cursorInput);
    }
    final cursor = _parseCursor(cursorInput);
    if (cursor != null && cursor.pageSize != limit) {
      throw const ApiException(
        400,
        'Feed page size changed; refresh the feed.',
        code: 'FEED_CURSOR_STALE',
      );
    }
    final randomSeed = cursor?.randomSeed ?? _newFeedSeed();
    final refreshed = await PreferenceEvidenceService().refresh(
      _database,
      viewerId,
      buildRankerConfig(DateTime.now().millisecondsSinceEpoch.toDouble())
          .preferenceHalfLifeMs,
    );
    if (refreshed && cursor != null) {
      throw const ApiException(
        400,
        'Feed preferences changed; refresh the feed.',
        code: 'FEED_CURSOR_STALE',
      );
    }
    final asOfMs = cursor?.asOfMs ?? DateTime.now().millisecondsSinceEpoch;
    final taxonomyVersion = _activeTaxonomyVersion();
    final candidateLimit = readCandidateLimit();
    final rankerConfig = buildRankerConfig(asOfMs.toDouble());
    final profileFuture = _loadViewerProfile(viewerId, taxonomyVersion, asOfMs);
    final candidatesFuture = _database.query(
      candidateRetrievalSql,
      parameters: candidateRetrievalParameters(
        viewerId: viewerId,
        config: rankerConfig,
        candidateLimit: candidateLimit,
        randomSeed: randomSeed,
      ),
    );
    final profileAndCandidates = await Future.wait<Object>([
      profileFuture,
      candidatesFuture,
    ]);
    final profile = profileAndCandidates[0] as ViewerProfile;
    final rows = profileAndCandidates[1] as Result;
    // Stored features can change after a cursor's clock (or while a first page
    // is loading). Never feed future-dated features into the pure ranker.
    if (profile.preferences.any((feature) => feature.updatedAtMs > asOfMs)) {
      if (cursor != null) {
        throw const ApiException(
          400,
          'Feed preferences changed; refresh the feed.',
          code: 'FEED_CURSOR_STALE',
        );
      }
      if (retryFreshProfile) {
        return forYou(viewerId, limit, null, retryFreshProfile: false);
      }
      throw const ApiException(503, 'Feed is changing; try again shortly.');
    }

    final prepared = _scoreCandidateRows(rows, profile, rankerConfig);
    final candidatesById = prepared.entries, scored = prepared.scored;
    final randomEntries =
        candidatesById.entries
            .where((e) => e.value.post['random_position'] != null)
            .toList()
          ..sort(
            (a, b) => (a.value.post['random_position'] as num).compareTo(
              b.value.post['random_position'] as num,
            ),
          );
    final mixed = mixFeedSnapshot(
      ranked: scored,
      randomOrderedIds: randomEntries.map((e) => e.key).toList(),
      pageSize: limit,
      config: rankerConfig,
      policy: FeedDistributionPolicy.fromEnvironment(),
    );
    final ranked = mixed.entries.map((e) => e.item).toList();
    final snapshotKey = _rankedSnapshotKey([
      rankerConfig.rankerVersion,
      for (final entry in mixed.entries)
        '${entry.isRandom ? 'r' : 'p'}:${entry.item.candidate.id}',
    ]);
    var startIndex = 0;
    if (cursor != null) {
      if (cursor.snapshotKey != snapshotKey) {
        throw const ApiException(
          400,
          'Feed ranking changed; refresh the feed.',
          code: 'FEED_CURSOR_STALE',
        );
      }
      final cursorIndex = ranked.indexWhere(
        (item) => item.candidate.id == cursor.afterId,
      );
      if (cursorIndex < 0) {
        throw const ApiException(
          400,
          'Feed cursor is no longer valid.',
          code: 'FEED_CURSOR_STALE',
        );
      }
      startIndex = cursorIndex + 1;
    }
    final page = ranked.skip(startIndex).take(limit).toList();
    final attachmentViews = await contentAttachmentViews(
      _database,
      page.map((item) => item.candidate.id).toList(),
    );
    final items = page.map((item) {
      final post = candidatesById[item.candidate.id]!.post;
      return <String, Object?>{
        'id': '${post['id']}',
        'authorId': '${post['author_id']}',
        'body': '${post['body']}',
        'kind': '${post['kind']}',
        if (post['mime_type'] != null) 'mimeType': '${post['mime_type']}',
        'createdAt': _asDateTime(post['created_at']).toUtc().toIso8601String(),
        'authorHandle': '${post['author_handle']}',
        'authorDisplayName': '${post['author_display_name']}',
        'authorAvatarId': post['author_avatar_id'],
        'likeCount': (post['like_count'] as num).toInt(),
        'replyCount': (post['reply_count'] as num).toInt(),
        'liked': post['liked'] == true,
        'saved': post['saved'] == true,
        'attachments': attachmentViews[item.candidate.id] ?? const [],
      };
    }).toList();
    final hasNext = startIndex + page.length < ranked.length && page.isNotEmpty;
    final nextCursor = hasNext
        ? _encodeCursor(
            _FeedCursor(
              asOfMs: asOfMs,
              afterId: page.last.candidate.id,
              snapshotKey: snapshotKey,
              randomSeed: randomSeed,
              pageSize: limit,
            ),
          )
        : null;
    return {'items': items, 'nextCursor': nextCursor};
  }

  Future<Map<String, bool>> settings(String viewerId) async {
    final result = await _database.query(
      r'SELECT learning_paused FROM user_recommendation_setting WHERE user_id = $1',
      parameters: [viewerId],
    );
    return {'paused': result.isNotEmpty && result.first.first == true};
  }

  Future<Map<String, bool>> updateSettings(
    String viewerId,
    Map<String, Object?> input,
  ) async {
    if (input.length != 1 || input['paused'] is! bool) {
      throw const ApiException(400, 'Settings are invalid.');
    }
    final paused = input['paused'] as bool;
    await _database.transaction((tx) async {
      await lockPreference(tx, viewerId);
      await tx.execute(
        r'''INSERT INTO user_recommendation_setting(user_id, learning_paused)
          VALUES ($1, $2)
          ON CONFLICT (user_id) DO UPDATE
          SET learning_paused = EXCLUDED.learning_paused, updated_at = now()''',
        parameters: [viewerId, paused],
      );
      if (paused) {
        await tx.execute(
          r'UPDATE recommendation_delivery_receipt SET measurement_enabled=false WHERE user_id=$1',
          parameters: [viewerId],
        );
      }
    });
    return {'paused': paused};
  }

  Future<Map<String, String>> reset(String viewerId) async {
    await _database.transaction((transaction) async {
      await lockPreference(transaction, viewerId);
      for (final table in [
        'recommendation_feed_plan',
        'recommendation_delivery_receipt',
        'recommendation_attention_summary',
        'recommendation_audience_grant',
        'user_preference_evidence',
        'user_preference_baseline',
        'recommendation_item_feedback',
      ]) {
        await transaction.execute(
          'DELETE FROM $table WHERE user_id=\$1',
          parameters: [viewerId],
        );
      }
      await transaction.execute(
        r'DELETE FROM user_preference_control WHERE user_id = $1',
        parameters: [viewerId],
      );
      await transaction.execute(
        r'DELETE FROM user_preference_feature WHERE user_id = $1',
        parameters: [viewerId],
      );
      await transaction.execute(
        r'DELETE FROM recommendation_video_signal WHERE user_id = $1',
        parameters: [viewerId],
      );
      await transaction.execute(
        r'''INSERT INTO user_recommendation_setting(user_id, learning_paused)
            VALUES ($1, false)
            ON CONFLICT (user_id) DO UPDATE SET learning_paused = false, evidence_dirty=false,delivery_sequence=0, updated_at = now()''',
        parameters: [viewerId],
      );
    });
    return {'status': 'reset'};
  }

  Future<Map<String, String>> setPreference(
    String viewerId,
    String inputContentId,
    Map<String, Object?> input,
  ) async {
    final contentId = _parseContentId(inputContentId);
    if (input.length != 1 ||
        !const ['more', 'less', 'none'].contains(input['preference'])) {
      throw const ApiException(400, 'Preference is invalid.');
    }
    final preference = input['preference'] as String;
    final taxonomyVersion = _activeTaxonomyVersion();
    await _database.transaction((transaction) async {
      final labels = await _accessibleContentLabels(
        transaction,
        viewerId,
        contentId,
        taxonomyVersion,
      );
      if (labels.isEmpty) {
        throw const ApiException(
          400,
          'Content has no active recommendation labels.',
        );
      }
      await lockPreference(transaction, viewerId);
      if (preference == 'none') {
        await transaction.execute(
          r'DELETE FROM recommendation_item_feedback WHERE user_id=$1 AND content_id=$2',
          parameters: [viewerId, contentId],
        );
      } else {
        await transaction.execute(
          r'''INSERT INTO recommendation_item_feedback(user_id,content_id,preference,source_updated_at)
          SELECT $1,id,$3,updated_at FROM content WHERE id=$2
          ON CONFLICT(user_id,content_id) DO UPDATE SET preference=EXCLUDED.preference,
            source_updated_at=EXCLUDED.source_updated_at,updated_at=now()''',
          parameters: [viewerId, contentId, preference],
        );
        await transaction.execute(
          r'''DELETE FROM recommendation_item_feedback WHERE user_id=$1 AND content_id NOT IN
          (SELECT content_id FROM recommendation_item_feedback WHERE user_id=$1 ORDER BY updated_at DESC,content_id LIMIT 512)''',
          parameters: [viewerId],
        );
      }
      await transaction.execute(
        r'UPDATE recommendation_post_distribution SET dirty=true WHERE content_id=$1',
        parameters: [contentId],
      );
      for (final row in labels) {
        final values = row.toColumnMap();
        final dimension = '${values['dimension']}';
        final labelId = '${values['label_id']}';
        if (preference == 'none') {
          await transaction.execute(
            r'''DELETE FROM user_preference_control
                WHERE user_id = $1 AND taxonomy_version = $2 AND dimension = $3 AND label_id = $4''',
            parameters: [viewerId, taxonomyVersion, dimension, labelId],
          );
        } else {
          await transaction.execute(
            r'''INSERT INTO user_preference_control(user_id, taxonomy_version, dimension, label_id, control)
                VALUES ($1, $2, $3, $4, $5)
                ON CONFLICT (user_id, taxonomy_version, dimension, label_id)
                DO UPDATE SET control = EXCLUDED.control, source = 'item_feedback', updated_at = now()''',
            parameters: [
              viewerId,
              taxonomyVersion,
              dimension,
              labelId,
              preference,
            ],
          );
        }
      }
    });
    return {'status': 'updated'};
  }

  Future<Map<String, String>> hide(
    String viewerId,
    String inputContentId,
  ) async {
    final contentId = _parseContentId(inputContentId);
    await _database.transaction((transaction) async {
      await _accessibleContentLabels(
        transaction,
        viewerId,
        contentId,
        _activeTaxonomyVersion(),
        requireLabels: false,
      );
      await transaction.execute(
        r'INSERT INTO feed_content_hide(user_id, content_id) VALUES ($1, $2) ON CONFLICT DO NOTHING',
        parameters: [viewerId, contentId],
      );
      await transaction.execute(
        r'UPDATE recommendation_post_distribution SET dirty=true WHERE content_id=$1',
        parameters: [contentId],
      );
    });
    return {'status': 'hidden'};
  }

  Future<Map<String, Object?>> hidden(String viewerId) async {
    final rows = await _database.query(
      r'''SELECT c.id, c.body, u.handle, h.created_at
      FROM feed_content_hide h JOIN content c ON c.id = h.content_id
      JOIN app_user u ON u.id = c.author_id AND u.state = 'active'
      JOIN user_profile p ON p.user_id = u.id
      WHERE h.user_id = $1 AND c.status = 'published' AND c.deleted_at IS NULL
        AND (p.visibility = 'public' OR u.id = $1 OR EXISTS (SELECT 1 FROM account_follow f WHERE f.follower_id = $1 AND f.followed_id = u.id))
        AND NOT EXISTS (SELECT 1 FROM account_block b WHERE (b.blocker_id = $1 AND b.blocked_id = u.id) OR (b.blocker_id = u.id AND b.blocked_id = $1))
      ORDER BY h.created_at DESC, c.id LIMIT 100''',
      parameters: [viewerId],
    );
    return {
      'items': rows
          .map((r) => {'id': '${r[0]}', 'body': '${r[1]}', 'handle': '${r[2]}'})
          .toList(),
    };
  }

  Future<Map<String, String>> unhide(String viewerId, String inputId) async {
    final id = _parseContentId(inputId);
    await _database.transaction((tx) async {
      await tx.execute(
        r'DELETE FROM feed_content_hide WHERE user_id=$1 AND content_id=$2',
        parameters: [viewerId, id],
      );
      await tx.execute(
        r'UPDATE recommendation_post_distribution SET dirty=true WHERE content_id=$1',
        parameters: [id],
      );
    });
    return {'status': 'unhidden'};
  }

  Future<Map<String, String>> recordVideoSignal(
    String viewerId,
    String inputContentId,
    Map<String, Object?> input,
  ) async {
    final contentId = _parseContentId(inputContentId);
    if (input.length != 2 ||
        input['eventId'] is! String ||
        !_uuidPattern.hasMatch(input['eventId'] as String) ||
        !const ['active_view', 'skip'].contains(input['kind'])) {
      throw const ApiException(400, 'Video signal is invalid.');
    }
    final eventId = input['eventId'] as String;
    final kind = input['kind'] == 'active_view'
        ? PreferenceSignalKind.active_view
        : PreferenceSignalKind.skip;
    final taxonomyVersion = _activeTaxonomyVersion();
    return _database.transaction((transaction) async {
      await transaction.execute(
        r'''INSERT INTO user_recommendation_setting(user_id, learning_paused)
            VALUES ($1, false) ON CONFLICT (user_id) DO NOTHING''',
        parameters: [viewerId],
      );
      final setting = await transaction.execute(
        r'SELECT learning_paused FROM user_recommendation_setting WHERE user_id = $1 FOR UPDATE',
        parameters: [viewerId],
      );
      if (setting.isNotEmpty && setting.first.first == true) {
        return {'status': 'paused'};
      }

      final eligible = await transaction.execute(
        r'''SELECT c.id
            FROM content c
            JOIN video_asset a ON a.content_id = c.id AND a.state = 'ready'
            JOIN app_user u ON u.id = c.author_id AND u.state = 'active'
            JOIN user_profile p ON p.user_id = u.id
            WHERE c.id = $1 AND c.kind = 'short_video' AND c.visibility = 'public'
              AND c.status = 'published' AND c.deleted_at IS NULL
              AND (p.visibility = 'public' OR EXISTS (
                SELECT 1 FROM account_follow f WHERE f.follower_id = $2 AND f.followed_id = u.id
              ))
              AND EXISTS (SELECT 1 FROM content_label l
                WHERE l.content_id = c.id AND l.taxonomy_version = $3 AND l.status = 'active')
              AND NOT EXISTS (SELECT 1 FROM account_block b
                WHERE (b.blocker_id = $2 AND b.blocked_id = u.id)
                   OR (b.blocker_id = u.id AND b.blocked_id = $2))
              AND NOT EXISTS (SELECT 1 FROM account_mute m WHERE m.muter_id = $2 AND m.muted_id = u.id)
              AND NOT EXISTS (SELECT 1 FROM feed_content_hide h WHERE h.user_id = $2 AND h.content_id = c.id)''',
        parameters: [contentId, viewerId, taxonomyVersion],
      );
      if (eligible.isEmpty) {
        throw const ApiException(404, 'Video was not found.');
      }

      await transaction.execute(
        r'DELETE FROM recommendation_video_signal WHERE user_id = $1 AND expires_at <= now()',
        parameters: [viewerId],
      );
      await transaction.execute(
        r'''SELECT pg_advisory_xact_lock(
              hashtextextended(concat_ws(':', $1::text, $2::text, $3::text), 0))''',
        parameters: [viewerId, contentId, kind.name],
      );
      final recent = await transaction.execute(
        r'''SELECT 1 FROM recommendation_video_signal
            WHERE user_id = $1 AND content_id = $2 AND signal_kind = $3
              AND created_at > now() - interval '24 hours' LIMIT 1''',
        parameters: [viewerId, contentId, kind.name],
      );
      if (recent.isNotEmpty) return {'status': 'duplicate'};

      final inserted = await transaction.execute(
        r'''INSERT INTO recommendation_video_signal(user_id, event_id, content_id, signal_kind)
            VALUES ($1, $2, $3, $4)
            ON CONFLICT (user_id, event_id) DO NOTHING RETURNING event_id''',
        parameters: [viewerId, eventId, contentId, kind.name],
      );
      if (inserted.isEmpty) return {'status': 'duplicate'};
      await _signals.recordContentAction(
        transaction: transaction,
        userId: viewerId,
        contentId: contentId,
        actionId: eventId,
        kind: kind,
      );
      return {'status': 'recorded'};
    });
  }

  Future<ViewerProfile> _loadViewerProfile(
    String viewerId,
    String taxonomyVersion,
    int nowMs,
  ) async {
    final results = await Future.wait<Result>([
      _database.query(
        r'''SELECT f.followed_id AS creator_id FROM account_follow f
            WHERE f.follower_id = $1 AND NOT EXISTS (
              SELECT 1 FROM account_block b
              WHERE (b.blocker_id = $1 AND b.blocked_id = f.followed_id)
                 OR (b.blocker_id = f.followed_id AND b.blocked_id = $1)
            ) ORDER BY f.followed_id''',
        parameters: [viewerId],
      ),
      _database.query(
        r'''SELECT CASE WHEN blocker_id = $1 THEN blocked_id ELSE blocker_id END AS creator_id
            FROM account_block WHERE blocker_id = $1 OR blocked_id = $1 ORDER BY creator_id''',
        parameters: [viewerId],
      ),
      _database.query(
        r'SELECT muted_id AS creator_id FROM account_mute WHERE muter_id = $1 ORDER BY muted_id',
        parameters: [viewerId],
      ),
      _database.query(
        r'SELECT content_id FROM feed_content_hide WHERE user_id = $1 ORDER BY content_id',
        parameters: [viewerId],
      ),
      _database.query(
        r'''SELECT dimension, label_id, control FROM user_preference_control
            WHERE user_id = $1 AND taxonomy_version = $2 ORDER BY dimension, label_id''',
        parameters: [viewerId, taxonomyVersion],
      ),
      _database.query(
        r'''SELECT dimension, label_id, score, confidence, source_summary, updated_at, expires_at
            FROM user_preference_feature
            WHERE user_id = $1 AND taxonomy_version = $2 AND expires_at > $3
            ORDER BY dimension, label_id''',
        parameters: [
          viewerId,
          taxonomyVersion,
          DateTime.fromMillisecondsSinceEpoch(nowMs, isUtc: true),
        ],
      ),
    ]);
    final controls = results[4].map((row) => row.toColumnMap()).toList();
    final features = results[5].map((row) => row.toColumnMap()).toList();
    final preferences = features.map((row) {
      final rawSources = row['source_summary'];
      if (rawSources is! List) {
        throw StateError(
          'Stored preference feature has an invalid source summary.',
        );
      }
      return PreferenceFeature(
        taxonomyVersion: taxonomyVersion,
        dimension: LabelDimension.values.byName('${row['dimension']}'),
        labelId: '${row['label_id']}',
        sourceSummary: rawSources
            .map((source) => PreferenceSignalKind.values.byName('$source'))
            .toList(),
        score: (row['score'] as num).toDouble(),
        confidence: (row['confidence'] as num).toDouble(),
        updatedAtMs: _asDateTime(row['updated_at']).millisecondsSinceEpoch
            .toDouble(),
        expiresAtMs: _asDateTime(row['expires_at']).millisecondsSinceEpoch
            .toDouble(),
      );
    }).toList();
    List<TaxonomyLabelRef> controlledBy(String value) => controls
        .where((control) => control['control'] == value)
        .map(
          (control) => TaxonomyLabelRef(
            taxonomyVersion: taxonomyVersion,
            dimension: LabelDimension.values.byName('${control['dimension']}'),
            labelId: '${control['label_id']}',
          ),
        )
        .toList();

    return ViewerProfile(
      explicitInterests: controlledBy('more')
          .map(
            (control) => ExplicitInterest(
              taxonomyVersion: control.taxonomyVersion,
              dimension: control.dimension,
              labelId: control.labelId,
            ),
          )
          .toList(),
      preferences: preferences,
      followingCreatorIds: results[0].map((row) => '${row.first}').toList(),
      blockedCreatorIds: results[1].map((row) => '${row.first}').toList(),
      mutedCreatorIds: results[2].map((row) => '${row.first}').toList(),
      hiddenContentIds: results[3].map((row) => '${row.first}').toList(),
      hiddenLabels: const [],
      lessLikeLabels: controlledBy('less'),
      recentExposures: const [],
    );
  }

  Future<List<ResultRow>> _accessibleContentLabels(
    TxSession transaction,
    String viewerId,
    String contentId,
    String taxonomyVersion, {
    bool requireLabels = true,
  }) async {
    final access = await transaction.execute(
      r'''SELECT c.id FROM content c
          JOIN app_user u ON u.id = c.author_id AND u.state = 'active'
          JOIN user_profile p ON p.user_id = u.id
          WHERE c.id = $1 AND c.status = 'published' AND c.visibility = 'public' AND c.deleted_at IS NULL
            AND (p.visibility = 'public' OR EXISTS (
              SELECT 1 FROM account_follow f WHERE f.follower_id = $2 AND f.followed_id = u.id
            ))
            AND NOT EXISTS (SELECT 1 FROM account_block b
              WHERE (b.blocker_id = $2 AND b.blocked_id = u.id)
                 OR (b.blocker_id = u.id AND b.blocked_id = $2))
          FOR SHARE OF c, u, p''',
      parameters: [contentId, viewerId],
    );
    if (access.length != 1) {
      throw const ApiException(404, 'Content was not found.');
    }
    if (!requireLabels) return const [];
    final labels = await transaction.execute(
      r'''SELECT dimension, label_id FROM content_label
          WHERE content_id = $1 AND taxonomy_version = $2 AND status = 'active'
          ORDER BY dimension, label_id''',
      parameters: [contentId, taxonomyVersion],
    );
    return labels.toList();
  }
}

String _activeTaxonomyVersion() {
  final version = Platform.environment['RECOMMENDATION_TAXONOMY_VERSION']
      ?.trim();
  if (version == null || version.isEmpty) return 'ionic-taxonomy-v1';
  if (version.length > 64) {
    throw StateError(
      'RECOMMENDATION_TAXONOMY_VERSION cannot exceed 64 characters.',
    );
  }
  return version;
}

String _parseContentId(String input) {
  if (!_uuidPattern.hasMatch(input)) {
    throw const ApiException(400, 'Content ID is invalid.');
  }
  return input;
}

_FeedCursor? _parseCursor(String? input) {
  if (input == null) return null;
  if (input.length > 512 || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(input)) {
    throw const ApiException(400, 'Feed cursor is invalid.');
  }
  try {
    final decoded = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(input))),
    );
    if (decoded is Map && decoded['v'] == 3) {
      throw const ApiException(
        400,
        'Feed version changed; refresh the feed.',
        code: 'FEED_CURSOR_STALE',
      );
    }
    if (decoded is Map<String, dynamic> &&
        decoded.length == 3 &&
        decoded.keys.toSet().containsAll({
          'asOfMs',
          'afterId',
          'snapshotKey',
        })) {
      throw const ApiException(
        400,
        'Feed version changed; refresh the feed.',
        code: 'FEED_CURSOR_STALE',
      );
    }
    if (decoded is! Map<String, dynamic> ||
        decoded.length != 6 ||
        !decoded.keys.toSet().containsAll(const {
          'asOfMs',
          'afterId',
          'snapshotKey',
          'v',
          'seed',
          'pageSize',
        })) {
      throw const FormatException('Invalid cursor shape.');
    }
    final asOf = decoded['asOfMs'];
    final afterId = decoded['afterId'];
    final snapshotKey = decoded['snapshotKey'];
    final randomSeed = decoded['seed'], pageSize = decoded['pageSize'];
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (decoded['v'] != 2 ||
        randomSeed is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(randomSeed) ||
        pageSize is! int ||
        pageSize < 1 ||
        pageSize > 50 ||
        asOf is! int ||
        asOf < 0 ||
        asOf > 9007199254740991 ||
        asOf > nowMs + 60000 ||
        afterId is! String ||
        !_uuidPattern.hasMatch(afterId) ||
        snapshotKey is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(snapshotKey)) {
      throw const FormatException('Invalid cursor values.');
    }
    return _FeedCursor(
      asOfMs: asOf,
      afterId: afterId,
      snapshotKey: snapshotKey,
      randomSeed: randomSeed,
      pageSize: pageSize,
    );
  } on ApiException {
    rethrow;
  } on Object {
    throw const ApiException(400, 'Feed cursor is invalid.');
  }
}

String _rankedSnapshotKey(List<String> rankedIds) => base64Url
    .encode(sha256.convert(utf8.encode(jsonEncode(rankedIds))).bytes)
    .replaceAll('=', '');

String _encodeCursor(_FeedCursor cursor) => base64Url
    .encode(
      utf8.encode(
        jsonEncode({
          'v': 2,
          'asOfMs': cursor.asOfMs,
          'afterId': cursor.afterId,
          'snapshotKey': cursor.snapshotKey,
          'seed': cursor.randomSeed,
          'pageSize': cursor.pageSize,
        }),
      ),
    )
    .replaceAll('=', '');

String _newFeedSeed() {
  final random = math.Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

DateTime _asDateTime(Object? value) {
  if (value is DateTime) return value;
  throw StateError('Database returned an invalid timestamp.');
}

// Cosine thresholds are provisional evidence gates, not confidence estimates.
double _semanticAffinity(Map<String, dynamic> row) {
  final config = SemanticConfig();
  final positive = (row['semantic_positive'] as num?)?.toDouble();
  final negative = (row['semantic_negative'] as num?)?.toDouble();
  if (positive == null ||
      positive < config.minimumSimilarity ||
      (negative != null && positive - negative < config.negativeMargin)) {
    return 0;
  }
  return ((positive - config.minimumSimilarity) /
          (1 - config.minimumSimilarity))
      .clamp(0, 1)
      .toDouble();
}

double _semanticAversion(Map<String, dynamic> row) {
  final negative = (row['semantic_negative'] as num?)?.toDouble();
  final positive = (row['semantic_positive'] as num?)?.toDouble();
  final config = SemanticConfig();
  if (negative == null ||
      negative < config.minimumSimilarity ||
      (positive != null && positive - negative >= config.negativeMargin)) {
    return 0;
  }
  return ((negative - config.minimumSimilarity) /
          (1 - config.minimumSimilarity))
      .clamp(0, 1)
      .toDouble();
}

({Map<String, _CandidateEntry> entries, List<RankedCandidate> scored})
_scoreCandidateRows(
  Iterable<ResultRow> rows,
  ViewerProfile profile,
  RankerConfig rankerConfig,
) {
  final candidatesById = <String, _CandidateEntry>{};
  for (final row in rows) {
    final value = row.toColumnMap();
    final id = '${value['id']}';
    final label = ContentLabel(
      taxonomyVersion: '${value['taxonomy_version']}',
      dimension: LabelDimension.values.byName('${value['dimension']}'),
      labelId: '${value['label_id']}',
      confidence: (value['confidence'] as num).toDouble(),
      source: LabelSource.values.byName('${value['source']}'),
    );
    final existing = candidatesById[id];
    if (existing != null) {
      final old = existing.candidate;
      existing.candidate = FeedCandidate(
        id: old.id,
        creatorId: old.creatorId,
        kind: old.kind,
        publishedAtMs: old.publishedAtMs,
        labels: [...old.labels, label],
        eligible: old.eligible,
        visibleToViewer: old.visibleToViewer,
        duplicateGroupId: old.duplicateGroupId,
        qualityScore: old.qualityScore,
        semanticAffinity: old.semanticAffinity,
        semanticAversion: old.semanticAversion,
      );
    } else {
      candidatesById[id] = _CandidateEntry(
        candidate: FeedCandidate(
          id: id,
          creatorId: '${value['author_id']}',
          kind: ContentKind.values.byName('${value['kind']}'),
          publishedAtMs: _asDateTime(value['created_at']).millisecondsSinceEpoch
              .toDouble(),
          labels: [label],
          eligible: true,
          visibleToViewer: true,
          semanticAffinity: _semanticAffinity(value),
          semanticAversion: _semanticAversion(value),
        ),
        post: value,
      );
    }
  }

  final groups = textDuplicateGroups({
    for (final entry in candidatesById.entries)
      if (entry.value.post['has_attachments'] != true)
        entry.key: '${entry.value.post['body']}',
  });
  for (final entry in candidatesById.entries) {
    final old = entry.value.candidate;
    entry.value.candidate = FeedCandidate(
      id: old.id,
      creatorId: old.creatorId,
      kind: old.kind,
      publishedAtMs: old.publishedAtMs,
      labels: old.labels,
      eligible: old.eligible,
      visibleToViewer: old.visibleToViewer,
      duplicateGroupId: groups[old.id],
      semanticAffinity: old.semanticAffinity,
      semanticAversion: old.semanticAversion,
    );
  }
  final scored = rankCandidates(
    candidatesById.values.map((entry) => entry.candidate).toList(),
    profile,
    rankerConfig,
    candidatesById.length,
    diversify: false,
    deduplicateGroups: false,
  );

  return (entries: candidatesById, scored: scored);
}
