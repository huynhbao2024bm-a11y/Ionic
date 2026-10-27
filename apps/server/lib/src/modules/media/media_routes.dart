import 'dart:convert';

import 'package:ionic_server/src/http/api_exception.dart';
import 'package:ionic_server/src/modules/auth/auth_routes.dart';
import 'package:ionic_server/src/modules/auth/auth_service.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/media/media_service.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

Handler createMediaRoutes(DatabaseService database) {
  final auth = AuthService(database);
  final media = MediaService(database);
  final router = Router()
    ..post('/upload', (Request request) => _upload(request, auth, media))
    ..delete(
      '/<mediaId>/staged',
      (Request request, String mediaId) =>
          _deleteStaged(request, mediaId, auth, media),
    )
    ..get(
      '/<mediaId>/file',
      (Request request, String mediaId) => _file(request, mediaId, auth, media),
    );
  return router.call;
}

Future<Response> _upload(
  Request request,
  AuthService auth,
  MediaService media,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  final contentType = request.headers['content-type']?.split(';').first.trim();
  if (contentType != 'application/octet-stream') {
    throw const ApiException(400, 'Attachment request must be binary data.');
  }
  return _json(
    201,
    await media.upload(user.id, request.read(), request.headers),
  );
}

Future<Response> _deleteStaged(
  Request request,
  String mediaId,
  AuthService auth,
  MediaService media,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  await media.deleteStaged(user.id, mediaId);
  return _json(200, const {'status': 'deleted'});
}

Future<Response> _file(
  Request request,
  String mediaId,
  AuthService auth,
  MediaService media,
) async {
  String? viewerId;
  try {
    viewerId = (await auth.authenticate(
      readSessionToken(request.headers['cookie']),
    )).id;
  } on ApiException catch (error) {
    if (error.statusCode != 401) rethrow;
  }
  final asset = await media.read(viewerId, mediaId);
  return Response.ok(
    asset.path.openRead(),
    headers: {
      'content-type': asset.mimeType,
      'content-length': '${asset.byteSize}',
      'cache-control': 'private, no-store',
      'x-content-type-options': 'nosniff',
    },
  );
}

Response _json(int statusCode, Object value) => Response(
  statusCode,
  body: jsonEncode(value),
  headers: const {'content-type': 'application/json; charset=utf-8'},
);
