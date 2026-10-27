import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ionic_server/src/http/api_exception.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/media/media_attachment_service.dart';
import 'package:ionic_server/src/modules/recommendation/ranker.dart';
import 'package:ionic_server/src/modules/recommendation/ranker_config.dart';
import 'package:ionic_server/src/modules/recommendation/recommendation_signals.dart';
import 'package:ionic_server/src/modules/recommendation/types.dart';
import 'package:postgres/postgres.dart';

final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
);

class _FeedCursor {
  const _FeedCursor({
    required this.asOfMs,
    required this.afterId,
    required this.snapshotKey,
  });

  final int asOfMs;
  final String afterId;
  final String snapshotKey;
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

  Future<Map<String, Object?>> forYou(
    String viewerId,
    int limit,
    String? cursorInput,
  ) async {
    final cursor = _parseCursor(cursorInput);
    final asOfMs = cursor?.asOfMs ?? DateTime.now().millisecondsSinceEpoch;
    final taxonomyVersion = _activeTaxonomyVersion();
    final candidateLimit = readCandidateLimit();
    final rankerConfig = buildRankerConfig(asOfMs.toDouble());
    final profileFuture = _loadViewerProfile(viewerId, taxonomyVersion, asOfMs);
    final candidatesFuture = _loadCandidates(
      viewerId: viewerId,
      taxonomyVersion: taxonomyVersion,
      asOfMs: asOfMs,
      candidateLimit: candidateLimit,
      minimumPreferenceConfidence: rankerConfig.minimumPreferenceConfidence,
      preferenceHalfLifeMs: rankerConfig.preferenceHalfLifeMs,
      adjacentLabels: rankerConfig.adjacentLabels,
    );
    final profileAndCandidates = await Future.wait<Object>([
      profileFuture,
      candidatesFuture,
    ]);
    final profile = profileAndCandidates[0] as ViewerProfile;
    final rows = profileAndCandidates[1] as Result;

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
        );
      } else {
        candidatesById[id] = _CandidateEntry(
          candidate: FeedCandidate(
            id: id,
            creatorId: '${value['author_id']}',
            kind: ContentKind.values.byName('${value['kind']}'),
            publishedAtMs: _asDateTime(value['created_at'])
                .millisecondsSinceEpoch
                .toDouble(),
            labels: [label],
            eligible: true,
            visibleToViewer: true,
          ),
          post: value,
        );
      }
    }

    final ranked = rankCandidates(
      candidatesById.values.map((entry) => entry.candidate).toList(),
      profile,
      rankerConfig,
      candidateLimit,
    );
    final snapshotKey = _rankedSnapshotKey(
      ranked.map((item) => item.candidate.id).toList(),
    );
    var startIndex = 0;
    if (cursor != null) {
      if (cursor.snapshotKey != snapshotKey) {
        throw const ApiException(
          400,
          'Feed ranking changed; refresh the feed.',
        );
      }
      final cursorIndex = ranked.indexWhere(
        (item) => item.candidate.id == cursor.afterId,
      );
      if (cursorIndex < 0) {
        throw const ApiException(400, 'Feed cursor is no longer valid.');
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
    await _database.query(
      r'''INSERT INTO user_recommendation_setting(user_id, learning_paused)
          VALUES ($1, $2)
          ON CONFLICT (user_id) DO UPDATE
          SET learning_paused = EXCLUDED.learning_paused, updated_at = now()''',
      parameters: [viewerId, paused],
    );
    return {'paused': paused};
  }

  Future<Map<String, String>> reset(String viewerId) async {
    await _database.transaction((transaction) async {
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
            ON CONFLICT (user_id) DO UPDATE SET learning_paused = false, updated_at = now()''',
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
    });
    return {'status': 'hidden'};
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

  Future<Result> _loadCandidates({
    required String viewerId,
    required String taxonomyVersion,
    required int asOfMs,
    required int candidateLimit,
    required double minimumPreferenceConfidence,
    required double preferenceHalfLifeMs,
    required Map<String, List<String>> adjacentLabels,
  }) => _database.query(
    r'''WITH learned_positive_labels AS (
         SELECT feature.dimension, feature.label_id
         FROM user_preference_feature feature
         WHERE feature.user_id = $2 AND feature.taxonomy_version = $1
           AND feature.dimension IN ('topic', 'format', 'language', 'context')
           AND feature.score > 0
           AND feature.confidence * power(2::double precision,
             -((extract(epoch FROM ($3::timestamptz - feature.updated_at)) * 1000.0)::double precision) / $6::double precision
           ) >= $5
           AND feature.updated_at <= $3 AND feature.expires_at > $3
           AND NOT EXISTS (
             SELECT 1 FROM user_preference_control less_control
             WHERE less_control.user_id = $2 AND less_control.taxonomy_version = $1
               AND less_control.dimension = feature.dimension AND less_control.label_id = feature.label_id
               AND less_control.control = 'less'
           )
       ), positive_labels AS (
         SELECT control.dimension, control.label_id FROM user_preference_control control
         WHERE control.user_id = $2 AND control.taxonomy_version = $1 AND control.control = 'more'
         UNION SELECT dimension, label_id FROM learned_positive_labels
       ), adjacent_pairs AS (
         SELECT preferred.label_id AS preferred_label_id, neighbor.label_id AS adjacent_label_id
         FROM jsonb_each($7::jsonb) AS preferred(label_id, neighbors)
         CROSS JOIN LATERAL jsonb_array_elements_text(preferred.neighbors) AS neighbor(label_id)
       ), eligible_candidates AS NOT MATERIALIZED (
         SELECT c.id, c.author_id, c.created_at, c.kind
         FROM content c JOIN app_user u ON u.id = c.author_id AND u.state = 'active'
         JOIN user_profile p ON p.user_id = u.id
         WHERE c.kind = 'text' AND c.visibility = 'public'
           AND c.status = 'published' AND c.deleted_at IS NULL
           AND (c.kind = 'text' OR EXISTS (
             SELECT 1 FROM video_asset ready_video WHERE ready_video.content_id = c.id AND ready_video.state = 'ready'
           ))
           AND c.created_at <= $3
           AND (p.visibility = 'public' OR EXISTS (
             SELECT 1 FROM account_follow f WHERE f.follower_id = $2 AND f.followed_id = u.id
           ))
           AND NOT EXISTS (SELECT 1 FROM account_block b
             WHERE (b.blocker_id = $2 AND b.blocked_id = u.id) OR (b.blocker_id = u.id AND b.blocked_id = $2))
           AND NOT EXISTS (SELECT 1 FROM account_mute m WHERE m.muter_id = $2 AND m.muted_id = u.id)
           AND NOT EXISTS (SELECT 1 FROM feed_content_hide h WHERE h.user_id = $2 AND h.content_id = c.id)
           AND EXISTS (SELECT 1 FROM content_label active_label WHERE active_label.content_id = c.id
             AND active_label.taxonomy_version = $1 AND active_label.status = 'active')
       ), followed_candidates AS (
         SELECT e.id, e.created_at FROM eligible_candidates e
         WHERE EXISTS (SELECT 1 FROM account_follow f WHERE f.follower_id = $2 AND f.followed_id = e.author_id)
         ORDER BY e.created_at DESC, e.id DESC LIMIT $4
       ), preference_candidates AS (
         SELECT e.id, e.created_at FROM eligible_candidates e
         JOIN content_label matched_label ON matched_label.content_id = e.id
           AND matched_label.taxonomy_version = $1 AND matched_label.status = 'active'
         JOIN positive_labels preference ON preference.dimension = matched_label.dimension
           AND preference.label_id = matched_label.label_id
         GROUP BY e.id, e.created_at ORDER BY e.created_at DESC, e.id DESC LIMIT $4
       ), adjacent_candidates AS (
         SELECT e.id, e.created_at FROM eligible_candidates e
         JOIN content_label matched_label ON matched_label.content_id = e.id
           AND matched_label.taxonomy_version = $1 AND matched_label.status = 'active'
           AND matched_label.dimension = 'topic'
         JOIN adjacent_pairs adjacent ON adjacent.adjacent_label_id = matched_label.label_id
         JOIN learned_positive_labels learned ON learned.dimension = matched_label.dimension
           AND learned.label_id = adjacent.preferred_label_id
         WHERE NOT EXISTS (SELECT 1 FROM user_preference_control less_control
           WHERE less_control.user_id = $2 AND less_control.taxonomy_version = $1
             AND less_control.dimension = matched_label.dimension AND less_control.label_id = matched_label.label_id
             AND less_control.control = 'less')
         GROUP BY e.id, e.created_at ORDER BY e.created_at DESC, e.id DESC LIMIT $4
       ), fresh_candidates AS (
         SELECT e.id, e.created_at FROM eligible_candidates e
         ORDER BY e.created_at DESC, e.id DESC LIMIT $4
       ), source_candidates AS (
         SELECT e.id, e.created_at, 0 AS source_priority FROM followed_candidates e
         UNION ALL SELECT e.id, e.created_at, 1 AS source_priority FROM preference_candidates e
         UNION ALL SELECT e.id, e.created_at, 2 AS source_priority FROM adjacent_candidates e
         UNION ALL SELECT e.id, e.created_at, 3 AS source_priority FROM fresh_candidates e
       ), source_positions AS (
         SELECT id, source_priority, row_number() OVER (
           PARTITION BY source_priority ORDER BY created_at DESC, id DESC
         ) AS source_position FROM source_candidates
       ), best_source AS (
         SELECT DISTINCT ON (id) id, source_priority, source_position FROM source_positions
         ORDER BY id, source_position, source_priority
       ), selected_ids AS (
         SELECT id FROM best_source ORDER BY source_position, source_priority, id LIMIT $4
       ), selected_candidates AS (
         SELECT c.id, c.author_id, c.body, c.kind, c.created_at, NULL::text AS mime_type,
           u.handle AS author_handle, p.display_name AS author_display_name,
           (SELECT count(*)::int FROM content_reaction r WHERE r.content_id = c.id) AS like_count,
           (SELECT count(*)::int FROM content_reply r WHERE r.content_id = c.id AND r.status = 'published') AS reply_count,
           EXISTS (SELECT 1 FROM content_reaction r WHERE r.content_id = c.id AND r.user_id = $2) AS liked,
           EXISTS (SELECT 1 FROM content_bookmark b WHERE b.content_id = c.id AND b.user_id = $2) AS saved
         FROM selected_ids selected JOIN eligible_candidates eligible ON eligible.id = selected.id
         JOIN content c ON c.id = eligible.id JOIN app_user u ON u.id = c.author_id
         JOIN user_profile p ON p.user_id = u.id
       )
       SELECT e.id, e.author_id, e.body, e.kind, e.mime_type, e.created_at, e.author_handle,
         e.author_display_name, e.like_count, e.reply_count, e.liked, e.saved,
         l.taxonomy_version, l.dimension, l.label_id, l.confidence, l.source
       FROM selected_candidates e JOIN content_label l ON l.content_id = e.id
         AND l.taxonomy_version = $1 AND l.status = 'active'
       ORDER BY e.created_at DESC, e.id DESC, l.dimension, l.label_id''',
    parameters: [
      taxonomyVersion,
      viewerId,
      DateTime.fromMillisecondsSinceEpoch(asOfMs, isUtc: true),
      candidateLimit,
      minimumPreferenceConfidence,
      preferenceHalfLifeMs,
      jsonEncode(adjacentLabels),
    ],
  );

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
  if (input.length > 256 || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(input)) {
    throw const ApiException(400, 'Feed cursor is invalid.');
  }
  try {
    final decoded = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(input))),
    );
    if (decoded is! Map<String, dynamic> ||
        decoded.length != 3 ||
        !decoded.keys.toSet().containsAll(const {
          'asOfMs',
          'afterId',
          'snapshotKey',
        })) {
      throw const FormatException('Invalid cursor shape.');
    }
    final asOf = decoded['asOfMs'];
    final afterId = decoded['afterId'];
    final snapshotKey = decoded['snapshotKey'];
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (asOf is! int ||
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
    );
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
          'asOfMs': cursor.asOfMs,
          'afterId': cursor.afterId,
          'snapshotKey': cursor.snapshotKey,
        }),
      ),
    )
    .replaceAll('=', '');

DateTime _asDateTime(Object? value) {
  if (value is DateTime) return value;
  throw StateError('Database returned an invalid timestamp.');
}
