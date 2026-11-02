import '../trust/moderation_service.dart';

import 'dart:isolate';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:ionic_server/src/http/api_exception.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';

import 'media_cleanup_service.dart';

import 'attachment_storage.dart';

const maximumImageBytes = 8 * 1024 * 1024;
const maximumVoiceBytes = 2 * 1024 * 1024;
const maximumImagePixels = 16 * 1024 * 1024;
const maximumImageDimension = 8192;

final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
);

bool _uploadInProgress = false;

class MediaService {
  MediaService(
    this._database, {
    AttachmentStorage? storage,
    int? accountBudgetBytes,
    int? totalBudgetBytes,
  }) : _storage = storage ?? AttachmentStorage.fromEnvironment(),
       _accountBudget =
           accountBudgetBytes ??
           int.tryParse(
             Platform.environment['IONIC_MEDIA_ACCOUNT_BUDGET_BYTES'] ?? '',
           ) ??
           64 * 1024 * 1024,
       _totalBudget =
           totalBudgetBytes ??
           int.tryParse(
             Platform.environment['IONIC_MEDIA_TOTAL_BUDGET_BYTES'] ?? '',
           ) ??
           700 * 1024 * 1024;

  final DatabaseService _database;
  final AttachmentStorage _storage;
  final int _accountBudget, _totalBudget;

  Future<Map<String, Object?>> upload(
    String ownerId,
    Stream<List<int>> stream,
    Map<String, String> headers,
  ) async {
    if (_uploadInProgress) {
      throw const ApiException(
        503,
        'An attachment is being processed. Try again shortly.',
      );
    }
    _uploadInProgress = true;
    try {
      return await _upload(ownerId, stream, headers);
    } finally {
      _uploadInProgress = false;
    }
  }

  Future<Map<String, Object?>> _upload(
    String ownerId,
    Stream<List<int>> stream,
    Map<String, String> headers,
  ) async {
    await _cleanupExpiredStaging();
    await MediaCleanupService(
      _database,
      attachmentStorage: _storage,
      maxJobs: 8,
    ).drainBestEffort();
    final rawMediaType = headers['x-ionic-media-type'];
    if (rawMediaType == null ||
        (rawMediaType != 'image' && rawMediaType != 'audio')) {
      throw const ApiException(400, 'Media type is not supported.');
    }
    final mediaType = rawMediaType;
    final mimeType = mediaType == 'image' ? 'image/jpeg' : 'audio/wav';
    final maximumBytes = mediaType == 'image'
        ? maximumImageBytes
        : maximumVoiceBytes;
    final declaredLength = headers['content-length'];
    if (declaredLength != null) {
      final parsedLength = int.tryParse(declaredLength);
      if (parsedLength == null || parsedLength < 0) {
        throw const ApiException(400, 'Content length is invalid.');
      }
      if (parsedLength > maximumBytes) {
        throw ApiException(
          413,
          'Attachment exceeds the $maximumBytes byte limit.',
        );
      }
    }

    final input = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (input.length + chunk.length > maximumBytes) {
        throw ApiException(
          413,
          'Attachment exceeds the $maximumBytes byte limit.',
        );
      }
      input.add(chunk);
    }
    final bytes = input.takeBytes();
    if (bytes.isEmpty) throw const ApiException(400, 'Attachment is empty.');

    late final Uint8List storedBytes;
    late final int? width;
    late final int? height;
    late final int? durationMs;
    if (mediaType == 'image') {
      final result = await _sanitizeOffThread(bytes);
      storedBytes = result.bytes;
      width = result.width;
      height = result.height;
      durationMs = null;
      if (storedBytes.length > maximumImageBytes) {
        throw const ApiException(
          413,
          'Optimized image exceeds the upload limit.',
        );
      }
    } else {
      durationMs = _validateWave(bytes);
      storedBytes = bytes;
      width = null;
      height = null;
    }

