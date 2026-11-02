part of 'recommendation_service.dart';

class _AudienceBusy implements Exception {
  const _AudienceBusy(this.ids);
  final Set<String> ids;
}

class _AdaptivePageData {
  const _AdaptivePageData(
    this.posts,
    this.page,
    this.planId,
    this.pageIndex,
    this.paused,
  );
  final Map<String, Map<String, dynamic>> posts;
  final Map<String, dynamic> page;
  final String planId;
  final int pageIndex;
  final bool paused;
}

({String id, int page})? _adaptiveCursor(String? input) {
  if (input == null) return null;
  try {
    if (input.length > 512) throw const FormatException();
    final value = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(input))),
    );
    if (value is! Map || value['v'] != 3) {
      throw const ApiException(
        400,
        'Feed version changed; refresh the feed.',
        code: 'FEED_CURSOR_STALE',
      );
    }
    if (value.length != 3 ||
        value['plan'] is! String ||
        !_uuidPattern.hasMatch(value['plan'] as String) ||
        value['page'] is! int ||
        (value['page'] as int) < 1 ||
        (value['page'] as int) > 1000) {
      throw const FormatException();
    }
    return (id: value['plan'] as String, page: value['page'] as int);
  } on ApiException {
    rethrow;
  } on Object {
    throw const ApiException(400, 'Feed cursor is invalid.');
  }
}

String _encodeAdaptiveCursor(String id, int page) => base64Url
    .encode(utf8.encode(jsonEncode({'v': 3, 'plan': id, 'page': page})))
    .replaceAll('=', '');

