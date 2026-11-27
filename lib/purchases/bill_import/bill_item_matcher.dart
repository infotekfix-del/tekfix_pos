// =============================================================================
// TEKFIX ERP — Fuzzy matching of vendor bill lines to stock items
//
// Vendors write item names their own way ("SAM GAL A15 4/128 BLK" vs our
// "Samsung Galaxy A15 4GB/128GB Black"). The matcher scores every catalog item
// with a mix of token similarity (abbreviation and typo tolerant) and
// character trigrams, and strongly penalises a different *number* (128 vs 256,
// A15 vs A25) because that means a different variant.
//
// Once the owner confirms a match, the bill's wording is remembered as an
// alias so the same vendor wording matches instantly next time.
// =============================================================================

import 'dart:math' as math;

/// Minimal view of a stock item used for matching.
class CatalogItem {
  final dynamic key;
  final String id;
  final String name;
  final String brand;
  final String model;
  final String sku;
  final String barcode;
  final String hsn;
  final String unit;
  final double gstPercent;
  final int sellingPricePaise;
  final int mrpPaise;
  final int costPricePaise;
  final bool imeiRequired;
  final String category;
  final String warranty;

  const CatalogItem({
    required this.key,
    required this.id,
    required this.name,
    this.brand = '',
    this.model = '',
    this.sku = '',
    this.barcode = '',
    this.hsn = '',
    this.unit = '',
    this.gstPercent = 0,
    this.sellingPricePaise = 0,
    this.mrpPaise = 0,
    this.costPricePaise = 0,
    this.imeiRequired = false,
    this.category = '',
    this.warranty = '',
  });

  factory CatalogItem.fromMap(dynamic key, Map raw) {
    int paise(dynamic v, [dynamic paiseV]) {
      if (paiseV is num) return paiseV.round();
      if (v is num) return (v * 100).round();
      return 0;
    }

    final gst = raw['gstRate'] ?? raw['gst'] ?? raw['taxPercent'];
    final cat = (raw['category'] ?? '').toString();
    final name = (raw['name'] ?? raw['productName'] ?? '').toString();
    return CatalogItem(
      key: key,
      id: (raw['_id'] ?? '$key').toString(),
      name: name,
      brand: (raw['brand'] ?? '').toString(),
      model: (raw['model'] ?? '').toString(),
      sku: (raw['sku'] ?? raw['code'] ?? '').toString(),
      barcode: (raw['barcode'] ?? '').toString(),
      hsn: (raw['hsn'] ?? raw['hsnCode'] ?? '').toString(),
      unit: (raw['unit'] ?? raw['baseUnit'] ?? '').toString(),
      gstPercent: gst is num ? gst.toDouble() : 0,
      sellingPricePaise: paise(raw['sellingPrice'] ?? raw['price'],
          raw['sellingPricePaise']),
      mrpPaise: paise(raw['mrp'], raw['mrpPaise']),
      costPricePaise: paise(raw['costPrice'] ?? raw['lastPurchaseRate'],
          raw['costPricePaise']),
      // Only the item's own IMEI flag, or a handset category. Accessory
      // categories like "Mobile Phone Accessories" must not ask for IMEIs.
      imeiRequired: raw['imeiRequired'] == true ||
          raw['trackImei'] == true ||
          isHandsetCategory(cat),
      category: cat,
      warranty: (raw['warranty'] ?? '').toString(),
    );
  }
}

/// "Mobile Phones", "Smartphones", "Phones" → true;
/// "Mobile Phone Accessories", "Phone Cases" → false.
bool isHandsetCategory(String category) {
  final c = category.toLowerCase();
  if (!RegExp(r'phone|mobile').hasMatch(c)) return false;
  return !RegExp(r'access|case|cover|glass|guard|charger|cable|adapt|spare|'
          r'part|audio|ear|hf|pouch|holder|stand|skin|battery')
      .hasMatch(c);
}

/// Item names that are accessories even when they mention a phone model.
bool looksLikeAccessoryName(String name) => RegExp(
        r'adapt|charger|cable|glass|guard|case|cover|pouch|hf\b|handsfree|'
        r'earphone|ear\s*buds?|airdopes|neckband|dongle|cooler|holder|stand|'
        r'skin|sticker|lens|protector|tpu|power\s*bank|battery|speaker|'
        r'otg|connector|stylus|ring|strap|watch',
        caseSensitive: false)
    .hasMatch(name);

enum MatchLevel {
  /// Confident — auto-linked.
  matched,

  /// Probably this item — owner should confirm with one tap.
  suggested,

  /// Nothing close — new item.
  none,
}

class MatchCandidate {
  final CatalogItem item;
  final double score;
  final String reason;
  const MatchCandidate(this.item, this.score, this.reason);
}

class MatchResult {
  final MatchLevel level;
  final List<MatchCandidate> candidates;
  const MatchResult(this.level, this.candidates);

  MatchCandidate? get best => candidates.isEmpty ? null : candidates.first;
}

class BillItemMatcher {
  final List<CatalogItem> catalog;

