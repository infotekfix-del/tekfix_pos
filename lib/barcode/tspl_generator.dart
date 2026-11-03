import 'barcode_label_models.dart';

/// High-precision TSPL command generator for TVS LP 46 Lite and LP 44 Lite.
/// Designed for 203 DPI (8 dots/mm) with 50 mm x 25 mm die-cut labels and 3 mm gap.
class TsplGenerator {
  TsplGenerator._();

  /// Generates the complete TSPL byte string for one or more items.
  /// Strictly adheres to zero blank label feed requirements.
  static String generateJob({
    required List<BarcodeLabelItem> items,
    PrinterConfig config = const PrinterConfig(),
    bool showPrice = true,
  }) {
    final buffer = StringBuffer();

    for (final item in items) {
      if (item.quantity <= 0) continue;
      buffer.write(generateSingleItem(
        item: item,
        config: config,
        showPrice: showPrice,
        quantity: item.quantity,
      ));
    }

    return buffer.toString();
  }

  /// Generates TSPL commands for a single item with specified quantity.
  static String generateSingleItem({
    required BarcodeLabelItem item,
    PrinterConfig config = const PrinterConfig(),
    bool showPrice = true,
    int? quantity,
  }) {
    final qty = (quantity ?? item.quantity).clamp(1, 9999);
    final rawBarcode = item.barcode.trim();
    final barcodeData = rawBarcode.isNotEmpty ? rawBarcode : 'TF000000';
    final store = config.storeName.trim().isNotEmpty
        ? config.storeName.trim()
        : 'TEKFIX DIGITAL';

    final buffer = StringBuffer();

    // 1. PRINTER INITIALIZATION & MEDIA SETUP
    // Configurable size (38mm x 25mm default, or 50mm x 25mm), 3mm gap, 0 offset, reference 0,0
    buffer.writeln('SIZE ${config.widthMm.toStringAsFixed(0)} mm,${config.heightMm.toStringAsFixed(0)} mm');
    buffer.writeln('GAP ${config.gapMm.toStringAsFixed(0)} mm,0 mm');
    buffer.writeln('DIRECTION 1');
    buffer.writeln('REFERENCE 0,0');
    buffer.writeln('OFFSET ${config.offsetMm.toStringAsFixed(0)} mm');
    buffer.writeln('DENSITY ${config.darkness}');
    buffer.writeln('SPEED ${config.speed}');
    buffer.writeln('CLS');

    // 2. STORE NAME (TEKFIX DIGITAL)
    // Centered, bold uppercase, Font "2" (12x20 dots, ~7-8pt)
    final storeX = _calculateCenterX(store.length, charWidth: 12, maxDots: config.widthDots);
    buffer.writeln('TEXT $storeX,10,"2",0,1,1,"$store"');

    // 3. PRODUCT NAME (MAX 1 LINE, CENTER ALIGNED, TRUNCATE WITH ELLIPSIS)
    // Printable width: 38mm = 280 dots; 50mm = 376 dots.
    // Font "1" is 8 dots wide, 12 dots high (~6-7pt).
    final maxChars = (config.printableWidthDots ~/ 8).clamp(20, 60);
    final rawName = item.name.trim();
    final singleLineName = rawName.replaceAll(RegExp(r'\s+'), ' ');
    final truncatedName = singleLineName.length > maxChars
        ? '${singleLineName.substring(0, maxChars - 3)}...'
        : singleLineName;
    final prodX = _calculateCenterX(truncatedName.length, charWidth: 8, maxDots: config.widthDots);
    buffer.writeln('TEXT $prodX,32,"1",0,1,1,"$truncatedName"');

    // 4. CODE 128 BARCODE GRAPHIC
    // Barcode height: 10.5mm = 84 dots (range 10-11mm = 80-88 dots)
    // Narrow module: 1 dot, Wide module: 1 dot
    // Code 128 width: (N chars * 11) + 35 modules. Max barcode width: 32mm (256 dots).
    final int estimatedBarcodeWidth = (barcodeData.length * 11) + 35;
    final int safeBarcodeWidth = estimatedBarcodeWidth.clamp(40, 256);
    int barcodeX = ((config.widthDots - safeBarcodeWidth) ~/ 2);
    if (barcodeX < config.safetyMarginDots) barcodeX = config.safetyMarginDots;
    buffer.writeln('BARCODE $barcodeX,48,"128",84,0,0,1,1,"$barcodeData"');

    // 5. HUMAN READABLE TEXT (BARCODE NUMBER BELOW BARS)
    // Font "1" (8x12 dots, ~5.5-6pt), centered, no redundant document IDs
    final numX = _calculateCenterX(barcodeData.length, charWidth: 8, maxDots: config.widthDots);
    buffer.writeln('TEXT $numX,136,"1",0,1,1,"$barcodeData"');

    // 6. FOOTER: SELLING PRICE / MRP
    // High contrast, bold, Font "2" (12x20 dots, ~8-9pt).
    // Uses "PRICE: Rs.450" (ASCII-safe for physical thermal printers, preventing symbol corruption)
    if (showPrice && item.hasValidPrice) {
      final price = item.effectivePrice!;
      final priceVal = price.truncateToDouble() == price
          ? price.toStringAsFixed(0)
          : price.toStringAsFixed(2);
      final priceText = 'PRICE: Rs.$priceVal';
      final priceX = _calculateCenterX(priceText.length, charWidth: 12, maxDots: config.widthDots);
      buffer.writeln('TEXT $priceX,152,"2",0,1,1,"$priceText"');
    }

    // 7. PRINT COMMAND
    // Exact quantity without trailing feeds prevents blank sticker skips
    buffer.writeln('PRINT $qty,1');
    buffer.writeln();

    return buffer.toString();
  }

  /// Generates the standard TVS LP 46 Lite Gap Sensor Calibration command.
  static String generateCalibrationCommand() {
    return 'GAPDETECT\r\n';
  }

  /// Calculates horizontal coordinate for center alignment.
  static int _calculateCenterX(int charCount, {required int charWidth, int maxDots = 400}) {
    final textWidth = charCount * charWidth;
    final x = (maxDots - textWidth) ~/ 2;
    // Keep within safety margin (1.5mm = 12 dots)
    return x < 12 ? 12 : x;
  }

}

