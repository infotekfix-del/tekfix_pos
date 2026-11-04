import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../main.dart' show Db;
import '../utils/tek_helpers.dart';
import 'barcode_label_models.dart';
import 'tspl_generator.dart';
import 'windows_raw_printer.dart';

export 'barcode_label_models.dart';
export 'tspl_generator.dart';
export 'windows_raw_printer.dart';

/// Centralized Barcode Label Printing Service for TekFix ERP.
/// Standardized for TVS LP 46 Lite and LP 44 Lite on 50 mm x 25 mm die-cut labels with 3 mm gap.
class BarcodeLabelService extends ChangeNotifier {
  BarcodeLabelService._();
  static final BarcodeLabelService instance = BarcodeLabelService._();

  static const String settingsKey = 'barcode_printer_config';
  static const String defaultStoreName = 'TEKFIX DIGITAL';

  PrinterConfig _config = const PrinterConfig();
  PrinterConnectionStatus _status = PrinterConnectionStatus.disconnected;
  List<PrinterDevice> _availablePrinters = [];
  String? _lastError;
  bool _isInitialized = false;

  // Getters
  PrinterConfig get config => _config;
  PrinterConnectionStatus get status => _status;
  List<PrinterDevice> get availablePrinters => _availablePrinters;
  String? get lastError => _lastError;
  bool get isConnected => _status == PrinterConnectionStatus.connected;
  bool get isPrinting => _status == PrinterConnectionStatus.printing;

  // ---------------------------------------------------------------------------
  // 1. SPECIFICATIONS: 38 mm × 25 mm (DEFAULT) & 50 mm × 25 mm PROFILES
  // ---------------------------------------------------------------------------
  static const double defaultLabelWidthMm = 38.0;
  static const double defaultLabelHeightMm = 25.0;
  static const double defaultLabelGapMm = 3.0;

  /// Static standard PdfPageFormat matching default physical sticker dimensions (38 mm x 25 mm).
  /// Margins: 1.0 mm top/bottom, 1.2 mm left/right to maximize printable area.
  static PdfPageFormat get pageFormat => const PdfPageFormat(
        defaultLabelWidthMm * PdfPageFormat.mm,
        defaultLabelHeightMm * PdfPageFormat.mm,
        marginTop: 1.0 * PdfPageFormat.mm,
        marginBottom: 1.0 * PdfPageFormat.mm,
        marginLeft: 1.2 * PdfPageFormat.mm,
        marginRight: 1.2 * PdfPageFormat.mm,
      );

  /// Dynamic PdfPageFormat matching the currently configured profile/preset.
  PdfPageFormat get activePageFormat => PdfPageFormat(
        _config.widthMm * PdfPageFormat.mm,
        _config.heightMm * PdfPageFormat.mm,
        marginTop: _config.safetyMarginMm * PdfPageFormat.mm,
        marginBottom: _config.safetyMarginMm * PdfPageFormat.mm,
        marginLeft: _config.safetyMarginMm * PdfPageFormat.mm,
        marginRight: _config.safetyMarginMm * PdfPageFormat.mm,
      );

  /// Sets label preset (38x25mm, 50x25mm, or Custom) and persists to settings.
  Future<void> setPreset(LabelPreset preset,
      {double? customWidth, double? customHeight}) async {
    await saveSettings(_config.withPreset(preset,
        customWidth: customWidth, customHeight: customHeight));
  }

  /// Sets label profile (alias for setPreset).
  Future<void> setProfile(LabelProfile profile) async {
    await setPreset(profile);
  }

  /// Sets thermal printing darkness (DENSITY: 1 to 15, default 8 per spec).
  Future<void> setDarkness(int darkness) async {
    await saveSettings(_config.copyWith(darkness: darkness.clamp(1, 15)));
  }

  /// Sets thermal printing speed (SPEED: 2 to 6).
  Future<void> setSpeed(int speed) async {
    await saveSettings(_config.copyWith(speed: speed.clamp(2, 6)));
  }

