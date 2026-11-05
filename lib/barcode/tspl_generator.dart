import 'barcode_label_models.dart';

/// High-precision TSPL command generator for TVS LP 46 Lite and LP 44 Lite.
/// Single-up 38 mm x 25 mm sticker, 3 mm gap, 203 DPI (1-up only).
class TsplGenerator {
  TsplGenerator._();

  /// Generates the complete TSPL string for one or more items.
  /// Each label ends with PRINT 1,1 (1-up only, no 2-up or column logic).
  static String generateJob({
    required List<BarcodeLabelItem> items,
    PrinterConfig config = const PrinterConfig(),
    bool showPrice = true,
  }) {
    final buffer = StringBuffer();

    for (final item in items) {
      if (item.quantity <= 0) continue;
      // Generate each individual label with PRINT 1,1
      for (int i = 0; i < item.quantity; i++) {
        buffer.write(generateSingleLabel(
          item: item,
          config: config,
          showPrice: showPrice,
        ));
      }
    }

    return buffer.toString();
  }

  /// Generates TSPL commands for a single label copy ending with PRINT 1,1.
  static String generateSingleLabel({
    required BarcodeLabelItem item,
    PrinterConfig config = const PrinterConfig(),
    bool showPrice = true,
  }) {
    final rawBarcode = item.barcode.trim();
    // Primary code only (TKF... / IMEI) - no ITEM_... prefix
    final barcodeData = rawBarcode.isNotEmpty ? rawBarcode : 'TF000000';
    final store = config.storeName.trim().isNotEmpty
        ? config.storeName.trim()
        : 'TEKFIX DIGITAL';

    final buffer = StringBuffer();

    // 1. TSPL HEADER
    // SIZE 38 mm,25 mm; GAP 3 mm,0 mm; DIRECTION 1; REFERENCE 0,0; DENSITY 8; SPEED 3; CLS
    buffer.writeln(
        'SIZE ${config.widthMm.toStringAsFixed(0)} mm,${config.heightMm.toStringAsFixed(0)} mm');
    buffer.writeln('GAP ${config.gapMm.toStringAsFixed(0)} mm,0 mm');
    buffer.writeln('DIRECTION 1');
    buffer
        .writeln('REFERENCE ${config.referenceXDots},${config.referenceYDots}');
    buffer.writeln('DENSITY ${config.darkness}');
    buffer.writeln('SPEED ${config.speed}');
    buffer.writeln('CLS');

    // 2. SHOP NAME (SMALL, CENTERED)
    // Font "1" (8x12 dots), centered at Y = 16
    final shopX = _calculateCenterX(store.length,
        charWidth: 8, maxDots: config.widthDots, margin: config.safeMarginDots);
    buffer.writeln('TEXT $shopX,16,"1",0,1,1,"$store"');

    // 3. ITEM NAME (MAX 2 LINES, CLEAN WRAP)
    // Safe printable width: 272 dots for 38mm. Font "1" = 8 dots/char -> ~32 chars per line max.
    final nameLines =
        _wrapName(item.name.trim(), maxCharsPerLine: 28, maxLines: 2);
    final hasTwoLines = nameLines.length > 1;

    if (hasTwoLines) {
      final line1X = _calculateCenterX(nameLines[0].length,
          charWidth: 8,
          maxDots: config.widthDots,
          margin: config.safeMarginDots);
      buffer.writeln('TEXT $line1X,32,"1",0,1,1,"${nameLines[0]}"');
      final line2X = _calculateCenterX(nameLines[1].length,
          charWidth: 8,
          maxDots: config.widthDots,
          margin: config.safeMarginDots);
      buffer.writeln('TEXT $line2X,46,"1",0,1,1,"${nameLines[1]}"');
    } else {
      final line1 = nameLines.isNotEmpty ? nameLines[0] : '';
      final line1X = _calculateCenterX(line1.length,
          charWidth: 8,
          maxDots: config.widthDots,
          margin: config.safeMarginDots);
      buffer.writeln('TEXT $line1X,36,"1",0,1,1,"$line1"');
    }

    // 4. CODE 128 BARCODE (HEIGHT ~60 DOTS, AUTO-REDUCE BAR WIDTH IF TOO WIDE)
    // Code 128 module count = (N * 11) + 35.
    // If narrow module = 2 fits inside printableWidthDots (272 dots), use 2; otherwise auto-reduce to 1.
    final moduleCount = (barcodeData.length * 11) + 35;
    final int moduleWidth =
        (moduleCount * 2 <= config.printableWidthDots) ? 2 : 1;
    final int barcodeWidth = moduleCount * moduleWidth;
    int barcodeX = ((config.widthDots - barcodeWidth) ~/ 2);
    if (barcodeX < config.safeMarginDots) barcodeX = config.safeMarginDots;
    final barcodeY = hasTwoLines ? 62 : 54;
    buffer.writeln(
        'BARCODE $barcodeX,$barcodeY,"128",60,0,0,$moduleWidth,$moduleWidth,"$barcodeData"');

    // 5. HUMAN-READABLE PRIMARY CODE ONLY (BELOW BARS, NO ITEM_... LINE)
    final codeY = hasTwoLines ? 126 : 118;
    final codeX = _calculateCenterX(barcodeData.length,
        charWidth: 8, maxDots: config.widthDots, margin: config.safeMarginDots);
    buffer.writeln('TEXT $codeX,$codeY,"1",0,1,1,"$barcodeData"');

    // 6. MRP AT THE BOTTOM (PRINT WHEN TOGGLE IS ON AND PRICE > 0, ALWAYS 2 DECIMALS)
    if (showPrice && item.hasValidPrice) {
      final price = item.effectivePrice!;
      final priceVal = price.toStringAsFixed(2);
      final mrpText = 'MRP: Rs.$priceVal';
      final mrpX = _calculateCenterX(mrpText.length,
          charWidth: 12,
          maxDots: config.widthDots,
          margin: config.safeMarginDots);
      buffer.writeln('TEXT $mrpX,144,"2",0,1,1,"$mrpText"');
    }

    // 7. END OF LABEL: PRINT 1,1
    buffer.writeln('PRINT 1,1');
    buffer.writeln();

    return buffer.toString();
  }

