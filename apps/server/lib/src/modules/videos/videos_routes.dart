import 'dart:convert';

import 'package:ionic_server/src/modules/auth/auth_routes.dart';
import 'package:ionic_server/src/modules/auth/auth_service.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/videos/videos_service.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

class _ByteRange {
  const _ByteRange(this.start, this.end);

  final int start;
  final int end;
}

Handler createVideosRoutes(DatabaseService database) {
  final auth = AuthService(database);
  final videos = VideosService(database);
  final router = Router()
    ..get('/', (Request request) => _list(request, auth, videos))
    ..post('/upload', (Request request) => _upload(request, auth, videos))
    ..get(
      '/<contentId>/file',
      (Request request, String contentId) =>
          _file(request, contentId, auth, videos),
    );
  return router.call;
}

Future<Response> _list(
  Request request,
  AuthService auth,
  VideosService videos,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  return _json(200, await videos.list(user.id));
}

Future<Response> _upload(
  Request request,
  AuthService auth,
  VideosService videos,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  return _json(
    201,
    await videos.upload(user.id, request.read(), request.headers),
  );
}

Future<Response> _file(
  Request request,
  String contentId,
  AuthService auth,
  VideosService videos,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  final asset = await videos.playback(user.id, contentId);
  final headers = <String, Object>{
    'accept-ranges': 'bytes',
    'cache-control': 'private, no-store',
    'content-type': asset.mimeType,
    'x-content-type-options': 'nosniff',
  };
  final rangeHeader = request.headers['range'];
  final range = _parseRange(rangeHeader, asset.byteSize);
  if (range == _invalidRange) {
    return Response(
      416,
      headers: {...headers, 'content-range': 'bytes */${asset.byteSize}'},
    );
  }
  if (range is _ByteRange) {
    final length = range.end - range.start + 1;
    return Response(
      206,
      body: asset.path.openRead(range.start, range.end + 1),
      headers: {
        ...headers,
        'content-range': 'bytes ${range.start}-${range.end}/${asset.byteSize}',
        'content-length': '$length',
      },
    );
  }
  return Response(
    200,
    body: asset.path.openRead(),
    headers: {...headers, 'content-length': '${asset.byteSize}'},
  );
}

const _invalidRange = Object();

Object? _parseRange(String? input, int size) {
  if (input == null) return null;
  final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(input.trim());
  if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) {
    return _invalidRange;
  }
  final startInput = match[1]!;
  final endInput = match[2]!;
  late int start;
  late int end;
  if (startInput.isEmpty) {
    final suffix = int.tryParse(endInput);
    if (suffix == null || suffix < 1) return _invalidRange;
    start = size > suffix ? size - suffix : 0;
    end = size - 1;
  } else {
    start = int.tryParse(startInput) ?? -1;
    end = endInput.isEmpty ? size - 1 : int.tryParse(endInput) ?? -1;
  }
  if (start < 0 || end < start || start >= size) return _invalidRange;
  if (end >= size) end = size - 1;
  return _ByteRange(start, end);
}

Response _json(int statusCode, Object value) => Response(
  statusCode,
  body: jsonEncode(value),
  headers: const {'content-type': 'application/json; charset=utf-8'},
);
