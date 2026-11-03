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
    // Exact 50 mm width, 25 mm height, 3 mm die-cut gap, zero offset, reference 0,0
    buffer.writeln('SIZE ${config.widthMm.toStringAsFixed(0)} mm,${config.heightMm.toStringAsFixed(0)} mm');
    buffer.writeln('GAP ${config.gapMm.toStringAsFixed(0)} mm,0 mm');
    buffer.writeln('DIRECTION 1');
    buffer.writeln('REFERENCE 0,0');
    buffer.writeln('OFFSET ${config.offsetMm.toStringAsFixed(0)} mm');
    buffer.writeln('CLS');

    // 2. STORE NAME (TEKFIX DIGITAL)
    // Horizontally centered, Font "2" (12x20 dots)
    final storeX = _calculateCenterX(store.length, charWidth: 12, maxDots: config.widthDots);
    buffer.writeln('TEXT $storeX,14,"2",0,1,1,"$store"');

    // 3. PRODUCT NAME (DYNAMIC SCALING & WRAPPING)
    final prodName = item.name.trim();
    final modelText = item.model.trim().isNotEmpty ? ' (${item.model.trim()})' : '';
    final fullProductName = '$prodName$modelText';

    if (fullProductName.length <= 20) {
      // Single line Font "2" (12x20 dots)
      final prodX = _calculateCenterX(fullProductName.length, charWidth: 12, maxDots: config.widthDots);
      buffer.writeln('TEXT $prodX,38,"2",0,1,1,"$fullProductName"');
    } else {
      // Multi-line intelligent wrap using Font "1" (8x12 dots)
      final lines = _wrapText(fullProductName, maxCharsPerLine: 44);
      final line1 = lines.isNotEmpty ? lines[0] : fullProductName;
      final line1X = _calculateCenterX(line1.length, charWidth: 8, maxDots: config.widthDots);
      buffer.writeln('TEXT $line1X,36,"1",0,1,1,"$line1"');

      if (lines.length > 1) {
        final line2 = lines[1];
        final line2X = _calculateCenterX(line2.length, charWidth: 8, maxDots: config.widthDots);
        buffer.writeln('TEXT $line2X,50,"1",0,1,1,"$line2"');
      }
    }

    // 4. CODE 128 BARCODE GRAPHIC
    // Centered horizontally, height 50 dots, module narrow 2, wide 2
    final barcodeWidth = (barcodeData.length + 3) * 11 * 2;
    final barcodeX = ((config.widthDots - barcodeWidth) / 2).clamp(12.0, 100.0).toInt();
    buffer.writeln('BARCODE $barcodeX,66,"128",50,0,0,2,2,"$barcodeData"');

    // 5. PRODUCT BARCODE (HUMAN READABLE STRING)
    // Centered directly beneath barcode, Font "2" (12x20 dots)
    final numX = _calculateCenterX(barcodeData.length, charWidth: 12, maxDots: config.widthDots);
    buffer.writeln('TEXT $numX,122,"2",0,1,1,"$barcodeData"');

    // 6. ITEM CODE / SKU & PRICE
    final priceStr = showPrice && (item.sellingPrice != null && item.sellingPrice! > 0)
        ? ' • MRP: Rs.${item.sellingPrice!.toStringAsFixed(0)}'
        : '';
    final itemCodeDisplay = item.itemCode.isNotEmpty ? item.itemCode : barcodeData;
    final footerText = '$itemCodeDisplay$priceStr';
    final footerX = _calculateCenterX(footerText.length, charWidth: 8, maxDots: config.widthDots);
    buffer.writeln('TEXT $footerX,146,"1",0,1,1,"$footerText"');

    // 7. PRINT COMMAND
    // Zero additional feed commands after PRINT ensures 1:1 label count without blank skips
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

  /// Wraps long text into lines without breaking mid-word when possible.
  static List<String> _wrapText(String text, {required int maxCharsPerLine}) {
    if (text.length <= maxCharsPerLine) return [text];

    final words = text.split(' ');
    final lines = <String>[];
    var currentLine = StringBuffer();

    for (final word in words) {
      if (currentLine.isEmpty) {
        currentLine.write(word);
      } else if (currentLine.length + 1 + word.length <= maxCharsPerLine) {
        currentLine.write(' $word');
      } else {
        lines.add(currentLine.toString());
        currentLine = StringBuffer(word);
        if (lines.length >= 2) break; // Limit to 2 lines to fit 25mm label
      }
    }

    if (currentLine.isNotEmpty && lines.length < 2) {
      lines.add(currentLine.toString());
    }

    return lines;
  }
}

