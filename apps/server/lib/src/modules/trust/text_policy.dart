import 'package:ionic_server/src/http/api_exception.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

// Publication validation only. Never fetch URLs or infer preference from text.
final _scheme = RegExp(
  r'(?:[a-z][a-z0-9+.-]{1,30}:\s*(?://|\\\\)|mailto:|tel:|www\s*\.)',
  caseSensitive: false,
);
final _domain = RegExp(
  r'(?:^|[^\p{L}\p{N}_])(?:[\p{L}\p{N}](?:[\p{L}\p{N}-]{0,62})\.)+(?:[\p{L}]{2,63}|xn--[a-z0-9-]{2,59})(?:[^\p{L}\p{N}_]|$)',
  unicode: true,
  caseSensitive: false,
);
final _ip = RegExp(
  r'(?:^|[^0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?::[0-9]{1,5})?(?:[^0-9]|$)',
);
final _invisible = RegExp(
  r'[\u00ad\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]',
);

void requireLinkFree(String text) {
  final normalized = unorm
      .nfkc(text)
      .replaceAll(_invisible, '')
      .replaceAll(RegExp(r'[。．｡]'), '.');
  if (_scheme.hasMatch(normalized) ||
      _domain.hasMatch(normalized) ||
      _ip.hasMatch(normalized)) {
    throw const ApiException(
      400,
      'Links are not allowed in user content.',
      code: 'LINK_NOT_ALLOWED',
    );
  }
}