  /// normalized bill wording → item key (learned from earlier imports).
  final Map<String, dynamic> aliases;

  static const double matchedThreshold = 0.82;
  static const double suggestThreshold = 0.58;

  BillItemMatcher(this.catalog, {Map<String, dynamic>? aliases})
      : aliases = aliases ?? {} {
    for (final c in catalog) {
      _prepared.add(_Prepared(c));
    }
  }

  final List<_Prepared> _prepared = [];

  MatchResult match(String description, {String hsn = '', int limit = 3}) {
    final norm = normalize(description);
    if (norm.isEmpty) return const MatchResult(MatchLevel.none, []);

    // 1. Learned alias
    final aliasKey = aliases[norm];
    if (aliasKey != null) {
      for (final p in _prepared) {
        if ('${p.item.key}' == '$aliasKey') {
          return MatchResult(MatchLevel.matched,
              [MatchCandidate(p.item, 1.0, 'Remembered (മുമ്പ് ലിങ്ക് ചെയ്തത്)')]);
        }
      }
    }

    final qTokens = tokens(norm);
    final qRaw = description.toUpperCase();
    final qTri = _trigrams(norm.replaceAll(' ', ''));
    final scored = <MatchCandidate>[];
    for (final p in _prepared) {
      // 2. Barcode / SKU printed in the bill line
      if (p.codes.isNotEmpty) {
        var hit = false;
        for (final code in p.codes) {
          if (code.length >= 5 && qRaw.contains(code)) {
            hit = true;
            break;
          }
        }
        if (hit) {
          scored.add(MatchCandidate(p.item, 1.0, 'Barcode/SKU'));
          continue;
        }
      }
      if (p.norm == norm) {
        scored.add(MatchCandidate(p.item, 1.0, 'Same name'));
        continue;
      }
      final s = _score(qTokens, qTri, p, hsn);
      if (s >= 0.35) scored.add(MatchCandidate(p.item, s, 'Similar name'));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    final top = scored.take(limit).toList();
    if (top.isEmpty) return const MatchResult(MatchLevel.none, []);
    final best = top.first.score;
    // Two near-identical candidates → owner must choose.
    final ambiguous = top.length > 1 &&
        top[1].score >= best - 0.02 &&
        best < 1.0 &&
        top[1].item.key != top.first.item.key;
    MatchLevel level;
    if (best >= matchedThreshold && !ambiguous) {
      level = MatchLevel.matched;
    } else if (best >= suggestThreshold) {
      level = MatchLevel.suggested;
    } else {
      level = MatchLevel.none;
    }
    return MatchResult(level, top);
  }

  // ---------------------------------------------------------------------------

  static const Map<String, String> _synonyms = {
    'blk': 'black', 'bk': 'black', 'blck': 'black', 'wht': 'white',
    'wh': 'white', 'blu': 'blue', 'bl': 'blue', 'grn': 'green', 'gld': 'gold',
    'slv': 'silver', 'sil': 'silver', 'gry': 'grey', 'gray': 'grey',
    'pnk': 'pink', 'prpl': 'purple', 'rd': 'red',
    'sam': 'samsung', 'sams': 'samsung', 'samsng': 'samsung',
    'gal': 'galaxy', 'glxy': 'galaxy', 'mi': 'xiaomi', 'rdmi': 'redmi',
    'opo': 'oppo', 'viv': 'vivo', 'nok': 'nokia', 'apl': 'apple',
    'chgr': 'charger', 'chrgr': 'charger', 'chr': 'charger', 'chg': 'charger',
    'adptr': 'adapter', 'adp': 'adapter', 'adaptor': 'adapter',
    'cbl': 'cable', 'hf': 'handsfree', 'hfree': 'handsfree',
    'earphone': 'earphones', 'tg': 'temperedglass', 'tgl': 'temperedglass',
    'bc': 'backcover', 'bcover': 'backcover', 'cvr': 'cover',
    'mob': 'mobile', 'ph': 'phone', 'btry': 'battery', 'batt': 'battery',
    'pb': 'powerbank', 'pwrbank': 'powerbank', 'spk': 'speaker',
    'typec': 'typec', 'usbc': 'typec', 'ctype': 'typec',
    'mtr': 'm', 'meter': 'm', 'mtrs': 'm', 'watt': 'w', 'watts': 'w',
  };

  static const Set<String> _stop = {
    'the', 'of', 'and', 'with', 'for', 'new', 'pcs', 'pc', 'nos', 'no',
    'piece', 'pieces', 'unit', 'units', 'set', 'item', 'model', 'colour',
    'color', 'ltd', 'pvt',
  };

  /// Lowercase, ASCII letters/digits only, splits "128GB" → "128 gb",
  /// joins common two-word terms.
  static String normalize(String s) {
    var t = s.toLowerCase();
    t = t
        .replaceAll(RegExp(r'tempered\s*glass'), ' temperedglass ')
        .replaceAll(RegExp(r'back\s*cover|back\s*case'), ' backcover ')
        .replaceAll(RegExp(r'power\s*bank'), ' powerbank ')
        .replaceAll(RegExp(r'hands\s*free'), ' handsfree ')
        .replaceAll(RegExp(r'type\s*-?\s*c\b'), ' typec ')
        .replaceAll(RegExp(r'c\s*-?\s*type\b'), ' typec ')
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .replaceAllMapped(RegExp(r'(\d)([a-z])'), (m) => '${m[1]} ${m[2]}')
        .replaceAllMapped(RegExp(r'([a-z])(\d)'), (m) => '${m[1]} ${m[2]}')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return t;
  }

  static List<String> tokens(String normalized) {
    final out = <String>[];
    for (final raw in normalized.split(' ')) {
      if (raw.isEmpty) continue;
      final t = _synonyms[raw] ?? raw;
      if (_stop.contains(t)) continue;
      out.add(t);
    }
    return out;
  }

  static Set<String> _trigrams(String s) {
    final p = '  $s ';
    final out = <String>{};
    for (var i = 0; i + 3 <= p.length; i++) {
      out.add(p.substring(i, i + 3));
    }
    return out;
  }

  static bool _isNum(String t) => RegExp(r'^\d+$').hasMatch(t);

  static double _tokenSim(String a, String b) {
    if (a == b) return 1;
    if (_isNum(a) || _isNum(b)) return 0;
    if (a.length >= 3 && b.length >= 3) {
      if (a.startsWith(b) || b.startsWith(a)) return 0.85; // abbreviations
    }
    final maxLen = math.max(a.length, b.length);
    if (maxLen < 4) return 0;
    final d = _levenshtein(a, b);
    final r = 1 - d / maxLen;
    return r >= 0.75 ? r : 0;
  }

  static int _levenshtein(String a, String b) {
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    var cur = List<int>.filled(b.length + 1, 0);
    for (var i = 1; i <= a.length; i++) {
      cur[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        cur[j] = math.min(math.min(cur[j - 1] + 1, prev[j] + 1),
            prev[j - 1] + cost);
      }
      final t = prev;
      prev = cur;
      cur = t;
    }
    return prev[b.length];
  }

  static double _softCover(List<String> a, List<String> b) {
    if (a.isEmpty) return 0;
    var sum = 0.0;
    for (final x in a) {
      var best = 0.0;
      for (final y in b) {
        final s = _tokenSim(x, y);
        if (s > best) best = s;
        if (best == 1) break;
      }
      sum += best;
    }
    return sum / a.length;
  }

  double _score(
      List<String> q, Set<String> qTri, _Prepared p, String hsn) {
    final c = p.tokens;
    if (q.isEmpty || c.isEmpty) return 0;
    final qCover = _softCover(q, c); // how much of the bill line is explained
    final cCover = _softCover(c, q); // how much of our item name is present
    final dice = (qCover * q.length + cCover * c.length) / (q.length + c.length);
    final inter = qTri.intersection(p.tri).length;
    final union = qTri.length + p.tri.length - inter;
    final tri = union == 0 ? 0.0 : inter / union;

    // Our item name fully contained in a longer vendor description is a
    // strong signal ("Samsung Galaxy A15 4/128 Blue" ⊇ "Galaxy A15 4/128").
    final contain = cCover;
    var score = math.max(0.65 * dice + 0.35 * tri, 0.55 * contain + 0.3 * dice + 0.15 * tri);

    // Different numbers = different variant (A15 vs A25, 128 vs 256).
    final qn = q.where(_isNum).toSet();
    final cn = c.where(_isNum).toSet();
    if (qn.isNotEmpty && cn.isNotEmpty) {
      final missingInBill = cn.difference(qn);
      if (missingInBill.isNotEmpty) {
        score -= 0.25 + 0.1 * (missingInBill.length - 1);
      }
    } else if (cn.isNotEmpty && qn.isEmpty) {
      score -= 0.15;
    }
    if (hsn.isNotEmpty && p.item.hsn.isNotEmpty) {
      if (p.item.hsn.startsWith(hsn.substring(0, math.min(4, hsn.length)))) {
        score += 0.03;
      }
    }
    return score.clamp(0.0, 0.99);
  }
}

class _Prepared {
  final CatalogItem item;
  late final String norm;
  late final List<String> tokens;
  late final Set<String> tri;
  late final List<String> codes;

  _Prepared(this.item) {
    final full = [item.name, if (!_contains(item.name, item.model)) item.model]
        .where((s) => s.trim().isNotEmpty)
        .join(' ');
    norm = BillItemMatcher.normalize(item.name);
    final fullNorm = BillItemMatcher.normalize(full);
    tokens = BillItemMatcher.tokens(fullNorm);
    tri = BillItemMatcher._trigrams(fullNorm.replaceAll(' ', ''));
    codes = [item.barcode, item.sku]
        .map((s) => s.trim().toUpperCase())
        .where((s) =>
            s.length >= 5 &&
            !s.startsWith('TKF') &&
            !s.startsWith('SKU_') &&
            RegExp(r'\d').hasMatch(s))
        .toList();
  }

  static bool _contains(String a, String b) =>
      b.trim().isEmpty || a.toLowerCase().contains(b.toLowerCase().trim());
}
