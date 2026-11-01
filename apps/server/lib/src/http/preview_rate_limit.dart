import 'package:shelf/shelf.dart';

import 'api_exception.dart';

/// Fixed global budgets for a single-instance private preview. No IP/device or
/// account data is retained. This is not a distributed abuse-prevention system.
Middleware previewRateLimit({
  bool enabled = true,
  int Function()? clockSeconds,
}) {
  final clock =
      clockSeconds ?? () => DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final windows = <String, ({int start, int count})>{};
  return (inner) => (request) async {
    if (!enabled || ['GET', 'HEAD', 'OPTIONS'].contains(request.method)) {
      return inner(request);
    }
    final path = request.url.path;
    final registration = path == 'api/v1/auth/register';
    final sensitive = path.startsWith('api/v1/auth/');
    final key = registration
        ? 'registration'
        : sensitive
        ? 'account'
        : 'writes';
    final limit = registration
        ? 10
        : sensitive
        ? 60
        : 120;
    final duration = registration
        ? 600
        : sensitive
        ? 300
        : 60;
    final now = clock(), previous = windows[key];
    final current =
        previous == null ||
            now - previous.start >= duration ||
            now < previous.start
        ? (start: now, count: 0)
        : previous;
    if (current.count >= limit) {
      final response = apiErrorResponse(
        const ApiException(429, 'Too many requests. Try again shortly.'),
      );
      return response.change(
        headers: {
          ...response.headers,
          'retry-after': '${duration - (now - current.start)}',
          'cache-control': 'private, no-store',
        },
      );
    }
    windows[key] = (start: current.start, count: current.count + 1);
    return inner(request);
  };
}
