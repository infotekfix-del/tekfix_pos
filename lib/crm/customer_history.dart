// Pure logic for the customer history screen (Phase 3): filtering by item
// name / date range, grouping by day, payment mode, warranty expiry and the
// customer's service jobs. No Flutter imports (unit-testable).

import 'customer_models.dart';
import 'phone_utils.dart';

/// Local calendar day of a sale (yyyy-MM-dd).
DateTime? saleDay(Map s) {
  final d = DateTime.tryParse(saleWhen(s));
  if (d == null) return null;
  final l = d.toLocal();
  return DateTime(l.year, l.month, l.day);
}

double _num(dynamic v) =>
    v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0.0);

/// "Cash", "UPI", "Cash + UPI", "Credit", ... from the bill's split.
String paymentMode(Map s) {
  final parts = <String>[];
  final hasSplit = s.containsKey('cash') || s.containsKey('upi');
  final cash = hasSplit ? _num(s['cash']) : _num(s['total']);
  if (cash > 0) parts.add('Cash');
  if (_num(s['upi']) > 0) parts.add('UPI');
  if (_num(s['card']) > 0) parts.add('Card');
  if (_num(s['due']) > 0) parts.add('Credit');
  return parts.isEmpty ? '-' : parts.join(' + ');
}

bool isSaleReturnedMap(Map s) =>
    s['returned'] == true ||
    '${s['status'] ?? ''}'.toUpperCase() == 'RETURNED';

List<Map> saleLines(Map s) =>
    [for (final e in (s['items'] as List?) ?? const []) if (e is Map) e];

/// Case-insensitive "contains" that works for Malayalam too (no ASCII-only
/// regex; Malayalam has no case so lowercasing leaves it unchanged).
bool textMatches(String haystack, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return haystack.toLowerCase().contains(q);
}

class HistoryDay {
  final DateTime day;
  final List<MapEntry<dynamic, Map<String, dynamic>>> sales;
  HistoryDay(this.day, this.sales);
  int get totalPaise => sales.fold(
      0, (a, e) => a + (isSaleReturnedMap(e.value) ? 0 : toPaise(e.value['total'])));
}

/// Filters [sales] (any order) and groups them by day, newest day first and
/// newest bill first within a day. [from]/[to] are inclusive calendar days.
List<HistoryDay> groupHistory(
  List<MapEntry<dynamic, Map<String, dynamic>>> sales, {
  String itemQuery = '',
  DateTime? from,
  DateTime? to,
}) {
  final f = from == null ? null : DateTime(from.year, from.month, from.day);
  final t = to == null ? null : DateTime(to.year, to.month, to.day);
  final rows = <MapEntry<dynamic, Map<String, dynamic>>>[];
  for (final e in sales) {
    final s = e.value;
    final d = saleDay(s);
    if (f != null && (d == null || d.isBefore(f))) continue;
    if (t != null && (d == null || d.isAfter(t))) continue;
    if (itemQuery.trim().isNotEmpty &&
        !saleLines(s).any((l) => textMatches('${l['name'] ?? ''}', itemQuery))) {
      continue;
    }
    rows.add(e);
  }
  rows.sort((a, b) => saleWhen(b.value).compareTo(saleWhen(a.value)));
  final out = <HistoryDay>[];
  for (final e in rows) {
    final d = saleDay(e.value) ?? DateTime(1970);
    if (out.isEmpty || out.last.day != d) out.add(HistoryDay(d, []));
    out.last.sales.add(e);
  }
  return out;
}

/// Warranty length from item text like "3 Months", "1 Year", "90 Days".
Duration? parseWarranty(String? w) {
  final m = RegExp(r'(\d+)\s*(day|month|year)', caseSensitive: false)
      .firstMatch(w ?? '');
  if (m == null) return null;
  final n = int.parse(m.group(1)!);
  switch (m.group(2)!.toLowerCase()) {
    case 'day':
      return Duration(days: n);
    case 'month':
      return Duration(days: n * 30);
    default:
      return Duration(days: n * 365);
  }
}

class WarrantyLine {
  final dynamic saleKey;
  final Map<String, dynamic> sale;
  final String item;
  final String imei;
  final String warranty;
  final DateTime soldOn;
  final DateTime expires;
  WarrantyLine(this.saleKey, this.sale, this.item, this.imei, this.warranty,
      this.soldOn, this.expires);
  bool activeOn(DateTime now) => !expires.isBefore(now);
}

/// Bill lines that carry a warranty (newest first). Returned bills excluded.
List<WarrantyLine> warrantyLines(
    List<MapEntry<dynamic, Map<String, dynamic>>> sales) {
  final out = <WarrantyLine>[];
  for (final e in sales) {
    final s = e.value;
    if (isSaleReturnedMap(s)) continue;
    final sold = DateTime.tryParse(saleWhen(s))?.toLocal();
    if (sold == null) continue;
    for (final l in saleLines(s)) {
      final w = '${l['warranty'] ?? ''}';
      final dur = parseWarranty(w);
      if (dur == null) continue;
      out.add(WarrantyLine(e.key, s, '${l['name'] ?? ''}', '${l['imei'] ?? ''}',
          w, sold, sold.add(dur)));
    }
  }
  out.sort((a, b) => b.soldOn.compareTo(a.soldOn));
  return out;
}

/// Service / repair jobs whose phone matches the customer (newest first).
/// One scan of the services box when the screen opens — never per keystroke.
List<MapEntry<dynamic, Map<String, dynamic>>> servicesForPhone(
    Iterable<MapEntry<dynamic, dynamic>> jobs, String phone,
    {String? customerId}) {
  if (phone.isEmpty && customerId == null) return const [];
  final out = <MapEntry<dynamic, Map<String, dynamic>>>[];
  for (final e in jobs) {
    final v = e.value;
    if (v is! Map) continue;
    final byId = customerId != null && v['customerId'] == customerId;
    final byPhone =
        phone.isNotEmpty && normalizePhone('${v['phone'] ?? ''}') == phone;
    if (byId || byPhone) {
      out.add(MapEntry(e.key, {for (final x in v.entries) '${x.key}': x.value}));
    }
  }
  out.sort((a, b) =>
      '${b.value['createdAt'] ?? ''}'.compareTo('${a.value['createdAt'] ?? ''}'));
  return out;
}
