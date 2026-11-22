// =============================================================================
// TEKFIX ERP — Import vendor bill (PDF / photo) → review → purchase entry
//
// Step 1  Pick the vendor's PDF (or a photo on Windows).
// Step 2  Review what was read: vendor, bill no, date, every line linked to a
//         stock item, suggested, or NEW (one tap to register it, pre-filled).
// Step 3  Continue to the normal Purchase Entry screen, which saves through the
//         same path as a manual bill (stock, vendor ledger, payments).
// =============================================================================

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../ui/dashboard/dashboard_tokens.dart';
import '../../ui/tek_feedback.dart';
import '../manual_purchase_entry_screen.dart';
import '../purchase_bill_service.dart';
import '../purchase_models.dart';
import '../quick_register_drawer.dart';
import '../supplier_search_sheet.dart';
import 'bill_item_matcher.dart';
import 'bill_import_service.dart';
import 'vendor_bill_parser.dart';

/// Everything the Purchase Entry screen needs to pre-fill itself.
class ImportedPurchaseBill {
  final dynamic vendorKey;
  final String vendorName;
  final String vendorPhone;
  final String vendorGst;
  final String vendorAddress;
  final String invoiceNumber;
  final DateTime? invoiceDate;
  final int? printedTotalPaise;
  final int otherChargesPaise;
  final BillAttachment? attachment;
  final Uint8List? attachmentBytes;
  final List<PurchaseBillItem> items;
  final bool gstEnabled;
  final String sourceNote;

  const ImportedPurchaseBill({
    this.vendorKey,
    this.vendorName = '',
    this.vendorPhone = '',
    this.vendorGst = '',
    this.vendorAddress = '',
    this.invoiceNumber = '',
    this.invoiceDate,
    this.printedTotalPaise,
    this.otherChargesPaise = 0,
    this.attachment,
    this.attachmentBytes,
    this.items = const [],
    this.gstEnabled = false,
    this.sourceNote = '',
  });
}

/// Builds the purchase line handed to Purchase Entry. Pure (tested).
PurchaseBillItem buildPurchaseItemFromLine({
  required String rowId,
  required String description,
  required String hsn,
  required int qty,
  required int ratePaise,
  required int discountPaise,
  required double gstPercent,
  required int mrpPaise,
  required List<String> serials,
  CatalogItem? linked,
}) {
  final rate = ratePaise / 100.0;
  final disc = discountPaise / 100.0;
  final taxable = (qty * ratePaise - discountPaise).clamp(0, 1 << 52);
  final taxPaise = (taxable * gstPercent / 100).round();
  final mrp = mrpPaise > 0
      ? mrpPaise / 100.0
      : (linked != null ? linked.mrpPaise / 100.0 : 0.0);
  final sp = linked != null && linked.sellingPricePaise > 0
      ? linked.sellingPricePaise / 100.0
      : mrp;
  return PurchaseBillItem(
    id: rowId,
    itemKey: linked?.key,
    itemId: linked?.id,
    name: linked?.name ?? description,
    brand: linked?.brand ?? '',
    model: linked?.model ?? '',
    category: linked?.category ?? '',
    sku: linked != null
        ? (linked.sku.isNotEmpty ? linked.sku : linked.barcode)
        : '',
    hsnCode: hsn.isNotEmpty ? hsn : (linked?.hsn ?? ''),
    quantity: qty,
    purchaseRate: rate,
    mrp: mrp,
    sellingPrice: sp,
    discount: disc,
    taxPercent: gstPercent,
    taxAmount: taxPaise / 100.0,
    lineTotal: (taxable + taxPaise) / 100.0,
    serialNumbers: serials,
    imeiRequired: linked?.imeiRequired ?? false,
    warrantyDuration: (linked != null && linked.warranty.isNotEmpty)
        ? linked.warranty
        : ItemWarrantyDuration.noWarranty,
    matchedProductId: linked?.id,
    matchedProductName: linked?.name,
    isNewProduct: linked == null,
    isStagedReady: true,
    matchStatusOverride: linked != null
        ? ProductMatchStatus.matched
        : ProductMatchStatus.quickRegister,
    matchNotes: linked != null && linked.name != description
        ? 'Bill: $description'
        : null,
  );
}

class BillImportScreen extends StatefulWidget {
  /// true = pop with an [ImportedPurchaseBill] (called from Purchase Entry);
  /// false = open Purchase Entry pre-filled when the owner continues.
  final bool returnResult;

  /// Optional file to read immediately (tests, "open with" in future).
  final Uint8List? initialBytes;
  final String? initialFileName;

  const BillImportScreen({
    super.key,
    this.returnResult = false,
    this.initialBytes,
    this.initialFileName,
  });

