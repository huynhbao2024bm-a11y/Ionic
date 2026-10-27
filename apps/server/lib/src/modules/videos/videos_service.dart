import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ionic_server/src/http/api_exception.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/recommendation/content_labeler.dart';
import 'package:ionic_server/src/modules/recommendation/text_label_rules.dart';
import 'package:ionic_server/src/modules/recommendation/types.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

const _maxUploadBytes = 60 * 1024 * 1024;
final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
);

class VideosService {
  VideosService(this._database)
    : _storageDirectory = Directory(
        Platform.environment['IONIC_MEDIA_DIR'] ?? '.data/media',
      ).absolute;

  final DatabaseService _database;
  final Directory _storageDirectory;

  Future<Map<String, Object?>> list(String viewerId) async {
    final result = await _database.query(
      r'''SELECT c.id, c.author_id, u.handle, p.display_name, c.body,
                c.created_at, a.mime_type, a.state
         FROM content c
         JOIN video_asset a ON a.content_id = c.id
         JOIN app_user u ON u.id = c.author_id AND u.state = 'active'
         JOIN user_profile p ON p.user_id = u.id
         WHERE c.kind = 'short_video' AND c.deleted_at IS NULL AND
           ((c.visibility = 'public' AND c.status = 'published' AND a.state = 'ready')
             OR (c.author_id = $1 AND c.status = 'processing'))
           AND NOT EXISTS (
             SELECT 1 FROM account_block b WHERE
               (b.blocker_id = $1 AND b.blocked_id = c.author_id)
                OR (b.blocker_id = c.author_id AND b.blocked_id = $1)
           )
         ORDER BY c.created_at DESC, c.id DESC
         LIMIT 40''',
      parameters: [viewerId],
    );
    return {
      'items': result.map((row) => _videoView(row.toColumnMap())).toList(),
    };
  }

  Future<Map<String, Object?>> upload(
    String authorId,
    Stream<List<int>> bodyStream,
    Map<String, String> headers,
  ) async {
    final caption = _parseCaption(headers['x-ionic-caption']);
    final mimeType = _parseMimeType(headers['content-type']);
    final declaredLength = headers['content-length'];
    if (declaredLength != null) {
      final parsedLength = int.tryParse(declaredLength);
      if (parsedLength == null || parsedLength < 0) {
        throw const ApiException(400, 'Content length is invalid.');
      }
      if (parsedLength > _maxUploadBytes) {
        throw const ApiException(413, 'Video exceeds the 60 MB upload limit.');
      }
    }

    final id = _randomUuid();
    final storageKey = _randomUuid();
    await _storageDirectory.create(recursive: true);
    final temporaryFile = File(
      '${_storageDirectory.path}${Platform.pathSeparator}$storageKey.part',
    );
    final finalFile = File(
      '${_storageDirectory.path}${Platform.pathSeparator}$storageKey',
    );
    var size = 0;
    try {
      final output = await temporaryFile.open(mode: FileMode.writeOnly);
      try {
        await for (final chunk in bodyStream) {
          size += chunk.length;
          if (size > _maxUploadBytes) {
            throw const ApiException(
              413,
              'Video exceeds the 60 MB upload limit.',
            );
          }
          await output.writeFrom(chunk);
        }
        await output.flush();
      } finally {
        await output.close();
      }
      if (size == 0) throw const ApiException(400, 'Video file is empty.');
      final headerFile = await temporaryFile.open(mode: FileMode.read);
      Uint8List header;
      try {
        header = await headerFile.read(12);
      } finally {
        await headerFile.close();
      }
      if (!_looksLikeVideo(header, mimeType)) {
        throw const ApiException(
          400,
          'Video file content does not match its type.',
        );
      }
      await temporaryFile.rename(finalFile.path);

      final taxonomyVersion = _taxonomyVersion();
      final labels = labelContent(
        LabelContentInput(
          taxonomyVersion: taxonomyVersion,
          kind: ContentKind.short_video,
          text: caption,
          formatLabelIds: const {
            ContentKind.text: 'format.text',
            ContentKind.short_video: 'format.short_video',
          },
          keywordRules: textLabelRules,
        ),
      );
      final created = await _database.transaction((transaction) async {
        final content = await transaction.execute(
          r'''INSERT INTO content (id, author_id, kind, body, status)
              VALUES ($1, $2, 'short_video', $3, 'processing')
              RETURNING id, author_id, body, created_at''',
          parameters: [id, authorId, caption],
        );
        await transaction.execute(
          r'''INSERT INTO video_asset(content_id, storage_key, mime_type, byte_size, state)
              VALUES ($1, $2, $3, $4, 'pending_review')''',
          parameters: [id, storageKey, mimeType, size],
        );
        for (final label in labels) {
          await transaction.execute(
            r'''INSERT INTO content_label
                (content_id, taxonomy_version, dimension, label_id, confidence, source)
                VALUES ($1, $2, $3, $4, $5, $6)''',
            parameters: [
              id,
              label.taxonomyVersion,
              label.dimension.name,
              label.labelId,
              label.confidence,
              label.source.name,
            ],
          );
        }
        final author = await transaction.execute(
          r'''SELECT u.handle, p.display_name FROM app_user u
              JOIN user_profile p ON p.user_id = u.id WHERE u.id = $1''',
          parameters: [authorId],
        );
        if (author.isEmpty || content.isEmpty) {
          throw const ApiException(404, 'Account was not found.');
        }
        return {...content.first.toColumnMap(), ...author.first.toColumnMap()};
      });
      return {
        'id': '${created['id']}',
        'authorId': '${created['author_id']}',
        'authorHandle': '${created['handle']}',
        'authorDisplayName': '${created['display_name']}',
        'caption': '${created['body']}',
        'createdAt': _dateTime(created['created_at']).toUtc().toIso8601String(),
        'mimeType': mimeType,
        'state': 'pending_review',
      };
    } catch (_) {
      await _deleteIfExists(temporaryFile);
      await _deleteIfExists(finalFile);
      rethrow;
    }
  }

