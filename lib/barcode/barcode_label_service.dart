import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../main.dart' show Db;
import '../utils/tek_helpers.dart';

/// Represents a single item to be printed on a barcode label.
class BarcodeLabelItem {
  final dynamic itemKey;
  final String itemId;
  final String name;
  final String model;
  final String brand;
  String barcode;
  double? sellingPrice;
  int quantity;

  BarcodeLabelItem({
    this.itemKey,
    this.itemId = '',
    required this.name,
    this.model = '',
    this.brand = '',
    required this.barcode,
    this.sellingPrice,
    this.quantity = 1,
  });

  BarcodeLabelItem copyWith({
    dynamic itemKey,
    String? itemId,
    String? name,
    String? model,
    String? brand,
    String? barcode,
    double? sellingPrice,
    int? quantity,
  }) {
    return BarcodeLabelItem(
      itemKey: itemKey ?? this.itemKey,
      itemId: itemId ?? this.itemId,
      name: name ?? this.name,
      model: model ?? this.model,
      brand: brand ?? this.brand,
      barcode: barcode ?? this.barcode,
      sellingPrice: sellingPrice ?? this.sellingPrice,
      quantity: quantity ?? this.quantity,
    );
  }
}

/// Service configured specifically for TVS LP 46 Lite and standard 38 mm x 25 mm barcode labels.
class BarcodeLabelService {
  BarcodeLabelService._();
  static final BarcodeLabelService instance = BarcodeLabelService._();

  // ---------------------------------------------------------------------------
  // CONSTANTS: TVS LP 46 LITE & 38 x 25 MM SPECIFICATIONS
  // ---------------------------------------------------------------------------
  static const double labelWidthMm = 38.0;
  static const double labelHeightMm = 25.0;
  static const String defaultShopName = 'TEKFIX DIGITAL';

  /// Standard PdfPageFormat matching physical sticker dimensions (38mm x 25mm).
  /// Margins: 1.0mm top/bottom, 1.2mm left/right to maximize printable area
  /// while preventing clipping on thermal printer edges.
  static PdfPageFormat get pageFormat => const PdfPageFormat(
        labelWidthMm * PdfPageFormat.mm,
        labelHeightMm * PdfPageFormat.mm,
        marginTop: 1.0 * PdfPageFormat.mm,
        marginBottom: 1.0 * PdfPageFormat.mm,
        marginLeft: 1.2 * PdfPageFormat.mm,
        marginRight: 1.2 * PdfPageFormat.mm,
      );

  // ---------------------------------------------------------------------------
  // 1. UNIQUE BARCODE GENERATION & PERMANENT DB STORAGE
  // ---------------------------------------------------------------------------

  /// Generates a clean, unique Code 128 scannable barcode string.
  /// Format: TF followed by 6 numeric digits (e.g. TF894218).
  String generateUniqueBarcode({String prefix = 'TF'}) {
    final now = DateTime.now();
    final millisPart = now.millisecondsSinceEpoch.toString();
    final suffix = millisPart.substring(millisPart.length - 6);
    var candidate = '$prefix$suffix';

    // Verify uniqueness in local Db.items
    int attempts = 0;
    while (_isBarcodeInUse(candidate) && attempts < 100) {
      attempts++;
      final alt = (int.parse(suffix) + attempts) % 1000000;
      candidate = '$prefix${alt.toString().padLeft(6, '0')}';
    }

    return candidate;
  }

  bool _isBarcodeInUse(String code) {
    if (code.isEmpty) return false;
    final lower = code.toLowerCase();
    for (final k in Db.items.keys) {
      final m = tekM(Db.items.get(k));
      final b = '${m['barcode'] ?? m['code'] ?? m['sku'] ?? ''}'.toLowerCase();
      if (b == lower) return true;
    }
    return false;
  }