  @override
  State<BillImportScreen> createState() => _BillImportScreenState();
}

class _ReviewLine {
  final String rowId;
  final TextEditingController name;
  final TextEditingController hsn;
  final TextEditingController qty;
  final TextEditingController unit;
  final TextEditingController rate;
  final TextEditingController gst;
  final TextEditingController disc;
  final int mrpPaise;
  final List<String> serials;
  final bool consistent;
  MatchResult match;
  CatalogItem? linked;
  bool suggestionPending;

  _ReviewLine({
    required this.rowId,
    required ExtractedBillLine src,
    required this.match,
  })  : name = TextEditingController(text: src.description),
        hsn = TextEditingController(text: src.hsn),
        qty = TextEditingController(
            text: src.hasFractionalQty
                ? (src.qtyCenti / 100).toString()
                : '${src.quantity}'),
        unit = TextEditingController(text: src.unit),
        rate = TextEditingController(text: _rupees(src.ratePaise)),
        gst = TextEditingController(
            text: src.gstBp < 0 ? '0' : _trimZeros(src.gstBp / 100)),
        disc = TextEditingController(
            text: src.discountPaise > 0 ? _rupees(src.discountPaise) : ''),
        mrpPaise = src.mrpPaise,
        serials = List<String>.from(src.serials),
        consistent = src.consistent,
        linked = match.level == MatchLevel.matched ? match.best?.item : null,
        suggestionPending = match.level == MatchLevel.suggested;

  int get qtyInt {
    final v = double.tryParse(qty.text.trim()) ?? 0;
    return v.round();
  }

  int get ratePaise => VendorBillParser.parsePaise(rate.text) ?? 0;
  int get discountPaise => VendorBillParser.parsePaise(disc.text) ?? 0;
  double get gstPercent => double.tryParse(gst.text.trim()) ?? 0;
  int get totalPaise {
    final taxable = qtyInt * ratePaise - discountPaise;
    return taxable + (taxable * gstPercent / 100).round();
  }

  bool get isNew => linked == null && !suggestionPending;

  void dispose() {
    for (final c in [name, hsn, qty, unit, rate, gst, disc]) {
      c.dispose();
    }
  }

  static String _rupees(int paise) => (paise / 100).toStringAsFixed(2);
  static String _trimZeros(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
}

class _BillImportScreenState extends State<BillImportScreen> {
  final _money = NumberFormat.currency(locale: 'en_IN', symbol: '₹');
  final _billNoCtrl = TextEditingController();

  bool _busy = false;
  String? _error;
  String? _fileName;
  Uint8List? _bytes;
  ExtractedBill? _bill;
  BillItemMatcher? _matcher;
  final List<_ReviewLine> _lines = [];
  DateTime? _billDate;
  bool _showRaw = false;

  @override
  void initState() {
    super.initState();
    final b = widget.initialBytes;
    if (b != null) {
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => _read(b, widget.initialFileName ?? 'bill.pdf'));
    }
  }

  // Vendor
  Map<String, dynamic>? _vendor; // existing supplier
  String _vName = '';
  String _vPhone = '';
  String _vGst = '';
  String _vAddress = '';

  @override
  void dispose() {
    _billNoCtrl.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Step 1: pick & read
  // ---------------------------------------------------------------------------

  Future<void> _pick() async {
    final exts = ['pdf'];
    if (!kIsWeb && Platform.isWindows) {
      exts.addAll(['jpg', 'jpeg', 'png', 'bmp', 'tif', 'tiff']);
    }
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: exts,
      withData: true,
    );
    if (res == null || res.files.isEmpty) return;
    final f = res.files.first;
    var bytes = f.bytes;
    if (bytes == null && f.path != null) {
      bytes = await File(f.path!).readAsBytes();
    }
    if (bytes == null) {
      TekFeedback.error('Could not read the file (ഫയൽ വായിക്കാനായില്ല)');
      return;
    }
    await _read(bytes, f.name);
  }

