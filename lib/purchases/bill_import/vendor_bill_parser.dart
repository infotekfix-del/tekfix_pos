// =============================================================================
// TEKFIX ERP — Vendor bill parser
//
// Turns the positioned lines of a vendor's GST bill into structured data:
// vendor, bill number, date, line items and totals.  All money is integer
// paise; GST rates are basis points (18% = 1800).
//
// Strategy (works for Tally / Busy / Marg / Zoho / Vyapar style bills):
//  1. Header fields via labels ("Invoice No", "Dated", GSTIN …), looking in the
//     same cell, the next cell, or the cell directly below the label.
//  2. Item table: find the header row (Description / HSN / Qty / Rate /
//     Amount …), remember each column's x-position, and read rows until a
//     footer line (Total, CGST, Amount in words …).
//  3. Every row is cross-checked arithmetically (qty × rate − discount ≈
//     taxable, taxable × (1 + GST) ≈ amount). If the column reading does not
//     add up, a search over the row's numbers finds the combination that does.
//  4. Bill level: decides whether rates include GST, fills missing GST % from
//     the CGST/SGST/IGST totals, and compares with the printed grand total.
// =============================================================================

import 'bill_text_layout.dart';

/// Standard Indian GST slabs in basis points.
const List<int> kGstSlabsBp = [0, 25, 100, 150, 300, 500, 1200, 1800, 2800];

/// Slabs we guess when the bill does not print the rate.
const List<int> _inferSlabsBp = [1800, 1200, 500, 2800, 300];

class ExtractedBillLine {
  String description;
  String hsn;

  /// Quantity in hundredths (2 pcs = 200, 2.5 kg = 250).
  int qtyCenti;
  String unit;

  /// Purchase rate per unit, excluding GST, in paise.
  int ratePaise;

  /// Total discount for the line in paise.
  int discountPaise;

  /// GST rate in basis points (1800 = 18%). -1 = not printed on the bill.
  int gstBp;
  int mrpPaise;

  /// Amount printed on the bill for this row (may be taxable or incl. tax).
  int amountPaise;
  final List<String> serials;

  /// true when qty × rate and the amount agree.
  bool consistent;

  ExtractedBillLine({
    required this.description,
    this.hsn = '',
    required this.qtyCenti,
    this.unit = '',
    required this.ratePaise,
    this.discountPaise = 0,
    this.gstBp = -1,
    this.mrpPaise = 0,
    required this.amountPaise,
    List<String>? serials,
    this.consistent = true,
  }) : serials = serials ?? [];

  int get quantity => (qtyCenti / 100).round();
  bool get hasFractionalQty => qtyCenti % 100 != 0;
  int get grossPaise => _mulCenti(qtyCenti, ratePaise);
  int get taxablePaise => grossPaise - discountPaise;
  int get gstBpOrZero => gstBp < 0 ? 0 : gstBp;
  int get taxPaise => (taxablePaise * gstBpOrZero / 10000).round();
  int get totalPaise => taxablePaise + taxPaise;
  double get gstPercent => gstBpOrZero / 100.0;

  @override
  String toString() => 'Line($description | hsn=$hsn qty=${qtyCenti / 100} '
      '$unit rate=${ratePaise / 100} disc=${discountPaise / 100} '
      'gst=${gstBp / 100}% amt=${amountPaise / 100} ok=$consistent'
      '${serials.isEmpty ? '' : ' serials=$serials'})';
}

class ExtractedBill {
  String? vendorName;
  String? vendorGstin;
  String? vendorPhone;
  String? vendorAddress;
  String? billNumber;
  DateTime? billDate;
  final List<ExtractedBillLine> lines;
  int? grandTotalPaise;
  int cgstPaise;
  int sgstPaise;
  int igstPaise;
  int roundOffPaise;
  int otherChargesPaise;
  bool ratesIncludedGst;
  final List<String> warnings;
  String rawText;
  String method;

  ExtractedBill({
    this.vendorName,
    this.vendorGstin,
    this.vendorPhone,
    this.vendorAddress,
    this.billNumber,
    this.billDate,
    List<ExtractedBillLine>? lines,
    this.grandTotalPaise,
    this.cgstPaise = 0,
    this.sgstPaise = 0,
    this.igstPaise = 0,
    this.roundOffPaise = 0,
    this.otherChargesPaise = 0,
    this.ratesIncludedGst = false,
    List<String>? warnings,
    this.rawText = '',
    this.method = '',
  })  : lines = lines ?? [],
        warnings = warnings ?? [];

  int get taxTotalPaise => cgstPaise + sgstPaise + igstPaise;
  int get computedTotalPaise =>
      lines.fold<int>(0, (s, l) => s + l.totalPaise) + otherChargesPaise;

  /// Difference between printed total and our computed total (before
  /// round-off), or null when the bill shows no total.
  int? get totalDifferencePaise => grandTotalPaise == null
      ? null
      : grandTotalPaise! - (computedTotalPaise + roundOffPaise);

  bool get isEmpty => lines.isEmpty && billNumber == null && vendorName == null;
}

class VendorBillParser {
  /// The shop's own GSTIN / names, so "Bill To: TekFix" is not taken as vendor.
  final String ownGstin;
  final List<String> ownNames;
  final String ownPhone;

  const VendorBillParser({
    this.ownGstin = '',
    this.ownNames = const [],
    this.ownPhone = '',
  });

  ExtractedBill parseText(String text, {String method = 'Text'}) =>
      parseLines(BillTextLayout.fromPlainText(text), method: method);

  ExtractedBill parseLines(List<LayoutLine> lines, {String method = 'PDF'}) {
    final bill = ExtractedBill(
      rawText: BillTextLayout.toText(lines),
      method: method,
    );
    if (lines.isEmpty) return bill;

    final buyerIdx = _findBuyerLineIndex(lines);
    _extractGstin(lines, buyerIdx, bill);
    _extractPhone(lines, buyerIdx, bill);
    bill.billNumber = _extractBillNumber(lines);
    bill.billDate = _extractDate(lines);
    final table = _extractItems(lines, bill);
    _extractVendorName(lines, buyerIdx, table.headerIndex, bill);
    _extractTotals(lines, table.endIndex, bill);
    _finalise(bill);
    return bill;
  }

  // ===========================================================================
  // Numbers & money
  // ===========================================================================