extension AdaptiveFeedServing on RecommendationService {
  Future<Map<String, Object?>> _forYouAdaptive(
    String viewerId,
    int limit,
    String? cursorInput,
  ) async {
    final cursor = _adaptiveCursor(cursorInput),
        planId = cursor?.id ?? recommendationUuid();
    final pageIndex = cursor?.page ?? 0,
        seed = _newFeedSeed(),
        policy = AdaptivePolicy.fromEnvironment();
    await PreferenceEvidenceService().refresh(
      _database,
      viewerId,
      buildRankerConfig(DateTime.now().millisecondsSinceEpoch.toDouble())
          .preferenceHalfLifeMs,
    );
    final profile = await _loadViewerProfile(
      viewerId,
      _activeTaxonomyVersion(),
      DateTime.now().millisecondsSinceEpoch,
    );
    final banned = <String>{};
    _AdaptivePageData? result;
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        result = await _database.transaction((tx) async {
          await lockPreference(tx, viewerId);
          final feedback = AdaptiveFeedbackService(_database);
          await feedback.pruneViewer(tx, viewerId);
          if (cursor == null) {
            await tx.execute(
              r'INSERT INTO recommendation_feed_plan(id,user_id,page_size,seed) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING',
              parameters: [planId, viewerId, limit, seed],
            );
          }
          final plans = await tx.execute(
            r'SELECT * FROM recommendation_feed_plan WHERE id=$1 AND user_id=$2 AND expires_at>now() FOR UPDATE',
            parameters: [planId, viewerId],
          );
          if (plans.isEmpty ||
              plans.first.toColumnMap()['page_size'] != limit) {
            throw const ApiException(
              400,
              'Feed plan changed; refresh the feed.',
              code: 'FEED_CURSOR_STALE',
            );
          }
          final plan = plans.first.toColumnMap(),
              context = await feedback.loadContext(tx, viewerId);
          final rawPages = plan['pages'];
          final pages = List<dynamic>.from(
            rawPages is String
                ? jsonDecode(rawPages) as List
                : rawPages as List,
          );
          if (pageIndex < pages.length) {
            final cached = Map<String, dynamic>.from(pages[pageIndex] as Map);
            final posts = await _authorizedReceiptPosts(
              tx,
              viewerId,
              (cached['receipts'] as Map).values.cast<String>().toList(),
            );
            if (posts.length != (cached['ids'] as List).length) {
              throw const ApiException(
                400,
                'Feed content changed; refresh the feed.',
                code: 'FEED_CURSOR_STALE',
              );
            }
            return _AdaptivePageData(
              posts,
              cached,
              planId,
              pageIndex,
              context.paused,
            );
          }
          if (pageIndex != pages.length) {
            throw const ApiException(
              400,
              'Feed cursor is stale.',
              code: 'FEED_CURSOR_STALE',
            );
          }
          final delivered = (plan['delivered_ids'] as List).cast<String>(),
              keys = (plan['delivered_keys'] as List).cast<String>();
          final seen = await tx.execute(
            r'''SELECT DISTINCT content_id FROM recommendation_delivery_receipt
            WHERE user_id=$1 AND observed_at>now()-interval '24 hours' AND expires_at>now() LIMIT 2000''',
            parameters: [viewerId],
          );
          final excluded = {
            ...delivered,
            ...banned,
            ...seen.map((r) => '${r.first}'),
          }.toList();
          final clock = DateTime.now().millisecondsSinceEpoch;
          final config = buildRankerConfig(clock.toDouble());
          if (profile.preferences.any((f) => f.updatedAtMs > config.nowMs)) {
            throw const ApiException(
              503,
              'Feed is changing; try again.',
              code: 'FEED_BUSY',
            );
          }
          final windowMs = policy.audienceWindowMinutes * 60000;
          final window = DateTime.fromMillisecondsSinceEpoch(
            clock ~/ windowMs * windowMs,
            isUtc: true,
          );
          final rows = await tx.execute(
            candidateRetrievalSql,
            parameters: candidateRetrievalParameters(
              viewerId: viewerId,
              config: config,
              candidateLimit: readCandidateLimit(),
              randomSeed: '${plan['seed']}',
              excludedIds: excluded,
              audienceWindowStart: window,
            ),
          );
          var prepared = _scoreCandidateRows(
            rows,
            _attentionProfile(profile, context, config, policy),
            config,
          );
          final seenIds = seen.map((r) => r.first.toString()).toSet();
          final size = math.min(limit, 1000 - delivered.length);
          List<MixedFeedEntry> mixCurrent() {
            final eligible = prepared.scored.where((e) {
              final post = prepared.entries[e.candidate.id]!.post;
              final key = post['has_attachments'] == true
                  ? null
                  : exactTextDuplicateKey(post['body'].toString());
              return key == null || !keys.contains(key);
            }).toList();
            final available = [
              ...eligible.where((e) => !seenIds.contains(e.candidate.id)),
              ...eligible.where((e) => seenIds.contains(e.candidate.id)),
            ];
            final random =
                prepared.entries.entries
                    .where((e) => e.value.post['random_position'] != null)
                    .toList()
                  ..sort((a, b) {
                    final repeatedA = seenIds.contains(a.key) ? 1 : 0,
                        repeatedB = seenIds.contains(b.key) ? 1 : 0;
                    if (repeatedA != repeatedB) {
                      return repeatedA.compareTo(repeatedB);
                    }
                    final order = (a.value.post['random_position'] as num)
                        .compareTo(b.value.post['random_position'] as num);
                    return order == 0 ? a.key.compareTo(b.key) : order;
                  });
            return size <= 0
                ? <MixedFeedEntry>[]
                : mixAdaptivePage(
                    ranked: available,
                    randomOrderedIds: random.map((e) => e.key).toList(),
                    pageSize: size,
                    config: config,
                    randomBasisPoints: adaptiveRandomBasisPoints(
                      context.interest,
                      policy,
                    ),
                    startSequence: context.sequence,
                    topicGaps: {
                      for (final e in context.topicInterest.entries)
                        e.key: topicGap(e.value, policy),
                    },
                    lastTopicSequence: context.lastTopicSequence,
                  );
          }

          var mixed = mixCurrent();
          // D-061: seen suppression is a soft freshness preference in sparse
          // supply. Never relax current-plan dedup or viewer authorization.
          if (mixed.length < math.min(10, size) && seenIds.isNotEmpty) {
            final extra = await tx.execute(
              candidateRetrievalSql,
              parameters: candidateRetrievalParameters(
                viewerId: viewerId,
                config: config,
                candidateLimit: readCandidateLimit(),
                randomSeed: plan['seed'].toString(),
                excludedIds: {
                  ...delivered,
                  ...banned,
                  ...prepared.entries.keys,
                }.toList(),
                audienceWindowStart: window,
              ),
            );
            if (extra.isNotEmpty) {
              prepared = _scoreCandidateRows(
                [...rows, ...extra],
                _attentionProfile(profile, context, config, policy),
                config,
              );
              mixed = mixCurrent();
            }
          }
          final rejected = await feedback.reserveAudience(
            tx,
            viewerId,
            mixed.map((e) => e.item.candidate.id).toList(),
            policy,
          );
          if (rejected.isNotEmpty) {
            throw _AudienceBusy(
              rejected,
            ); // Entire attempt rolls back, including grants.
          }
          final receipts = <String, String>{},
              selectedIds = <String>[],
              newKeys = <String>[];
          for (var i = 0; i < mixed.length; i++) {
            final entry = mixed[i],
                contentId = entry.item.candidate.id,
                post = prepared.entries[contentId]!.post;
            final receiptId = recommendationUuid();
            receipts[contentId] = receiptId;
            selectedIds.add(contentId);
            final topics = entry.item.candidate.labels
                .where((l) => l.dimension == LabelDimension.topic)
                .map((l) => l.labelId)
                .take(16)
                .toList();
            final key = post['has_attachments'] == true
                ? null
                : exactTextDuplicateKey('${post['body']}');
            if (key != null) newKeys.add(key);
            await tx.execute(
              r'''INSERT INTO recommendation_delivery_receipt
              (id,user_id,content_id,plan_id,source_updated_at,delivery_sequence,topic_ids,text_characters,has_media,is_random,measurement_enabled)
              VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)''',
              parameters: [
                receiptId,
                viewerId,
                contentId,
                planId,
                post['updated_at'],
                context.sequence + i + 1,
                topics,
                '${post['body']}'.runes.length,
                post['has_attachments'] == true,
                entry.isRandom,
                !context.paused && post['author_id'] != viewerId,
              ],
            );
          }
          final page = <String, dynamic>{
            'ids': selectedIds,
            'receipts': receipts,
            'next':
                mixed.length == limit && delivered.length + mixed.length < 1000,
          };
          pages.add(page);
          await tx.execute(
            r'''UPDATE recommendation_feed_plan SET delivered_ids=$2,delivered_keys=$3,pages=$4::jsonb WHERE id=$1''',
            parameters: [
              planId,
              [...delivered, ...selectedIds],
              [...keys, ...newKeys],
              jsonEncode(pages),
            ],
          );
          await tx.execute(
            r'UPDATE user_recommendation_setting SET delivery_sequence=delivery_sequence+$2 WHERE user_id=$1',
            parameters: [viewerId, mixed.length],
          );
          // Enforce caps after insertion as well as before reading old state.
          await feedback.pruneViewer(tx, viewerId);
          final posts = await _authorizedReceiptPosts(
            tx,
            viewerId,
            receipts.values.toList(),
          );
          if (posts.length != selectedIds.length) {
            throw const ApiException(
              400,
              'Feed content changed; refresh the feed.',
              code: 'FEED_CURSOR_STALE',
            );
          }
          return _AdaptivePageData(
            posts,
            page,
            planId,
            pageIndex,
            context.paused,
          );
        });
        break;
      } on _AudienceBusy catch (e) {
        banned.addAll(e.ids);
      }
    }
    if (result == null) {
      throw const ApiException(
        503,
        'Feed is busy; try again shortly.',
        code: 'FEED_BUSY',
      );
    }
    final pageIds = (result.page['ids'] as List).cast<String>();
    final attachments = await contentAttachmentViews(_database, pageIds);
    final items = pageIds.map((id) {
      final p = result!.posts[id]!;
      return <String, Object?>{
        'id': id,
        'authorId': '${p['author_id']}',
        'body': '${p['body']}',
        'kind': '${p['kind']}',
        'createdAt': _asDateTime(p['created_at']).toUtc().toIso8601String(),
        'authorHandle': '${p['author_handle']}',
        'authorDisplayName': '${p['author_display_name']}',
        'authorAvatarId': p['author_avatar_id'],
        'likeCount': p['like_count'],
        'replyCount': p['reply_count'],
        'liked': p['liked'] == true,
        'saved': p['saved'] == true,
        'attachments': attachments[id] ?? const [],
        if (!result.paused && p['measurement_enabled'] == true)
          'receiptId': '${p['receipt_id']}',
      };
    }).toList();
    return {
      'items': items,
      'nextCursor': result.page['next'] == true
          ? _encodeAdaptiveCursor(result.planId, result.pageIndex + 1)
          : null,
    };
  }

  Future<Map<String, Map<String, dynamic>>> _authorizedReceiptPosts(
    TxSession tx,
    String viewerId,
    List<String> receiptIds,
  ) async {
    if (receiptIds.isEmpty) return {};
    final rows = await tx.execute(
      r'''SELECT c.*,u.handle AS author_handle,p.display_name AS author_display_name, p.avatar_media_id AS author_avatar_id,
      r.id AS receipt_id,r.measurement_enabled,
      (SELECT count(*)::int FROM content_reaction a WHERE a.content_id=c.id) AS like_count,
      (SELECT count(*)::int FROM content_reply a WHERE a.content_id=c.id AND a.status='published') AS reply_count,
      EXISTS(SELECT 1 FROM content_reaction a WHERE a.content_id=c.id AND a.user_id=$1) AS liked,
      EXISTS(SELECT 1 FROM content_bookmark a WHERE a.content_id=c.id AND a.user_id=$1) AS saved
      FROM recommendation_delivery_receipt r JOIN content c ON c.id=r.content_id AND c.updated_at=r.source_updated_at
      JOIN app_user u ON u.id=c.author_id AND u.state='active' JOIN user_profile p ON p.user_id=u.id
      WHERE r.id=ANY($2::uuid[]) AND r.user_id=$1 AND r.expires_at>now() AND c.kind='text' AND c.visibility='public'
        AND c.status='published' AND c.deleted_at IS NULL
        AND (p.visibility='public' OR u.id=$1 OR EXISTS(SELECT 1 FROM account_follow f WHERE f.follower_id=$1 AND f.followed_id=u.id))
        AND NOT EXISTS(SELECT 1 FROM account_block b WHERE (b.blocker_id=$1 AND b.blocked_id=u.id) OR (b.blocker_id=u.id AND b.blocked_id=$1))
        AND NOT EXISTS(SELECT 1 FROM account_mute m WHERE m.muter_id=$1 AND m.muted_id=u.id)
        AND NOT EXISTS(SELECT 1 FROM feed_content_hide h WHERE h.user_id=$1 AND h.content_id=c.id)''',
      parameters: [viewerId, receiptIds],
    );
    return {for (final r in rows) '${r.toColumnMap()['id']}': r.toColumnMap()};
  }
}

