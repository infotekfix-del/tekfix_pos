// New POS product discovery: category chips, Top Selling, Favorites.
// Pure Dart (no Flutter, no Hive): the screen passes plain maps in, so this
// is unit-testable and never writes item or sale records.
//
// Categories are mapped in the UI only; stored category values are never
// renamed. Unknown / empty categories -> Other Products.

enum PosCategory {
  mobiles,
  accessories,
  chargers,
  cables,
  earphones,
  bluetooth,
  gadgets,
  service,
  other,
}

extension PosCategoryInfo on PosCategory {
  String get label => switch (this) {
        PosCategory.mobiles => 'Mobile Phones (മൊബൈൽ)',
        PosCategory.accessories => 'Accessories (ആക്സസറീസ്)',
        PosCategory.chargers => 'Chargers (ചാർജർ)',
        PosCategory.cables => 'Cables (കേബിൾ)',
        PosCategory.earphones => 'Earphones (ഇയർഫോൺ)',
        PosCategory.bluetooth => 'Bluetooth Devices (ബ്ലൂടൂത്ത്)',
        PosCategory.gadgets => 'Gadgets (ഗാഡ്ജറ്റ്സ്)',
        PosCategory.service => 'Mobile Service (സർവീസ്)',
        PosCategory.other => 'Other Products (മറ്റുള്ളവ)',
      };
}

/// Stored category text (upper case, no spaces / punctuation) -> chip.
/// Built from the categories found in the shop's item data on 2026-11-19.
const Map<String, PosCategory> _kCategoryMap = {
  // Mobile phones
  'MOBILE': PosCategory.mobiles,
  'MOBILES': PosCategory.mobiles,
  'PHONE': PosCategory.mobiles,
  'PHONES': PosCategory.mobiles,
  'MOBILEPHONE': PosCategory.mobiles,
  'MOBILEPHONES': PosCategory.mobiles,
  'SMARTPHONE': PosCategory.mobiles,
  'FEATUREPHONE': PosCategory.mobiles,
  // Accessories
  'ACCESSORY': PosCategory.accessories,
  'ACCESSORIES': PosCategory.accessories,
  'CASE': PosCategory.accessories,
  'COVER': PosCategory.accessories,
  'BACKCASE': PosCategory.accessories,
  'STAND': PosCategory.accessories,
  'HOLDER': PosCategory.accessories,
  'CAMERAGLASS': PosCategory.accessories,
  'GLASS': PosCategory.accessories,
  'TEMPEREDGLASS': PosCategory.accessories,
  'SCREENGUARD': PosCategory.accessories,
  'BAG': PosCategory.accessories,
  'FASHION': PosCategory.accessories,
  // Chargers
  'CHARGER': PosCategory.chargers,
  'CHARGERS': PosCategory.chargers,
  'ADAPTER': PosCategory.chargers,
  'ADAPTOR': PosCategory.chargers,
  'POWERBANK': PosCategory.chargers,
  'CARCHARGER': PosCategory.chargers,
  // Cables
  'CABLE': PosCategory.cables,
  'CABLES': PosCategory.cables,
  'DATA': PosCategory.cables,
  'DATACABLE': PosCategory.cables,
  'OTG': PosCategory.cables,
  'EXTENSION': PosCategory.cables,
  // Earphones (wired)
  'EARPHONE': PosCategory.earphones,
  'EARPHONES': PosCategory.earphones,
  'HF': PosCategory.earphones,
  'HANDSFREE': PosCategory.earphones,
  'HEADPHONE': PosCategory.earphones,
  'HEADPHONES': PosCategory.earphones,
  'HEADSET': PosCategory.earphones,
  'OVERHEAD': PosCategory.earphones,
  // Bluetooth devices
  'TWS': PosCategory.bluetooth,
  'EARBUDS': PosCategory.bluetooth,
  'NECKBAND': PosCategory.bluetooth,
  'SPEAKER': PosCategory.bluetooth,
  'SPEAKERS': PosCategory.bluetooth,
  'SPEAKIER': PosCategory.bluetooth, // spelling used in item data
  'BLUETOOTH': PosCategory.bluetooth,
  // Gadgets
  'GADGET': PosCategory.gadgets,
  'GADGETS': PosCategory.gadgets,
  'COMPUTER': PosCategory.gadgets,
  'LAPTOP': PosCategory.gadgets,
  'CAMERA': PosCategory.gadgets,
  'CALCULATOR': PosCategory.gadgets,
  'TRIMMER': PosCategory.gadgets,
  'REMOTE': PosCategory.gadgets,
  'CAR': PosCategory.gadgets,
  'HOME': PosCategory.gadgets,
  'TOY': PosCategory.gadgets,
  'GAME': PosCategory.gadgets,
  'STICK': PosCategory.gadgets,
  'WATCH': PosCategory.gadgets,
  'SMARTWATCH': PosCategory.gadgets,
  // Mobile service
  'SERVICE': PosCategory.service,
  'SERVICES': PosCategory.service,
  'REPAIR': PosCategory.service,
  'MOBILESERVICE': PosCategory.service,
};