  /// Sets X and Y offsets in millimeters.
  Future<void> setOffset({double? xOffsetMm, double? yOffsetMm}) async {
    await saveSettings(_config.copyWith(
      xOffsetMm: xOffsetMm ?? _config.xOffsetMm,
      yOffsetMm: yOffsetMm ?? _config.yOffsetMm,
    ));
  }

  /// Initializes the service, loads saved configuration, and discovers printers.
  Future<void> initialize() async {
    if (_isInitialized) return;
    await loadSettings();
    await refreshPrinters();
    _isInitialized = true;
    notifyListeners();
  }

  /// Loads printer configuration from Hive storage.
  Future<void> loadSettings() async {
    try {
      if (Hive.isBoxOpen('tek_settings')) {
        final box = Hive.box('tek_settings');
        final raw = box.get(settingsKey);
        if (raw is Map) {
          _config = PrinterConfig.fromMap(raw);
        }
      }
    } catch (e) {
      debugPrint('BarcodeLabelService: Error loading settings: $e');
    }
  }

  /// Persists printer configuration to Hive.
  Future<void> saveSettings(PrinterConfig newConfig) async {
    _config = newConfig;
    try {
      if (Hive.isBoxOpen('tek_settings')) {
        final box = Hive.box('tek_settings');
        await box.put(settingsKey, newConfig.toMap());
      }
    } catch (e) {
      debugPrint('BarcodeLabelService: Error saving settings: $e');
    }
    notifyListeners();
  }

  /// Discovers installed and connected printers.
  Future<void> refreshPrinters() async {
    _status = PrinterConnectionStatus.connecting;
    notifyListeners();

    try {
      if (Platform.isWindows) {
        _availablePrinters = await WindowsRawPrinter.instance.listPrinters();
      } else {
        final pList = await Printing.listPrinters();
        _availablePrinters = pList
            .map((p) => PrinterDevice(
                  name: p.name,
                  driver: p.model ?? '',
                  port: p.url,
                  isDefault: p.isDefault,
                ))
            .toList();
      }

      // Automatically connect to TVS LP 46 Lite or saved printer
      if (_config.printerName.isNotEmpty &&
          _availablePrinters.any((p) => p.name == _config.printerName)) {
        _status = PrinterConnectionStatus.connected;
      } else {
        // Auto-select preferred TVS LP 46 / TT065 printer
        final tvs = _availablePrinters.firstWhere(
          (p) => p.isTargetTvs,
          orElse: () => _availablePrinters.isNotEmpty
              ? _availablePrinters.first
              : const PrinterDevice(name: ''),
        );
        if (tvs.name.isNotEmpty) {
          await saveSettings(_config.copyWith(printerName: tvs.name));
          _status = PrinterConnectionStatus.connected;
        } else {
          _status = PrinterConnectionStatus.disconnected;
        }
      }
      _lastError = null;
    } catch (e) {
      _status = PrinterConnectionStatus.error;
      _lastError = e.toString();
    } finally {
      notifyListeners();
    }
  }

  /// Sets the active printer.
  Future<void> selectPrinter(String printerName) async {
    await saveSettings(_config.copyWith(printerName: printerName));
    _status = printerName.isNotEmpty
        ? PrinterConnectionStatus.connected
        : PrinterConnectionStatus.disconnected;
    notifyListeners();
  }

