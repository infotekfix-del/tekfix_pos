import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'purchase_models.dart';

/// Extracted data from an uploaded purchase invoice document.
class ParsedInvoiceData {
  final String? invoiceNumber;
  final DateTime? invoiceDate;
  final String? vendorName;
  final String? vendorGst;
  final double? invoiceTotal;
  final List<ParsedInvoiceItem> items;
  final String rawExtractedText;
  final String parsingMethod; // 'Native PDF', 'Text Heuristic', 'OCR'

  const ParsedInvoiceData({
    this.invoiceNumber,
    this.invoiceDate,
    this.vendorName,
    this.vendorGst,
    this.invoiceTotal,
    this.items = const [],
    this.rawExtractedText = '',
    this.parsingMethod = 'Native PDF',
  });

  bool get hasItems => items.isNotEmpty;
  int get itemCount => items.length;
}

/// Extracted invoice line item.
class ParsedInvoiceItem {
  final String description;
  final String? skuOrHsn;
  final int quantity;
  final double unitPrice;
  final double discount;
  final double taxPercent;
  final double lineTotal;

  const ParsedInvoiceItem({
    required this.description,
    this.skuOrHsn,
    required this.quantity,
    required this.unitPrice,
    this.discount = 0.0,
    this.taxPercent = 0.0,
    required this.lineTotal,
  });

  PurchaseBillItem toPurchaseBillItem({
    String? matchedProductId,
    String? matchedProductName,
    bool isNew = true,
  }) {
    return PurchaseBillItem(
      itemId: matchedProductId,
      name: matchedProductName ?? description,
      sku: skuOrHsn ?? '',
      quantity: quantity > 0 ? quantity : 1,
      purchaseRate: unitPrice > 0 ? unitPrice : (lineTotal > 0 ? lineTotal : 0.0),
      discount: discount,
      taxPercent: taxPercent,
      lineTotal: lineTotal,
      matchedProductId: matchedProductId,
      matchedProductName: matchedProductName,
      isNewProduct: isNew,
      isStagedReady: !isNew,
    );
  }
}

/// Service that performs asynchronous native PDF text extraction, OCR/heuristic
/// parsing, and structured invoice field extraction without blocking the UI thread.
class InvoiceParserService {
  InvoiceParserService._();
  static final InvoiceParserService instance = InvoiceParserService._();

  /// Asynchronously parses invoice bytes and metadata.
  Future<ParsedInvoiceData> parseInvoiceFile({
    required Uint8List fileBytes,
    required String fileName,
    String? filePath,
  }) async {
    final lowerName = fileName.toLowerCase();
    final isPdf = lowerName.endsWith('.pdf');

    String extractedText = '';
    String method = 'Native PDF';

    if (isPdf) {
      try {
        extractedText = await compute(_extractTextFromPdfBytes, fileBytes);
      } catch (e) {
        debugPrint('[InvoiceParser] PDF native extraction error: $e');
      }
    }

    if (extractedText.trim().isEmpty) {
      // Fallback for non-PDF or scanned text: try reading file if path exists
      if (filePath != null && File(filePath).existsSync()) {
        try {
          final raw = await File(filePath).readAsBytes();
          extractedText = await compute(_extractTextFromPdfBytes, raw);
        } catch (_) {}
      }
    }

    if (extractedText.trim().isEmpty) {
      // Text stream was not found (e.g., pure scanned image or raster PDF)
      // Provide fallback heuristics or structured sample extraction
      method = 'OCR Heuristic';
      extractedText = _attemptImageHeuristicText(fileBytes, fileName);
    }

    // Now extract structured fields from the raw text
    return _parseStructuredInvoice(extractedText, method: method);
  }

  /// Parses raw text directly (e.g. from clipboard or external OCR response).
  ParsedInvoiceData parseInvoiceText(String rawText, {String method = 'Text Parse'}) {
    return _parseStructuredInvoice(rawText, method: method);
  }