    final id = _randomUuid();
    final storageKey = _randomUuid();
    try {
      await _database.transaction((tx) async {
        await tx.execute(
          "SELECT pg_advisory_xact_lock(hashtext('ionic:attachment-budget'))",
        );
        final budget = (await tx.execute(
          r"""
          SELECT coalesce(sum(byte_size),0)::bigint AS total,
            coalesce(sum(byte_size) FILTER(WHERE owner_id=$1),0)::bigint AS owned,
            EXISTS(SELECT 1 FROM media_deletion_job WHERE storage_kind='attachment') AS cleanup_pending
          FROM media_asset""",
          parameters: [ownerId],
        )).first.toColumnMap();
        if (budget['cleanup_pending'] == true) {
          throw const ApiException(
            503,
            'Storage cleanup is pending.',
            code: 'MEDIA_CLEANUP_PENDING',
          );
        }
        if (_accountBudget < 1 ||
            _totalBudget < 1 ||
            (budget['total'] as int) + storedBytes.length > _totalBudget) {
          throw const ApiException(
            413,
            'Preview storage budget is full.',
            code: 'MEDIA_QUOTA_TOTAL',
          );
        }
        if ((budget['owned'] as int) + storedBytes.length > _accountBudget) {
          throw const ApiException(
            413,
            'Account storage budget is full.',
            code: 'MEDIA_QUOTA_ACCOUNT',
          );
        }
        await tx.execute(
          r'''INSERT INTO media_asset
             (id, owner_id, storage_key, media_type, mime_type, byte_size,
              width, height, duration_ms, processing_state)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'staged')''',
          parameters: [
            id,
            ownerId,
            storageKey,
            mediaType,
            mimeType,
            storedBytes.length,
            width,
            height,
            durationMs,
          ],
        );
      });
      // Retain a private staged row before network I/O so interrupted uploads
      // can expire and enqueue deletion; the opaque ID is returned after write.
      await _storage.write(storageKey, storedBytes, mimeType);
    } catch (_) {
      try {
        await _database.query(
          r"DELETE FROM media_asset WHERE id=$1 AND processing_state='staged'",
          parameters: [id],
        );
      } catch (_) {
        /* Staging expiry retries if the database is unavailable. */
      }
      rethrow;
    }
    return _view(
      id: id,
      mediaType: mediaType,
      mimeType: mimeType,
      byteSize: storedBytes.length,
      width: width,
      height: height,
      durationMs: durationMs,
    );
  }

  Future<StoredAttachment> read(String? viewerId, String inputId) async {
    if (!_uuidPattern.hasMatch(inputId)) {
      throw const ApiException(400, 'Attachment ID is invalid.');
    }
    var result = await _database.query(
      r'''SELECT a.storage_key, a.media_type, a.mime_type, a.byte_size
         FROM media_asset a
         JOIN content_attachment ca ON ca.media_asset_id = a.id
         LEFT JOIN content_reply r ON r.id = ca.reply_id AND r.status = 'published'
         JOIN content c ON c.id = COALESCE(ca.content_id, r.content_id)
         JOIN app_user u ON u.id = c.author_id AND u.state = 'active'
         JOIN app_user asset_owner ON asset_owner.id = a.owner_id AND asset_owner.state = 'active'
         JOIN user_profile p ON p.user_id = u.id
         WHERE a.id = $1 AND a.processing_state = 'ready'
           AND c.visibility = 'public' AND c.status = 'published' AND c.deleted_at IS NULL
           AND (p.visibility = 'public' OR ($2::uuid IS NOT NULL AND (
             u.id = $2 OR EXISTS (
               SELECT 1 FROM account_follow f WHERE f.follower_id = $2 AND f.followed_id = u.id
             )
           )))
           AND ($2::uuid IS NULL OR NOT EXISTS (
             SELECT 1 FROM account_block b
             WHERE (b.blocker_id = $2 AND b.blocked_id = u.id)
                OR (b.blocker_id = u.id AND b.blocked_id = $2)
                OR (b.blocker_id = $2 AND b.blocked_id = a.owner_id)
                OR (b.blocker_id = a.owner_id AND b.blocked_id = $2)
           ))''',
      parameters: [inputId, viewerId],
    );
    if (result.isEmpty) {
      result = await _database.query(
        r'''SELECT a.storage_key, a.media_type, a.mime_type, a.byte_size
        FROM media_asset a JOIN user_profile p ON p.avatar_media_id=a.id
        JOIN app_user u ON u.id=p.user_id AND u.state='active'
        WHERE a.id=$1 AND a.owner_id=u.id AND a.media_type='image' AND a.processing_state='ready'
          AND (p.visibility='public' OR u.id=$2 OR EXISTS(
            SELECT 1 FROM account_follow f WHERE f.follower_id=$2 AND f.followed_id=u.id))
          AND ($2::uuid IS NULL OR NOT EXISTS(SELECT 1 FROM account_block b
            WHERE (b.blocker_id=$2 AND b.blocked_id=u.id) OR (b.blocker_id=u.id AND b.blocked_id=$2)))''',
        parameters: [inputId, viewerId],
      );
    }
    if (result.isEmpty && viewerId != null) {
      // Review access is limited to the exact reported target; no private browsing.
      result = await ModerationService(_database)
          .reportedMedia(inputId, viewerId);
    }
    if (result.isEmpty) {
      throw const ApiException(404, 'Attachment was not found.');
    }
    final row = result.first.toColumnMap();
    final storageKey = '${row['storage_key']}';
    if (!_uuidPattern.hasMatch(storageKey)) {
      throw const ApiException(404, 'Attachment was not found.');
    }
    final mimeType = '${row['mime_type']}';
    if (mimeType != 'image/jpeg' && mimeType != 'audio/wav') {
      throw const ApiException(404, 'Attachment was not found.');
    }
    final size = (row['byte_size'] as num).toInt();
    if (size < 1 || size > maximumImageBytes) {
      throw const ApiException(404, 'Attachment was not found.');
    }
    return StoredAttachment(
      stream: await _storage.read(storageKey, size),
      mimeType: mimeType,
      byteSize: size,
    );
  }

  Future<void> deleteStaged(String ownerId, String inputId) async {
    if (!_uuidPattern.hasMatch(inputId)) {
      throw const ApiException(400, 'Attachment ID is invalid.');
    }
    final removed = await _database.transaction((transaction) async {
      final result = await transaction.execute(
        r'''DELETE FROM media_asset a
            WHERE a.id = $1 AND a.owner_id = $2 AND a.processing_state = 'staged'
              AND NOT EXISTS (SELECT 1 FROM content_attachment ca WHERE ca.media_asset_id = a.id)
            RETURNING storage_key''',
        parameters: [inputId, ownerId],
      );
      return result.isEmpty ? null : '${result.first.first}';
    });
    if (removed == null || !_uuidPattern.hasMatch(removed)) {
      throw const ApiException(404, 'Staged attachment was not found.');
    }
    await _storage.delete(removed);
  }

  Future<void> _cleanupExpiredStaging() async {
    final removed = await _database.transaction((transaction) async {
      final result = await transaction.execute(r'''DELETE FROM media_asset a
            WHERE a.id IN (
              SELECT candidate.id FROM media_asset candidate
              WHERE candidate.created_at < now() - interval '24 hours'
                AND NOT EXISTS (
                  SELECT 1 FROM content_attachment ca WHERE ca.media_asset_id = candidate.id
                )
                AND NOT EXISTS (
                  SELECT 1 FROM user_profile p WHERE p.avatar_media_id = candidate.id
                )
              ORDER BY candidate.created_at
              LIMIT 100
              FOR UPDATE SKIP LOCKED
            )
            RETURNING storage_key''');
      return result.map((row) => '${row.first}').toList(growable: false);
    });
    for (final key in removed) {
      if (_uuidPattern.hasMatch(key)) {
        await _storage.delete(key);
      }
    }
  }
}

