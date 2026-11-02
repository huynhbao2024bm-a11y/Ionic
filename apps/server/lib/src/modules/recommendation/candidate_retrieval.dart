import 'dart:convert';
import 'dart:io';

import 'types.dart';
import 'semantic_config.dart';

// Shared by serving and diagnostics; measurements must use the serving query.
const candidateRetrievalSql = r'''WITH learned_positive_labels AS (
         SELECT feature.dimension, feature.label_id
         FROM user_preference_feature feature
         WHERE feature.user_id = $2 AND feature.taxonomy_version = $1
           AND feature.dimension IN ('topic', 'format', 'language', 'context')
           AND NOT (feature.dimension = 'format' AND feature.label_id = 'format.text')
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
           AND NOT (control.dimension = 'format' AND control.label_id = 'format.text')
         UNION SELECT dimension, label_id FROM learned_positive_labels
       ), adjacent_pairs AS (
         SELECT preferred.label_id AS preferred_label_id, neighbor.label_id AS adjacent_label_id
         FROM jsonb_each($7::jsonb) AS preferred(label_id, neighbors)
         CROSS JOIN LATERAL jsonb_array_elements_text(preferred.neighbors) AS neighbor(label_id)
       ), exhausted_audience AS MATERIALIZED (
         SELECT d.content_id FROM recommendation_post_distribution d
         JOIN content source ON source.id=d.content_id AND source.updated_at=d.source_updated_at
         WHERE $13::timestamptz IS NOT NULL AND d.window_start=$13 AND NOT d.dirty AND d.valid_until>now()
           AND d.issued_unique>=d.allowance AND NOT EXISTS(
             SELECT 1 FROM recommendation_audience_grant g WHERE g.content_id=d.content_id
               AND g.user_id=$2 AND g.window_start=$13 AND g.expires_at>now())
       ), eligible_candidates AS MATERIALIZED (
         SELECT c.id, c.author_id, c.created_at, c.kind, c.updated_at,
           row_number() OVER(PARTITION BY c.author_id ORDER BY c.created_at DESC,c.id DESC) AS creator_position
         FROM content c JOIN app_user u ON u.id = c.author_id AND u.state = 'active'
         JOIN user_profile p ON p.user_id = u.id
         WHERE c.kind = 'text' AND c.visibility = 'public'
           AND c.status = 'published' AND c.deleted_at IS NULL
           AND c.created_at <= $3
           AND NOT(c.id=ANY($12::uuid[]))
           AND (c.author_id=$2 OR c.id NOT IN(SELECT content_id FROM exhausted_audience))
           AND (p.visibility = 'public' OR EXISTS (
             SELECT 1 FROM account_follow f WHERE f.follower_id = $2 AND f.followed_id = u.id
           ))
           AND NOT EXISTS (SELECT 1 FROM account_block b
             WHERE (b.blocker_id = $2 AND b.blocked_id = u.id) OR (b.blocker_id = u.id AND b.blocked_id = $2))
           AND NOT EXISTS (SELECT 1 FROM account_mute m WHERE m.muter_id = $2 AND m.muted_id = u.id)
           AND NOT EXISTS (SELECT 1 FROM feed_content_hide h WHERE h.user_id = $2 AND h.content_id = c.id)
           AND EXISTS (SELECT 1 FROM content_label active_label WHERE active_label.content_id = c.id
             AND active_label.taxonomy_version = $1 AND active_label.status = 'active')
       ), positive_attention_seeds AS MATERIALIZED (
         SELECT s.content_id,s.source_updated_at,max(s.updated_at) AS at
         FROM recommendation_attention_summary s JOIN content e
           ON e.id=s.content_id AND e.updated_at=s.source_updated_at
         JOIN app_user account ON account.id=e.author_id AND account.state='active'
         JOIN content_semantic_feature vector ON vector.content_id=e.id AND vector.source_updated_at=e.updated_at AND vector.model_version=$8
         JOIN user_profile p ON p.user_id=e.author_id AND p.visibility='public'
         WHERE $14::bool AND s.user_id=$2 AND s.reward>=0.65 AND s.expires_at>$3 AND s.updated_at<=$3
           AND e.author_id<>$2 AND e.kind='text' AND e.visibility='public' AND e.status='published' AND e.deleted_at IS NULL
           AND NOT EXISTS(SELECT 1 FROM account_block b WHERE (b.blocker_id=$2 AND b.blocked_id=e.author_id) OR (b.blocker_id=e.author_id AND b.blocked_id=$2))
           AND NOT EXISTS(SELECT 1 FROM account_mute m WHERE m.muter_id=$2 AND m.muted_id=e.author_id)
           AND NOT EXISTS(SELECT 1 FROM feed_content_hide h WHERE h.user_id=$2 AND h.content_id=e.id)
           AND s.updated_at>$3::timestamptz-interval '7 days'
           AND NOT EXISTS(SELECT 1 FROM recommendation_item_feedback f WHERE f.user_id=$2 AND f.content_id=e.id AND f.preference='less' AND f.source_updated_at=e.updated_at)
           AND NOT EXISTS(SELECT 1 FROM content_label l JOIN user_preference_control ctl
             ON ctl.user_id=$2 AND ctl.taxonomy_version=l.taxonomy_version AND ctl.dimension=l.dimension AND ctl.label_id=l.label_id AND ctl.control='less'
             WHERE l.content_id=e.id AND l.status='active' AND l.taxonomy_version=$1 AND l.dimension IN ('topic','context'))
         GROUP BY s.content_id,s.source_updated_at ORDER BY at DESC,s.content_id LIMIT 24
       ), raw_semantic_seeds AS (
         SELECT e.content_id,e.source_updated_at,max(e.occurred_at) AS at,'more'::text AS preference
         FROM user_preference_evidence e WHERE e.user_id=$2 AND e.expires_at>$3 AND e.occurred_at<=$3
         GROUP BY e.content_id,e.source_updated_at
         UNION ALL SELECT f.content_id,f.source_updated_at,f.updated_at,f.preference
         FROM recommendation_item_feedback f WHERE f.user_id=$2 AND f.updated_at<=$3
         UNION ALL SELECT content_id,source_updated_at,at,'more' FROM positive_attention_seeds
           WHERE (SELECT count(DISTINCT content_id) FROM positive_attention_seeds)>=2
       ), accessible_seeds AS (
         SELECT DISTINCT ON (c.id) c.id,c.author_id,r.at,
           coalesce(f.preference,r.preference) AS preference,s.embedding
         FROM raw_semantic_seeds r JOIN content c ON c.id=r.content_id
         JOIN content_semantic_feature s ON s.content_id=c.id AND s.model_version=$8
           AND s.source_updated_at=c.updated_at AND r.source_updated_at=c.updated_at
         JOIN app_user u ON u.id=c.author_id AND u.state='active'
         JOIN user_profile p ON p.user_id=u.id AND p.visibility='public'
         LEFT JOIN recommendation_item_feedback f ON f.user_id=$2 AND f.content_id=c.id
           AND f.source_updated_at=c.updated_at AND f.updated_at<=$3
         WHERE $8<>'' AND c.kind='text' AND c.visibility='public' AND c.status='published'
           AND c.deleted_at IS NULL
           AND NOT EXISTS (SELECT 1 FROM account_block b WHERE
             (b.blocker_id=$2 AND b.blocked_id=u.id) OR (b.blocker_id=u.id AND b.blocked_id=$2))
           AND NOT EXISTS (SELECT 1 FROM account_mute m WHERE m.muter_id=$2 AND m.muted_id=u.id)
           AND NOT EXISTS (SELECT 1 FROM feed_content_hide h WHERE h.user_id=$2 AND h.content_id=c.id)
           AND (coalesce(f.preference,r.preference)='less' OR NOT EXISTS (
             SELECT 1 FROM content_label l JOIN user_preference_control ctl ON ctl.user_id=$2
               AND ctl.taxonomy_version=l.taxonomy_version AND ctl.dimension=l.dimension AND ctl.label_id=l.label_id
               AND ctl.control='less'
             WHERE l.content_id=c.id AND l.status='active' AND l.taxonomy_version=$1
               AND l.dimension IN ('topic','context')))
         ORDER BY c.id,r.at DESC
       ), balanced_seeds AS (
         SELECT *,row_number() OVER(PARTITION BY author_id,preference ORDER BY at DESC,id) AS creator_seed
         FROM accessible_seeds
       ), seed_polarity_positions AS (
         SELECT *,row_number() OVER(PARTITION BY preference ORDER BY at DESC,id) AS polarity_position
         FROM balanced_seeds WHERE creator_seed<=2
       ), semantic_seeds AS MATERIALIZED (
         SELECT *,power(2::double precision,
           -greatest(0,extract(epoch FROM ($3::timestamptz-at))*1000)/$6::double precision) AS recency
         FROM seed_polarity_positions WHERE polarity_position<=12 ORDER BY at DESC,id LIMIT 24
       ), semantic_scores AS MATERIALIZED (
         SELECT e.id,score.semantic_positive,score.semantic_negative
         FROM eligible_candidates e JOIN content_semantic_feature s ON s.content_id=e.id
           AND s.source_updated_at=e.updated_at AND s.model_version=$8
         JOIN user_profile p ON p.user_id=e.author_id AND p.visibility='public'
         CROSS JOIN LATERAL (
           SELECT max(-(s.embedding <#> seed.embedding)*seed.recency)
             FILTER(WHERE seed.preference='more') AS semantic_positive,
             max(-(s.embedding <#> seed.embedding)) FILTER(WHERE seed.preference='less') AS semantic_negative
           FROM semantic_seeds seed
         ) score
         WHERE EXISTS(SELECT 1 FROM semantic_seeds)
       ), semantic_candidates AS (
         SELECT e.id,e.created_at FROM eligible_candidates e JOIN semantic_scores s ON s.id=e.id
         WHERE s.semantic_positive >= $9 AND (s.semantic_negative IS NULL OR s.semantic_positive-s.semantic_negative >= $10)
         ORDER BY e.creator_position,s.semantic_positive DESC,e.created_at DESC,e.id LIMIT $4
       ), followed_candidates AS (
         SELECT e.id, e.created_at FROM eligible_candidates e
         WHERE EXISTS (SELECT 1 FROM account_follow f WHERE f.follower_id = $2 AND f.followed_id = e.author_id)
         ORDER BY e.creator_position,e.created_at DESC, e.id DESC LIMIT $4
       ), preference_candidates AS (
         SELECT e.id, e.created_at,
           max(CASE WHEN matched_label.dimension IN ('topic', 'context') THEN 1 ELSE 0 END) AS specificity
         FROM eligible_candidates e
         JOIN content_label matched_label ON matched_label.content_id = e.id
           AND matched_label.taxonomy_version = $1 AND matched_label.status = 'active'
         JOIN positive_labels preference ON preference.dimension = matched_label.dimension
           AND preference.label_id = matched_label.label_id
         GROUP BY e.id, e.created_at,e.creator_position ORDER BY specificity DESC,e.creator_position,e.created_at DESC,e.id DESC LIMIT $4
       ), adjacent_candidates AS (
         SELECT e.id, e.created_at FROM eligible_candidates e
         JOIN content_label matched_label ON matched_label.content_id = e.id
           AND matched_label.taxonomy_version = $1 AND matched_label.status = 'active'
           AND matched_label.dimension = 'topic'
         JOIN adjacent_pairs adjacent ON adjacent.adjacent_label_id = matched_label.label_id
         JOIN positive_labels learned ON learned.dimension = matched_label.dimension
           AND learned.label_id = adjacent.preferred_label_id
         WHERE NOT EXISTS (SELECT 1 FROM user_preference_control less_control
           WHERE less_control.user_id = $2 AND less_control.taxonomy_version = $1
             AND less_control.dimension = matched_label.dimension AND less_control.label_id = matched_label.label_id
             AND less_control.control = 'less')
         GROUP BY e.id,e.created_at,e.creator_position ORDER BY e.creator_position,e.created_at DESC, e.id DESC LIMIT $4
       ), fresh_candidates AS (
         SELECT e.id, e.created_at FROM eligible_candidates e
         ORDER BY e.creator_position,e.created_at DESC, e.id DESC LIMIT $4
       ), negative_random_ids AS MATERIALIZED (
         SELECT l.content_id AS id FROM user_preference_control ctl JOIN content_label l
           ON l.taxonomy_version=ctl.taxonomy_version AND l.dimension=ctl.dimension AND l.label_id=ctl.label_id
         WHERE ctl.user_id=$2 AND ctl.taxonomy_version=$1 AND ctl.control='less'
           AND ctl.dimension IN ('topic','context') AND l.status='active'
         UNION SELECT e.id FROM recommendation_item_feedback f JOIN eligible_candidates e
           ON e.id=f.content_id AND f.source_updated_at=e.updated_at
         WHERE f.user_id=$2 AND f.preference='less'
       ), random_constraints AS (
         SELECT e.id,e.author_id,CASE WHEN negative.id IS NULL THEN 0 ELSE 1 END AS negative_control
         FROM eligible_candidates e LEFT JOIN negative_random_ids negative ON negative.id=e.id
       ), random_author_positions AS (
         SELECT *,row_number() OVER(PARTITION BY author_id
           ORDER BY negative_control,md5(id::text || $11::text),id) AS random_author_position
         FROM random_constraints
       ), random_candidates AS MATERIALIZED (
         SELECT id,row_number() OVER(ORDER BY negative_control,random_author_position,
           md5(author_id::text || $11::text),md5(id::text || $11::text),id) AS random_position
         FROM random_author_positions
         ORDER BY negative_control,random_author_position,md5(author_id::text || $11::text),
           md5(id::text || $11::text),id LIMIT $4
       ), source_candidates AS (
         SELECT e.id, e.created_at, 0 AS source_priority, 0 AS specificity FROM followed_candidates e
         UNION ALL SELECT e.id, e.created_at, 1 AS source_priority, e.specificity FROM preference_candidates e
         UNION ALL SELECT e.id, e.created_at, 2 AS source_priority, 0 AS specificity FROM adjacent_candidates e
         UNION ALL SELECT e.id,e.created_at,3 AS source_priority,0 AS specificity FROM semantic_candidates e
         UNION ALL SELECT e.id,e.created_at,4 AS source_priority,0 AS specificity FROM fresh_candidates e
       ), source_author_positions AS (
         SELECT s.*,row_number() OVER(PARTITION BY s.source_priority,e.author_id
           ORDER BY s.specificity DESC,s.created_at DESC,s.id) AS author_position
         FROM source_candidates s JOIN eligible_candidates e ON e.id=s.id
       ), source_positions AS (
         SELECT id, source_priority, row_number() OVER (
           PARTITION BY source_priority ORDER BY author_position,specificity DESC,created_at DESC,id DESC
         ) AS source_position FROM source_author_positions
       ), best_source AS (
         SELECT DISTINCT ON (id) id, source_priority, source_position FROM source_positions
         ORDER BY id, source_position, source_priority
       ), selected_ids AS (
         SELECT id FROM best_source ORDER BY source_position, source_priority, id LIMIT $4
       ), merged_ids AS (
         SELECT id FROM selected_ids UNION SELECT id FROM random_candidates
       ), selected_candidates AS (
         SELECT c.id, c.author_id, c.body, c.kind, c.created_at,c.updated_at, NULL::text AS mime_type,
           u.handle AS author_handle, p.display_name AS author_display_name, p.avatar_media_id AS author_avatar_id,
           (SELECT count(*)::int FROM content_reaction r WHERE r.content_id = c.id) AS like_count,
           (SELECT count(*)::int FROM content_reply r WHERE r.content_id = c.id AND r.status = 'published') AS reply_count,
           EXISTS (SELECT 1 FROM content_reaction r WHERE r.content_id = c.id AND r.user_id = $2) AS liked,
           EXISTS (SELECT 1 FROM content_bookmark b WHERE b.content_id = c.id AND b.user_id = $2) AS saved,
           EXISTS (SELECT 1 FROM content_attachment a WHERE a.content_id=c.id) AS has_attachments
         FROM merged_ids selected JOIN eligible_candidates eligible ON eligible.id = selected.id
         JOIN content c ON c.id = eligible.id JOIN app_user u ON u.id = c.author_id
         JOIN user_profile p ON p.user_id = u.id
       )
       SELECT e.id, e.author_id, e.body, e.kind, e.mime_type, e.created_at,e.updated_at, e.author_handle,
         e.author_display_name, e.author_avatar_id, e.like_count, e.reply_count, e.liked, e.saved, e.has_attachments,
         l.taxonomy_version, l.dimension, l.label_id, l.confidence, l.source,
         sem.semantic_positive,sem.semantic_negative,random_source.random_position
       FROM selected_candidates e JOIN content_label l ON l.content_id = e.id
         AND l.taxonomy_version = $1 AND l.status = 'active'
       LEFT JOIN semantic_scores sem ON sem.id=e.id
       LEFT JOIN random_candidates random_source ON random_source.id=e.id
       ORDER BY e.created_at DESC, e.id DESC, l.dimension, l.label_id''';

List<Object?> candidateRetrievalParameters({
  required String viewerId,
  required RankerConfig config,
  required int candidateLimit,
  String randomSeed = '00000000000000000000000000000000',
  List<String> excludedIds = const [],
  DateTime? audienceWindowStart,
}) {
  if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(randomSeed)) {
    throw ArgumentError('Invalid random feed nonce.');
  }
  return [
    config.taxonomyVersion,
    viewerId,
    DateTime.fromMillisecondsSinceEpoch(config.nowMs.toInt(), isUtc: true),
    candidateLimit,
    config.minimumPreferenceConfidence,
    config.preferenceHalfLifeMs,
    jsonEncode(config.adjacentLabels),
    SemanticConfig().enabled ? semanticModelVersion : '',
    SemanticConfig().minimumSimilarity,
    SemanticConfig().negativeMargin,
    randomSeed,
    excludedIds,
    audienceWindowStart,
    Platform.environment['RECOMMENDATION_ADAPTIVE_ENABLED'] == 'true',
  ];
}