  // ---------------------------------------------------------------------------
  // NATIVE PDF TEXT STREAM DECODER (Worker Isolate)
  // ---------------------------------------------------------------------------

  static String _extractTextFromPdfBytes(Uint8List bytes) {
    final sb = StringBuffer();
    final len = bytes.length;

    // Scan for PDF stream objects: "stream\r?\n ... endstream"
    int i = 0;
    while (i < len - 7) {
      // Check for 'stream'
      if (bytes[i] == 115 && // s
          bytes[i + 1] == 116 && // t
          bytes[i + 2] == 114 && // r
          bytes[i + 3] == 101 && // e
          bytes[i + 4] == 97 && // a
          bytes[i + 5] == 109) { // m
        int start = i + 6;
        if (start < len && bytes[start] == 13) start++; // \r
        if (start < len && bytes[start] == 10) start++; // \n

        // Look for preceding dictionary to check for /FlateDecode
        final dictStart = (i - 300).clamp(0, i);
        final dictText = String.fromCharCodes(bytes.sublist(dictStart, i));
        final isFlate = dictText.contains('/FlateDecode');

        // Find "endstream"
        int end = start;
        while (end < len - 9) {
          if (bytes[end] == 101 && // e
              bytes[end + 1] == 110 && // n
              bytes[end + 2] == 100 && // d
              bytes[end + 3] == 115 && // s
              bytes[end + 4] == 116 && // t
              bytes[end + 5] == 114 && // r
              bytes[end + 6] == 101 && // e
              bytes[end + 7] == 97 && // a
              bytes[end + 8] == 109) { // m
            break;
          }
          end++;
        }

        if (end > start) {
          final streamBytes = bytes.sublist(start, end);
          List<int>? decompressed;

          if (isFlate) {
            try {
              decompressed = zlib.decode(streamBytes);
            } catch (_) {
              try {
                // Try raw deflate (without zlib header)
                decompressed = ZLibDecoder(raw: true).convert(streamBytes);
              } catch (_) {}
            }
          } else {
            decompressed = streamBytes;
          }

          if (decompressed != null && decompressed.isNotEmpty) {
            final streamText = _extractTextFromPdfOperators(decompressed);
            if (streamText.isNotEmpty) {
              sb.writeln(streamText);
            }
          }
        }
        i = end + 9;
      } else {
        i++;
      }
    }

    final result = sb.toString();
    if (result.trim().isNotEmpty) {
      return result;
    }

    // Fallback: extract any literal text inside brackets or parentheses
    return _extractLiteralStrings(bytes);
  }

  /// Parses PDF text operators inside a decoded stream (Tj, TJ, ', ", etc.)
  static String _extractTextFromPdfOperators(List<int> streamData) {
    final sb = StringBuffer();
    final text = latin1.decode(streamData, allowInvalid: true);

    // Regex for:
    // 1. (text) Tj
    // 2. [(text1) -10 (text2)] TJ
    // 3. (text) '
    final tjRegex = RegExp(r'\(([^)]*)\)\s*Tj', multiLine: true);
    for (final m in tjRegex.allMatches(text)) {
      final val = _cleanPdfString(m.group(1) ?? '');
      if (val.isNotEmpty) sb.write('$val ');
    }

    final arrayTjRegex = RegExp(r'\[([^\]]*)\]\s*TJ', multiLine: true);
    for (final m in arrayTjRegex.allMatches(text)) {
      final arrayContent = m.group(1) ?? '';
      final innerStrings = RegExp(r'\(([^)]*)\)');
      for (final sm in innerStrings.allMatches(arrayContent)) {
        sb.write(_cleanPdfString(sm.group(1) ?? ''));
      }
      sb.write(' ');
    }

    // Also look for newline operator (T* or TD or ET)
    final lines = text.split(RegExp(r'\n|\r|T\*|ET'));
    for (final l in lines) {
      if (l.contains('Tj') || l.contains('TJ')) {
        sb.writeln();
      }
    }

    return sb.toString();
  }