String _norm(dynamic v) =>
    '${v ?? ''}'.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

/// Chip for an item, from its stored `category` (and `itemType` for
/// services). Never changes the item.
PosCategory posCategoryOf(Map item) {
  final c = _kCategoryMap[_norm(item['category'])];
  if (c != null) return c;
  if ('${item['itemType'] ?? ''}'.toLowerCase().contains('service')) {
    return PosCategory.service;
  }
  return PosCategory.other;
}

/// Reference used to find an item again: its uuid `_id`, else its Hive key.
String posItemRef(dynamic key, Map item) {
  final id = '${item['_id'] ?? ''}'.trim();
  return id.isNotEmpty ? id : 'k:$key';
}

/// Line reference inside a sale (sales store itemId + Hive key).
String _lineRef(Map line) {
  final id = '${line['itemId'] ?? ''}'.trim();
  return id.isNotEmpty && id != 'null' ? id : 'k:${line['key']}';
}

DateTime? _saleDate(Map s) {
  for (final f in const ['saleDate', 'createdAt', 'date']) {
    final d = DateTime.tryParse('${s[f] ?? ''}');
    if (d != null) return d;
  }
  return null;
}

const _kNotSold = {'CANCELLED', 'CANCELED', 'VOID', 'DELETED', 'RETURNED'};

/// Item refs ordered by quantity sold in the last [days] days (newest data
/// only, cancelled / voided / fully returned bills skipped), at most [limit].
/// Ties: more recent sale first, then name order is left to the caller.
List<String> posTopSelling(
  Iterable<Map> sales, {
  DateTime? now,
  int days = 30,
  int limit = 16,
}) {
  final from = (now ?? DateTime.now()).subtract(Duration(days: days));
  final qty = <String, int>{};
  final last = <String, DateTime>{};
  for (final s in sales) {
    if (_kNotSold.contains('${s['status'] ?? ''}'.toUpperCase())) continue;
    final d = _saleDate(s);
    if (d == null || d.isBefore(from)) continue;
    for (final l in (s['items'] as List?) ?? const []) {
      if (l is! Map) continue;
      final q = int.tryParse('${l['qty'] ?? 1}') ??
          (double.tryParse('${l['qty']}')?.round() ?? 1);
      if (q <= 0) continue;
      final r = _lineRef(l);
      qty[r] = (qty[r] ?? 0) + q;
      final prev = last[r];
      if (prev == null || d.isAfter(prev)) last[r] = d;
    }
  }
  final refs = qty.keys.toList()
    ..sort((a, b) {
      final c = qty[b]!.compareTo(qty[a]!);
      return c != 0 ? c : last[b]!.compareTo(last[a]!);
    });
  return refs.take(limit).toList();
}

/// Favorites are a list of item `_id`s in the local settings box.
const String kPosFavoritesSetting = 'pos_favorites';

List<String> posFavoritesFrom(dynamic stored) {
  if (stored is List) {
    return [
      for (final v in stored)
        if ('$v'.trim().isNotEmpty) '$v'.trim()
    ];
  }
  return const [];
}

List<String> posToggleFavorite(List<String> favs, String ref) {
  final out = favs.toList();
  if (!out.remove(ref)) out.insert(0, ref);
  return out;
}

/// View All sort orders.
enum PosSort { name, priceLow, priceHigh, stock }

extension PosCategoryParts on PosCategory {
  /// "Mobile Phones" (English part of [label]).
  String get en => label.substring(0, label.indexOf(' ('));

  /// "മൊബൈൽ" (Malayalam part of [label]).
  String get ml => label.substring(label.indexOf('(') + 1, label.length - 1);
}
