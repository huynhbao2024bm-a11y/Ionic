import 'dart:convert';

import 'package:ionic_server/src/http/request_body.dart';
import 'package:ionic_server/src/modules/auth/auth_service.dart';
import 'package:ionic_server/src/modules/database/database_service.dart';
import 'package:ionic_server/src/modules/media/media_cleanup_service.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

Handler createAuthRoutes(DatabaseService database) {
  final auth = AuthService(database);
  final router = Router()
    ..post('/register', (Request request) => _register(request, auth))
    ..post('/login', (Request request) => _login(request, auth))
    ..post('/logout', (Request request) => _logout(request, auth))
    ..get(
      '/settings',
      (Request request) async => _accountJson(
        200,
        await auth.settings((await requireAuthenticatedUser(request, auth)).id),
      ),
    )
    ..get(
      '/export',
      (Request request) async => _accountJson(
        200,
        await auth.exportAccount(
          (await requireAuthenticatedUser(request, auth)).id,
        ),
      ),
    )
    ..patch(
      '/settings',
      (Request request) async => _accountJson(
        200,
        await auth.updateSettings(
          (await requireAuthenticatedUser(request, auth)).id,
          await readJsonObject(request),
        ),
      ),
    )
    ..get(
      '/sessions',
      (Request request) async => _accountJson(
        200,
        await auth.sessions(
          (await requireAuthenticatedUser(request, auth)).id,
          readSessionToken(request.headers['cookie'])!,
        ),
      ),
    )
    ..delete('/sessions/<id>', (Request request, String id) async {
      final user = await requireAuthenticatedUser(request, auth);
      await auth.revokeSession(user.id, id);
      return _accountJson(200, const {'status': 'revoked'});
    })
    ..post('/logout-all', (Request request) async {
      await auth.logoutAll((await requireAuthenticatedUser(request, auth)).id);
      return _accountJson(200, const {'status': 'signed_out'}, clear: true);
    })
    ..post('/password', (Request request) async {
      await auth.changePassword(
        (await requireAuthenticatedUser(request, auth)).id,
        readSessionToken(request.headers['cookie'])!,
        await readJsonObject(request),
      );
      return _accountJson(200, const {'status': 'changed'});
    })
    ..post(
      '/recovery-code',
      (Request request) async => _accountJson(201, {
        'recoveryCode': await auth.rotateRecoveryCode(
          (await requireAuthenticatedUser(request, auth)).id,
          await readJsonObject(request),
        ),
      }),
    )
    ..post('/recover', (Request request) async {
      await auth.recover(await readJsonObject(request));
      return _accountJson(200, const {'status': 'recovered'}, clear: true);
    })
    ..post('/delete-account', (Request request) async {
      await auth.deleteAccount(
        (await requireAuthenticatedUser(request, auth)).id,
        await readJsonObject(request),
      );
      // The transaction has durably queued file cleanup. A filesystem failure
      // must not turn a committed deletion into a misleading failed response.
      await MediaCleanupService(database).drainBestEffort();
      return _accountJson(200, const {'status': 'deleted'}, clear: true);
    })
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

Response _accountJson(int status, Object body, {bool clear = false}) =>
    Response(
      status,
      body: jsonResponse(body),
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'cache-control': 'no-store',
        if (clear) 'set-cookie': clearSessionCookie(),
      },
    );