  Future<void> _read(Uint8List bytes, String name) async {
    setState(() {
      _busy = true;
      _error = null;
      _fileName = name;
      _bytes = bytes;
    });
    try {
      final bill = await BillImportService.instance.readBill(bytes, name);
      final matcher = BillImportService.instance.buildMatcher();
      for (final l in _lines) {
        l.dispose();
      }
      _lines.clear();
      final ts = DateTime.now().microsecondsSinceEpoch;
      for (var i = 0; i < bill.lines.length; i++) {
        final src = bill.lines[i];
        _lines.add(_ReviewLine(
          rowId: 'IMP_${ts}_$i',
          src: src,
          match: matcher.match(src.description, hsn: src.hsn),
        ));
      }
      final vendor = BillImportService.instance.matchVendor(bill);
      setState(() {
        _bill = bill;
        _matcher = matcher;
        _billNoCtrl.text = bill.billNumber ?? '';
        _billDate = bill.billDate;
        _applyVendor(vendor, bill);
      });
      if (bill.lines.isEmpty) {
        TekFeedback.toast('No items found — check the bill text below. '
            '(ഐറ്റങ്ങൾ കണ്ടെത്തിയില്ല)');
      } else {
        TekFeedback.success('Read ${bill.lines.length} items '
            '(${bill.lines.length} ഐറ്റങ്ങൾ വായിച്ചു)');
      }
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _applyVendor(Map<String, dynamic>? v, ExtractedBill bill) {
    _vendor = v;
    if (v != null) {
      _vName = '${v['name'] ?? ''}';
      _vPhone = '${v['phone'] ?? ''}';
      _vGst = '${v['gst'] ?? ''}';
      _vAddress = '${v['address'] ?? ''}';
      if (_vGst.isEmpty) _vGst = bill.vendorGstin ?? '';
    } else {
      _vName = bill.vendorName ?? '';
      _vPhone = bill.vendorPhone ?? '';
      _vGst = bill.vendorGstin ?? '';
      _vAddress = bill.vendorAddress ?? '';
    }
  }

  // ---------------------------------------------------------------------------
  // Vendor actions
  // ---------------------------------------------------------------------------

  Future<void> _chooseVendor() async {
    final r = await SupplierSearchSheet.show(context);
    if (r == null || !mounted) return;
    setState(() => _applyVendor(r, _bill ?? ExtractedBill()));
  }

  Future<void> _addVendor() async {
    final name = TextEditingController(text: _vName);
    final phone = TextEditingController(text: _vPhone);
    final gst = TextEditingController(text: _vGst);
    final addr = TextEditingController(text: _vAddress);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF101846),
        title: const Text('Add vendor (വെണ്ടർ ചേർക്കുക)',
            style: TextStyle(color: Colors.white)),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _dialogField(name, 'Vendor name (വെണ്ടറുടെ പേര്)'),
            _dialogField(phone, 'Phone (ഫോൺ)', keyboard: TextInputType.phone),
            _dialogField(gst, 'GSTIN'),
            _dialogField(addr, 'Address (വിലാസം)'),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel (റദ്ദാക്കുക)')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save (സേവ്)')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final v = await PurchaseBillService.instance.addNewVendor(
        name: name.text,
        phone: phone.text,
        gst: gst.text,
        address: addr.text,
      );
      if (!mounted) return;
      setState(() => _applyVendor(v, _bill ?? ExtractedBill()));
      TekFeedback.success('Vendor added (വെണ്ടർ ചേർത്തു)');
    } catch (e) {
      TekFeedback.error(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      name.dispose();
      phone.dispose();
      gst.dispose();
      addr.dispose();
    }
  }

  Widget _dialogField(TextEditingController c, String label,
      {TextInputType? keyboard}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: c,
        keyboardType: keyboard,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: DashboardColors.textMuted),
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Line actions
  // ---------------------------------------------------------------------------

  /// A handset (needs IMEI) — not an accessory that mentions a phone model.
  static bool _looksLikePhone(String s) =>
      !looksLikeAccessoryName(s) &&
      RegExp(r'\b(iphone|galaxy|redmi|realme|oppo|vivo|oneplus|pixel|nokia|'
              r'poco|iqoo|moto|tecno|infinix|itel|lava|smartphone)\b',
              caseSensitive: false)
          .hasMatch(s);

  Future<void> _addAsNew(_ReviewLine l) async {
    final mrp = l.mrpPaise / 100.0;
    final r = await QuickRegisterDrawer.show(
      context,
      prefillName: l.name.text.trim(),
      prefillHsn: l.hsn.text.trim(),
      prefillGstRate: l.gstPercent,
      prefillMrp: mrp,
      prefillSellingPrice: mrp,
      prefillUnit: _unitForDrawer(l.unit.text),
      prefillTrackImei: _looksLikePhone(l.name.text) || l.serials.isNotEmpty,
      prefillCategory:
          _looksLikePhone(l.name.text) ? 'Mobile Phones' : '',
    );
    if (r == null || !mounted) return;
    final item = CatalogItem.fromMap(r['key'], r);
    setState(() {
      l.linked = item;
      l.suggestionPending = false;
    });
  }

  static String _unitForDrawer(String u) {
    const known = {
      'Piece', 'Box', 'Bundle', 'Pair', 'Set', 'Kg', 'Gram', 'Litre', 'Metre'
    };
    return known.contains(u) ? u : 'Piece';
  }

