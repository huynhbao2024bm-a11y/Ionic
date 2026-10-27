import 'dart:convert';

import 'package:shelf/shelf.dart';

class ApiException implements Exception {
  const ApiException(this.statusCode, this.message);

  final int statusCode;
  final String message;
}

Response apiErrorResponse(ApiException error) {
  final (title, label) = switch (error.statusCode) {
    400 => ('Bad Request', 'Bad Request'),
    401 => ('Unauthorized', 'Unauthorized'),
    403 => ('Forbidden', 'Forbidden'),
    404 => ('Not Found', 'Not Found'),
    409 => ('Conflict', 'Conflict'),
    413 => ('Payload Too Large', 'Payload Too Large'),
    429 => ('Too Many Requests', 'Too Many Requests'),
    503 => ('Service Unavailable', 'Service Unavailable'),
    _ => ('Internal Server Error', 'Internal Server Error'),
  };
  return Response(
    error.statusCode,
    body: jsonEncode({
      'statusCode': error.statusCode,
      'error': label.isEmpty ? title : label,
      'message': error.message,
    }),
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}
