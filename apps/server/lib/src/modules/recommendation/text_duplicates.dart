import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'dart:convert';

import 'package:crypto/crypto.dart';

String? exactTextDuplicateKey(String body) {
  final tokens = RegExp(
    r'[\p{L}\p{M}\p{N}]+',
    unicode: true,
  ).allMatches(unorm.nfkc(body).toLowerCase()).map((m) => m[0]!).toList();
  final normalized = tokens.join(' ');
  if (tokens.length < 8 || normalized.length < 40) return null;
  return sha256.convert(utf8.encode(normalized)).toString();
}

/// Conservative per-batch text clone grouping. Media posts are excluded by the
/// caller: an identical caption does not make two different photographs clones.
Map<String, String> textDuplicateGroups(Map<String, String> bodies) {
  final result = <String, String>{};
  final exact = <String, String>{};
  final gramsById = <String, Set<String>>{};
  final buckets = <String, List<String>>{};
  for (final entry in bodies.entries) {
    final tokens = RegExp(r'[\p{L}\p{M}\p{N}]+', unicode: true)
        .allMatches(unorm.nfkc(entry.value).toLowerCase())
        .map((m) => m[0]!)
        .toList();
    if (tokens.length < 8) continue;
    final normalized = tokens.join(' ');
    if (normalized.length < 40) continue;
    final identical = exact[normalized];
    if (identical != null) {
      result[entry.key] = result[identical] ?? identical;
      continue;
    }
    exact[normalized] = entry.key;
    final grams = <String>{
      for (var i = 0; i + 2 < tokens.length; i++)
        tokens.sublist(i, i + 3).join(' '),
    };
    // Four lexicographic anchors and at most 64 comparisons keep work bounded.
    final anchors = (grams.toList()..sort()).take(4).toList();
    final possible = anchors
        .expand((a) => buckets[a] ?? <String>[])
        .toSet()
        .take(64);
    String? clone;
    for (final other in possible) {
      final old = gramsById[other]!;
      final overlap = grams.intersection(old).length;
      if (overlap / (grams.length + old.length - overlap) >= .88) {
        clone = other;
        break;
      }
    }
    result[entry.key] = clone == null ? entry.key : (result[clone] ?? clone);
    gramsById[entry.key] = grams;
    for (final anchor in anchors) {
      (buckets[anchor] ??= []).add(entry.key);
    }
  }
  return result;
}