  Future<void> _addAllNew() async {
    final pending = _lines.where((l) => l.isNew).toList();
    for (final l in pending) {
      if (!mounted) return;
      final before = l.linked;
      await _addAsNew(l);
      if (l.linked == before) break; // owner closed the drawer → stop
    }
  }

  Future<void> _linkExisting(_ReviewLine l) async {
    final picked = await showModalBottomSheet<CatalogItem>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0B1030),
      builder: (_) => _ItemPickerSheet(
        matcher: _matcher!,
        initialQuery: l.name.text,
        hsn: l.hsn.text,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      l.linked = picked;
      l.suggestionPending = false;
    });
  }

  // ---------------------------------------------------------------------------
  // Step 3: continue
  // ---------------------------------------------------------------------------

  Future<void> _continue() async {
    final active = _lines;
    if (active.isEmpty) {
      TekFeedback.error('No items to add (ഐറ്റങ്ങൾ ഇല്ല)');
      return;
    }
    final bad = active.where((l) => l.qtyInt <= 0 || l.ratePaise <= 0).length;
    if (bad > 0) {
      TekFeedback.error('$bad line(s) have zero qty or rate. Fix or remove '
          'them. (അളവ്/വില 0 ആയ ലൈനുകൾ ശരിയാക്കുക)');
      return;
    }
    final pendingSuggest = active.where((l) => l.suggestionPending).toList();
    if (pendingSuggest.isNotEmpty) {
      final accept = await _ask(
        'Accept suggested matches? (നിർദ്ദേശിച്ചവ സ്വീകരിക്കണോ?)',
        '${pendingSuggest.length} line(s) have a suggested stock item that '
            'you have not confirmed.\n\nAccept = link them to the suggestion.\n'
            'Review = go back and check each one.',
        yes: 'Accept (സ്വീകരിക്കുക)',
        no: 'Review (പരിശോധിക്കാം)',
      );
      if (accept != true) return;
      setState(() {
        for (final l in pendingSuggest) {
          l.linked = l.match.best?.item;
          l.suggestionPending = false;
        }
      });
    }
    final newCount = active.where((l) => l.linked == null).length;
    if (newCount > 0) {
      final go = await _ask(
        'New items (പുതിയ ഐറ്റങ്ങൾ)',
        '$newCount line(s) are not in your stock list yet.\n\n'
            'Tip: "Add as new item" first so GST, unit and selling price are '
            'saved with the item. If you continue, they will be created '
            'automatically with the bill name and rate only.\n'
            '(ആദ്യം "പുതിയ ഐറ്റം ചേർക്കുക" ഉപയോഗിക്കുന്നതാണ് നല്ലത്)',
        yes: 'Continue anyway (തുടരുക)',
        no: 'Go back (തിരികെ)',
      );
      if (go != true) return;
    }

    // Remember vendor wording → item for next time.
    final aliases = <String, dynamic>{};
    for (final l in active) {
      final item = l.linked;
      if (item == null) continue;
      final norm = BillItemMatcher.normalize(l.name.text);
      if (norm.isNotEmpty && norm != BillItemMatcher.normalize(item.name)) {
        aliases[norm] = item.key;
      }
    }
    try {
      await BillImportService.instance.rememberAliases(aliases);
    } catch (e) {
      debugPrint('[BillImport] alias save failed: $e');
    }

    final items = <PurchaseBillItem>[
      for (final l in active)
        buildPurchaseItemFromLine(
          rowId: l.rowId,
          description: l.name.text.trim(),
          hsn: l.hsn.text.trim(),
          qty: l.qtyInt,
          ratePaise: l.ratePaise,
          discountPaise: l.discountPaise,
          gstPercent: l.gstPercent,
          mrpPaise: l.mrpPaise,
          serials: l.serials,
          linked: l.linked,
        ),
    ];
    final bytes = _bytes;
    final name = _fileName ?? 'bill.pdf';
    final lower = name.toLowerCase();
    final mime = lower.endsWith('.pdf')
        ? 'application/pdf'
        : 'image/${lower.split('.').last.replaceAll('jpg', 'jpeg')}';
    final result = ImportedPurchaseBill(
      vendorKey: _vendor?['key'],
      vendorName: _vName,
      vendorPhone: _vPhone,
      vendorGst: _vGst,
      vendorAddress: _vAddress,
      invoiceNumber: _billNoCtrl.text.trim(),
      invoiceDate: _billDate,
      printedTotalPaise: _bill?.grandTotalPaise,
      otherChargesPaise: _bill?.otherChargesPaise ?? 0,
      attachment: bytes == null
          ? null
          : BillAttachment(
              fileName: name,
              fileType: mime,
              fileSizeBytes: bytes.length,
              bytesBase64: base64Encode(bytes),
              uploadedAt: DateTime.now(),
            ),
      attachmentBytes: bytes,
      items: items,
      gstEnabled: items.any((i) => i.taxPercent > 0),
      sourceNote: 'Imported from $name (${_bill?.method ?? ''})',
    );
    if (!mounted) return;
    if (widget.returnResult) {
      Navigator.of(context).pop(result);
    } else {
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => ManualPurchaseEntryScreen(importedBill: result),
      ));
    }
  }

  Future<bool?> _ask(String title, String body,
      {required String yes, required String no}) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF101846),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: Text(body,
            style: const TextStyle(color: DashboardColors.textMuted)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: Text(no)),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true), child: Text(yes)),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF070B24),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B1030),
        foregroundColor: Colors.white,
        title: const Text('Import Vendor Bill (വെണ്ടർ ബിൽ ഇംപോർട്ട്)',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        actions: [
          if (_bill != null)
            MediaQuery.of(context).size.width < 600
                ? IconButton(
                    tooltip: 'Another file (മറ്റൊരു ഫയൽ)',
                    onPressed: _busy ? null : _pick,
                    icon: const Icon(Icons.upload_file_rounded),
                  )
                : TextButton.icon(
                    onPressed: _busy ? null : _pick,
                    icon: const Icon(Icons.upload_file_rounded, size: 18),
                    label: const Text('Another file (മറ്റൊരു ഫയൽ)'),
                  ),
        ],
      ),
      body: _busy
          ? const Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
              CircularProgressIndicator(),
              SizedBox(height: 14),
              Text('Reading bill… (ബിൽ വായിക്കുന്നു…)',
                  style: TextStyle(color: Colors.white70)),
            ]))
          : (_bill == null ? _buildPickStep() : _buildReview()),
      bottomNavigationBar: _bill == null || _busy ? null : _buildBottomBar(),
    );
  }

  Widget _buildPickStep() {
    final win = !kIsWeb && Platform.isWindows;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.picture_as_pdf_rounded,
                size: 72, color: DashboardColors.neonBlue),
            const SizedBox(height: 14),
            const Text(
              'Upload the vendor\'s bill and the items will be filled in for '
              'you.\n(വെണ്ടറുടെ ബിൽ അപ്‌ലോഡ് ചെയ്യൂ — ഐറ്റങ്ങൾ തനിയെ വരും)',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 15),
            ),
            const SizedBox(height: 8),
            Text(
              win
                  ? 'PDF works best. Photos/scans are read with Windows OCR '
                      '(offline). (PDF ആണ് ഏറ്റവും നല്ലത്)'
                  : 'Choose the PDF bill. (PDF ബിൽ തിരഞ്ഞെടുക്കുക)',
              textAlign: TextAlign.center,
              style: const TextStyle(color: DashboardColors.textMuted),
            ),
            const SizedBox(height: 22),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: DashboardColors.neonGreen,
                foregroundColor: Colors.black,
                padding:
                    const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
              ),
              onPressed: _pick,
              icon: const Icon(Icons.upload_file_rounded),
              label: Text(
                win
                    ? 'Choose PDF / Photo (PDF / ഫോട്ടോ തിരഞ്ഞെടുക്കുക)'
                    : 'Choose PDF (PDF തിരഞ്ഞെടുക്കുക)',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 18),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: DashboardColors.alertRed)),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _card({required Widget child}) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF0E1440),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white12),
        ),
        child: child,
      );

  Widget _buildReview() {
    final bill = _bill!;
    final linked = _lines.where((l) => l.linked != null).length;
    final suggested = _lines.where((l) => l.suggestionPending).length;
    final fresh = _lines.where((l) => l.isNew).length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        _buildHeaderCard(bill),
        if (bill.warnings.isNotEmpty)
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final w in bill.warnings)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.warning_amber_rounded,
                              size: 16, color: DashboardColors.neonOrange),
                          const SizedBox(width: 6),
                          Expanded(
                              child: Text(w,
                                  style: const TextStyle(
                                      color: DashboardColors.neonOrange,
                                      fontSize: 12.5))),
                        ]),
                  ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Items (ഐറ്റങ്ങൾ): ${_lines.length}',
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700)),
              _chip('$linked linked (ലിങ്ക്)', DashboardColors.neonGreen),
              if (suggested > 0)
                _chip('$suggested check (പരിശോധിക്കുക)',
                    DashboardColors.neonOrange),
              if (fresh > 0)
                _chip('$fresh new (പുതിയത്)', DashboardColors.alertRed),
              if (fresh > 1)
                TextButton.icon(
                  onPressed: _addAllNew,
                  icon: const Icon(Icons.playlist_add_rounded, size: 18),
                  label: const Text(
                      'Add all new items (എല്ലാ പുതിയതും ചേർക്കുക)'),
                ),
              TextButton.icon(
                onPressed: () => setState(() {
                  _lines.add(_ReviewLine(
                    rowId: 'IMP_${DateTime.now().microsecondsSinceEpoch}',
                    src: ExtractedBillLine(
                        description: '',
                        qtyCenti: 100,
                        ratePaise: 0,
                        amountPaise: 0,
                        gstBp: 0),
                    match: const MatchResult(MatchLevel.none, []),
                  ));
                }),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Add line (ലൈൻ ചേർക്കുക)'),
              ),
            ],
          ),
        ),
        for (var i = 0; i < _lines.length; i++) _buildLineCard(i),
        _buildTotalsCard(bill),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                onTap: () => setState(() => _showRaw = !_showRaw),
                child: Row(children: [
                  Icon(_showRaw ? Icons.expand_less : Icons.expand_more,
                      color: DashboardColors.textMuted),
                  const SizedBox(width: 6),
                  Text(
                      'Text read from the bill (ബില്ലിൽ നിന്ന് വായിച്ചത്) — '
                      '${bill.method}',
                      style: const TextStyle(
                          color: DashboardColors.textMuted, fontSize: 12.5)),
                ]),
              ),
              if (_showRaw)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SelectableText(
                    bill.rawText,
                    style: const TextStyle(
                        color: Colors.white70,
                        fontFamily: 'monospace',
                        fontSize: 11.5),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _chip(String t, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: c.withValues(alpha: 0.6)),
        ),
        child: Text(t,
            style: TextStyle(
                color: c, fontSize: 12, fontWeight: FontWeight.w600)),
      );

  Widget _buildHeaderCard(ExtractedBill bill) {
    final dateText = _billDate == null
        ? 'Pick date (തീയതി)'
        : DateFormat('dd MMM yyyy').format(_billDate!);
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.store_rounded, color: DashboardColors.neonBlue),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _vName.isEmpty
                        ? 'Vendor not found (വെണ്ടർ കണ്ടെത്തിയില്ല)'
                        : _vName,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700),
                  ),
                  Text(
                    [
                      if (_vGst.isNotEmpty) 'GSTIN $_vGst',
                      if (_vPhone.isNotEmpty) _vPhone,
                    ].join('  •  '),
                    style: const TextStyle(
                        color: DashboardColors.textMuted, fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  _vendor != null
                      ? _chip('Existing vendor (നിലവിലുള്ള വെണ്ടർ)',
                          DashboardColors.neonGreen)
                      : _chip('New vendor (പുതിയ വെണ്ടർ)',
                          DashboardColors.neonOrange),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 6, children: [
            OutlinedButton.icon(
              onPressed: _chooseVendor,
              icon: const Icon(Icons.search_rounded, size: 16),
              label: const Text('Choose vendor (വെണ്ടർ തിരഞ്ഞെടുക്കുക)'),
            ),
            if (_vendor == null)
              OutlinedButton.icon(
                onPressed: _addVendor,
                icon: const Icon(Icons.person_add_alt_1_rounded, size: 16),
                label: const Text('Add as new vendor (പുതിയ വെണ്ടർ)'),
              ),
          ]),
          const Divider(color: Colors.white12, height: 22),
          Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 240,
                child: TextField(
                  controller: _billNoCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Vendor bill no. (ബിൽ നമ്പർ)',
                    labelStyle: TextStyle(color: DashboardColors.textMuted),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: _billDate ?? DateTime.now(),
                    firstDate: DateTime(2015),
                    lastDate: DateTime.now().add(const Duration(days: 1)),
                  );
                  if (d != null) setState(() => _billDate = d);
                },
                icon: const Icon(Icons.event_rounded, size: 16),
                label: Text('Bill date (തീയതി): $dateText'),
              ),
              Text(_fileName ?? '',
                  style: const TextStyle(
                      color: DashboardColors.textMuted, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLineCard(int i) {
    final l = _lines[i];
    Color status;
    Widget statusRow;
    if (l.linked != null) {
      status = DashboardColors.neonGreen;
      statusRow = Row(children: [
        const Icon(Icons.link_rounded, size: 16, color: DashboardColors.neonGreen),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'Linked (ലിങ്ക്): ${l.linked!.name}',
            style: const TextStyle(color: DashboardColors.neonGreen, fontSize: 12.5),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        TextButton(
            onPressed: () => _linkExisting(l),
            child: const Text('Change (മാറ്റുക)')),
      ]);
    } else if (l.suggestionPending && l.match.best != null) {
      status = DashboardColors.neonOrange;
      statusRow = Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        children: [
          const Icon(Icons.help_outline_rounded,
              size: 16, color: DashboardColors.neonOrange),
          Text('Is it (ഇതാണോ): ${l.match.best!.item.name}?',
              style: const TextStyle(
                  color: DashboardColors.neonOrange, fontSize: 12.5)),
          TextButton(
            onPressed: () => setState(() {
              l.linked = l.match.best!.item;
              l.suggestionPending = false;
            }),
            child: const Text('Yes (അതെ)'),
          ),
          TextButton(
              onPressed: () => _linkExisting(l),
              child: const Text('Other item (മറ്റൊന്ന്)')),
          TextButton(
              onPressed: () => _addAsNew(l),
              child: const Text('Add as new item (പുതിയ ഐറ്റം ചേർക്കുക)')),
        ],
      );
    } else {
      status = DashboardColors.alertRed;
      statusRow = Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        children: [
          _chip('NEW (പുതിയത്)', DashboardColors.alertRed),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: DashboardColors.neonGreen,
              foregroundColor: Colors.black,
              visualDensity: VisualDensity.compact,
            ),
            onPressed: () => _addAsNew(l),
            icon: const Icon(Icons.add_box_rounded, size: 16),
            label: const Text('Add as new item (പുതിയ ഐറ്റം ചേർക്കുക)'),
          ),
          TextButton(
              onPressed: () => _linkExisting(l),
              child: const Text('Link existing (നിലവിലുള്ളത്)')),
        ],
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0E1440),
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: status, width: 4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text('${i + 1}.',
                style: const TextStyle(color: DashboardColors.textMuted)),
            const SizedBox(width: 8),
            Expanded(
              child: _field(l.name, 'Item name on bill (ബില്ലിലെ പേര്)',
                  onChanged: (_) {}),
            ),
            IconButton(
              tooltip: 'Remove line (ലൈൻ നീക്കുക)',
              icon: const Icon(Icons.delete_outline_rounded,
                  color: DashboardColors.alertRed),
              onPressed: () => setState(() {
                _lines.removeAt(i).dispose();
              }),
            ),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            SizedBox(width: 110, child: _field(l.hsn, 'HSN')),
            SizedBox(
                width: 80,
                child: _field(l.qty, 'Qty (എണ്ണം)', numeric: true)),
            SizedBox(width: 80, child: _field(l.unit, 'Unit (യൂണിറ്റ്)')),
            SizedBox(
                width: 120,
                child: _field(l.rate, 'Rate ₹ (വില)', numeric: true)),
            SizedBox(
                width: 100,
                child: _field(l.disc, 'Disc ₹ (കിഴിവ്)', numeric: true)),
            SizedBox(
                width: 80, child: _field(l.gst, 'GST %', numeric: true)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              child: Text(
                _money.format(l.totalPaise / 100),
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w700),
              ),
            ),
          ]),
          if (!l.consistent)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                  'Check qty/rate — the bill amount did not match. '
                  '(എണ്ണം/വില പരിശോധിക്കുക)',
                  style: TextStyle(
                      color: DashboardColors.neonOrange, fontSize: 12)),
            ),
          if (l.serials.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('IMEI/Serial: ${l.serials.join(', ')}',
                  style: const TextStyle(
                      color: DashboardColors.textMuted, fontSize: 12)),
            ),
          const SizedBox(height: 4),
          statusRow,
        ],
      ),
    );
  }

  Widget _field(TextEditingController c, String label,
      {bool numeric = false, ValueChanged<String>? onChanged}) {
    return TextField(
      controller: c,
      onChanged: (v) {
        onChanged?.call(v);
        setState(() {});
      },
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      inputFormatters: numeric
          ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))]
          : null,
      style: const TextStyle(color: Colors.white, fontSize: 13.5),
      decoration: InputDecoration(
        labelText: label,
        labelStyle:
            const TextStyle(color: DashboardColors.textMuted, fontSize: 12),
        isDense: true,
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _buildTotalsCard(ExtractedBill bill) {
    final items = _lines.fold<int>(0, (s, l) => s + l.totalPaise);
    final other = bill.otherChargesPaise;
    final ours = items + other + bill.roundOffPaise;
    final printed = bill.grandTotalPaise;
    final diff = printed == null ? null : printed - ours;
    final ok = diff != null && diff.abs() <= 200;
    Widget row(String a, String b, {Color? c, bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(
                child: Text(a,
                    style: TextStyle(
                        color: c ?? DashboardColors.textMuted,
                        fontWeight: bold ? FontWeight.w700 : null))),
            Text(b,
                style: TextStyle(
                    color: c ?? Colors.white,
                    fontWeight: bold ? FontWeight.w700 : null)),
          ]),
        );
    return _card(
      child: Column(children: [
        row('Items total incl. GST (ഐറ്റം ടോട്ടൽ)', _money.format(items / 100)),
        if (other != 0)
          row('Other charges on bill (മറ്റ് ചാർജുകൾ)',
              _money.format(other / 100)),
        if (bill.roundOffPaise != 0)
          row('Round off (റൗണ്ട് ഓഫ്)',
              _money.format(bill.roundOffPaise / 100)),
        row('Our total (നമ്മുടെ ടോട്ടൽ)', _money.format(ours / 100),
            bold: true),
        if (printed != null)
          row('Total printed on bill (ബില്ലിലെ ടോട്ടൽ)',
              _money.format(printed / 100),
              bold: true),
        if (diff != null)
          row(
            ok
                ? 'Matches the bill ✓ (ബില്ലുമായി ഒത്തുപോകുന്നു)'
                : 'Difference (വ്യത്യാസം)',
            ok ? '' : _money.format(diff / 100),
            c: ok ? DashboardColors.neonGreen : DashboardColors.alertRed,
          ),
        if (bill.ratesIncludedGst)
          row('Bill rates included GST — converted to rates before GST. '
              '(GST ഉൾപ്പെടെയുള്ള വില മാറ്റി)', '',
              c: DashboardColors.neonBlue),
      ]),
    );
  }

  Widget _buildBottomBar() {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        color: const Color(0xFF0B1030),
        child: Row(children: [
          const Expanded(
            child: Text(
              'Next: payment & save, same as manual entry. '
              '(അടുത്തത്: പേയ്‌മെന്റ് & സേവ്)',
              style: TextStyle(
                  color: DashboardColors.textMuted, fontSize: 12),
              maxLines: 2,
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: DashboardColors.neonGreen,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            ),
            onPressed: _lines.isEmpty ? null : _continue,
            icon: const Icon(Icons.arrow_forward_rounded),
            label: const Text('Continue (തുടരുക)',
                style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ]),
      ),
    );
  }
}

