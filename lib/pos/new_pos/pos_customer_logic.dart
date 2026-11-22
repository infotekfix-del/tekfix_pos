// New POS customer helpers. Pure Dart (unit-testable); reads only.

/// "9847012321" -> "98******21". Anything shorter than 6 digits is fully
/// masked; non-digits are ignored.
String posMaskPhone(String? raw) {
  final d = (raw ?? '').replaceAll(RegExp(r'[^0-9]'), '');
  final ten = d.length > 10 ? d.substring(d.length - 10) : d;
  if (ten.isEmpty) return '';
  if (ten.length < 6) return '*' * ten.length;
  return '${ten.substring(0, 2)}${'*' * (ten.length - 4)}'
      '${ten.substring(ten.length - 2)}';
}

/// Distinct customer ids from [sales] given newest first (walk-ins and
/// bills without a customer skipped), at most [limit].
List<String> posRecentCustomerIds(Iterable<Map> sales, {int limit = 6}) {
  final out = <String>[];
  for (final s in sales) {
    final id = '${s['customerId'] ?? ''}'.trim();
    if (id.isEmpty || id == 'null' || out.contains(id)) continue;
    out.add(id);
    if (out.length >= limit) break;
  }
  return out;
}
