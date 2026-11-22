// =============================================================================
// TEKFIX ERP — Vendor bill import service
//
// file bytes → text (PDF text layer, or Windows OCR for photos/scans)
//            → ExtractedBill (vendor, bill no, date, lines, totals)
//            → each line matched to a stock item (or NEW)
//
// Everything runs on the device; nothing is uploaded anywhere.
// =============================================================================

import 'package:flutter/foundation.dart';

import '../../main.dart' show Db;
import '../purchase_bill_service.dart';
import 'bill_item_matcher.dart';
import 'bill_ocr_service.dart';
import 'bill_text_layout.dart';
import 'pdf_text_extractor.dart';
import 'vendor_bill_parser.dart';

class BillImportException implements Exception {
  final String message;
  const BillImportException(this.message);
  @override
  String toString() => message;
}

class BillImportService {
  BillImportService._();
  static final BillImportService instance = BillImportService._();

  static const String aliasSettingKey = 'bill_import_item_aliases_v1';

  // ---------------------------------------------------------------------------
  // Reading the file
  // ---------------------------------------------------------------------------

  Future<ExtractedBill> readBill(Uint8List bytes, String fileName) async {
    final lower = fileName.toLowerCase();
    final parser = _parserForShop();
    if (lower.endsWith('.pdf') || _looksLikePdf(bytes)) {
      final res = await compute(PdfTextExtractor.extract, bytes);
      if (res.encrypted && res.runs.isEmpty) {
        throw const BillImportException(
            'This PDF is password-protected. Open it, "Print to PDF" without '
            'a password, and upload again. (പാസ്‌വേഡ് ഉള്ള PDF)');
      }
      if (res.hasUsableText) {
        return parser.parseLines(BillTextLayout.groupRuns(res.runs),
            method: 'PDF text');
      }
      // Scanned PDF → OCR (Windows only)
      final runs = await BillOcrService.instance.ocrPdf(bytes);
      return parser.parseLines(BillTextLayout.groupRuns(runs),
          method: 'OCR (scanned PDF)');
    }
    if (RegExp(r'\.(png|jpe?g|bmp|tiff?|gif)$').hasMatch(lower)) {
      final ext = lower.split('.').last;
      final runs = await BillOcrService.instance
          .ocrImageBytes(bytes, extension: ext == 'jpeg' ? 'jpg' : ext);
      return parser.parseLines(BillTextLayout.groupRuns(runs),
          method: 'OCR (photo)');
    }
    throw const BillImportException(
        'Unsupported file. Please choose a PDF or a photo (JPG/PNG). '
        '(PDF അല്ലെങ്കിൽ ഫോട്ടോ തിരഞ്ഞെടുക്കുക)');
  }

  static bool _looksLikePdf(Uint8List b) =>
      b.length > 4 && b[0] == 0x25 && b[1] == 0x50 && b[2] == 0x44 && b[3] == 0x46;

  VendorBillParser _parserForShop() {
    String s(String k) {
      try {
        return Db.setting(k);
      } catch (_) {
        return '';
      }
    }

    return VendorBillParser(
      ownGstin: s('gstin'),
      ownNames: [s('shop_name'), 'tekfix'].where((e) => e.isNotEmpty).toList(),
      ownPhone: s('shop_phone'),
    );
  }

  // ---------------------------------------------------------------------------
  // Catalog & matching
  // ---------------------------------------------------------------------------

  List<CatalogItem> loadCatalog() {
    final out = <CatalogItem>[];
    if (!Db.items.isOpen) return out;
    for (final k in Db.items.keys) {
      final raw = Db.items.get(k);
      if (raw is! Map) continue;
      if (raw['deleted'] == true || raw['isDeleted'] == true) continue;
      if (raw['active'] == false || raw['isActive'] == false) continue;
      final name = (raw['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      out.add(CatalogItem.fromMap(k, raw));
    }
    return out;
  }

  Map<String, dynamic> loadAliases() {
    try {
      final raw = Db.settings.get(aliasSettingKey);
      if (raw is Map) {
        return raw.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {}
    return {};
  }

  /// Remembers "vendor wording → item" so the next bill matches instantly.
  Future<void> rememberAliases(Map<String, dynamic> newAliases) async {
    if (newAliases.isEmpty) return;
    final all = loadAliases()..addAll(newAliases);
    // keep the box small
    if (all.length > 5000) {
      final keys = all.keys.toList();
      for (var i = 0; i < keys.length - 5000; i++) {
        all.remove(keys[i]);
      }
    }
    await Db.settings.put(aliasSettingKey, all);
  }

  BillItemMatcher buildMatcher() =>
      BillItemMatcher(loadCatalog(), aliases: loadAliases());

  // ---------------------------------------------------------------------------
  // Vendor
  // ---------------------------------------------------------------------------

  /// Finds an existing supplier by GSTIN, phone, or similar name.
  Map<String, dynamic>? matchVendor(ExtractedBill bill) =>
      matchVendorIn(PurchaseBillService.instance.getVendors(), bill);

  @visibleForTesting
  static Map<String, dynamic>? matchVendorIn(
      List<Map<String, dynamic>> vendors, ExtractedBill bill) {
    final g = bill.vendorGstin?.toUpperCase().trim() ?? '';
    if (g.isNotEmpty) {
      for (final v in vendors) {
        if ((v['gst'] ?? '').toString().toUpperCase().trim() == g) return v;
      }
    }
    final ph = bill.vendorPhone ?? '';
    if (ph.length >= 10) {
      final tail = ph.substring(ph.length - 10);
      for (final v in vendors) {
        final vp = (v['phone'] ?? '').toString().replaceAll(RegExp(r'\D'), '');
        if (vp.length >= 10 && vp.substring(vp.length - 10) == tail) return v;
      }
    }
    final name = bill.vendorName ?? '';
    if (name.trim().length >= 3) {
      final catalog = [
        for (final v in vendors)
          CatalogItem(key: v['key'], id: '${v['key']}', name: '${v['name']}'),
      ];
      final r = BillItemMatcher(catalog).match(name);
      if (r.best != null && r.best!.score >= 0.8) {
        return vendors.firstWhere((v) => '${v['key']}' == '${r.best!.item.key}');
      }
    }
    return null;
  }
}