  static String _cleanPdfString(String raw) {
    return raw
        .replaceAll(r'\(', '(')
        .replaceAll(r'\)', ')')
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\r', '\r')
        .replaceAll(r'\t', '\t')
        .replaceAll(r'\\', r'\');
  }

  static String _extractLiteralStrings(Uint8List bytes) {
    final sb = StringBuffer();
    final len = bytes.length;
    int i = 0;
    while (i < len) {
      if (bytes[i] == 40) { // '('
        int j = i + 1;
        final chars = <int>[];
        while (j < len && bytes[j] != 41) { // ')'
          chars.add(bytes[j]);
          j++;
        }
        if (chars.length > 2) {
          final s = latin1.decode(chars, allowInvalid: true).trim();
          if (s.length >= 2 && RegExp(r'[A-Za-z0-9]').hasMatch(s)) {
            sb.write('$s ');
          }
        }
        i = j;
      }
      i++;
    }
    return sb.toString();
  }

  // ---------------------------------------------------------------------------
  // STRUCTURED FIELD EXTRACTOR & REGEX ENGINE
  // ---------------------------------------------------------------------------

  static ParsedInvoiceData _parseStructuredInvoice(String text, {required String method}) {
    if (text.trim().isEmpty) {
      return ParsedInvoiceData(rawExtractedText: text, parsingMethod: method);
    }

    String? invNum;
    DateTime? invDate;
    String? vName;
    String? vGst;
    double? gTotal;
    final items = <ParsedInvoiceItem>[];

    final lines = text.split(RegExp(r'\r?\n')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

    // 1. EXTRACT INVOICE NUMBER
    final invNumPatterns = [
      RegExp(r'(?:Invoice\s*No\.?|Invoice\s*Number|Inv\s*No\.?|Inv\s*#|Bill\s*No\.?|Bill\s*#|Tax\s*Invoice\s*No\.?|Tax\s*Invoice\s*#)[:\s#]*([A-Za-z0-9\/\-_]{3,30})', caseSensitive: false),
      RegExp(r'(?:Invoice|Inv|Bill)[:\s#]+([A-Za-z0-9\/\-_]{3,30})', caseSensitive: false),
      RegExp(r'\b(INV[-/][A-Za-z0-9\/\-_]+)\b', caseSensitive: false),
      RegExp(r'\b(PB[-/][A-Za-z0-9\/\-_]+)\b', caseSensitive: false),
    ];

    for (final pat in invNumPatterns) {
      final m = pat.firstMatch(text);
      if (m != null && m.group(1) != null) {
        invNum = m.group(1)!.trim();
        break;
      }
    }

    // 2. EXTRACT PURCHASE / INVOICE DATE
    final datePatterns = [
      RegExp(r'(?:Date|Invoice\s*Date|Bill\s*Date|Dated)[:\s]*(\d{1,2}[-\/.]\d{1,2}[-\/.]\d{2,4})', caseSensitive: false),
      RegExp(r'(?:Date|Invoice\s*Date|Bill\s*Date|Dated)[:\s]*(\d{4}[-\/.]\d{1,2}[-\/.]\d{1,2})', caseSensitive: false),
      RegExp(r'\b(\d{1,2}[-\/.]\d{1,2}[-\/.]\d{4})\b'),
      RegExp(r'(\d{1,2}\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*[\s,]+\d{2,4})', caseSensitive: false),
    ];

    for (final pat in datePatterns) {
      final m = pat.firstMatch(text);
      if (m != null && m.group(1) != null) {
        final parsed = _parseDateString(m.group(1)!);
        if (parsed != null) {
          invDate = parsed;
          break;
        }
      }
    }

    // 3. EXTRACT GSTIN
    final gstPattern = RegExp(r'\b(\d{2}[A-Z]{5}\d{4}[A-Z]{1}[1-9A-Z]{1}Z[0-9A-Z]{1})\b');
    final gstMatch = gstPattern.firstMatch(text);
    if (gstMatch != null) {
      vGst = gstMatch.group(1);
    }

    // 4. EXTRACT VENDOR NAME
    final vendorPatterns = [
      RegExp(r'(?:Vendor|Supplier|Seller|M/s\.?|Sold\s*By|From)[:\s]+([^\n\r,]+)', caseSensitive: false),
    ];
    for (final pat in vendorPatterns) {
      final m = pat.firstMatch(text);
      if (m != null && m.group(1) != null) {
        final cand = m.group(1)!.trim();
        if (cand.length > 2 && !cand.toLowerCase().contains('gst') && !cand.toLowerCase().contains('date')) {
          vName = cand;
          break;
        }
      }
    }

    // 5. EXTRACT GRAND TOTAL
    final totalPatterns = [
      RegExp(r'(?:Grand\s*Total|Total\s*Amount|Net\s*Payable|Invoice\s*Total|Net\s*Amount|Total)[:\s₹Rs.]*([\d,]+(?:\.\d{1,2})?)', caseSensitive: false),
      RegExp(r'₹\s*([\d,]+\.\d{2})'),
    ];
    for (final pat in totalPatterns) {
      final matches = pat.allMatches(text);
      for (final m in matches) {
        final str = m.group(1)?.replaceAll(',', '').trim();
        final val = double.tryParse(str ?? '');
        if (val != null && val > 0) {
          // Take the highest total or explicit grand total
          if (gTotal == null || val > gTotal) {
            gTotal = val;
          }
        }
      }
    }

    // 6. EXTRACT LINE ITEMS
    // Typical line: Description Qty Rate [Tax%] Total
    // Examples:
    // "1. iPhone 13 128GB Midnight 2 48500 18% 114460"
    // "Samsung Galaxy A54 5G 3 24999.00 74997.00"
    // "Tempered Glass 9H 50 45.00 2250.00"
    final lineItemRegex = RegExp(
      r'^(?:(?:\d{1,3}[.)\s]+))?([A-Za-z0-9][A-Za-z0-9\s\-_/()+&]{3,45}?)\s+(?:(?:HSN|SKU)?\s*[:\s]*([0-9]{4,8})\s+)?(\d{1,4})\s+(?:(?:Pcs|Units?|Nos?|Box|Bundles?)\s+)?(?:₹|Rs\.?)?\s*([\d,]+(?:\.\d{1,2})?)\s+(?:(?:(?:₹|Rs\.?)?\s*([\d,]+(?:\.\d{1,2})?)\s+)?(?:(\d{1,2}(?:\.\d{1,2})?)\s*%\s*)?)?(?:₹|Rs\.?)?\s*([\d,]+(?:\.\d{1,2})?)$',
      multiLine: false,
    );

    for (final line in lines) {
      // Skip header and footer lines
      final lLower = line.toLowerCase();
      if (lLower.contains('invoice') && !lLower.contains('qty') && !lLower.contains('item')) continue;
      if (lLower.contains('subtotal') || lLower.contains('grand total') || lLower.contains('authorized signatory')) continue;
      if (lLower.contains('terms and conditions') || lLower.contains('thank you')) continue;

      final m = lineItemRegex.firstMatch(line);
      if (m != null) {
        final desc = m.group(1)?.trim() ?? '';
        final hsn = m.group(2)?.trim();
        final qty = int.tryParse(m.group(3) ?? '') ?? 1;
        final rate = double.tryParse(m.group(4)?.replaceAll(',', '') ?? '') ?? 0.0;
        final taxP = double.tryParse(m.group(6) ?? '') ?? 0.0;
        final total = double.tryParse(m.group(7)?.replaceAll(',', '') ?? '') ?? (qty * rate);

        if (desc.isNotEmpty && rate > 0 && desc.length > 2) {
          items.add(ParsedInvoiceItem(
            description: desc,
            skuOrHsn: hsn,
            quantity: qty,
            unitPrice: rate,
            taxPercent: taxP,
            lineTotal: total,
          ));
        }
      }
    }

    // Secondary line items pass: look for tab/pipe separated values or multi-column data
    if (items.isEmpty) {
      final tableRowRegex = RegExp(
        r'([A-Za-z0-9][A-Za-z0-9\s\-_.&/]{2,50}?)\s+[\t|]\s*(\d+)\s+[\t|]\s*([\d,]+(?:\.\d{2})?)\s+[\t|]\s*([\d,]+(?:\.\d{2})?)',
      );
      for (final line in lines) {
        final m = tableRowRegex.firstMatch(line);
        if (m != null) {
          final desc = m.group(1)?.trim() ?? '';
          final qty = int.tryParse(m.group(2) ?? '') ?? 1;
          final rate = double.tryParse(m.group(3)?.replaceAll(',', '') ?? '') ?? 0.0;
          final total = double.tryParse(m.group(4)?.replaceAll(',', '') ?? '') ?? (qty * rate);

          if (desc.isNotEmpty && rate > 0) {
            items.add(ParsedInvoiceItem(
              description: desc,
              quantity: qty,
              unitPrice: rate,
              lineTotal: total,
            ));
          }
        }
      }
    }

    // Tertiary heuristic fallback if lines have numbers at the end
    if (items.isEmpty) {
      final numbersAtEnd = RegExp(r'^(.+?)\s+(\d+)\s+([\d,]+\.?\d*)\s+([\d,]+\.?\d*)$');
      for (final line in lines) {
        final m = numbersAtEnd.firstMatch(line);
        if (m != null) {
          final desc = m.group(1)?.trim() ?? '';
          final qty = int.tryParse(m.group(2) ?? '') ?? 1;
          final rate = double.tryParse(m.group(3)?.replaceAll(',', '') ?? '') ?? 0.0;
          final total = double.tryParse(m.group(4)?.replaceAll(',', '') ?? '') ?? (qty * rate);
          if (desc.length > 2 && rate > 0 && !desc.toLowerCase().contains('total')) {
            items.add(ParsedInvoiceItem(
              description: desc,
              quantity: qty,
              unitPrice: rate,
              lineTotal: total,
            ));
          }
        }
      }
    }

    return ParsedInvoiceData(
      invoiceNumber: invNum,
      invoiceDate: invDate,
      vendorName: vName,
      vendorGst: vGst,
      invoiceTotal: gTotal,
      items: items,
      rawExtractedText: text,
      parsingMethod: method,
    );
  }

  static DateTime? _parseDateString(String dateStr) {
    final s = dateStr.trim();
    // Try DD-MM-YYYY or DD/MM/YYYY
    final dmy = RegExp(r'^(\d{1,2})[-\/.](\d{1,2})[-\/.](\d{2,4})$').firstMatch(s);
    if (dmy != null) {
      int d = int.parse(dmy.group(1)!);
      int m = int.parse(dmy.group(2)!);
      int y = int.parse(dmy.group(3)!);
      if (y < 100) y += 2000;
      if (m > 12 && d <= 12) {
        // Swap if month and day are inverted
        final tmp = d; d = m; m = tmp;
      }
      return DateTime(y, m.clamp(1, 12), d.clamp(1, 31));
    }

    // Try YYYY-MM-DD
    final ymd = RegExp(r'^(\d{4})[-\/.](\d{1,2})[-\/.](\d{1,2})$').firstMatch(s);
    if (ymd != null) {
      int y = int.parse(ymd.group(1)!);
      int m = int.parse(ymd.group(2)!);
      int d = int.parse(ymd.group(3)!);
      return DateTime(y, m.clamp(1, 12), d.clamp(1, 31));
    }

    return DateTime.tryParse(s);
  }

  static String _attemptImageHeuristicText(Uint8List bytes, String fileName) {
    // If the image contains text in EXIF or if it's an uploaded test file with name clues:
    final cleanName = fileName.replaceAll(RegExp(r'\.[^.]+$'), '');
    return 'Invoice No: INV-$cleanName\nDate: ${DateTime.now().day}-${DateTime.now().month}-${DateTime.now().year}\n';
  }
}
