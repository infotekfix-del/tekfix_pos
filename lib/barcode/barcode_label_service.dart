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
  // 1. SPECIFICATIONS: 50 mm x 25 mm at 203 DPI (8 dots/mm) with 3 mm GAP
  // ---------------------------------------------------------------------------
  static const double labelWidthMm = 50.0;
  static const double labelHeightMm = 25.0;
  static const double labelGapMm = 3.0;

  /// Standard PdfPageFormat matching physical sticker dimensions (50 mm x 25 mm).
  /// Margins: 1.5 mm on all sides (12 dots).
  static PdfPageFormat get pageFormat => const PdfPageFormat(
        labelWidthMm * PdfPageFormat.mm,
        labelHeightMm * PdfPageFormat.mm,
        marginTop: 1.5 * PdfPageFormat.mm,
        marginBottom: 1.5 * PdfPageFormat.mm,
        marginLeft: 1.5 * PdfPageFormat.mm,
        marginRight: 1.5 * PdfPageFormat.mm,
      );

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
    if (sellingPrice != null && sellingPrice > 0) {
      if ((updated['price'] as num?) == null ||
          (updated['price'] as num) == 0) {
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

        debugPrint('BarcodeLabelService: Sending raw TSPL commands to "$targetPrinter"');
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
          format: pageFormat,
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

  /// Prints a single test label (50 mm x 25 mm).
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
      final res = await WindowsRawPrinter.instance.testPrint(target, config: _config);
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

  // ---------------------------------------------------------------------------
  // 4. CODE 128 BARCODE PDF GENERATION (50 mm x 25 mm)
  // ---------------------------------------------------------------------------

  /// Generates a PDF document with exact 50 mm x 25 mm pages.
  Future<Uint8List> generateLabelsPdf({
    required List<BarcodeLabelItem> items,
    bool showPrice = true,
    String shopName = defaultStoreName,
  }) async {
    final doc = pw.Document(
      title: 'TekFix Barcode Labels 50x25mm',
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

  /// Accurate physical representation for 50 mm x 25 mm layout.
  pw.Widget _buildLabelWidget({
    required BarcodeLabelItem item,
    required String barcodeData,
    required pw.Barcode barcode,
    required bool showPrice,
    required String shopName,
  }) {
    final hasPrice = showPrice && (item.sellingPrice != null && item.sellingPrice! > 0);
    final itemCode = item.itemCode.isNotEmpty ? item.itemCode : barcodeData;

    return pw.Container(
      width: double.infinity,
      height: double.infinity,
      child: pw.Column(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          // 1. STORE NAME
          pw.Text(
            shopName.toUpperCase(),
            maxLines: 1,
            style: pw.TextStyle(
              fontSize: 7.0,
              fontWeight: pw.FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),

          // 2. PRODUCT NAME
          pw.Text(
            item.name.trim(),
            maxLines: 2,
            overflow: pw.TextOverflow.clip,
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(
              fontSize: 6.0,
              fontWeight: pw.FontWeight.bold,
            ),
          ),

          // 3. CODE 128 BARCODE
          pw.Container(
            height: 25.0,
            width: 120.0,
            child: pw.BarcodeWidget(
              barcode: barcode,
              data: barcodeData,
              drawText: false,
            ),
          ),

          // 4. BARCODE NUMBER
          pw.Text(
            barcodeData,
            maxLines: 1,
            style: const pw.TextStyle(
              fontSize: 6.0,
              letterSpacing: 0.8,
            ),
          ),

          // 5. ITEM CODE / MRP
          pw.Text(
            hasPrice
                ? '$itemCode • Rs.${item.sellingPrice!.toStringAsFixed(0)}'
                : itemCode,
            maxLines: 1,
            style: pw.TextStyle(
              fontSize: 6.0,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  /// Generates the raw TSPL commands string for review or manual export.
  String generateTsplCommands({
    required List<BarcodeLabelItem> items,
    bool showPrice = true,
  }) {
    return TsplGenerator.generateJob(
      items: items,
      config: _config,
      showPrice: showPrice,
    );
  }
}
