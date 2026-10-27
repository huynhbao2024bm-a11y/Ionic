import 'content_labeler.dart';
import 'types.dart';

/// Versioned starter vocabulary for neutral topics; not a sensitive-trait classifier.
const textLabelRules = <KeywordRule>[
  KeywordRule(
    dimension: LabelDimension.topic,
    labelId: 'topic.design',
    terms: [
      'thiết kế',
      'giao diện',
      'trải nghiệm người dùng',
      'figma',
      'design',
      'user interface',
      'user experience',
    ],
    confidence: 0.8,
  ),
  KeywordRule(
    dimension: LabelDimension.topic,
    labelId: 'topic.software',
    terms: [
      'lập trình',
      'mã nguồn',
      'typescript',
      'javascript',
      'angular',
      'phần mềm',
      'software',
      'code',
      'api',
    ],
    confidence: 0.8,
  ),
  KeywordRule(
    dimension: LabelDimension.topic,
    labelId: 'topic.product',
    terms: [
      'sản phẩm',
      'product',
      'roadmap',
      'tính năng',
      'người dùng',
      'product design',
    ],
    confidence: 0.76,
  ),
  KeywordRule(
    dimension: LabelDimension.topic,
    labelId: 'topic.writing',
    terms: ['viết', 'bài viết', 'nội dung', 'writing', 'storytelling'],
    confidence: 0.76,
  ),
  KeywordRule(
    dimension: LabelDimension.topic,
    labelId: 'topic.learning',
    terms: ['học tập', 'bài học', 'kiến thức', 'learning', 'course'],
    confidence: 0.74,
  ),
  KeywordRule(
    dimension: LabelDimension.topic,
    labelId: 'topic.creativity',
    terms: ['sáng tạo', 'ý tưởng', 'brainstorm', 'creative'],
    confidence: 0.74,
  ),
  KeywordRule(
    dimension: LabelDimension.context,
    labelId: 'context.howto',
    terms: ['hướng dẫn', 'mẹo', 'cách làm', 'tutorial', 'how to'],
    confidence: 0.78,
  ),
  KeywordRule(
    dimension: LabelDimension.language,
    labelId: 'language.vi',
    terms: [
      'mình',
      'bạn',
      'và',
      'của',
      'được',
      'không',
      'những',
      'người',
      'trong',
      'với',
      'một',
      'các',
    ],
    minimumMatches: 2,
    confidence: 0.76,
  ),
];
