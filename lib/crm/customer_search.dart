// Phase 4: party / customer search by name, full phone or partial phone
// (e.g. last 4 digits). Case-insensitive and Malayalam-safe. Pure Dart.

import 'phone_utils.dart';

// Atomic chillu letters (Unicode 5.1) -> consonant + virama, so text typed
// with either keyboard encoding matches: ൽ == ല്‍, ൻ == ന്‍, ...
const _chillu = {
  'ൺ': 'ണ്', // ൺ -> ണ്
  'ൻ': 'ന്', // ൻ -> ന്
  'ർ': 'ര്', // ർ -> ര്
  'ൽ': 'ല്', // ൽ -> ല്
  'ൾ': 'ള്', // ൾ -> ള്
  'ൿ': 'ക്', // ൿ -> ക്
  'ൔ': 'മ്', // ൔ -> മ്
};

/// Lower-cased, whitespace-collapsed, Malayalam-normalised search key.
String searchKey(String? s) {
  var t = (s ?? '').toLowerCase();
  _chillu.forEach((k, v) => t = t.replaceAll(k, v));
  t = t.replaceAll(RegExp('[‌‍]'), ''); // ZWNJ / ZWJ
  return t.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// A query made only of phone characters (digits, space, +, -, brackets).
bool isPhoneQuery(String q) =>
    RegExp(r'^[0-9+\-\s()]+$').hasMatch(q.trim()) && phoneDigits(q).length >= 3;

/// 0 = no match; higher = better. Used to filter and rank.
int partyMatchScore(Map party, String query) {
  final q = searchKey(query);
  if (q.isEmpty) return 1;
  if (isPhoneQuery(q)) {
    final qd = phoneDigits(q);
    final raw = phoneDigits('${party['phone'] ?? ''}');
    final p = normalizePhone(raw) ?? raw;
    if (p.isEmpty) return 0;
    final full = normalizePhone(qd);
    if (full != null && full == p) return 100;
    if (p.endsWith(qd)) return 80;
    if (p.contains(qd) || raw.contains(qd)) return 60;
    return 0;
  }
  final name = searchKey('${party['name'] ?? ''}');
  if (name == q) return 90;
  if (name.startsWith(q)) return 70;
  if (name.split(' ').any((w) => w.startsWith(q))) return 50;
  if (name.contains(q)) return 30;
  // "anu 9847" style: every word must match name or phone
  final words = q.split(' ');
  if (words.length > 1 &&
      words.every((w) => partyMatchScore(party, w) > 0)) {
    return 20;
  }
  return 0;
}