  /// Ensures that an item has a barcode. If missing, generates a unique barcode
  /// and permanently writes it to the product in Db.items.
  Future<String> ensureItemHasBarcode(dynamic itemKey, {String? defaultBarcode, double? sellingPrice}) async {
    if (itemKey == null || !Db.items.containsKey(itemKey)) {
      return defaultBarcode?.trim().isNotEmpty == true
          ? defaultBarcode!.trim()
          : generateUniqueBarcode();
    }

    final raw = tekM(Db.items.get(itemKey));
    String existing = '${raw['barcode'] ?? raw['code'] ?? raw['sku'] ?? ''}'.trim();

    if (existing.isNotEmpty) {
      return existing;
    }

    // Generate new permanent barcode
    final newBarcode = defaultBarcode?.trim().isNotEmpty == true
        ? defaultBarcode!.trim()
        : generateUniqueBarcode();

    final updated = Map<String, dynamic>.from(raw);
    updated['barcode'] = newBarcode;
    if ((updated['code'] ?? '').toString().trim().isEmpty) {
      updated['code'] = newBarcode;
    }
    if ((updated['sku'] ?? '').toString().trim().isEmpty) {
      updated['sku'] = newBarcode;
    }
    if (sellingPrice != null && sellingPrice > 0) {
      if ((updated['price'] as num?) == null || (updated['price'] as num) == 0) {
        updated['price'] = sellingPrice;
        updated['sellingPrice'] = sellingPrice;
      }
    }

    await Db.items.put(itemKey, updated);
    return newBarcode;
  }

  /// Permanently updates the barcode of an item in Db.items.
  Future<void> saveItemBarcode(dynamic itemKey, String barcode, {double? price}) async {
    if (itemKey == null || !Db.items.containsKey(itemKey)) return;
    final raw = tekM(Db.items.get(itemKey));
    final updated = Map<String, dynamic>.from(raw);
    updated['barcode'] = barcode.trim();
    if ((updated['code'] ?? '').toString().trim().isEmpty) {
      updated['code'] = barcode.trim();
    }
    if (price != null && price > 0) {
      updated['price'] = price;
      updated['sellingPrice'] = price;
    }
    await Db.items.put(itemKey, updated);
  }

  // ---------------------------------------------------------------------------
  // 2. CODE 128 BARCODE PDF GENERATION (38 mm x 25 mm)
  // ---------------------------------------------------------------------------

  /// Generates a PDF document with exact 38 mm x 25 mm pages for each label.
  /// If an item has quantity = 10, exactly 10 individual pages are generated.
  Future<Uint8List> generateLabelsPdf({
    required List<BarcodeLabelItem> items,
    bool showPrice = true,
    String shopName = defaultShopName,
  }) async {
    final doc = pw.Document(
      title: 'TekFix Barcode Labels',
      author: 'TekFix POS',
    );

    final barcodeFormat = pw.Barcode.code128();

    for (final item in items) {
      final qty = item.quantity.clamp(1, 9999);
      final rawBarcode = item.barcode.trim();
      final barcodeData = rawBarcode.isNotEmpty ? rawBarcode : generateUniqueBarcode();

      for (int i = 0; i < qty; i++) {
        doc.addPage(
          pw.Page(
            pageFormat: pageFormat,
            build: (pw.Context context) {
              return _buildLabelWidget(
                item: item,
                barcodeData: barcodeData,
                barcode: barcodeFormat,
                showPrice: showPrice,
                shopName: shopName,
              );
            },
          ),
        );
      }
    }

    return await doc.save();
  }

