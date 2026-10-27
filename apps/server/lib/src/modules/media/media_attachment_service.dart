import 'package:ionic_server/src/http/api_exception.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/media/media_service.dart';
import 'package:postgres/postgres.dart';

List<String> parseAttachmentIds(Object? value) {
  if (value == null) return const [];
  if (value is! List ||
      value.length > 4 ||
      value.any((item) => item is! String)) {
    throw const ApiException(400, 'Attachments are invalid.');
  }
  final ids = value.cast<String>();
  final uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
  if (ids.toSet().length != ids.length || ids.any((id) => !uuid.hasMatch(id))) {
    throw const ApiException(400, 'Attachments are invalid.');
  }
  return ids;
}

Future<void> attachStagedMedia({
  required TxSession transaction,
  required String ownerId,
  required String parentId,
  required bool isReply,
  required List<String> attachmentIds,
}) async {
  if (attachmentIds.isEmpty) return;
  final staged = await transaction.execute(
    r'''SELECT a.id, a.media_type FROM media_asset a
        WHERE a.id = ANY($1::uuid[]) AND a.owner_id = $2
          AND a.processing_state = 'staged'
          AND NOT EXISTS (
            SELECT 1 FROM content_attachment ca WHERE ca.media_asset_id = a.id
          )
        ORDER BY a.id FOR UPDATE''',
    parameters: [attachmentIds, ownerId],
  );
  if (staged.length != attachmentIds.length) {
    throw const ApiException(400, 'An attachment is no longer available.');
  }
  final types = staged
      .map((row) => '${row.toColumnMap()['media_type']}')
      .toSet();
  if (types.length != 1) {
    throw const ApiException(
      400,
      'Combine images or one voice note, not both.',
    );
  }
  final mediaType = types.single;
  if ((mediaType == 'audio' && attachmentIds.length != 1) ||
      (mediaType != 'audio' && mediaType != 'image')) {
    throw const ApiException(400, 'Attachment combination is not supported.');
  }
  for (var index = 0; index < attachmentIds.length; index++) {
    await transaction.execute(
      r'''INSERT INTO content_attachment(media_asset_id, content_id, reply_id, position)
          VALUES ($1, $2, $3, $4)''',
      parameters: [
        attachmentIds[index],
        isReply ? null : parentId,
        isReply ? parentId : null,
        index,
      ],
    );
  }
  await transaction.execute(
    r'''UPDATE media_asset SET processing_state = 'ready'
        WHERE id = ANY($1::uuid[]) AND owner_id = $2''',
    parameters: [attachmentIds, ownerId],
  );
}

Future<Map<String, List<Map<String, Object?>>>> contentAttachmentViews(
  DatabaseService database,
  List<String> parentIds,
) async {
  if (parentIds.isEmpty) return const {};
  final rows = await database.query(
    r'''SELECT ca.content_id AS parent_id, a.id, a.media_type, a.mime_type,
               a.byte_size, a.width, a.height, a.duration_ms
        FROM content_attachment ca JOIN media_asset a ON a.id = ca.media_asset_id
        WHERE ca.content_id = ANY($1::uuid[]) AND a.processing_state = 'ready'
        ORDER BY ca.content_id, ca.position''',
    parameters: [parentIds],
  );
  return _groupAttachmentViews(rows);
}

Future<Map<String, List<Map<String, Object?>>>> replyAttachmentViews(
  DatabaseService database,
  List<String> parentIds,
) async {
  if (parentIds.isEmpty) return const {};
  final rows = await database.query(
    r'''SELECT ca.reply_id AS parent_id, a.id, a.media_type, a.mime_type,
               a.byte_size, a.width, a.height, a.duration_ms
        FROM content_attachment ca JOIN media_asset a ON a.id = ca.media_asset_id
        WHERE ca.reply_id = ANY($1::uuid[]) AND a.processing_state = 'ready'
        ORDER BY ca.reply_id, ca.position''',
    parameters: [parentIds],
  );
  return _groupAttachmentViews(rows);
}

Map<String, List<Map<String, Object?>>> _groupAttachmentViews(Result rows) {
  final result = <String, List<Map<String, Object?>>>{};
  for (final row in rows) {
    final value = row.toColumnMap();
    final parentId = '${value['parent_id']}';
    (result[parentId] ??= []).add(attachmentView(value));
  }
  return result;
}

Future<List<Map<String, Object?>>> attachmentsForContent(
  DatabaseService database,
  String contentId,
) async =>
    (await contentAttachmentViews(database, [contentId]))[contentId] ??
    const [];

Future<List<Map<String, Object?>>> attachmentsForReply(
  DatabaseService database,
  String replyId,
) async =>
    (await replyAttachmentViews(database, [replyId]))[replyId] ?? const [];