  Future<StoredVideo> playback(String viewerId, String inputId) async {
    if (!_uuidPattern.hasMatch(inputId)) {
      throw const ApiException(400, 'Video ID is invalid.');
    }
    final result = await _database.query(
      r'''SELECT c.author_id, c.status, a.storage_key, a.mime_type, a.byte_size
         FROM content c
         JOIN video_asset a ON a.content_id = c.id
         JOIN app_user u ON u.id = c.author_id AND u.state = 'active'
         WHERE c.id = $1 AND c.kind = 'short_video' AND c.deleted_at IS NULL
           AND ((c.author_id = $2 AND c.status = 'processing') OR
             (c.visibility = 'public' AND c.status = 'published' AND a.state = 'ready'))
           AND NOT EXISTS (
             SELECT 1 FROM account_block b WHERE
               (b.blocker_id = $2 AND b.blocked_id = c.author_id)
                OR (b.blocker_id = c.author_id AND b.blocked_id = $2)
           )''',
      parameters: [inputId, viewerId],
    );
    if (result.isEmpty) throw const ApiException(404, 'Video was not found.');
    final asset = result.first.toColumnMap();
    final storageKey = '${asset['storage_key']}';
    final byteSize = _number(asset['byte_size']);
    if (!_uuidPattern.hasMatch(storageKey) || byteSize < 1) {
      throw const ApiException(404, 'Video was not found.');
    }
    final mimeType = '${asset['mime_type']}';
    if (mimeType != 'video/webm' && mimeType != 'video/mp4') {
      throw const ApiException(404, 'Video was not found.');
    }
    final file = File(
      '${_storageDirectory.path}${Platform.pathSeparator}$storageKey',
    );
    if (!await file.exists()) {
      throw const ApiException(404, 'Video was not found.');
    }
    return StoredVideo(path: file, mimeType: mimeType, byteSize: byteSize);
  }
}

class StoredVideo {
  const StoredVideo({
    required this.path,
    required this.mimeType,
    required this.byteSize,
  });

  final File path;
  final String mimeType;
  final int byteSize;
}

Map<String, Object?> _videoView(Map<String, dynamic> value) => {
  'id': '${value['id']}',
  'authorId': '${value['author_id']}',
  'authorHandle': '${value['handle']}',
  'authorDisplayName': '${value['display_name']}',
  'caption': '${value['body']}',
  'createdAt': _dateTime(value['created_at']).toUtc().toIso8601String(),
  'mimeType': '${value['mime_type']}',
  'state': '${value['state']}',
};

String _parseCaption(String? encoded) {
  if (encoded == null ||
      encoded.length > 2240 ||
      encoded.length.isOdd ||
      !RegExp(r'^[0-9a-f]*$', caseSensitive: false).hasMatch(encoded)) {
    throw const ApiException(400, 'Caption is invalid.');
  }
  try {
    final bytes = <int>[];
    for (var index = 0; index < encoded.length; index += 2) {
      bytes.add(int.parse(encoded.substring(index, index + 2), radix: 16));
    }
    final decoded = utf8.decode(bytes, allowMalformed: false);
    if (utf8
            .encode(decoded)
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join() !=
        encoded.toLowerCase()) {
      throw const FormatException();
    }
    final caption = unorm.nfc(decoded.trim());
    if (caption.isEmpty || caption.length > 280) {
      throw const ApiException(400, 'Caption must contain 1–280 characters.');
    }
    return caption;
  } on ApiException {
    rethrow;
  } on Object {
    throw const ApiException(400, 'Caption is invalid.');
  }
}

String _parseMimeType(String? input) {
  final value = input?.split(';').first.trim().toLowerCase();
  if (value == null || (value != 'video/webm' && value != 'video/mp4')) {
    throw const ApiException(400, 'Use a WebM or MP4 video.');
  }
  return value;
}

bool _looksLikeVideo(List<int> header, String mimeType) {
  final webm =
      header.length >= 4 &&
      header[0] == 0x1a &&
      header[1] == 0x45 &&
      header[2] == 0xdf &&
      header[3] == 0xa3;
  final mp4 =
      header.length >= 8 &&
      ascii.decode(header.sublist(4, 8), allowInvalid: true) == 'ftyp';
  return (mimeType == 'video/webm' && webm) || (mimeType == 'video/mp4' && mp4);
}

String _taxonomyVersion() {
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

DateTime _dateTime(Object? value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.parse(value);
  throw StateError('Database returned an invalid timestamp.');
}

int _number(Object? value) =>
    value is num ? value.toInt() : int.parse('$value');

String _randomUuid() {
  final random = Random.secure();
  final bytes = Uint8List.fromList(
    List<int>.generate(16, (_) => random.nextInt(256)),
  );
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

Future<void> _deleteIfExists(File file) async {
  if (await file.exists()) await file.delete();
}