  /// Disconnects the active printer.
  void disconnectPrinter() {
    _status = PrinterConnectionStatus.disconnected;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 2. UNIQUE BARCODE GENERATION & PERMANENT DB STORAGE
  // ---------------------------------------------------------------------------

  /// Generates a clean, unique Code 128 scannable barcode string.
  /// Format: TF followed by 6 numeric digits (e.g. TF894218).
  String generateUniqueBarcode({String prefix = 'TF'}) {
    final now = DateTime.now();
    final millisPart = now.millisecondsSinceEpoch.toString();
    final suffix = millisPart.substring(millisPart.length - 6);
    var candidate = '$prefix$suffix';

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
  Future<String> ensureItemHasBarcode(
    dynamic itemKey, {
    String? defaultBarcode,
    double? sellingPrice,
    double? mrp,
  }) async {
    if (itemKey == null || !Db.items.containsKey(itemKey)) {
      return defaultBarcode?.trim().isNotEmpty == true
          ? defaultBarcode!.trim()
          : generateUniqueBarcode();
    }

    final raw = tekM(Db.items.get(itemKey));
    String existing =
        '${raw['barcode'] ?? raw['code'] ?? raw['sku'] ?? ''}'.trim();

    if (existing.isNotEmpty) {
      return existing;
    }

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
    final p = (sellingPrice != null && sellingPrice > 0)
        ? sellingPrice
        : ((mrp != null && mrp > 0) ? mrp : null);
    if (p != null) {
      if ((updated['price'] as num?) == null ||
          (updated['price'] as num) == 0) {
        updated['price'] = p;
        updated['sellingPrice'] = p;
      }
    }

    await Db.items.put(itemKey, updated);
    return newBarcode;
  }

  /// Permanently updates the barcode of an item in Db.items.
  Future<void> saveItemBarcode(
    dynamic itemKey,
    String barcode, {
    double? price,
    double? mrp,
  }) async {
    if (itemKey == null || !Db.items.containsKey(itemKey)) return;
    final raw = tekM(Db.items.get(itemKey));
    final updated = Map<String, dynamic>.from(raw);
    updated['barcode'] = barcode.trim();
    if ((updated['code'] ?? '').toString().trim().isEmpty) {
      updated['code'] = barcode.trim();
    }
    final effective = (price != null && price > 0)
        ? price
        : ((mrp != null && mrp > 0) ? mrp : null);
    if (effective != null) {
      updated['price'] = effective;
      updated['sellingPrice'] = effective;
    }
    if (mrp != null && mrp > 0) {
      updated['mrp'] = mrp;
    }
    await Db.items.put(itemKey, updated);
  }

  // ---------------------------------------------------------------------------
  // 3. TSPL DIRECT HARDWARE PRINTING ENGINE
  // ---------------------------------------------------------------------------

  /// Prints barcode labels directly using native TSPL commands on Windows,
  /// or falls back to PDF printing on other platforms.
  /// Prevents blank label skipping during single-label and multi-label printing.
  Future<PrintJobResult> printLabels({
    required List<BarcodeLabelItem> items,
    bool showPrice = true,
    String? printerOverride,
  }) async {
    final validItems = items.where((it) => it.quantity > 0).toList();
    if (validItems.isEmpty) {
      return const PrintJobResult(
        success: false,
        message: 'No labels to print (Quantities are 0)',
        error: 'Zero quantity',
      );
    }

    final targetPrinter = printerOverride ?? _config.printerName;
    if (targetPrinter.trim().isEmpty) {
      return const PrintJobResult(
        success: false,
        message: 'Please select a printer before printing.',
        error: 'No printer selected',
      );
    }

    final totalCount = validItems.fold<int>(0, (sum, it) => sum + it.quantity);
    _status = PrinterConnectionStatus.printing;
    _lastError = null;
    notifyListeners();

    try {
      if (Platform.isWindows && _config.useDirectRaw) {
        // Generate pure TSPL commands specifically for 50x25mm with 3mm gap
        final tsplCommands = TsplGenerator.generateJob(
          items: validItems,
          config: _config,
          showPrice: showPrice,
        );

        debugPrint(
            'BarcodeLabelService: Sending raw TSPL commands to "$targetPrinter"');
        final result = await WindowsRawPrinter.instance.sendRawTspl(
          printerName: targetPrinter,
          tsplCommand: tsplCommands,
          docName: 'TekFix 50x25mm Barcode Labels',
          labelsCount: totalCount,
        );

        if (result.success) {
          _status = PrinterConnectionStatus.connected;
        } else {
          _status = PrinterConnectionStatus.error;
          _lastError = result.error;
        }
        notifyListeners();
        return result;
      } else {
        // Cross-platform PDF Fallback (exact 50x25mm page size)
        final pdfBytes = await generateLabelsPdf(
          items: validItems,
          showPrice: showPrice,
          shopName: _config.storeName,
        );

        await Printing.layoutPdf(
          name: 'TekFix_Barcode_50x25mm',
          format: activePageFormat,
          onLayout: (PdfPageFormat format) async => pdfBytes,
        );

        _status = PrinterConnectionStatus.connected;
        notifyListeners();
        return PrintJobResult(
          success: true,
          message: 'Printed $totalCount label(s) successfully.',
          labelsPrinted: totalCount,
        );
      }
    } catch (e) {
      _status = PrinterConnectionStatus.error;
      _lastError = e.toString();
      notifyListeners();
      return PrintJobResult(
        success: false,
        message: 'Print failed: $e',
        error: e.toString(),
      );
    }
  }

  /// Sends the Gap Sensor Calibration command to TVS LP 46 Lite.
  Future<PrintJobResult> calibratePrinter({String? printerOverride}) async {
    final target = printerOverride ?? _config.printerName;
    if (target.trim().isEmpty) {
      return const PrintJobResult(
        success: false,
        message: 'No printer selected for calibration.',
        error: 'No printer selected',
      );
    }

    _status = PrinterConnectionStatus.printing;
    notifyListeners();

    try {
      final res = await WindowsRawPrinter.instance.calibrate(target);
      _status = res.success
          ? PrinterConnectionStatus.connected
          : PrinterConnectionStatus.error;
      _lastError = res.error;
      notifyListeners();
      return res;
    } catch (e) {
      _status = PrinterConnectionStatus.error;
      _lastError = e.toString();
      notifyListeners();
      return PrintJobResult(
        success: false,
        message: 'Calibration failed: $e',
        error: e.toString(),
      );
    }
  }

  /// Prints a single test label.
  Future<PrintJobResult> printTestLabel({String? printerOverride}) async {
    final target = printerOverride ?? _config.printerName;
    if (target.trim().isEmpty) {
      return const PrintJobResult(
        success: false,
        message: 'No printer selected for test printing.',
        error: 'No printer selected',
      );
    }

    _status = PrinterConnectionStatus.printing;
    notifyListeners();

    try {
      final res =
          await WindowsRawPrinter.instance.testPrint(target, config: _config);
      _status = res.success
          ? PrinterConnectionStatus.connected
          : PrinterConnectionStatus.error;
      _lastError = res.error;
      notifyListeners();
      return res;
    } catch (e) {
      _status = PrinterConnectionStatus.error;
      _lastError = e.toString();
      notifyListeners();
      return PrintJobResult(
        success: false,
        message: 'Test print failed: $e',
        error: e.toString(),
      );
    }
  }

  /// Prints a Border Test rectangle at the label edge to verify even borders on all 4 sides.
  Future<PrintJobResult> printBorderTest({String? printerOverride}) async {
    final target = printerOverride ?? _config.printerName;
    if (target.trim().isEmpty) {
      return const PrintJobResult(
        success: false,
        message: 'No printer selected for border test.',
        error: 'No printer selected',
      );
    }

    _status = PrinterConnectionStatus.printing;
    notifyListeners();

    try {
      final tspl = TsplGenerator.generateBorderTestCommand(config: _config);
      final res = await WindowsRawPrinter.instance.sendRawTspl(
        printerName: target,
        tsplCommand: tspl,
        docName: 'TekFix Border Test',
        labelsCount: 1,
      );
      _status = res.success
          ? PrinterConnectionStatus.connected
          : PrinterConnectionStatus.error;
      _lastError = res.error;
      notifyListeners();
      return res;
    } catch (e) {
      _status = PrinterConnectionStatus.error;
      _lastError = e.toString();
      notifyListeners();
      return PrintJobResult(
        success: false,
        message: 'Border test failed: $e',
        error: e.toString(),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // 4. CODE 128 BARCODE PDF GENERATION (38x25mm & 50x25mm)
  // ---------------------------------------------------------------------------

  /// Generates a PDF document with exact physical label page dimensions.
  Future<Uint8List> generateLabelsPdf({
    required List<BarcodeLabelItem> items,
    bool showPrice = true,
    String shopName = defaultStoreName,
  }) async {
    final doc = pw.Document(
      title:
          'TekFix Barcode Labels ${_config.widthMm.toStringAsFixed(0)}x${_config.heightMm.toStringAsFixed(0)}mm',
      author: 'TekFix POS',
    );

    final barcodeFormat = pw.Barcode.code128();

    for (final item in items) {
      final qty = item.quantity.clamp(1, 9999);
      final rawBarcode = item.barcode.trim();
      final barcodeData =
          rawBarcode.isNotEmpty ? rawBarcode : generateUniqueBarcode();

      for (int i = 0; i < qty; i++) {
        doc.addPage(
          pw.Page(
            pageFormat: activePageFormat,
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

  /// Compact, high-precision representation for 38x25mm / 50x25mm thermal stickers.
  pw.Widget _buildLabelWidget({
    required BarcodeLabelItem item,
    required String barcodeData,
    required pw.Barcode barcode,
    required bool showPrice,
    required String shopName,
  }) {
    final hasPrice = showPrice && item.hasValidPrice;
    final price = item.effectivePrice ?? 0.0;
    final priceVal = price.truncateToDouble() == price
        ? price.toStringAsFixed(0)
        : price.toStringAsFixed(2);

    return pw.Container(
      width: double.infinity,
      height: double.infinity,
      child: pw.Column(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          // 1. HEADER: TEKFIX DIGITAL (small, centered)
          pw.Text(
            shopName.toUpperCase(),
            maxLines: 1,
            style: const pw.TextStyle(
              fontSize: 7.0,
              fontWeight: pw.FontWeight.bold,
              letterSpacing: 0.4,
            ),
          ),

          // 2. PRODUCT NAME (max 2 lines, centered)
          pw.Text(
            item.name.trim(),
            maxLines: 2,
            overflow: pw.TextOverflow.clip,
            textAlign: pw.TextAlign.center,
            style: const pw.TextStyle(
              fontSize: 6.0,
              fontWeight: pw.FontWeight.bold,
            ),
          ),

          // 3. CODE 128 BARCODE (height ~60 dots ≈ 21pt, auto-reduce width)
          pw.Container(
            height: 21.0,
            constraints: const pw.BoxConstraints(maxWidth: 95.0),
            child: pw.BarcodeWidget(
              barcode: barcode,
              data: barcodeData,
              drawText: false,
            ),
          ),

          // 4. HUMAN READABLE PRIMARY CODE ONLY (below bars, no ITEM_... line)
          pw.Text(
            barcodeData,
            maxLines: 1,
            style: const pw.TextStyle(
              fontSize: 6.0,
              letterSpacing: 0.8,
            ),
          ),

          // 5. FOOTER: MRP AT THE BOTTOM
          if (hasPrice)
            pw.Text(
              'MRP: Rs.$priceVal',
              maxLines: 1,
              style: const pw.TextStyle(
                fontSize: 8.0,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
        ],
      ),
    );
  }

  /// Generates direct TSPL2 commands supported natively by TVS LP 46 Lite & TSC printers.
  String generateTsplCommands({
    required List<BarcodeLabelItem> items,
    bool showPrice = true,
    String? shopName,
  }) {
    final buffer = StringBuffer();
    final store = (shopName != null && shopName.isNotEmpty)
        ? shopName
        : (_config.storeName.isNotEmpty ? _config.storeName : 'TEKFIX DIGITAL');

    for (final item in items) {
      final qty = item.quantity.clamp(1, 9999);
      final rawBarcode = item.barcode.trim();
      final barcodeData =
          rawBarcode.isNotEmpty ? rawBarcode : generateUniqueBarcode();
      final price = item.effectivePrice ?? item.sellingPrice;
      final priceStr = showPrice && (price != null && price > 0)
          ? 'MRP: Rs. ${price.toStringAsFixed(2)}'
          : '';

      buffer.writeln('SIZE 38 mm, 25 mm');
      buffer.writeln('GAP 2 mm, 0 mm');
      buffer.writeln('DIRECTION 1');
      buffer.writeln('CLS');
      buffer.writeln('TEXT 152,10,"2",0,1,1,"$store"');
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
