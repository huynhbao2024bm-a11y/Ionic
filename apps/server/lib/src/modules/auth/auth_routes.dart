import 'dart:convert';

import 'package:ionic_server/src/http/request_body.dart';
import 'package:ionic_server/src/modules/auth/auth_service.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

Handler createAuthRoutes(DatabaseService database) {
  final auth = AuthService(database);
  final router = Router()
    ..post('/register', (Request request) => _register(request, auth))
    ..post('/login', (Request request) => _login(request, auth))
    ..post('/logout', (Request request) => _logout(request, auth))
    ..get('/me', (Request request) => _currentUser(request, auth));
  return router.call;
}

Future<AuthenticatedUser> requireAuthenticatedUser(
  Request request,
  AuthService auth,
) => auth.authenticate(readSessionToken(request.headers['cookie']));

Future<Response> _register(Request request, AuthService auth) async {
  final result = await auth.register(await readJsonObject(request));
  return Response(
    201,
    body: jsonResponse({'user': result.user.toJson()}),
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'set-cookie': sessionCookie(result.token),
    },
  );
}

Future<Response> _login(Request request, AuthService auth) async {
  final result = await auth.login(await readJsonObject(request));
  return Response(
    201,
    body: jsonResponse({'user': result.user.toJson()}),
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'set-cookie': sessionCookie(result.token),
    },
  );
}

Future<Response> _logout(Request request, AuthService auth) async {
  await auth.logout(readSessionToken(request.headers['cookie']));
  return Response(
    201,
    body: jsonResponse(const {'status': 'signed_out'}),
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'set-cookie': clearSessionCookie(),
    },
  );
}

Future<Response> _currentUser(Request request, AuthService auth) async {
  final user = await requireAuthenticatedUser(request, auth);
  return Response.ok(
    jsonResponse({'user': user.toJson()}),
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

String jsonResponse(Object value) => const JsonEncoder().convert(value);