ViewerProfile _attentionProfile(
  ViewerProfile base,
  AdaptiveContext context,
  RankerConfig config,
  AdaptivePolicy policy,
) {
  final existing = base.preferences
      .map((e) => '${e.dimension.name}:${e.labelId}')
      .toSet();
  final extra = <PreferenceFeature>[];
  for (final entry in context.topicInterest.entries) {
    final confidence = entry.value.confidence(policy);
    if (confidence < config.minimumPreferenceConfidence ||
        existing.contains('topic:${entry.key}')) {
      continue;
    }
    extra.add(
      PreferenceFeature(
        taxonomyVersion: config.taxonomyVersion,
        dimension: LabelDimension.topic,
        labelId: entry.key,
        sourceSummary: const [PreferenceSignalKind.active_view],
        score: ((entry.value.mean(policy) - .5) * 2 * confidence).clamp(
          -.25,
          .25,
        ),
        confidence: confidence,
        updatedAtMs: config.nowMs,
        expiresAtMs: config.nowMs + 30 * 86400000,
      ),
    );
  }
  return ViewerProfile(
    explicitInterests: base.explicitInterests,
    preferences: [...base.preferences, ...extra],
    followingCreatorIds: base.followingCreatorIds,
    blockedCreatorIds: base.blockedCreatorIds,
    mutedCreatorIds: base.mutedCreatorIds,
    hiddenContentIds: base.hiddenContentIds,
    hiddenLabels: base.hiddenLabels,
    lessLikeLabels: base.lessLikeLabels,
    recentExposures: base.recentExposures,
  );
}