/// Search sheet to link a bill line to an existing stock item.
class _ItemPickerSheet extends StatefulWidget {
  final BillItemMatcher matcher;
  final String initialQuery;
  final String hsn;

  const _ItemPickerSheet({
    required this.matcher,
    required this.initialQuery,
    required this.hsn,
  });

  @override
  State<_ItemPickerSheet> createState() => _ItemPickerSheetState();
}

class _ItemPickerSheetState extends State<_ItemPickerSheet> {
  late final TextEditingController _q =
      TextEditingController(text: widget.initialQuery);

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  List<CatalogItem> _results() {
    final q = _q.text.trim();
    if (q.isEmpty) return widget.matcher.catalog.take(40).toList();
    final lower = q.toLowerCase();
    final contains = widget.matcher.catalog
        .where((c) =>
            c.name.toLowerCase().contains(lower) ||
            c.sku.toLowerCase() == lower ||
            c.barcode.toLowerCase() == lower)
        .take(20)
        .toList();
    final fuzzy = widget.matcher
        .match(q, hsn: widget.hsn, limit: 20)
        .candidates
        .map((c) => c.item);
    final seen = <String>{};
    return [
      for (final c in [...fuzzy, ...contains])
        if (seen.add('${c.key}')) c,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final results = _results();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _q,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                labelText: 'Search stock item (ഐറ്റം തിരയുക)',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: results.isEmpty
                ? const Center(
                    child: Text('No items found (ഐറ്റം ഇല്ല)',
                        style: TextStyle(color: DashboardColors.textMuted)))
                : ListView.separated(
                    itemCount: results.length,
                    separatorBuilder: (_, __) =>
                        const Divider(color: Colors.white10, height: 1),
                    itemBuilder: (_, i) {
                      final c = results[i];
                      return ListTile(
                        title: Text(c.name,
                            style: const TextStyle(color: Colors.white)),
                        subtitle: Text(
                          [
                            if (c.sku.isNotEmpty) 'SKU ${c.sku}',
                            if (c.hsn.isNotEmpty) 'HSN ${c.hsn}',
                            if (c.sellingPricePaise > 0)
                              '₹${(c.sellingPricePaise / 100).toStringAsFixed(2)}',
                          ].join('  •  '),
                          style: const TextStyle(
                              color: DashboardColors.textMuted, fontSize: 12),
                        ),
                        onTap: () => Navigator.pop(context, c),
                      );
                    },
                  ),
          ),
        ]),
      ),
    );
  }
}