class StoredAttachment {
  const StoredAttachment({
    required this.stream,
    required this.mimeType,
    required this.byteSize,
  });

  final Stream<List<int>> stream;
  final String mimeType;
  final int byteSize;
}

Future<({Uint8List bytes, int width, int height})> _sanitizeOffThread(
  Uint8List input,
) => Isolate.run(() => _sanitizeJpeg(input));

({Uint8List bytes, int width, int height}) _sanitizeJpeg(Uint8List input) {
  final dimensions = _jpegDimensions(input);
  if (dimensions == null ||
      dimensions.width > maximumImageDimension ||
      dimensions.height > maximumImageDimension ||
      dimensions.width * dimensions.height > maximumImagePixels) {
    throw const ApiException(400, 'Image dimensions are not supported.');
  }
  final decoded = img.decodeJpg(input);
  if (decoded == null) throw const ApiException(400, 'Image data is invalid.');
  final oriented = img.bakeOrientation(decoded);
  final normalized = oriented.width > 2048 || oriented.height > 2048
      ? img.copyResize(
          oriented,
          width: oriented.width >= oriented.height ? 2048 : null,
          height: oriented.height > oriented.width ? 2048 : null,
        )
      : oriented;
  normalized.exif = img.ExifData();
  normalized.iccProfile = null;
  normalized.textData = null;
  final output = Uint8List.fromList(img.encodeJpg(normalized, quality: 88));
  return (bytes: output, width: normalized.width, height: normalized.height);
}