  /// Layout optimized specifically for 38 mm x 25 mm label without overflow.
  /// Total available height is ~65 points (23 mm), width is ~99 points (35 mm).
  pw.Widget _buildLabelWidget({
    required BarcodeLabelItem item,
    required String barcodeData,
    required pw.Barcode barcode,
    required bool showPrice,
    required String shopName,
  }) {
    final hasModel = item.model.trim().isNotEmpty;
    final hasPrice = showPrice && (item.sellingPrice != null && item.sellingPrice! > 0);

    return pw.Container(
      width: double.infinity,
      height: double.infinity,
      child: pw.Column(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          // 1. SHOP NAME HEADER
          pw.Text(
            shopName.toUpperCase(),
            maxLines: 1,
            style: pw.TextStyle(
              fontSize: 6.2,
              fontWeight: pw.FontWeight.bold,
              letterSpacing: 0.3,
            ),
          ),

          // 2. PRODUCT NAME
          pw.Text(
            item.name.trim(),
            maxLines: 1,
            overflow: pw.TextOverflow.clip,
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(
              fontSize: 5.5,
              fontWeight: pw.FontWeight.bold,
            ),
          ),

          // 3. PRODUCT MODEL (if present)
          if (hasModel)
            pw.Text(
              'Model: ${item.model.trim()}',
              maxLines: 1,
              overflow: pw.TextOverflow.clip,
              style: const pw.TextStyle(
                fontSize: 4.5,
              ),
            ),

          // 4. GENUINE CODE 128 BARCODE GRAPHIC
          // Height: ~21 pt (~7.4 mm) for fast omnidirectional scanning
          pw.Container(
            height: hasModel ? 19.5 : 22.0,
            width: 92.0,
            child: pw.BarcodeWidget(
              barcode: barcode,
              data: barcodeData,
              drawText: false,
            ),
          ),

          // 5. BARCODE / SKU NUMBER
          pw.Text(
            barcodeData,
            maxLines: 1,
            style: const pw.TextStyle(
              fontSize: 5.0,
              letterSpacing: 0.6,
            ),
          ),

          // 6. SELLING PRICE (MRP)
          if (hasPrice)
            pw.Text(
              'MRP: Rs. ${item.sellingPrice!.toStringAsFixed(2)}',
              maxLines: 1,
              style: pw.TextStyle(
                fontSize: 5.8,
                fontWeight: pw.FontWeight.bold,
              ),
            )
          else
            pw.SizedBox(height: 1),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 3. PRINT DISPATCHING VIA NATIVE WINDOWS / TVS DRIVER
  // ---------------------------------------------------------------------------

  /// Opens the native print dialog or sends directly to the TVS LP 46 Lite driver.
  Future<void> printLabels(
    BuildContext context, {
    required List<BarcodeLabelItem> items,
    bool showPrice = true,
    String shopName = defaultShopName,
    String jobName = 'TVS_LP46_Barcode_Job',
  }) async {
    try {
      final pdfBytes = await generateLabelsPdf(
        items: items,
        showPrice: showPrice,
        shopName: shopName,
      );

      // Use native print dialog so the user can select TVS LP 46 Lite
      await Printing.layoutPdf(
        name: jobName,
        format: pageFormat,
        onLayout: (PdfPageFormat format) async => pdfBytes,
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Print failed: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 4. TSPL COMMAND GENERATOR (FOR DIRECT THERMAL COMMUNICATOR)
  // ---------------------------------------------------------------------------

  /// Generates direct TSPL2 commands supported natively by TVS LP 46 Lite & TSC printers.
  String generateTsplCommands({
    required List<BarcodeLabelItem> items,
    bool showPrice = true,
    String shopName = defaultShopName,
  }) {
    final buffer = StringBuffer();

    for (final item in items) {
      final qty = item.quantity.clamp(1, 9999);
      final rawBarcode = item.barcode.trim();
      final barcodeData = rawBarcode.isNotEmpty ? rawBarcode : generateUniqueBarcode();
      final priceStr = showPrice && (item.sellingPrice != null && item.sellingPrice! > 0)
          ? 'MRP: Rs. ${item.sellingPrice!.toStringAsFixed(2)}'
          : '';

      buffer.writeln('SIZE 38 mm, 25 mm');
      buffer.writeln('GAP 2 mm, 0 mm');
      buffer.writeln('DIRECTION 1');
      buffer.writeln('CLS');
      buffer.writeln('TEXT 152,10,"2",0,1,1,"$shopName"');
      buffer.writeln('TEXT 152,32,"1",0,1,1,"${item.name}"');
      if (item.model.isNotEmpty) {
        buffer.writeln('TEXT 152,50,"1",0,1,1,"Model: ${item.model}"');
      }
      buffer.writeln('BARCODE 28,68,"128",50,1,0,2,2,"$barcodeData"');
      if (priceStr.isNotEmpty) {
        buffer.writeln('TEXT 152,148,"2",0,1,1,"$priceStr"');
      }
      buffer.writeln('PRINT $qty,1');
      buffer.writeln();
    }

    return buffer.toString();
  }
}
