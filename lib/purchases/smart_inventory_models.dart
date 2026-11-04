// =============================================================================
// TEKFIX ERP — SMART INVENTORY SEARCH MODELS
// Version 2.0 Pro: Tokenized Autocomplete, Relevance Scoring & Highlighting
// =============================================================================

import 'package:flutter/material.dart';

/// Lightweight in-memory representation of an inventory item for fast search.
class InventorySearchItem {
  final String productId;
  final dynamic itemKey;
  final String name;
  final String brand;
  final String model;
  final String sku;
  final String barcode;
  final String category;
  final String hsn;
  final int stock;
  final double lastPurchaseRate;
  final double sellingPrice;
  final double mrp;
  final double gst;
  final String warranty;
  final bool trackImei;
  final bool isActive;
  final bool isDeleted;
  final String normalizedSearchString;
  final List<String> searchTokens;

  const InventorySearchItem({
    required this.productId,
    this.itemKey,
    required this.name,
    this.brand = '',
    this.model = '',
    this.sku = '',
    this.barcode = '',
    this.category = '',
    this.hsn = '',
    this.stock = 0,
    this.lastPurchaseRate = 0.0,
    this.sellingPrice = 0.0,
    this.mrp = 0.0,
    this.gst = 0.0,
    this.warranty = 'No Warranty',
    this.trackImei = false,
    this.isActive = true,
    this.isDeleted = false,
    required this.normalizedSearchString,
    required this.searchTokens,
  });

  bool get isOutOfStock => stock <= 0;

