import 'dart:io';

import 'package:ionic_server/src/modules/recommendation/content_labeler.dart';
import 'package:ionic_server/src/modules/recommendation/ranker.dart';
import 'package:ionic_server/src/modules/recommendation/ranker_config.dart';
import 'package:ionic_server/src/modules/recommendation/text_label_rules.dart';
import 'package:ionic_server/src/modules/recommendation/types.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

void main() {
  const now = 1793491200000.0;
  final config = buildRankerConfig(now, environment: {});
  final version = config.taxonomyVersion;
  var checks = 0;
  void check(bool value, String name) {
    if (!value) throw StateError(name);
    checks++;
  }

  List<ContentLabel> labels(String text) => labelContent(
    LabelContentInput(
      taxonomyVersion: version,
      kind: ContentKind.text,
      text: text,
      formatLabelIds: const {ContentKind.text: 'format.text'},
      keywordRules: textLabelRules,
    ),
  );
  Set<String> keys(String text) => labels(text).map((l) => l.labelId).toSet();
  for (final sample in {
    'topic.design': 'THIET KE GIAO DIEN',
    'topic.software': 'lap trinh phan mem',
    'topic.product': 'san pham roadmap',
    'topic.writing': 'storytelling',
    'topic.learning': 'hoc tap kien thuc',
    'topic.creativity': 'sang tao y tuong',
    'topic.music': 'am nhac guitar',
    'topic.food': 'nau an mon an',
    'topic.travel': 'du lich travel',
    'topic.gaming': 'gaming gameplay',
    'topic.photography': 'nhiep anh ong kinh',
    'topic.film': 'dien anh cinema',
    'topic.books': 'doc sach tieu thuyet',
    'topic.sports': 'bong da the thao',
    'topic.nature': 'thien nhien wildlife',
    'topic.science': 'thien van vat ly',
    'topic.crafts': 'thu cong origami',
    'topic.pets': 'thu cung nuoi meo',
  }.entries) {
    check(
      keys(sample.value).contains(sample.key),
      'Neutral topic ${sample.key}',
    );
  }
  check(
    keys(unorm.nfd('THIẾT KẾ GIAO DIỆN')).contains('topic.design'),
    'Decomposed Unicode normalization',
  );
  check(
    !keys('decode apiculture designation').contains('topic.software'),
    'Whole-token boundaries',
  );
  check(
    !keys('ban va cua').contains('language.vi'),
    'Diacritic folding does not guess language',
  );
  check(
    keys('mình và bạn').contains('language.vi'),
    'Language rule retains original tokens',
  );

  ViewerProfile profile({
    List<PreferenceFeature> preferences = const [],
    List<ExplicitInterest> explicit = const [],
    List<TaxonomyLabelRef> less = const [],
    List<String> blocked = const [],
    List<String> muted = const [],
    List<String> hidden = const [],
  }) => ViewerProfile(
    explicitInterests: explicit,
    preferences: preferences,
    followingCreatorIds: const [],
    blockedCreatorIds: blocked,
    mutedCreatorIds: muted,
    hiddenContentIds: hidden,
    hiddenLabels: const [],
    lessLikeLabels: less,
    recentExposures: const [],
  );
  FeedCandidate candidate(String id, String text) => FeedCandidate(
    id: id,
    creatorId: id,
    kind: ContentKind.text,
    publishedAtMs: now - 3600000,
    labels: labels(text),
    eligible: true,
    visibleToViewer: true,
  );
  final pool = [
    candidate('design', 'thiết kế'),
    candidate('product', 'sản phẩm'),
    candidate('astronomy', 'thiên văn'),
    candidate('music', 'âm nhạc'),
  ];
  PreferenceFeature learned(double age) => PreferenceFeature(
    taxonomyVersion: version,
    dimension: LabelDimension.topic,
    labelId: 'topic.design',
    sourceSummary: const [PreferenceSignalKind.like],
    score: .8,
    confidence: .8,
    updatedAtMs: now - age,
    expiresAtMs: now + 86400000,
  );
  final negative = profile(
    preferences: [learned(0)],
    less: [
      TaxonomyLabelRef(
        taxonomyVersion: version,
        dimension: LabelDimension.topic,
        labelId: 'topic.design',
      ),
    ],
  );
  final negativeRank = rankCandidates(pool, negative, config, 4);
  check(
    negativeRank.firstWhere((r) => r.candidate.id == 'product').tier ==
        RelevanceTier.fresh,
    'Explicit less overrides a learned source of adjacent discovery',
  );
  final positiveRank = rankCandidates(
    pool,
    profile(preferences: [learned(0)]),
    config,
    4,
  );
  check(
    positiveRank.first.candidate.id == 'design',
    'Learned strong match leads',
  );
  check(
    positiveRank.firstWhere((r) => r.candidate.id == 'product').tier ==
        RelevanceTier.adjacent,
    'Eligible positive source supports adjacent discovery',
  );
  final decayed = rankCandidates(
    pool,
    profile(preferences: [learned(14 * 86400000)]),
    config,
    4,
  );
  check(
    decayed.every((r) => r.tier == RelevanceTier.fresh),
    'Confidence decay removes stale strong evidence',
  );
  final filtered = rankCandidates(
    pool,
    profile(blocked: ['design'], muted: ['product'], hidden: ['astronomy']),
    config,
    4,
  );
  check(
    filtered.length == 1 && filtered.single.candidate.id == 'music',
    'Hard eligibility controls survive ranking',
  );
  check(rankCandidates([], profile(), config, 10).isEmpty, 'Empty fallback');
  final repeat = rankCandidates(
    pool,
    profile(preferences: [learned(0)]),
    config,
    4,
  );
  check(
    repeat.map((r) => r.candidate.id).join() ==
        positiveRank.map((r) => r.candidate.id).join(),
    'Deterministic order',
  );
  check(
    pool.first.id == 'design' && pool.length == 4,
    'Ranker does not mutate input',
  );
  stdout.writeln(
    'PASS: $checks recommendation core checks; $textLabelRulesVersion; ${config.rankerVersion}.',
  );
}
