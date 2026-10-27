import 'dart:convert';

import 'package:ionic_server/src/http/api_exception.dart';
import 'package:ionic_server/src/http/request_body.dart';
import 'package:ionic_server/src/modules/auth/auth_routes.dart';
import 'package:ionic_server/src/modules/auth/auth_service.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/messages/messages_service.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

Handler createMessagesRoutes(DatabaseService database) {
  final auth = AuthService(database);
  final messages = MessagesService(database);
  final router = Router()
    ..get(
      '/conversations',
      (Request request) => _conversations(request, auth, messages),
    )
    ..post(
      '/conversations',
      (Request request) => _start(request, auth, messages),
    )
    ..get(
      '/conversations/<conversationId>',
      (Request request, String conversationId) =>
          _list(request, conversationId, auth, messages),
    )
    ..post(
      '/conversations/<conversationId>',
      (Request request, String conversationId) =>
          _send(request, conversationId, auth, messages),
    );
  return router.call;
}

Future<Response> _conversations(
  Request request,
  AuthService auth,
  MessagesService messages,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  return _json(200, await messages.listConversations(user.id));
}

Future<Response> _start(
  Request request,
  AuthService auth,
  MessagesService messages,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  return _json(
    201,
    await messages.startConversation(user.id, await readJsonObject(request)),
  );
}

Future<Response> _list(
  Request request,
  String conversationId,
  AuthService auth,
  MessagesService messages,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  final rawLimit = request.url.queryParameters['limit'];
  final limit = rawLimit == null ? 50 : int.tryParse(rawLimit);
  if (limit == null || limit < 1 || limit > 50) {
    throw const ApiException(400, 'Limit must be between 1 and 50.');
  }
  return _json(
    200,
    await messages.listMessages(
      user.id,
      conversationId,
      limit,
      request.url.queryParameters['cursor'],
    ),
  );
}

Future<Response> _send(
  Request request,
  String conversationId,
  AuthService auth,
  MessagesService messages,
) async {
  final user = await requireAuthenticatedUser(request, auth);
  return _json(
    201,
    await messages.sendMessage(
      user.id,
      conversationId,
      await readJsonObject(request),
    ),
  );
}

Response _json(int statusCode, Object value) => Response(
  statusCode,
  body: jsonEncode(value),
  headers: const {'content-type': 'application/json; charset=utf-8'},
);