  /// String normalization: lowercased, special characters replaced with whitespace, excess spaces stripped.
  static String normalize(String input) {
    return input
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  factory InventorySearchItem.fromMap({
    required String id,
    dynamic key,
    required Map<dynamic, dynamic> map,
  }) {
    final name = (map['name'] ?? map['productName'] ?? '').toString().trim();
    final brand = (map['brand'] ?? '').toString().trim();
    final model = (map['model'] ?? '').toString().trim();
    final sku = (map['sku'] ?? map['code'] ?? '').toString().trim();
    final barcode = (map['barcode'] ?? map['imei'] ?? '').toString().trim();
    final category = (map['category'] ?? '').toString().trim();
    final hsn = (map['hsn'] ?? map['hsnCode'] ?? '').toString().trim();

    final stockNum = map['stock'] ?? map['stockCount'] ?? map['units'];
    final stock = stockNum is num ? stockNum.toInt() : 0;

    final rateNum = map['lastPurchaseRate'] ?? map['costPrice'] ?? map['cost'] ?? map['purchaseRate'];
    final lastPurchaseRate = rateNum is num ? rateNum.toDouble() : 0.0;

    final spNum = map['sellingPrice'] ?? map['price'];
    final sellingPrice = spNum is num ? spNum.toDouble() : 0.0;

    final mrpNum = map['mrp'];
    final mrp = mrpNum is num
        ? mrpNum.toDouble()
        : (sellingPrice > 0 ? sellingPrice : lastPurchaseRate);

    final gstNum = map['gst'] ?? map['gstRate'] ?? map['taxPercent'];
    final gst = gstNum is num ? gstNum.toDouble() : 0.0;

    final warranty = (map['warranty'] ?? map['warrantyDuration'] ?? 'No Warranty').toString().trim();

    final catLower = category.toLowerCase();
    final nameLower = name.toLowerCase();
    final trackImei = map['trackImei'] == true ||
        map['imeiRequired'] == true ||
        catLower.contains('phone') ||
        catLower.contains('mobile') ||
        catLower.contains('tablet') ||
        nameLower.contains('iphone') ||
        nameLower.contains('samsung galaxy') ||
        nameLower.contains('pixel');

    final isActive = map['active'] != false && map['isActive'] != false;
    final isDeleted = map['deleted'] == true || map['isDeleted'] == true;

    final searchRaw = '$name $brand $model $sku $barcode $category $hsn';
    final normalized = normalize(searchRaw);
    final tokens = normalized.split(' ').where((t) => t.isNotEmpty).toList();

    return InventorySearchItem(
      productId: id,
      itemKey: key,
      name: name.isNotEmpty ? name : 'Unnamed Product',
      brand: brand,
      model: model,
      sku: sku,
      barcode: barcode,
      category: category.isNotEmpty ? category : 'General',
      hsn: hsn,
      stock: stock,
      lastPurchaseRate: lastPurchaseRate,
      sellingPrice: sellingPrice,
      mrp: mrp,
      gst: gst,
      warranty: warranty,
      trackImei: trackImei,
      isActive: isActive,
      isDeleted: isDeleted,
      normalizedSearchString: normalized,
      searchTokens: tokens,
    );
  }

  /// Checks if every token in [queryTokens] is present in this item's searchable text.
  bool matchesTokens(List<String> queryTokens) {
    if (queryTokens.isEmpty) return true;
    for (final qToken in queryTokens) {
      if (!normalizedSearchString.contains(qToken)) {
        return false;
      }
    }
    return true;
  }

  /// Calculates a relevance score for ordering search results.
  int matchScore(List<String> queryTokens, String rawQuery) {
    if (queryTokens.isEmpty) return 0;
    int score = 0;
    final normQuery = normalize(rawQuery);
    final normName = normalize(name);
    final normSku = normalize(sku);
    final normBarcode = normalize(barcode);

    // Exact matches get highest priority
    if (normBarcode.isNotEmpty && normBarcode == normQuery) score += 1000;
    if (normSku.isNotEmpty && normSku == normQuery) score += 900;
    if (normName == normQuery) score += 500;
    if (normName.startsWith(normQuery)) score += 300;

    // Token-level prefix and presence scoring
    for (final token in queryTokens) {
      if (normName.startsWith(token)) {
        score += 80;
      } else if (normName.contains(token)) {
        score += 40;
      } else if (normSku.contains(token) || normBarcode.contains(token)) {
        score += 50;
      } else if (normalizedSearchString.contains(token)) {
        score += 20;
      }
    }

    // Availability bonus (in-stock items given modest priority over out of stock)
    if (stock > 0) score += 10;

    return score;
  }

  /// Renders a [RichText] widget with highlighted matching query words.
  static Widget buildHighlightedText({
    required String text,
    required List<String> queryTokens,
    required TextStyle baseStyle,
    required TextStyle highlightStyle,
    int maxLines = 1,
    TextOverflow overflow = TextOverflow.ellipsis,
  }) {
    if (queryTokens.isEmpty || text.isEmpty) {
      return Text(text, style: baseStyle, maxLines: maxLines, overflow: overflow);
    }

    final lowerText = text.toLowerCase();
    final spans = <TextSpan>[];
    int start = 0;

    // Find all matches for all tokens
    final matchIntervals = <_Interval>[];
    for (final token in queryTokens) {
      if (token.isEmpty) continue;
      int idx = 0;
      while ((idx = lowerText.indexOf(token, idx)) != -1) {
        matchIntervals.add(_Interval(idx, idx + token.length));
        idx += token.length;
      }
    }

    if (matchIntervals.isEmpty) {
      return Text(text, style: baseStyle, maxLines: maxLines, overflow: overflow);
    }

    // Merge overlapping intervals
    matchIntervals.sort((a, b) => a.start.compareTo(b.start));
    final merged = <_Interval>[];
    for (final interval in matchIntervals) {
      if (merged.isEmpty) {
        merged.add(interval);
      } else {
        final last = merged.last;
        if (interval.start <= last.end) {
          merged[merged.length - 1] = _Interval(
            last.start,
            interval.end > last.end ? interval.end : last.end,
          );
        } else {
          merged.add(interval);
        }
      }
    }

    for (final interval in merged) {
      if (interval.start > start) {
        spans.add(TextSpan(
          text: text.substring(start, interval.start),
          style: baseStyle,
        ));
      }
      spans.add(TextSpan(
        text: text.substring(interval.start, interval.end),
        style: highlightStyle,
      ));
      start = interval.end;
    }

    if (start < text.length) {
      spans.add(TextSpan(
        text: text.substring(start),
        style: baseStyle,
      ));
    }

    return RichText(
      text: TextSpan(children: spans),
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}

class _Interval {
  final int start;
  final int end;
  _Interval(this.start, this.end);
}