({int width, int height})? _jpegDimensions(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) return null;
  var offset = 2;
  while (offset + 4 < bytes.length) {
    if (bytes[offset] != 0xff) return null;
    while (offset < bytes.length && bytes[offset] == 0xff) {
      offset++;
    }
    if (offset >= bytes.length) return null;
    final marker = bytes[offset++];
    if (marker == 0xd9 || marker == 0xda) break;
    if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (offset + 2 > bytes.length) return null;
    final segmentLength = (bytes[offset] << 8) | bytes[offset + 1];
    if (segmentLength < 2 || offset + segmentLength > bytes.length) return null;
    if (const {
      0xc0,
      0xc1,
      0xc2,
      0xc3,
      0xc5,
      0xc6,
      0xc7,
      0xc9,
      0xca,
      0xcb,
      0xcd,
      0xce,
      0xcf,
    }.contains(marker)) {
      if (segmentLength < 7) return null;
      final height = (bytes[offset + 3] << 8) | bytes[offset + 4];
      final width = (bytes[offset + 5] << 8) | bytes[offset + 6];
      if (width < 1 || height < 1) return null;
      return (width: width, height: height);
    }
    offset += segmentLength;
  }
  return null;
}

int _validateWave(Uint8List bytes) {
  if (bytes.length < 44 ||
      String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE' ||
      String.fromCharCodes(bytes.sublist(12, 16)) != 'fmt ' ||
      String.fromCharCodes(bytes.sublist(36, 40)) != 'data') {
    throw const ApiException(400, 'Voice recording must be a PCM WAV file.');
  }
  final view = ByteData.sublistView(bytes);
  final riffSize = view.getUint32(4, Endian.little);
  final formatSize = view.getUint32(16, Endian.little);
  final format = view.getUint16(20, Endian.little);
  final channels = view.getUint16(22, Endian.little);
  final sampleRate = view.getUint32(24, Endian.little);
  final byteRate = view.getUint32(28, Endian.little);
  final blockAlign = view.getUint16(32, Endian.little);
  final bitsPerSample = view.getUint16(34, Endian.little);
  final dataSize = view.getUint32(40, Endian.little);
  if (riffSize != bytes.length - 8 ||
      formatSize != 16 ||
      format != 1 ||
      channels != 1 ||
      sampleRate != 16000 ||
      byteRate != 32000 ||
      blockAlign != 2 ||
      bitsPerSample != 16 ||
      dataSize != bytes.length - 44) {
    throw const ApiException(400, 'Voice recording format is not supported.');
  }
  final durationMs = (dataSize * 1000 / byteRate).round();
  if (durationMs < 1000 || durationMs > 60000) {
    throw const ApiException(400, 'Voice recording must be 1–60 seconds.');
  }
  return durationMs;
}

Map<String, Object?> attachmentView(Map<String, dynamic> row) => {
  'id': '${row['id']}',
  'mediaType': '${row['media_type']}',
  'mimeType': '${row['mime_type']}',
  'byteSize': (row['byte_size'] as num).toInt(),
  if (row['width'] != null) 'width': (row['width'] as num).toInt(),
  if (row['height'] != null) 'height': (row['height'] as num).toInt(),
  if (row['duration_ms'] != null)
    'durationMs': (row['duration_ms'] as num).toInt(),
};

Map<String, Object?> _view({
  required String id,
  required String mediaType,
  required String mimeType,
  required int byteSize,
  required int? width,
  required int? height,
  required int? durationMs,
}) => {
  'id': id,
  'mediaType': mediaType,
  'mimeType': mimeType,
  'byteSize': byteSize,
  'width': width,
  'height': height,
  'durationMs': durationMs,
};

String _randomUuid() {
  final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
