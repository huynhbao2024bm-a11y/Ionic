import 'dart:convert';

import 'package:shelf/shelf.dart';

import 'api_exception.dart';

Future<Map<String, Object?>> readJsonObject(
  Request request, {
  int maximumBytes = 16 * 1024,
}) async {
  final contentLength = int.tryParse(request.headers['content-length'] ?? '');
  if (contentLength != null && contentLength > maximumBytes) {
    throw ApiException(413, 'Request body is too large.');
  }

  final bytes = await request.read().fold<List<int>>(<int>[], (buffer, chunk) {
    if (buffer.length + chunk.length > maximumBytes) {
      throw ApiException(413, 'Request body is too large.');
    }
    return buffer..addAll(chunk);
  });
  if (bytes.isEmpty) return <String, Object?>{};

  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is Map<String, Object?>) return decoded;
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry('$key', value));
    }
  } on FormatException {
    throw const ApiException(400, 'Request body must be valid JSON.');
  }
  throw const ApiException(400, 'Body must be an object.');
}