  /// Backward-compatible wrapper for single item.
  static String generateSingleItem({
    required BarcodeLabelItem item,
    PrinterConfig config = const PrinterConfig(),
    bool showPrice = true,
    int? quantity,
  }) {
    final qty = (quantity ?? item.quantity).clamp(1, 9999);
    final buffer = StringBuffer();
    for (int i = 0; i < qty; i++) {
      buffer.write(generateSingleLabel(
        item: item,
        config: config,
        showPrice: showPrice,
      ));
    }
    return buffer.toString();
  }

  /// Generates Border Test command (rectangle at label edge to verify even borders on all 4 sides).
  static String generateBorderTestCommand({
    PrinterConfig config = const PrinterConfig(),
  }) {
    final buffer = StringBuffer();
    buffer.writeln(
        'SIZE ${config.widthMm.toStringAsFixed(0)} mm,${config.heightMm.toStringAsFixed(0)} mm');
    buffer.writeln('GAP ${config.gapMm.toStringAsFixed(0)} mm,0 mm');
    buffer.writeln('DIRECTION 1');
    buffer
        .writeln('REFERENCE ${config.referenceXDots},${config.referenceYDots}');
    buffer.writeln('DENSITY ${config.darkness}');
    buffer.writeln('SPEED ${config.speed}');
    buffer.writeln('CLS');
    // Draw outer border test rectangle at 16-dot safe margins
    final endX = config.widthDots - config.safeMarginDots;
    final endY = config.heightDots - config.safeMarginDots;
    buffer.writeln(
        'BOX ${config.safeMarginDots},${config.safeMarginDots},$endX,$endY,2');

    const testText = 'BORDER TEST';
    final textX = _calculateCenterX(testText.length,
        charWidth: 12,
        maxDots: config.widthDots,
        margin: config.safeMarginDots);
    buffer.writeln('TEXT $textX,90,"2",0,1,1,"$testText"');
    buffer.writeln('PRINT 1,1');
    buffer.writeln();
    return buffer.toString();
  }

  /// Generates the standard TVS LP 46 Lite Gap Sensor Calibration command (GAPDETECT).
  static String generateCalibrationCommand() {
    return 'GAPDETECT\r\n';
  }

  /// Splits product name cleanly into up to 2 lines without breaking words.
  static List<String> _wrapName(String text,
      {required int maxCharsPerLine, required int maxLines}) {
    final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.length <= maxCharsPerLine) return [clean];

    final words = clean.split(' ');
    final lines = <String>[];
    var current = StringBuffer();

    for (final word in words) {
      if (current.isEmpty) {
        current.write(word);
      } else if (current.length + 1 + word.length <= maxCharsPerLine) {
        current.write(' $word');
      } else {
        lines.add(current.toString());
        current = StringBuffer(word);
        if (lines.length >= maxLines - 1) break;
      }
    }

    if (current.isNotEmpty && lines.length < maxLines) {
      var lastLine = current.toString();
      if (lastLine.length > maxCharsPerLine) {
        lastLine = '${lastLine.substring(0, maxCharsPerLine - 3)}...';
      }
      lines.add(lastLine);
    }

    return lines;
  }

  /// Calculates horizontal coordinate for center alignment within safe margins.
  static int _calculateCenterX(int charCount,
      {required int charWidth, required int maxDots, required int margin}) {
    final textWidth = charCount * charWidth;
    final x = (maxDots - textWidth) ~/ 2;
    return x < margin ? margin : x;
  }
}
