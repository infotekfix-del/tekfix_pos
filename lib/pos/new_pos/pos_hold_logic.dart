// Hold / resume a bill (new POS). Pure Dart, unit-testable.
//
// A held bill is ONLY a cart draft in the local settings box (key
// `pos_held_bills`, never synced): item ids, qty, price, IMEI, customer and
// discount. Holding does not touch stock, create a sale, sync or use an
// invoice number. Resuming re-checks every line against current stock.

const String kPosHeldSetting = 'pos_held_bills';
const int kPosMaxHeld = 10;

double _n(dynamic v) =>
    v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;
int _q(dynamic v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;

Map<String, dynamic> posHeldDraft({
  required List<Map> cart,
  required String customerPhone,
  required String customerName,
  required dynamic partyId,
  required String discount,
  required String by,
  required DateTime now,
}) =>
    {
      'id': 'H${now.microsecondsSinceEpoch}',
      'heldAt': now.toUtc().toIso8601String(),
      'by': by,
      'customerPhone': customerPhone.trim(),
      'customerName': customerName.trim(),
      'partyId': partyId?.toString(),
      'discount': discount.trim(),
      'lines': [
        for (final l in cart)
          {
            'itemId': l['itemId']?.toString(),
            'key': l['key'],
            'name': '${l['name'] ?? ''}',
            'qty': _q(l['qty']),
            'price': _n(l['price']),
            'imei': '${l['imei'] ?? ''}',
          }
      ],
    };

List<Map<String, dynamic>> posHeldFrom(dynamic stored) => [
      if (stored is List)
        for (final e in stored)
          if (e is Map) Map<String, dynamic>.from(e)
    ];

double posHeldTotal(Map held) {
  var sub = 0.0;
  for (final l in (held['lines'] as List?) ?? const []) {
    if (l is Map) sub += _n(l['price']) * _q(l['qty']);
  }
  final d = _n(held['discount']);
  return d <= 0 ? sub : (d > sub ? 0 : sub - d);
}

int posHeldCount(Map held) {
  var n = 0;
  for (final l in (held['lines'] as List?) ?? const []) {
    if (l is Map) n += _q(l['qty']);
  }
  return n;
}

/// "just now", "12 min", "3 h", "2 days".
String posHeldAge(String? heldAt, DateTime now) {
  final t = DateTime.tryParse(heldAt ?? '');
  if (t == null) return '';
  final d = now.toUtc().difference(t.toUtc());
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min';
  if (d.inDays < 1) return '${d.inHours} h';
  return d.inDays == 1 ? '1 day' : '${d.inDays} days';
}

typedef PosResumeLine = ({dynamic key, Map item, int qty, double price});

/// What can come back on the bill now, and what changed since holding.
/// [find] returns the current item for a held line (by item id, then key),
/// or null when it no longer exists.
({List<PosResumeLine> lines, List<String> warnings}) posPlanResume(
  Map held, {
  required ({dynamic key, Map item})? Function(Map line) find,
}) {
  final lines = <PosResumeLine>[];
  final warnings = <String>[];
  for (final raw in (held['lines'] as List?) ?? const []) {
    if (raw is! Map) continue;
    final name = '${raw['name'] ?? 'Item'}';
    final f = find(raw);
    if (f == null) {
      warnings.add('$name: no longer in the item list – left out '
          '(ഐറ്റം ഇല്ല)');
      continue;
    }
    final stock = _q(f.item['stock']);
    final imei = '${raw['imei'] ?? ''}'.trim().isNotEmpty;
    var qty = _q(raw['qty']);
    if (stock <= 0) {
      warnings.add(imei
          ? '$name: this IMEI is already sold – left out (വിറ്റുപോയി)'
          : '$name: out of stock now – left out (സ്റ്റോക്ക് ഇല്ല)');
      continue;
    }
    if (imei) qty = 1;
    if (qty > stock) {
      warnings.add('$name: only $stock in stock now (was $qty) '
          '(സ്റ്റോക്ക് $stock മാത്രം)');
      qty = stock;
    }
    if (qty < 1) qty = 1;
    final held = _n(raw['price']);
    final now = _n(f.item['sellingPrice']);
    if ((held - now).abs() > 0.004) {
      warnings.add('$name: price is now ₹${_p(now)} (held ₹${_p(held)}) – '
          'held price kept, tap the price to change (വില മാറി)');
    }
    lines.add((key: f.key, item: f.item, qty: qty, price: held));
  }
  return (lines: lines, warnings: warnings);
}

String _p(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
