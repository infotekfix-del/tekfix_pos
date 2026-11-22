// New POS cart rules (UI side only). Pure Dart, unit-testable.
// The bill itself is still built and saved by the existing SaleView logic;
// these helpers only decide what the cashier may type or add.

/// A typed quantity must be a whole number from 1 to [stock] (the existing
/// stock rule: a line can never be more than what is in stock).
({int? qty, String? error}) posQtyCheck(String text, {required int stock}) {
  final q = int.tryParse(text.trim());
  if (q == null || q < 1) {
    return (qty: null, error: 'Minimum 1 (കുറഞ്ഞത് 1)');
  }
  if (q > stock) {
    return (
      qty: null,
      error: 'Only $stock in stock (സ്റ്റോക്ക് $stock മാത്രം)'
    );
  }
  return (qty: q, error: null);
}

/// "6.7%" / "10%" of [subtotal]; '' when there is no discount.
String posDiscountPercent(double discount, double subtotal) {
  if (discount <= 0 || subtotal <= 0) return '';
  final p = discount * 100 / subtotal;
  final r = (p * 10).round() / 10;
  return r == r.roundToDouble() ? '${r.round()}%' : '${r.toStringAsFixed(1)}%';
}

bool posHasImei(Map item) => '${item['imei'] ?? ''}'.trim().isNotEmpty;

/// A real IMEI / serial unit: something in the IMEI box AND a stock of at
/// most 1 (one record per device). Many shop items use the IMEI box as a
/// short code ("TPU", "1") with a big stock: those are normal items whose
/// quantity can go up like any other.
bool posIsUnitItem(Map item, int stock) => posHasImei(item) && stock <= 1;

/// "IMEI ••••5678" (last 4 only) for screens the customer may see.
String posImeiMasked(String? imei) {
  final s = (imei ?? '').trim();
  if (s.isEmpty) return '';
  final last = s.length <= 4 ? s : s.substring(s.length - 4);
  return 'IMEI ••••$last';
}

/// True when [item] has an IMEI / serial that is already on the bill (same
/// item record, or another line with the same IMEI). Such an item can never
/// be added twice.
bool posImeiAlreadyInCart(List<Map> cart, dynamic key, Map item) {
  if (!posIsUnitItem(item, _posInt(item['stock']))) return false;
  final imei = '${item['imei']}'.trim().toLowerCase();
  for (final l in cart) {
    if (l['key'] == key) return true;
    if ('${l['imei'] ?? ''}'.trim().toLowerCase() == imei) return true;
  }
  return false;
}

// ------------------------------------------------- quantity controls (− +)

/// Units of item [key] already on the bill, over ALL lines (a held bill
/// resumed into a cart can hold the same item twice). [exceptIndex] leaves
/// one line out (the line being edited).
int posCartQtyOf(List<Map> cart, dynamic key, {int? exceptIndex}) {
  var n = 0;
  for (var i = 0; i < cart.length; i++) {
    if (i == exceptIndex) continue;
    if (cart[i]['key'] == key) n += _posInt(cart[i]['qty']);
  }
  return n;
}

/// How many more units of [key] may still be added (stock minus every unit
/// already on the bill), never below 0.
int posQtyRoom(List<Map> cart, dynamic key, int stock) {
  final r = stock - posCartQtyOf(cart, key);
  return r < 0 ? 0 : r;
}

String posStockShortMsg(int available) =>
    'Insufficient stock (സ്റ്റോക്ക് ലഭ്യമല്ല) – Available: $available';

/// A typed quantity for line [index]: a whole number from 0 (= remove the
/// line) up to the stock left after the item's OTHER lines.
({int? qty, String? error}) posLineQtyCheck(
    String text, List<Map> cart, int index, int stock) {
  final q = int.tryParse(text.trim());
  if (q == null || q < 0) {
    return (qty: null, error: 'Enter 0 or more (0 = remove)');
  }
  final avail =
      stock - posCartQtyOf(cart, cart[index]['key'], exceptIndex: index);
  if (q > avail) {
    return (qty: null, error: posStockShortMsg(avail < 0 ? 0 : avail));
  }
  return (qty: q, error: null);
}

/// Same model = same item name (case and spaces ignored). Phones with an
/// IMEI are stored one record per IMEI, all with the model's name.
String posModelKey(Map item) => '${item['name'] ?? ''}'
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'\s+'), ' ');

/// Unsold IMEI records of [model] that are in stock and not on the bill,
/// for the "+" picker. [items] are (key, item) pairs from the items box.
List<MapEntry<dynamic, Map>> posImeiCandidates(
    Iterable<MapEntry<dynamic, Map>> items, List<Map> cart, String model) {
  final out = <MapEntry<dynamic, Map>>[];
  for (final e in items) {
    final it = e.value;
    if (!posIsUnitItem(it, _posInt(it['stock']))) continue;
    if (_posInt(it['stock']) <= 0) continue;
    if (posModelKey(it) != model) continue;
    if (posImeiAlreadyInCart(cart, e.key, it)) continue;
    out.add(e);
  }
  out.sort((a, b) => '${a.value['imei']}'.compareTo('${b.value['imei']}'));
  return out;
}

/// Bill line indexes holding an IMEI unit of [model]. [isUnit] tells
/// whether a line is a real IMEI unit (see [posIsUnitItem]).
List<int> posImeiLinesOf(
        List<Map> cart, String model, bool Function(Map line) isUnit) =>
    [
      for (var i = 0; i < cart.length; i++)
        if (isUnit(cart[i]) && posModelKey(cart[i]) == model) i
    ];

/// Final check right before the bill is saved: every quantity 1..stock
/// counted over all lines of an item, one unit per IMEI line, no IMEI twice.
/// Returns the first problem, or null when the bill can be saved.
String? posValidateCart(List<Map> cart, int? Function(dynamic key) stockOf) {
  final seenImei = <String>{};
  final checked = <dynamic>{};
  for (final l in cart) {
    final q = _posInt(l['qty']);
    final name = '${l['name']}';
    if (q < 1) return '$name – quantity must be at least 1';
    final stock = stockOf(l['key']);
    if (posIsUnitItem(l, stock ?? 0)) {
      if (q != 1) return '$name – one IMEI is one unit (IMEI = 1)';
      final im = '${l['imei']}'.trim().toLowerCase();
      if (!seenImei.add(im)) {
        return '$name – IMEI twice in the bill (ഒരേ IMEI രണ്ടുതവണ)';
      }
    }
    if (checked.add(l['key'])) {
      final need = posCartQtyOf(cart, l['key']);
      if (stock == null || need > stock) {
        return '$name – ${posStockShortMsg(stock ?? 0)}';
      }
    }
  }
  return null;
}

int _posInt(dynamic v) =>
    v is int ? v : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);