  /// Parses "1,23,456.50", "₹ 500", "Rs.99.9", "(-)0.40" → paise.
  static int? parsePaise(String raw) {
    var t = raw.trim();
    if (t.isEmpty) return null;
    var neg = false;
    if (t.startsWith('(-)')) {
      neg = true;
      t = t.substring(3);
    }
    if (t.startsWith('(') && t.endsWith(')')) {
      neg = true;
      t = t.substring(1, t.length - 1);
    }
    t = t
        .replaceAll(RegExp(r'^(₹|Rs\.?|INR|Rs)\s*', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s*(Cr|Dr|/-)$', caseSensitive: false), '')
        .replaceAll(' ', '');
    if (t.startsWith('-')) {
      neg = !neg;
      t = t.substring(1);
    } else if (t.startsWith('+')) {
      t = t.substring(1);
    }
    if (t.endsWith('-')) {
      neg = !neg;
      t = t.substring(0, t.length - 1);
    }
    if (!RegExp(r'^(\d{1,3}(,\d{2,3})+|\d+)(\.\d{1,3})?$|^\.\d{1,3}$')
        .hasMatch(t)) {
      return null;
    }
    t = t.replaceAll(',', '');
    final parts = t.split('.');
    final rupees = parts[0].isEmpty ? 0 : int.parse(parts[0]);
    var paise = 0;
    if (parts.length > 1) {
      final f = parts[1];
      if (f.length == 1) {
        paise = int.parse(f) * 10;
      } else if (f.length == 2) {
        paise = int.parse(f);
      } else {
        paise = int.parse(f.substring(0, 2));
        if (int.parse(f[2]) >= 5) paise++;
      }
    }
    final v = rupees * 100 + paise;
    return neg ? -v : v;
  }

  // ===========================================================================
  // Header fields
  // ===========================================================================

  static final _gstinRe =
      RegExp(r'\b(\d{2}[A-Z]{5}\d{4}[A-Z][1-9A-Z]Z[0-9A-Z])\b');

  static final _buyerRe = RegExp(
      r'\b(bill(ed)?\s*to|buyer|consignee|ship(ped)?\s*to|sold\s*to|'
      r'customer\s*(name|details)?|party\s*details|recipient|receiver)\b',
      caseSensitive: false);

  int _findBuyerLineIndex(List<LayoutLine> lines) {
    for (var i = 0; i < lines.length; i++) {
      if (_buyerRe.hasMatch(lines[i].text)) return i;
    }
    return -1;
  }

  bool _isOwnGstin(String g) =>
      ownGstin.isNotEmpty && g.toUpperCase() == ownGstin.trim().toUpperCase();

  void _extractGstin(List<LayoutLine> lines, int buyerIdx, ExtractedBill bill) {
    String? before;
    String? any;
    for (var i = 0; i < lines.length; i++) {
      // Per cell, with spaces removed (OCR sometimes splits the GSTIN) but
      // without gluing neighbouring columns together.
      final found = <String>[
        for (final c in lines[i].cells)
          for (final m
              in _gstinRe.allMatches(c.text.toUpperCase().replaceAll(' ', '')))
            m.group(1)!,
        for (final m in _gstinRe.allMatches(lines[i].text.toUpperCase()))
          m.group(1)!,
      ];
      for (final g in found) {
        if (_isOwnGstin(g)) continue;
        any ??= g;
        if (buyerIdx < 0 || i < buyerIdx) before ??= g;
      }
    }
    // Buyer block usually holds *our* GSTIN; the vendor's is before it.
    bill.vendorGstin = before ?? any;
  }

  static final _phoneRe = RegExp(r'(?<!\d)(?:\+?91[\s-]?)?([6-9]\d{4}[\s-]?\d{5})(?!\d)');

  void _extractPhone(List<LayoutLine> lines, int buyerIdx, ExtractedBill bill) {
    final limit = buyerIdx > 0 ? buyerIdx : lines.length.clamp(0, 15);
    for (var i = 0; i < limit; i++) {
      final m = _phoneRe.firstMatch(lines[i].text);
      if (m != null) {
        final p = m.group(1)!.replaceAll(RegExp(r'[\s-]'), '');
        if (ownPhone.isNotEmpty && p == ownPhone) continue;
        bill.vendorPhone = p;
        return;
      }
    }
  }

  static final _billNoLabel = RegExp(
      // Not "order"/"challan": those numbers often appear before the bill no.
      r'(tax\s*)?(invoice|inv|bill|voucher|vch|memo|estimate|est)\s*'
      r'(no\.?|number|num|#)'
      r'|invoice\s*#|^\s*inv\.?\s*no',
      caseSensitive: false);

  /// Spreadsheet-style exports print "111713.0" for 111713.
  static String _cleanBillNo(String s) => s
      .replaceFirstMapped(RegExp(r'^(\d+)\.0+$'), (m) => m[1]!)
      .replaceAll(RegExp(r'[,;:]$'), '');

  static bool _looksLikeBillNo(String s) {
    final t = s.trim();
    if (t.isEmpty || t.length > 30) return false;
    if (!RegExp(r'\d').hasMatch(t)) return false;
    if (_parseDateStr(t) != null) return false;
    if (RegExp(r'^[A-Za-z0-9][A-Za-z0-9/\-_.#]*$').hasMatch(t)) return true;
    return false;
  }

  String? _extractBillNumber(List<LayoutLine> lines) {
    for (var i = 0; i < lines.length && i < 60; i++) {
      final cells = lines[i].cells;
      for (var c = 0; c < cells.length; c++) {
        final text = cells[c].text;
        final m = _billNoLabel.firstMatch(text);
        if (m == null) continue;
        // a) value in the same cell after the label
        final rest = text
            .substring(m.end)
            .replaceFirst(RegExp(r'^\s*[:.#\-]*\s*'), '')
            .trim();
        if (rest.isNotEmpty) {
          final tok = rest.split(RegExp(r'\s+')).first;
          if (_looksLikeBillNo(tok)) return _cleanBillNo(tok);
        }
        // b) next cell on the same line
        if (c + 1 < cells.length) {
          final tok = cells[c + 1]
              .text
              .replaceFirst(RegExp(r'^[:.#\-\s]*'), '')
              .split(RegExp(r'\s+'))
              .first;
          if (_looksLikeBillNo(tok)) return _cleanBillNo(tok);
        }
        // c) cell directly below (Tally boxes)
        final below = _cellBelow(lines, i, cells[c]);
        if (below != null) {
          final tok = below.split(RegExp(r'\s+')).first;
          if (_looksLikeBillNo(tok)) return _cleanBillNo(tok);
        }
      }
    }
    return null;
  }

  String? _cellBelow(List<LayoutLine> lines, int i, LayoutCell cell) {
    for (var j = i + 1; j < lines.length && j <= i + 2; j++) {
      if (lines[j].page != lines[i].page) break;
      for (final c in lines[j].cells) {
        final overlap = (c.x1 < cell.x1 ? c.x1 : cell.x1) -
            (c.x0 > cell.x0 ? c.x0 : cell.x0);
        if (overlap > 0 || (c.x0 - cell.x0).abs() < 6) return c.text.trim();
      }
    }
    return null;
  }

  static final _dateLabel = RegExp(
      r'(invoice|inv|bill|voucher)?\s*(date|dated|dt\.?)\b',
      caseSensitive: false);

  static final _dateFind = RegExp(
      r'(\d{1,2}[-/. ](?:\d{1,2}|[A-Za-z]{3,9})[-/., ]+\d{2,4}|\d{4}-\d{1,2}-\d{1,2}|'
      r'[A-Za-z]{3,9}\s+\d{1,2},?\s+\d{4})');

  DateTime? _extractDate(List<LayoutLine> lines) {
    for (var i = 0; i < lines.length && i < 60; i++) {
      final cells = lines[i].cells;
      for (var c = 0; c < cells.length; c++) {
        final text = cells[c].text;
        final m = _dateLabel.firstMatch(text);
        if (m == null) continue;
        if (RegExp(r'due|order|challan|dispatch|e-?way|ack',
                caseSensitive: false)
            .hasMatch(text.substring(0, m.end))) {
          continue;
        }
        final candidates = <String>[
          text.substring(m.end),
          if (c + 1 < cells.length) cells[c + 1].text,
          _cellBelow(lines, i, cells[c]) ?? '',
        ];
        for (final cand in candidates) {
          final dm = _dateFind.firstMatch(cand);
          if (dm != null) {
            final d = _parseDateStr(dm.group(1)!);
            if (d != null) return d;
          }
        }
      }
    }
    // Fallback: first date anywhere in the top part.
    for (var i = 0; i < lines.length && i < 40; i++) {
      for (final dm in _dateFind.allMatches(lines[i].text)) {
        final d = _parseDateStr(dm.group(1)!);
        if (d != null) return d;
      }
    }
    return null;
  }

  static const _months = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };

  static DateTime? _parseDateStr(String s) {
    final t = s.trim();
    DateTime? build(int y, int m, int d) {
      if (y < 100) y += 2000;
      if (m < 1 || m > 12 || d < 1 || d > 31 || y < 2000 || y > 2100) {
        return null;
      }
      final dt = DateTime(y, m, d);
      return dt.month == m ? dt : null;
    }

    var m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(t);
    if (m != null) {
      return build(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
    }
    m = RegExp(r'^(\d{1,2})[-/. ](\d{1,2})[-/. ](\d{2,4})$').firstMatch(t);
    if (m != null) {
      // Indian bills are day-first.
      return build(int.parse(m[3]!), int.parse(m[2]!), int.parse(m[1]!));
    }
    m = RegExp(r'^(\d{1,2})[-/. ]([A-Za-z]{3,9})[-/., ]+(\d{2,4})$')
        .firstMatch(t);
    if (m != null) {
      final mon = _months[m[2]!.substring(0, 3).toLowerCase()];
      if (mon == null) return null;
      return build(int.parse(m[3]!), mon, int.parse(m[1]!));
    }
    m = RegExp(r'^([A-Za-z]{3,9})\s+(\d{1,2}),?\s+(\d{4})$').firstMatch(t);
    if (m != null) {
      final mon = _months[m[1]!.substring(0, 3).toLowerCase()];
      if (mon == null) return null;
      return build(int.parse(m[3]!), mon, int.parse(m[2]!));
    }
    return null;
  }

  static final _skipVendorRe = RegExp(
      r'tax\s*invoice|invoice|original|duplicate|triplicate|recipient|'
      r'gstin|gst\s*no|state\s*(name|code)|e-?mail|'
      r'(phone|mobile|mob|ph|tel|cell)\.?\s*(no\.?)?\s*[:#]|'
      r'pan\b|cin\b|website|www\.|page\s*\d|bill\s*of\s*supply|cash\s*memo|'
      r'estimate|quotation|delivery\s*note|^\d+$',
      caseSensitive: false);

  static final _businessRe = RegExp(
      r'\b(m/s|pvt|private|ltd|limited|llp|traders?|trading|enterprises?|'
      r'agenc(y|ies)|distributors?|distribution|mobiles?|telecom|electronics|'
      r'communications?|marketing|sales|associates|company|co\.|corporation|'
      r'stores?|impex|exports?|imports?|solutions|international|india)\b',
      caseSensitive: false);

  bool _isOwnName(String s) {
    final l = s.toLowerCase();
    for (final n in ownNames) {
      final o = n.toLowerCase().trim();
      if (o.length >= 3 && l.contains(o)) return true;
    }
    return false;
  }

  void _extractVendorName(List<LayoutLine> lines, int buyerIdx, int tableIdx,
      ExtractedBill bill) {
    // 1. Explicit label: "Supplier:", "Seller:", "Sold By:", "From:", "M/s"
    final labelRe = RegExp(
        r'^(supplier|seller|sold\s*by|vendor|from|billed\s*by|issued\s*by)\s*'
        r'(name|details)?\s*[:\-]\s*(.+)$',
        caseSensitive: false);
    for (var i = 0; i < lines.length && i < 40; i++) {
      for (final c in lines[i].cells) {
        final m = labelRe.firstMatch(c.text.trim());
        if (m != null) {
          final v = m.group(3)!.trim();
          if (v.length >= 3 && !_isOwnName(v)) {
            bill.vendorName = _cleanName(v);
            return;
          }
        }
      }
    }
    // 2. Top block before buyer / table.
    var limit = lines.length.clamp(0, 25);
    if (buyerIdx > 0 && buyerIdx < limit) limit = buyerIdx;
    if (tableIdx > 0 && tableIdx < limit) limit = tableIdx;
    String? firstPlain;
    for (var i = 0; i < limit; i++) {
      for (final c in lines[i].cells) {
        final t = c.text.trim();
        if (t.length < 3 || t.length > 70) continue;
        if (_skipVendorRe.hasMatch(t) || _gstinRe.hasMatch(t.toUpperCase())) {
          continue;
        }
        if (_isOwnName(t)) continue;
        final letters = RegExp(r'[A-Za-z]').allMatches(t).length;
        if (letters < t.replaceAll(' ', '').length * 0.6) continue;
        if (_businessRe.hasMatch(t)) {
          bill.vendorName = _cleanName(t);
          return;
        }
        firstPlain ??= t;
      }
    }
    if (firstPlain != null) bill.vendorName = _cleanName(firstPlain);
  }

  static String _cleanName(String s) => s
      .replaceFirst(RegExp(r'^m/s\.?\s*', caseSensitive: false), '')
      .replaceAll(RegExp(r'[,:;]+$'), '')
      .trim();

  // ===========================================================================
  // Item table
  // ===========================================================================

  static const _roleWords = <String, List<String>>{
    'sl': ['sl', 'sl.', 'slno', 'sno', 's.no', 's.no.', 'sr', 'sr.', 'srno', '#', 'no.', 'no', 'si'],
    'desc': ['description', 'particulars', 'item', 'items', 'product', 'products', 'goods', 'name', 'details', 'itemname', 'model'],
    'hsn': ['hsn', 'sac', 'hsn/sac', 'hsncode', 'hsn/sac.', 'hsn/'],
    'qty': ['qty', 'qty.', 'quantity', 'qnty', 'qty(nos)', 'quan'],
    'unit': ['unit', 'uom', 'per', 'units'],
    'mrp': ['mrp', 'm.r.p', 'm.r.p.'],
    'rate': ['rate', 'price', 'unitprice', 'rate/unit', 'cost', 'u.price', 'rate(rs)', 'rate(₹)'],
    'disc': ['disc', 'disc.', 'disc%', 'discount', 'dis%', 'dis.', 'dis'],
    'gst': ['gst', 'gst%', 'igst', 'igst%', 'tax%', 'gstrate', 'gst(%)', 'taxrate', 'vat%'],
    'taxable': ['taxable', 'taxablevalue', 'taxableamt', 'taxableamount', 'nettaxable', 'assessable'],
    'taxamt': ['taxamt', 'taxamount', 'gstamt', 'gstamount', 'cgst', 'sgst', 'cgstamt', 'sgstamt', 'igstamt'],
    'amount': ['amount', 'amt', 'total', 'value', 'netamount', 'netamt', 'linetotal', 'amount(rs)', 'amount(₹)', 'net'],
  };

  static String? _roleOf(String rawWord) {
    final w = rawWord.toLowerCase().replaceAll(RegExp(r'[:]+$'), '');
    for (final e in _roleWords.entries) {
      if (e.value.contains(w)) return e.key;
    }
    return null;
  }

  /// Classifies a header phrase (one cell). Returns role or null.
  static String? _rolePhrase(String phrase) {
    final p = phrase.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    if (p.isEmpty) return null;
    if (p.contains('hsn') || p == 'sac') return 'hsn';
    if (p.contains('taxable')) return 'taxable';
    if (p.contains('mrp') || p.contains('m.r.p')) return 'mrp';
    if (RegExp(r'(gst|igst|tax|vat).*(%|rate)|^(gst|igst)$|^(gst|igst)%')
        .hasMatch(p)) {
      return 'gst';
    }
    if (RegExp(r'(gst|tax|cgst|sgst|igst).*(amt|amount)').hasMatch(p) ||
        p == 'cgst' ||
        p == 'sgst') {
      return 'taxamt';
    }
    if (p.startsWith('disc') || p.startsWith('dis%')) return 'disc';
    if (p.startsWith('qty') || p.startsWith('quantity') || p == 'qnty') {
      return 'qty';
    }
    if (RegExp(r'^(description|particulars|item|product|goods|name|details)')
        .hasMatch(p)) {
      return 'desc';
    }
    if (RegExp(r'^(rate|price|unitprice|u\.price|cost)').hasMatch(p)) {
      return 'rate';
    }
    if (RegExp(r'^(amount|amt|total|netamount|netamt|value|linetotal)')
        .hasMatch(p)) {
      return 'amount';
    }
    if (p == 'unit' || p == 'uom' || p == 'per' || p == 'units') return 'unit';
    if (RegExp(r'^(sl|s\.?no|sr|#|si)').hasMatch(p)) return 'sl';
    return _roleOf(phrase);
  }

  static const Map<String, String> _multiWord = {
    'description of goods': 'desc',
    'description of goods/services': 'desc',
    'description of services': 'desc',
    'item description': 'desc',
    'item name': 'desc',
    'item details': 'desc',
    'product name': 'desc',
    'product description': 'desc',
    'name of product': 'desc',
    'name of item': 'desc',
    'particulars of goods': 'desc',
    'hsn/sac': 'hsn',
    'hsn / sac': 'hsn',
    'hsn code': 'hsn',
    'hsn/sac code': 'hsn',
    'sac code': 'hsn',
    'unit price': 'rate',
    'rate per unit': 'rate',
    'price per unit': 'rate',
    'unit rate': 'rate',
    'unit cost': 'rate',
    'net rate': 'rate',
    'rate (rs)': 'rate',
    'rate (₹)': 'rate',
    'taxable value': 'taxable',
    'taxable amount': 'taxable',
    'taxable amt': 'taxable',
    'taxable val': 'taxable',
    'gst %': 'gst',
    'gst rate': 'gst',
    'gst (%)': 'gst',
    'tax %': 'gst',
    'tax rate': 'gst',
    'igst %': 'gst',
    'igst rate': 'gst',
    'disc %': 'disc',
    'disc. %': 'disc',
    'discount %': 'disc',
    'disc amt': 'disc',
    'discount amount': 'disc',
    'net amount': 'amount',
    'net amt': 'amount',
    'net value': 'amount',
    'total amount': 'amount',
    'total value': 'amount',
    'line total': 'amount',
    'amount (rs)': 'amount',
    'amount (₹)': 'amount',
    'tax amount': 'taxamt',
    'tax amt': 'taxamt',
    'gst amount': 'taxamt',
    'gst amt': 'taxamt',
    'sl no': 'sl',
    'sl. no': 'sl',
    'sl. no.': 'sl',
    'sl no.': 'sl',
    's. no': 'sl',
    's. no.': 'sl',
    'sr. no': 'sl',
    'sr. no.': 'sl',
    'sr no': 'sl',
    's no': 'sl',
  };

  List<_Col>? _detectHeader(LayoutLine line) {
    final cols = <_Col>[];
    for (final cell in line.cells) {
      final whole = cell.text.toLowerCase().trim();
      final wholeRole = _multiWord[whole] ??
          (cell.words.length == 1 ? _rolePhrase(cell.text) : null);
      if (wholeRole != null) {
        cols.add(_Col(wholeRole, cell.x0, cell.x1, cell.text));
        continue;
      }
      // Several column titles packed into one cell ("Qty Rate per Amount"):
      // segment by known multi-word titles, then single words. Words without
      // a role ("of", "(Rs)") stay with the previous title.
      final ws = cell.words;
      _Col? cur;
      var i = 0;
      while (i < ws.length) {
        String? role;
        var used = 1;
        for (var k = 3; k >= 2; k--) {
          if (i + k > ws.length) continue;
          final phrase =
              ws.sublist(i, i + k).map((w) => w.text).join(' ').toLowerCase();
          final r = _multiWord[phrase];
          if (r != null) {
            role = r;
            used = k;
            break;
          }
        }
        role ??= _roleOf(ws[i].text);
        if (role != null && cur != null && cur.role == role) {
          cur.x1 = ws[i + used - 1].x1; // "Item & Description"
          cur.label = '${cur.label} ${ws.sublist(i, i + used).map((w) => w.text).join(' ')}';
        } else if (role != null) {
          cur = _Col(role, ws[i].x0, ws[i + used - 1].x1,
              ws.sublist(i, i + used).map((w) => w.text).join(' '));
          cols.add(cur);
        } else if (cur != null) {
          cur.x1 = ws[i].x1;
          cur.label = '${cur.label} ${ws[i].text}';
        }
        i += used;
      }
    }
    final roles = cols.map((c) => c.role).toSet();
    final hasDesc = roles.contains('desc');
    final numeric = roles.intersection({'qty', 'rate', 'amount', 'taxable'});
    if (!hasDesc || numeric.length < 2) return null;
    return cols;
  }

  static final _footerRe = RegExp(
      r'^(sub\s*-?\s*total|total|grand\s*total|net\s*(amount|payable|total)|'
      r'taxable\s*(value|amount)|cgst|sgst|igst|utgst|cess|round(ed)?\s*off|'
      r'r/?off|amount\s*(chargeable|in\s*words|payable)|rupees|rs\.?\s+[a-z]|'
      r'inr\s+[a-z]|bank|declaration|terms|e\.?\s*&\s*o\.?\s*e|'
      r'for\s+[a-z]|authori[sz]ed|less\s*:|add\s*:|freight|packing|'
      r'tax\s*amount|output|input|hsn/?sac\s+taxable|discount\s*:|'
      r'previous\s*balance|balance|received|paid|thank)',
      caseSensitive: false);

  static final _strongFooterRe = RegExp(
      r'^(sub\s*-?\s*total|total|grand\s*total|net\s*(amount|payable|total)|'
      r'taxable|cgst|sgst|igst|utgst|cess|round(ed)?\s*off|r/?off|'
      r'amount\s*(chargeable|in\s*words|payable)|rupees|tax\s*amount|'
      r'output|input|hsn/?sac)',
      caseSensitive: false);

  static final _unitRe = RegExp(
      r'^(nos?\.?|pcs?\.?|pieces?|units?|box(es)?|bxs?|sets?|pairs?|prs?|'
      r'kgs?|kg\.|gms?|grams?|ltrs?|litres?|mtrs?|meters?|metres?|pkts?|'
      r'packets?|bundles?|rolls?|dozens?|dzn|each|ea|qty|pkt)$',
      caseSensitive: false);

  static final _numTokRe = RegExp(r'^\(?[-+]?(₹|Rs\.?)?\d[\d,]*(\.\d+)?\)?$');

  _TableInfo _extractItems(List<LayoutLine> lines, ExtractedBill bill) {
    var headerIdx = -1;
    for (var i = 0; i < lines.length; i++) {
      if (_detectHeader(lines[i]) != null) {
        headerIdx = i;
        break;
      }
    }
    if (headerIdx < 0) {
      // No recognisable table header: read line by line.
      final idx = [for (var i = 0; i < lines.length; i++) i];
      final end = _parseLinesSequential(lines, idx, null, bill);
      return _TableInfo(-1, bill.lines.isEmpty ? 0 : end);
    }

    var tableEnd = headerIdx + 1;
    var h = headerIdx;
    final used = <int>{};
    while (h >= 0 && h < lines.length) {
      final fragments = <int>{};
      final cols = _mergeHeaderFragments(
          lines, h, _detectHeader(lines[h])!, fragments);
      used
        ..add(h)
        ..addAll(fragments);
      final region = <int>[];
      var j = h + 1;
      while (j < lines.length) {
        if (fragments.contains(j)) {
          j++;
          continue;
        }
        final l = lines[j];
        if (_detectHeader(l) != null) break;
        if (_isFooterLine(l, cols)) break;
        region.add(j);
        j++;
      }
      _parseRegion(lines, region, cols, bill);
      if (region.isNotEmpty) tableEnd = j;
      final next = _nextHeaderIndex(lines, j);
      if (next < 0 || used.contains(next)) break;
      h = next;
    }
    return _TableInfo(headerIdx, tableEnd);
  }

  /// Header titles split over 2–3 lines ("Taxable" / "Value", "GST" / "%").
  List<_Col> _mergeHeaderFragments(
      List<LayoutLine> lines, int h, List<_Col> cols, Set<int> fragments) {
    final hdr = lines[h];
    final band = (hdr.h <= 0 ? 10 : hdr.h) * 1.7;
    final cand = <int>[];
    for (var k = h - 2; k <= h + 2; k++) {
      if (k == h || k < 0 || k >= lines.length) continue;
      final l = lines[k];
      if (l.page != hdr.page || (l.y - hdr.y).abs() > band) continue;
      final ok = l.cells.every((c) =>
          !RegExp(r'\d').hasMatch(c.text.replaceAll(RegExp(r'[%#]'), '')) &&
          (_rolePhrase(c.text) != null ||
              _headerSuffixRe.hasMatch(c.text.trim())));
      if (ok) cand.add(k);
    }
    cand.sort((a, b) => lines[a].y.compareTo(lines[b].y));
    final out = [...cols];
    for (final k in cand) {
      fragments.add(k);
      for (final c in lines[k].cells) {
        _Col? hit;
        for (final col in out) {
          final ov = (c.x1 < col.x1 ? c.x1 : col.x1) -
              (c.x0 > col.x0 ? c.x0 : col.x0);
          if (ov > 0 ||
              (c.x0 - col.x0).abs() < 8 ||
              (c.x1 - col.x1).abs() < 8) {
            hit = col;
            break;
          }
        }
        if (hit != null) {
          final label = lines[k].y < hdr.y
              ? '${c.text} ${hit.label}'
              : '${hit.label} ${c.text}';
          final role = _multiWord[label.toLowerCase()] ?? _rolePhrase(label);
          final idx = out.indexOf(hit);
          out[idx] = _Col(
              role ?? hit.role,
              c.x0 < hit.x0 ? c.x0 : hit.x0,
              c.x1 > hit.x1 ? c.x1 : hit.x1,
              label);
        } else {
          final role = _rolePhrase(c.text);
          if (role != null) out.add(_Col(role, c.x0, c.x1, c.text));
        }
      }
    }
    return out;
  }

  static final _headerSuffixRe = RegExp(
      r'^(value|%|\(%\)|\(rs\.?\)|\(₹\)|code|no\.?|amt\.?|price|rate|per|'
      r'details|of\s+goods)$',
      caseSensitive: false);

  bool _isFooterLine(LayoutLine line, List<_Col>? cols) {
    final firstText = _stripSerial(line.cells.first.text);
    final isFooter = _footerRe.hasMatch(firstText) ||
        (line.cells.length > 1 &&
            _footerRe.hasMatch(line.cells[1].text) &&
            RegExp(r'^\d{0,3}$').hasMatch(line.cells.first.text.trim()));
    if (!isFooter) return false;
    // Weak footer words ("For", "Bank", "Freight"…) can start a real item
    // name; keep the row if it adds up arithmetically.
    if (!_strongFooterRe.hasMatch(firstText)) {
      final probe = _parseRow(line, cols);
      if (probe != null && probe.consistent && probe.qtyCenti > 0) {
        return false;
      }
    }
    return true;
  }

  /// Parses the rows of one table region. Lines that carry a value in the
  /// Amount column are row "anchors"; nearby lines without one (wrapped
  /// names, vertically-centred qty/unit, IMEI lines) are merged into the
  /// closest anchor so each bill row becomes one logical row.
  void _parseRegion(List<LayoutLine> lines, List<int> region, List<_Col> cols,
      ExtractedBill bill) {
    if (region.isEmpty) return;
    _Col? amountCol;
    for (final c in cols) {
      if (c.role == 'amount') amountCol = c; // right-most "amount" wins
    }
    if (amountCol == null) {
      for (final c in cols) {
        if (c.role == 'taxable') amountCol = c;
      }
    }
    if (amountCol == null) {
      _parseLinesSequential(lines, region, cols, bill);
      return;
    }
    final numericCols = cols.where((c) => c.role != 'desc').toList();
    bool isAnchor(LayoutLine l) {
      for (final w in l.words) {
        final t = w.text.replaceAll(RegExp(r'^(₹|Rs\.?)'), '');
        if (!_numTokRe.hasMatch(t) || RegExp(r'^\d{9,}$').hasMatch(t)) {
          continue;
        }
        if (parsePaise(t) == null) continue;
        final tok = _Tok.number(t, w.x0, w.x1);
        if (identical(_nearest(tok, numericCols), amountCol)) return true;
      }
      return false;
    }

    final anchors = region.where((i) => isAnchor(lines[i])).toList();
    if (anchors.isEmpty) {
      _parseLinesSequential(lines, region, cols, bill);
      return;
    }
    final firstNumXForTies = _firstNumericColX0(cols) ?? double.infinity;
    bool hasOwnName(LayoutLine l) => l.words.any((w) =>
        w.x1 <= firstNumXForTies + 2 &&
        RegExp(r'[A-Za-z]{2}').hasMatch(w.text));
    final groupOf = <int, int>{}; // line → anchor line
    for (final i in region) {
      if (anchors.contains(i)) continue;
      final l = lines[i];
      int? best;
      var bestD = double.infinity;
      for (final a in anchors) {
        final al = lines[a];
        if (al.page != l.page) continue;
        final d = (al.y - l.y).abs();
        final tie = best != null && (d - bestD).abs() < l.h * 0.25;
        // On a tie, a name line belongs to the row that has no name yet.
        if (tie && hasOwnName(lines[best]) && !hasOwnName(al)) {
          bestD = d;
          best = a;
        } else if (!tie && d < bestD) {
          bestD = d;
          best = a;
        }
      }
      if (best == null) continue;
      final lh = l.h > lines[best].h ? l.h : lines[best].h;
      if (bestD <= lh * 2.6) groupOf[i] = best;
    }

    final firstNumX = _firstNumericColX0(cols) ?? double.infinity;
    ExtractedBillLine? last;
    var lastIdx = -1;
    for (final i in region) {
      if (anchors.contains(i)) {
        final members = <int>[
          i,
          for (final e in groupOf.entries)
            if (e.value == i) e.key,
        ];
        final merged = members.length == 1
            ? lines[i]
            : _mergeLines([for (final m in members) lines[m]], firstNumX);
        final row = _parseRow(merged, cols);
        if (row != null) {
          bill.lines.add(row);
          last = row;
          lastIdx = i;
        }
        continue;
      }
      if (groupOf.containsKey(i)) continue;
      // Unattached line: IMEIs or wrapped description of the previous row.
      if (last != null && i - lastIdx <= 4) {
        if (_attachContinuation(lines[i], last, cols)) lastIdx = i;
      }
    }
  }

  LayoutLine _mergeLines(List<LayoutLine> ls, double firstNumX) {
    final desc = <(double, LayoutWord)>[];
    final other = <LayoutWord>[];
    for (final l in ls) {
      for (final w in l.words) {
        if (w.x1 <= firstNumX + 2) {
          desc.add((l.y, w));
        } else {
          other.add(w);
        }
      }
    }
    desc.sort((a, b) {
      final dy = a.$1.compareTo(b.$1);
      return dy != 0 ? dy : a.$2.x0.compareTo(b.$2.x0);
    });
    final descWords = desc.map((e) => e.$2).toList();
    // The serial number ("1") sits beside a later line of a wrapped name;
    // move it to the front so it is stripped as a serial, not kept in the name.
    if (descWords.isNotEmpty) {
      final minX = descWords.map((e) => e.x0).reduce((a, b) => a < b ? a : b);
      final serialIdx = descWords.indexWhere((w) =>
          RegExp(r'^\d{1,3}[.)]?$').hasMatch(w.text) && w.x0 <= minX + 1);
      if (serialIdx > 0) {
        final sw = descWords.removeAt(serialIdx);
        descWords.insert(0, sw);
      }
    }
    other.sort((a, b) => a.x0.compareTo(b.x0));
    final anchor = ls.first;
    return LayoutLine(
      page: anchor.page,
      y: anchor.y,
      h: anchor.h,
      cells: [
        if (descWords.isNotEmpty) LayoutCell(descWords),
        for (final w in other) LayoutCell([w]),
      ],
    );
  }

  bool _attachContinuation(
      LayoutLine line, ExtractedBillLine last, List<_Col>? cols) {
    final text = line.text.trim();
    final serials = _serialRe.allMatches(text).map((m) => m.group(1)!).toList();
    if (serials.isNotEmpty) {
      for (final s in serials) {
        if (!last.serials.contains(s)) last.serials.add(s);
      }
      return true;
    }
    if (cols != null && _isDescriptionContinuation(line, cols)) {
      last.description =
          '${last.description} $text'.replaceAll(RegExp(r'\s+'), ' ');
      return true;
    }
    return false;
  }

  static final _serialRe = RegExp(r'(?<!\d)(\d{15})(?!\d)');

  /// Line-by-line reading (no header found / no amount column).
  int _parseLinesSequential(List<LayoutLine> lines, List<int> idxs,
      List<_Col>? cols, ExtractedBill bill) {
    ExtractedBillLine? last;
    var lastIdx = -1;
    var end = idxs.isEmpty ? 0 : idxs.last + 1;
    for (final i in idxs) {
      final line = lines[i];
      if (line.text.trim().isEmpty) continue;
      if (_isFooterLine(line, cols)) {
        if (bill.lines.isNotEmpty) {
          end = i;
          break;
        }
        continue;
      }
      final row = _parseRow(line, cols);
      if (row != null) {
        bill.lines.add(row);
        last = row;
        lastIdx = i;
        continue;
      }
      if (last != null && i - lastIdx <= 3) {
        if (_attachContinuation(line, last, cols)) lastIdx = i;
      }
    }
    return end;
  }

  int _nextHeaderIndex(List<LayoutLine> lines, int from) {
    for (var i = from; i < lines.length; i++) {
      if (_detectHeader(lines[i]) != null) return i;
    }
    return -1;
  }

  bool _isDescriptionContinuation(LayoutLine line, List<_Col>? cols) {
    final t = line.text.trim();
    if (t.length < 2 || t.length > 80) return false;
    if (RegExp(r'\d[\d,]*\.\d{2}').hasMatch(t)) return false;
    if (RegExp(r'^(batch|exp|mfg|serial|s/n|imei|warranty)',
            caseSensitive: false)
        .hasMatch(t)) {
      return false;
    }
    if (_gstinRe.hasMatch(t.toUpperCase())) return false;
    if (line.cells.length > 2) return false;
    if (cols == null) return false;
    final desc = cols.where((c) => c.role == 'desc');
    if (desc.isEmpty) return false;
    final d = desc.first;
    final firstNumeric = _firstNumericColX0(cols);
    return line.cells.first.x0 >= d.x0 - 40 &&
        (firstNumeric == null || line.cells.first.x0 < firstNumeric);
  }

  static String _stripSerial(String s) =>
      s.trim().replaceFirst(RegExp(r'^\d{1,3}[.)]?\s+'), '');

  double? _firstNumericColX0(List<_Col> cols) {
    double? x;
    for (final c in cols) {
      if (c.role == 'desc' || c.role == 'sl') continue;
      if (x == null || c.x0 < x) x = c.x0;
    }
    return x;
  }

  ExtractedBillLine? _parseRow(LayoutLine line, List<_Col>? cols) {
    final words = [...line.words];
    if (words.isEmpty) return null;

    // ---- tokenise ----
    final toks = <_Tok>[];
    final serials = <String>[];
    for (var i = 0; i < words.length; i++) {
      final w = words[i];
      var t = w.text.trim();
      if (t.isEmpty) continue;
      // IMEI / serial labels printed under the item name.
      if (RegExp(r'^(imei\d?|ime-i|s/?n|serial|sr\.?no)[:.\-]?$',
              caseSensitive: false)
          .hasMatch(t)) {
        continue;
      }
      final sm = RegExp(r'^(?:imei\d?[:\-]?)?(\d{15})[,;]?$',
              caseSensitive: false)
          .firstMatch(t);
      if (sm != null) {
        serials.add(sm.group(1)!);
        continue;
      }
      // OCR split "1 ,749.94" → "1,749.94"
      if (i + 1 < words.length &&
          RegExp(r'^\d{1,3}$').hasMatch(t) &&
          RegExp(r'^,\d{2,3}').hasMatch(words[i + 1].text)) {
        final nx = words[i + 1];
        words[i + 1] = LayoutWord('$t${nx.text}', w.x0, nx.x1);
        continue;
      }
      // Leading serial number "1", "1.", "2)" followed by the item name.
      if (i == 0 &&
          words.length > 2 &&
          RegExp(r'^\d{1,3}[.)]?$').hasMatch(t) &&
          !_numTokRe.hasMatch(words[1].text) &&
          !_unitRe.hasMatch(words[1].text)) {
        continue;
      }
      // "₹" / "Rs." standing alone in front of a number
      if ((t == '₹' || t.toLowerCase() == 'rs.' || t.toLowerCase() == 'rs') &&
          i + 1 < words.length) {
        continue;
      }
      // "10Nos", "2PCS"
      final qu = RegExp(r'^(\d+(?:\.\d+)?)([A-Za-z]{2,7}\.?)$').firstMatch(t);
      if (qu != null && _unitRe.hasMatch(qu.group(2)!)) {
        final mid = w.x0 + (w.x1 - w.x0) * qu.group(1)!.length / t.length;
        toks.add(_Tok.number(qu.group(1)!, w.x0, mid));
        toks.add(_Tok.unit(qu.group(2)!, mid, w.x1));
        continue;
      }
      if (t.endsWith('%')) {
        final v = parsePaise(t.substring(0, t.length - 1));
        if (v != null) {
          toks.add(_Tok.percent(t, v, w.x0, w.x1));
          continue;
        }
        if (t == '%' && toks.isNotEmpty && toks.last.kind == _K.num) {
          final prev = toks.removeLast();
          toks.add(_Tok.percent('${prev.raw}%', prev.value, prev.x0, w.x1));
          continue;
        }
      }
      if (_numTokRe.hasMatch(t)) {
        toks.add(_Tok.number(t, w.x0, w.x1));
        continue;
      }
      if (_unitRe.hasMatch(t)) {
        toks.add(_Tok.unit(t, w.x0, w.x1));
        continue;
      }
      toks.add(_Tok.text(t, w.x0, w.x1));
    }

    final numToks = toks.where((t) => t.kind == _K.num).toList();
    if (numToks.isEmpty) return null;
    final letters =
        toks.where((t) => t.kind == _K.text).map((t) => t.raw).join(' ');
    if (RegExp(r'[A-Za-z]').allMatches(letters).length < 2) return null;

    // ---- column-based reading ----
    _RowGuess? colGuess;
    if (cols != null) colGuess = _readByColumns(toks, cols);

    // ---- arithmetic search ----
    final heur = _readByArithmetic(toks, colGuess?.hsnTok);

    _RowGuess? pick;
    if (colGuess != null && colGuess.consistent) {
      pick = colGuess;
    } else if (heur != null && heur.consistent) {
      pick = heur;
      // keep column info we trust (HSN, unit, GST, MRP)
      if (colGuess != null) {
        pick.hsn = pick.hsn.isEmpty ? colGuess.hsn : pick.hsn;
        pick.unit = pick.unit.isEmpty ? colGuess.unit : pick.unit;
        if (pick.gstBp < 0) pick.gstBp = colGuess.gstBp;
        if (pick.mrpPaise == 0) pick.mrpPaise = colGuess.mrpPaise;
        if (colGuess.description.isNotEmpty) {
          pick.description = colGuess.description;
        }
      }
    } else if (colGuess != null && colGuess.amountPaise > 0 &&
        colGuess.ratePaise > 0) {
      pick = colGuess;
    } else {
      pick = heur;
    }
    if (pick == null) return null;
    if (pick.amountPaise <= 0 || pick.ratePaise <= 0 || pick.qtyCenti <= 0) {
      return null;
    }
    final desc = pick.description.trim();
    if (RegExp(r'[A-Za-z]').allMatches(desc).length < 2) return null;
    if (_footerRe.hasMatch(desc)) return null;

    return ExtractedBillLine(
      description: desc,
      hsn: pick.hsn,
      qtyCenti: pick.qtyCenti,
      unit: _normaliseUnit(pick.unit),
      ratePaise: pick.ratePaise,
      discountPaise: pick.discountPaise,
      gstBp: pick.gstBp,
      mrpPaise: pick.mrpPaise,
      amountPaise: pick.amountPaise,
      serials: serials,
      consistent: pick.consistent,
    );
  }

  static String _normaliseUnit(String u) {
    final l = u.toLowerCase().replaceAll('.', '');
    if (l.isEmpty) return '';
    if (RegExp(r'^(nos?|pcs?|pieces?|units?|each|ea)$').hasMatch(l)) {
      return 'Piece';
    }
    if (RegExp(r'^(box(es)?|bxs?)$').hasMatch(l)) return 'Box';
    if (RegExp(r'^(sets?)$').hasMatch(l)) return 'Set';
    if (RegExp(r'^(pairs?|prs?)$').hasMatch(l)) return 'Pair';
    if (RegExp(r'^(kgs?)$').hasMatch(l)) return 'Kg';
    if (RegExp(r'^(gms?|grams?)$').hasMatch(l)) return 'Gram';
    if (RegExp(r'^(ltrs?|litres?)$').hasMatch(l)) return 'Litre';
    if (RegExp(r'^(mtrs?|meters?|metres?)$').hasMatch(l)) return 'Metre';
    if (RegExp(r'^(bundles?)$').hasMatch(l)) return 'Bundle';
    if (RegExp(r'^(pkts?|packets?|pkt)$').hasMatch(l)) return 'Packet';
    return u;
  }

  _RowGuess? _readByColumns(List<_Tok> toks, List<_Col> cols) {
    final g = _RowGuess();
    final firstNumX = _firstNumericColX0(cols);
    final numericCols = cols.where((c) => c.role != 'desc').toList();
    final descParts = <String>[];
    int? qty, rate, disc, taxable, amount, mrp;
    int? discPct;
    for (final t in toks) {
      final inDescZone = firstNumX == null || t.x1 <= firstNumX + 2;
      if (t.kind == _K.text) {
        if (inDescZone || descParts.isEmpty) {
          descParts.add(t.raw);
        } else if (_nearest(t, numericCols)?.role == 'unit') {
          g.unit = t.raw;
        } else {
          descParts.add(t.raw);
        }
        continue;
      }
      if (inDescZone && t.kind == _K.num && descParts.isNotEmpty) {
        descParts.add(t.raw); // "iPhone 15", "Redmi 13C 4 128"
        continue;
      }
      if (inDescZone && t.kind == _K.num && descParts.isEmpty) {
        continue; // serial number column
      }
      final col = _nearest(t, numericCols);
      if (col == null) continue;
      if (t.kind == _K.unit) {
        g.unit = t.raw;
        continue;
      }
      switch (col.role) {
        case 'hsn':
          if (RegExp(r'^\d{4,8}$').hasMatch(t.raw)) {
            g.hsn = t.raw;
            g.hsnTok = t;
          }
          break;
        case 'qty':
          qty ??= t.value;
          break;
        case 'rate':
          rate ??= t.value;
          break;
        case 'mrp':
          mrp ??= t.value;
          break;
        case 'disc':
          if (t.kind == _K.pct || col.label.contains('%')) {
            discPct ??= t.value;
          } else {
            disc ??= t.value;
          }
          break;
        case 'gst':
          if (t.kind == _K.pct || (t.value <= 2800 && t.value >= 0)) {
            g.gstBp = g.gstBp < 0 ? t.value : g.gstBp + t.value;
          }
          break;
        case 'taxable':
          taxable ??= t.value;
          break;
        case 'amount':
          amount = t.value; // last one wins (Net Amount after Amount)
          break;
        case 'unit':
          break;
        case 'sl':
          break;
        default:
          break;
      }
    }
    g.description = descParts.join(' ');
    g.mrpPaise = mrp ?? 0;
    if (qty == null || rate == null) {
      g.qtyCenti = qty ?? 0;
      g.ratePaise = rate ?? 0;
      g.amountPaise = amount ?? taxable ?? 0;
      g.consistent = false;
      return g;
    }
    g.qtyCenti = qty;
    g.ratePaise = rate;
    final gross = _mulCenti(qty, rate);
    if (discPct != null) {
      g.discountPaise = (gross * discPct / 10000).round();
    } else {
      g.discountPaise = disc ?? 0;
    }
    final net = gross - g.discountPaise;
    g.amountPaise = amount ?? taxable ?? net;
    final tol = _tol(g.amountPaise);
    final target = taxable ?? amount;
    if (target != null && (net - target).abs() <= tol) {
      g.consistent = true;
    } else if (amount != null && g.gstBp > 0 &&
        (net + (net * g.gstBp / 10000).round() - amount).abs() <= tol) {
      g.consistent = true;
    } else if (amount != null && g.discountPaise == 0) {
      // Discount column may hold an amount we mis-read; try deriving it.
      final diff = gross - amount;
      g.consistent = false;
      if (diff > 0 && disc == null && discPct == null && diff < gross ~/ 2) {
        // Leave as inconsistent; arithmetic search will try alternatives.
      }
    }
    return g;
  }

  _Col? _nearest(_Tok t, List<_Col> cols) {
    _Col? best;
    double bestD = double.infinity;
    for (final c in cols) {
      final overlap = (t.x1 < c.x1 ? t.x1 : c.x1) - (t.x0 > c.x0 ? t.x0 : c.x0);
      double d;
      if (overlap > 0) {
        d = -overlap;
      } else {
        final dl = (t.x0 - c.x0).abs();
        final dr = (t.x1 - c.x1).abs();
        final dc = ((t.x0 + t.x1) / 2 - (c.x0 + c.x1) / 2).abs();
        d = [dl, dr, dc].reduce((a, b) => a < b ? a : b);
      }
      if (d < bestD) {
        bestD = d;
        best = c;
      }
    }
    return best;
  }

  /// Row tolerance: ₹1.50 or 0.3 % (rates printed with 2 decimals).
  static int _tol(int amountPaise) {
    final pct = (amountPaise.abs() * 0.003).round();
    return pct > 150 ? pct : 150;
  }

  /// Bill-total tolerance: ₹2 or 0.02 % (round-off is handled separately).
  static int _tolTotal(int amountPaise) {
    final pct = (amountPaise.abs() * 0.0002).round();
    return pct > 200 ? pct : 200;
  }

  /// Tries every (qty, rate) pair of the row's numbers to find the one that
  /// explains the amount.
  _RowGuess? _readByArithmetic(List<_Tok> toks, _Tok? knownHsn) {
    final nums = <_Tok>[];
    final pcts = <_Tok>[];
    String unit = '';
    for (final t in toks) {
      if (t.kind == _K.num) nums.add(t);
      if (t.kind == _K.pct) pcts.add(t);
      if (t.kind == _K.unit && unit.isEmpty) unit = t.raw;
    }
    if (nums.isEmpty) return null;

    // Description = text tokens (and numbers glued between them) before the
    // first number that starts the numeric tail.
    // The numeric tail starts after the last text token.
    var lastTextIdx = -1;
    for (var i = 0; i < toks.length; i++) {
      if (toks[i].kind == _K.text) lastTextIdx = i;
    }
    final tail = <_Tok>[];
    final descTok = <_Tok>[];
    for (var i = 0; i < toks.length; i++) {
      final t = toks[i];
      if (i <= lastTextIdx) {
        descTok.add(t);
      } else if (t.kind == _K.num) {
        tail.add(t);
      }
    }
    // Leading serial number is not part of the description.
    if (descTok.isNotEmpty &&
        descTok.first.kind == _K.num &&
        RegExp(r'^\d{1,3}\.?$').hasMatch(descTok.first.raw)) {
      descTok.removeAt(0);
    }
    final description = descTok.map((t) => t.raw).join(' ');

    // HSN: the known HSN token, or a 4/6/8-digit integer at the start of the
    // numeric tail. If the maths fails we retry treating it as a quantity.
    _Tok? hsnTok = knownHsn;
    if (hsnTok == null &&
        tail.isNotEmpty &&
        RegExp(r'^\d{4}$|^\d{6}$|^\d{8}$').hasMatch(tail.first.raw)) {
      hsnTok = tail.first;
    }
    final withoutHsn =
        tail.where((t) => hsnTok == null || !identical(t, hsnTok)).toList();

    int gstBp = -1;
    int? discPct;
    for (final p in pcts) {
      if (kGstSlabsBp.contains(p.value) && p.value > 0) {
        gstBp = gstBp < 0 ? p.value : gstBp + p.value;
      } else if (const [150, 250, 600, 900, 1400].contains(p.value)) {
        // CGST + SGST halves
        gstBp = gstBp < 0 ? p.value : gstBp + p.value;
      } else {
        discPct ??= p.value;
      }
    }
    if (gstBp > 2800) gstBp = -1;

    final variants = <List<dynamic>>[
      [withoutHsn, hsnTok, gstBp, discPct],
      if (pcts.length == 1 && gstBp > 0) [withoutHsn, hsnTok, -1, pcts.first.value],
      if (hsnTok != null && !identical(hsnTok, knownHsn))
        [tail, null, gstBp, discPct],
    ];
    _RowGuess? fallback;
    for (final v in variants) {
      final work = v[0] as List<_Tok>;
      if (work.isEmpty) continue;
      final h = v[1] as _Tok?;
      final r = _solve(description, unit, h?.raw ?? '', h, work, v[2] as int,
          v[3] as int?);
      if (r.consistent) return r;
      fallback ??= r;
    }
    return fallback;
  }

  _RowGuess _solve(String description, String unit, String hsn, _Tok? hsnTok,
      List<_Tok> work, int gstBp, int? discPct) {
    final amount = work.last.value;
    final g = _RowGuess()
      ..description = description
      ..unit = unit
      ..hsn = hsn
      ..hsnTok = hsnTok
      ..gstBp = gstBp;

    if (work.length == 1) {
      g
        ..qtyCenti = 100
        ..ratePaise = amount
        ..amountPaise = amount
        ..consistent = false;
      return g;
    }

    final tol = _tol(amount);
    _RowGuess? best;
    var bestScore = -1;
    final slabs = gstBp >= 0 ? [gstBp] : _inferSlabsBp;
    for (var i = 0; i < work.length - 1; i++) {
      for (var j = 0; j < work.length - 1; j++) {
        if (i == j) continue;
        final q = work[i].value;
        final r = work[j].value;
        if (q <= 0 || r <= 0) continue;
        // qty should look like a quantity
        final qWhole = q % 100 == 0;
        if (q > 100000 * 100) continue;
        final gross = _mulCenti(q, r);
        final disc = discPct != null ? (gross * discPct / 10000).round() : 0;
        final net = gross - disc;
        // Targets: final amount, or another number (taxable) between.
        final targets = <int, int>{work.length - 1: amount};
        for (var k = 0; k < work.length - 1; k++) {
          if (k != i && k != j) targets[k] = work[k].value;
        }
        for (final e in targets.entries) {
          final t = e.value;
          int? usedGst;
          int? discAmt;
          var ok = (net - t).abs() <= tol;
          if (!ok) {
            for (final s in slabs) {
              if (s == 0) continue;
              final withTax = net + (net * s / 10000).round();
              if ((withTax - t).abs() <= tol) {
                ok = true;
                usedGst = s;
                break;
              }
            }
          }
          if (!ok && discPct == null) {
            // A discount amount column between rate and amount.
            for (var k = 0; k < work.length - 1; k++) {
              if (k == i || k == j || k == e.key) continue;
              if ((gross - work[k].value - t).abs() <= tol) {
                ok = true;
                discAmt = work[k].value;
                break;
              }
            }
          }
          if (!ok) continue;
          var score = 10;
          if (i < j) score += 3; // qty before rate (usual order)
          if (qWhole) score += 4;
          if (q <= 1000 * 100) score += 2;
          if (e.key == work.length - 1) score += 2; // explains final amount
          if (r > q) score += 1;
          if (usedGst != null && gstBp < 0) score -= 1;
          if (score > bestScore) {
            bestScore = score;
            best = _RowGuess()
              ..description = g.description
              ..unit = unit
              ..hsn = hsn
              ..hsnTok = hsnTok
              ..qtyCenti = q
              ..ratePaise = r
              ..discountPaise = discAmt ?? disc
              ..gstBp = usedGst ?? gstBp
              ..amountPaise = amount
              ..consistent = true;
          }
        }
      }
    }
    if (best != null) {
      // Numbers before qty that were left in the tail belong to the name
      // (e.g. "iPhone 15" when 15 was parsed as a number).
      return best;
    }
    // Nothing adds up: assume "... qty rate amount".
    final n = work.length;
    g
      ..qtyCenti = n >= 3 ? work[n - 3].value : 100
      ..ratePaise = work[n - 2].value
      ..amountPaise = amount
      ..consistent = false;
    return g;
  }

  // ===========================================================================
  // Totals
  // ===========================================================================

  void _extractTotals(List<LayoutLine> lines, int from, ExtractedBill bill) {
    int? grand;
    int grandPriority = -1;
    var taxSeen = false;
    final start = from < 0 ? 0 : from;
    for (var i = start; i < lines.length; i++) {
      final text = lines[i].text;
      final lower = text.toLowerCase();
      final amounts = <int>[];
      for (final w in lines[i].words) {
        if (_numTokRe.hasMatch(w.text) && w.text.contains(RegExp(r'[.,]'))) {
          final v = parsePaise(w.text);
          if (v != null) amounts.add(v);
        } else if (_numTokRe.hasMatch(w.text)) {
          final v = parsePaise(w.text);
          if (v != null && v >= 10000) amounts.add(v); // ≥ ₹100 integers
        }
      }
      const pre = r'^\s*(\d{1,3}\s+)?((output|add|less|input)\s*:?\s*)?';
      if (RegExp('$pre(cgst|central\\s*tax)', caseSensitive: false)
              .hasMatch(text) &&
          amounts.isNotEmpty) {
        if (!taxSeen && bill.cgstPaise == 0) bill.cgstPaise = amounts.last;
        continue;
      }
      if (RegExp('$pre(sgst|utgst|state\\s*tax)', caseSensitive: false)
              .hasMatch(text) &&
          amounts.isNotEmpty) {
        if (!taxSeen && bill.sgstPaise == 0) bill.sgstPaise = amounts.last;
        continue;
      }
      if (RegExp('$pre(igst|integrated\\s*tax)', caseSensitive: false)
              .hasMatch(text) &&
          amounts.isNotEmpty) {
        if (!taxSeen && bill.igstPaise == 0) bill.igstPaise = amounts.last;
        continue;
      }
      if (RegExp(
              r'^\s*(\d{1,3}\s+)?(add\s*:?\s*)?(freight|packing|forwarding|'
              r'courier|transport(ation)?|delivery|shipping|handling|'
              r'insurance|loading)\b',
              caseSensitive: false)
          .hasMatch(text)) {
        if (amounts.isNotEmpty) bill.otherChargesPaise += amounts.last;
        continue;
      }
      if (RegExp(
              r'^\s*(less\s*:?\s*|add\s*:?\s*)?'
              r'(round(ed|ing)?(\s*-?\s*off)?|r/?off)\b',
              caseSensitive: false)
          .hasMatch(lower)) {
        final m = RegExp(r'(\(-\)|-|\+)?\s*(\d+\.\d{1,2})').allMatches(text);
        if (m.isNotEmpty) {
          final last = m.last;
          final v = parsePaise(last.group(2)!) ?? 0;
          bill.roundOffPaise =
              (last.group(1) == '-' || last.group(1) == '(-)') ? -v : v;
        }
        continue;
      }
      if (RegExp(r'hsn/?sac|taxable\s*value', caseSensitive: false)
              .hasMatch(lower) &&
          grand != null) {
        taxSeen = true; // tax summary table — don't double count
      }
      if (amounts.isEmpty) continue;
      if (RegExp(r'in\s*words|taxable|tax\s*amount|quantity|total\s*qty',
              caseSensitive: false)
          .hasMatch(lower)) {
        continue;
      }
      int pr = -1;
      if (RegExp(r'grand\s*total|invoice\s*(total|value|amount)|'
              r'net\s*(payable|amount|total)|amount\s*payable|bill\s*amount|'
              r'total\s*amount|total\s*invoice',
              caseSensitive: false)
          .hasMatch(lower)) {
        pr = 3;
      } else if (RegExp(r'^\s*total\b|\btotal\s*[:₹]|\btotal$',
              caseSensitive: false)
          .hasMatch(lower)) {
        pr = 2;
      }
      if (pr < 0) continue;
      final v = amounts.reduce((a, b) => a > b ? a : b);
      if (pr > grandPriority || (pr == grandPriority && v > (grand ?? 0))) {
        grand = v;
        grandPriority = pr;
      }
    }
    bill.grandTotalPaise = grand;
  }

  // ===========================================================================
  // Bill-level reconciliation
  // ===========================================================================

  void _finalise(ExtractedBill bill) {
    if (bill.lines.isEmpty) {
      bill.warnings.add('No item rows found. Add items manually. '
          '(ഐറ്റങ്ങൾ കണ്ടെത്താനായില്ല, കൈകൊണ്ട് ചേർക്കുക)');
      return;
    }
    final sumAmount = bill.lines.fold<int>(0, (s, l) => s + l.amountPaise);
    final sumTaxable = bill.lines.fold<int>(0, (s, l) => s + l.taxablePaise);
    final billTax = bill.taxTotalPaise;
    final grand = bill.grandTotalPaise;
    final tol = _tolTotal(grand ?? sumAmount);

    // 1. Rates inclusive of GST? (amounts already add up to the grand total
    //    and the bill shows tax, or the row amount ≈ qty × rate yet GST > 0)
    final anyGst = bill.lines.any((l) => l.gstBp > 0) || billTax > 0;
    if (grand != null && anyGst) {
      final exclusiveTotal = sumTaxable + (billTax > 0 ? billTax : _rowTax(bill));
      final inclusiveTotal = sumTaxable;
      final dEx = (exclusiveTotal + bill.roundOffPaise - grand).abs();
      final dIn = (inclusiveTotal + bill.roundOffPaise - grand).abs();
      if (dIn <= tol && dEx > tol) bill.ratesIncludedGst = true;
    }

    // 2. Fill missing GST % from row maths or bill-level tax.
    for (final l in bill.lines) {
      if (l.gstBp >= 0) continue;
      final net = l.taxablePaise;
      if (net > 0 && l.amountPaise > net + _tol(l.amountPaise)) {
        for (final s in _inferSlabsBp) {
          if (s == 0) continue;
          if ((net + (net * s / 10000).round() - l.amountPaise).abs() <=
              _tol(l.amountPaise)) {
            l.gstBp = s;
            break;
          }
        }
      }
    }
    if (billTax > 0 && bill.lines.any((l) => l.gstBp < 0)) {
      final base = bill.ratesIncludedGst ? sumTaxable - billTax : sumTaxable;
      if (base > 0) {
        final bp = (billTax * 10000 / base).round();
        int? slab;
        for (final s in kGstSlabsBp) {
          if ((s - bp).abs() <= 30) slab = s;
        }
        if (slab != null) {
          for (final l in bill.lines) {
            if (l.gstBp < 0) l.gstBp = slab;
          }
        } else {
          bill.warnings.add('Bill has items with different GST rates; '
              'check GST % on each line. (ഓരോ ലൈനിലെയും GST % പരിശോധിക്കുക)');
        }
      }
    }

    // 3. Convert inclusive rates to exclusive (the purchase engine adds GST).
    if (bill.ratesIncludedGst) {
      for (final l in bill.lines) {
        final g = l.gstBpOrZero;
        if (g == 0) continue;
        l.ratePaise = (l.ratePaise * 10000 / (10000 + g)).round();
        l.discountPaise = (l.discountPaise * 10000 / (10000 + g)).round();
      }
    }

    // 4. Per-line sanity.
    for (var i = 0; i < bill.lines.length; i++) {
      final l = bill.lines[i];
      if (!l.consistent) {
        bill.warnings.add('Line ${i + 1} "${_short(l.description)}": qty × rate '
            'does not match amount — please check. (തുക പരിശോധിക്കുക)');
      }
      if (l.hasFractionalQty) {
        bill.warnings.add('Line ${i + 1}: quantity ${l.qtyCenti / 100} is not '
            'a whole number; it will be rounded. (അളവ് റൗണ്ട് ചെയ്യും)');
      }
    }

    // 5. Compare with printed total.
    final diff = bill.totalDifferencePaise;
    if (diff != null && diff.abs() > tol) {
      // A positive leftover is often freight / packing charged on the bill.
      bill.warnings.add('Bill total ₹${(grand! / 100).toStringAsFixed(2)} '
          'differs from items total by ₹${(diff / 100).toStringAsFixed(2)}. '
          'Check items or add other charges. '
          '(ബിൽ ടോട്ടലും ഐറ്റം ടോട്ടലും തമ്മിൽ വ്യത്യാസം)');
    }
    if (bill.billNumber == null) {
      bill.warnings.add('Bill number not found. (ബിൽ നമ്പർ കണ്ടെത്തിയില്ല)');
    }
    if (bill.billDate == null) {
      bill.warnings.add('Bill date not found. (ബിൽ തീയതി കണ്ടെത്തിയില്ല)');
    }
  }

  static int _rowTax(ExtractedBill bill) =>
      bill.lines.fold<int>(0, (s, l) => s + l.taxPaise);

  static String _short(String s) => s.length > 28 ? '${s.substring(0, 28)}…' : s;
}

/// qty (hundredths) × rate (paise) → paise, rounded.
int _mulCenti(int qtyCenti, int ratePaise) => (qtyCenti * ratePaise + 50) ~/ 100;

class _TableInfo {
  final int headerIndex;
  final int endIndex;
  _TableInfo(this.headerIndex, this.endIndex);
}

class _Col {
  final String role;
  double x0;
  double x1;
  String label;
  _Col(this.role, this.x0, this.x1, this.label);
  @override
  String toString() => '$role[$x0-$x1]';
}

enum _K { text, num, pct, unit }

class _Tok {
  final _K kind;
  final String raw;
  final int value; // paise / centi for numbers and percents
  final double x0;
  final double x1;
  _Tok(this.kind, this.raw, this.value, this.x0, this.x1);

  factory _Tok.text(String r, double a, double b) => _Tok(_K.text, r, 0, a, b);
  factory _Tok.unit(String r, double a, double b) => _Tok(_K.unit, r, 0, a, b);
  factory _Tok.percent(String r, int v, double a, double b) =>
      _Tok(_K.pct, r, v, a, b);
  factory _Tok.number(String r, double a, double b) {
    final v = VendorBillParser.parsePaise(r.replaceAll(RegExp(r'[()]'), ''));
    if (v == null) return _Tok(_K.text, r, 0, a, b);
    return _Tok(_K.num, r, v, a, b);
  }
}

class _RowGuess {
  String description = '';
  String hsn = '';
  _Tok? hsnTok;
  String unit = '';
  int qtyCenti = 0;
  int ratePaise = 0;
  int discountPaise = 0;
  int gstBp = -1;
  int mrpPaise = 0;
  int amountPaise = 0;
  bool consistent = false;
}
