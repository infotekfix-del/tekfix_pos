import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../main.dart' show Db;

/// Represents the unit conversion and costing metadata for a consumable item.
class ConsumableItemConfig {
  final bool isMultiUnit;
  final String itemType; // 'Consumable / Raw Material' or 'Standard'
  final String purchaseUnit; // e.g. 'Bundle' / 'Rim'
  final String baseUnit; // e.g. 'Sheet'
  final int conversionFactor; // e.g. 500 sheets per bundle
  final double purchaseRate; // e.g. 207.0 per bundle
  final double costPrice; // dynamic WAC cost per base unit, e.g. 0.414 per sheet
  final int stock; // stock in base units (sheets)
  final int minStock; // low stock threshold in base units, e.g. 200 sheets

  const ConsumableItemConfig({
    this.isMultiUnit = true,
    this.itemType = 'Consumable / Raw Material',
    this.purchaseUnit = 'Bundle',
    this.baseUnit = 'Sheet',
    this.conversionFactor = 500,
    this.purchaseRate = 207.0,
    this.costPrice = 0.414,
    this.stock = 1500,
    this.minStock = 200,
  });

  /// Bundle equivalent of current base stock
  double get purchaseUnitsCount => conversionFactor > 0 ? stock / conversionFactor : stock.toDouble();

  /// Formatted stock string (e.g. "1,240 Sheets (~2.5 Bundles)")
  String get formattedStock => ConsumablesService.formatStockDisplay(
        baseStock: stock,
        conversionFactor: conversionFactor,
        baseUnit: baseUnit,
        purchaseUnit: purchaseUnit,
      );

  bool get isLowStock => stock <= minStock;
}

class ConsumablesService {
  ConsumablesService._();
  static final ConsumablesService instance = ConsumablesService._();

  static const String defaultA4Name = 'A4 Paper 75 GSM';
  static const int defaultPaperThreshold = 200; // Warning threshold in sheets (~0.4 bundle)
  static const int defaultConversionFactor = 500; // 500 sheets per bundle

  /// Calculates Weighted Average Cost (WAC) per base unit when new stock is purchased.
  ///
  /// Formula:
  ///   WAC = (Existing Stock Value + New Purchase Value) / Total Combined Base Units
  ///
  /// Where:
  ///   Existing Stock Value = max(0, oldStockBase) * oldUnitCostBase
  ///   New Purchase Value = newQuantityPurchase * newRatePurchase
  ///   Total Combined Base Units = max(0, oldStockBase) + (newQuantityPurchase * conversionFactor)
  static double calculateWAC({
    required int oldStockBase,
    required double oldUnitCostBase,
    required int newQuantityPurchase,
    required double newRatePurchase,
    required int conversionFactor,
  }) {
    final safeOldStock = oldStockBase > 0 ? oldStockBase : 0;
    final existingStockValue = safeOldStock * oldUnitCostBase;
    final newPurchaseValue = newQuantityPurchase * newRatePurchase;
    final safeFactor = conversionFactor > 0 ? conversionFactor : 1;
    final newBaseUnits = newQuantityPurchase * safeFactor;
    final totalBaseUnits = safeOldStock + newBaseUnits;

    if (totalBaseUnits <= 0) return 0.0;
    final rawWac = (existingStockValue + newPurchaseValue) / totalBaseUnits;
    // Round to 4 decimal places for precision currency fractions (e.g. ₹0.4140)
    return double.parse(rawWac.toStringAsFixed(4));
  }

  /// Formats base stock count with secondary purchase unit preview.
  /// e.g. "1,240 Sheets (~2.5 Bundles)" or "1,500 Sheets (3 Bundles)"
  static String formatStockDisplay({
    required int baseStock,
    required int conversionFactor,
    String baseUnit = 'Sheet',
    String purchaseUnit = 'Bundle',
  }) {
    if (conversionFactor <= 1) {
      return '$baseStock $baseUnit';
    }
    final bundles = baseStock / conversionFactor;
    final bundleStr = (bundles % 1 == 0)
        ? bundles.toInt().toString()
        : bundles.toStringAsFixed(1);
    final bundleLabel = bundles == 1 ? purchaseUnit : '${purchaseUnit}s';
    return '$baseStock $baseUnit (~$bundleStr $bundleLabel)';
  }

  /// Checks if an item is a Photostat / Printing service item that consumes paper sheets.
  static bool isPhotostatItem(String name, [String? category]) {
    final lowerName = name.toLowerCase();
    final lowerCat = (category ?? '').toLowerCase();

    return lowerName.contains('photostat') ||
        lowerName.contains('xerox') ||
        lowerName.contains('printing') ||
        lowerName.contains('print') ||
        lowerName.contains('single side') ||
        lowerName.contains('double side') ||
        lowerCat.contains('photostat') ||
        lowerCat.contains('printing') ||
        lowerCat.contains('xerox');
  }

  /// Calculates how many A4 sheets are consumed for a given item name.
  /// Single Side: 1 sheet
  /// Double Side: 1 sheet (printed front & back on 1 physical sheet)
  /// Default print: 1 sheet per unit
  static int sheetsConsumedPerItem(String name) {
    // Both Single Side and Double Side consume 1 physical A4 sheet per copy
    return 1;
  }

  /// Calculates profit margin for Photostat services given selling price and paper cost.
  static Map<String, dynamic> calculatePhotostatMargin({
    required double sellingPrice,
    double? paperCostPerSheet,
  }) {
    final cost = paperCostPerSheet ?? getEffectivePaperCost();
    final profit = (sellingPrice - cost).clamp(0.0, double.infinity);
    final marginPercent = sellingPrice > 0 ? (profit / sellingPrice) * 100 : 0.0;
    return {
      'sellingPrice': sellingPrice,
      'costPerSheet': cost,
      'profit': profit,
      'marginPercent': marginPercent,
    };
  }

  /// Retrieves the current dynamic cost per sheet from A4 Paper consumable.
  static double getEffectivePaperCost() {
    try {
      final item = getA4PaperItem();
      if (item != null) {
        final c = (item['costPrice'] as num?)?.toDouble();
        if (c != null && c > 0) return c;
      }
    } catch (_) {}
    return 0.414; // Default fallback: ₹207 / 500 = ₹0.414
  }

  /// Retrieves the A4 paper consumable item from `Db.items`, or null if not yet present.
  static Map<String, dynamic>? getA4PaperItem() {
    if (!Db.items.isOpen) return null;
    for (final k in Db.items.keys) {
      final raw = Db.items.get(k);
      if (raw is Map) {
        final m = Map<String, dynamic>.from(raw);
        final name = (m['name'] ?? '').toString().toLowerCase();
        final type = (m['itemType'] ?? '').toString().toLowerCase();
        if (name.contains('a4 paper') || (type.contains('consumable') && name.contains('a4'))) {
          m['_key'] = k;
          return m;
        }
      }
    }
    // Also check for any item with isMultiUnit == true and baseUnit contains sheet
    for (final k in Db.items.keys) {
      final raw = Db.items.get(k);
      if (raw is Map) {
        final m = Map<String, dynamic>.from(raw);
        if (m['isMultiUnit'] == true &&
            (m['baseUnit']?.toString().toLowerCase() == 'sheet' ||
             m['name']?.toString().toLowerCase().contains('paper') == true)) {
          m['_key'] = k;
          return m;
        }
      }
    }
    return null;
  }

  /// Finds the existing A4 Paper item in Hive, or initializes a default consumable item if none exists.
  static Future<Map<String, dynamic>> findOrCreateA4PaperItem() async {
    final existing = getA4PaperItem();
    if (existing != null) return existing;

    // Create default A4 Paper Consumable
    final defaultItem = <String, dynamic>{
      'name': defaultA4Name,
      'category': 'Consumable / Raw Material',
      'itemType': 'Consumable',
      'isMultiUnit': true,
      'purchaseUnit': 'Bundle',
      'baseUnit': 'Sheet',
      'conversionFactor': defaultConversionFactor,
      'purchaseRate': 207.0,
      'costPrice': 0.414,
      'sellingPrice': 0.0,
      'stock': 1500, // 3 Bundles initial default
      'minStock': defaultPaperThreshold,
      'warranty': 'No Warranty',
      'followUpEnabled': false,
    };

    final newKey = await Db.items.add(defaultItem);
    defaultItem['_key'] = newKey;
    await Db.stockMove(newKey, defaultA4Name, 1500, 'Initial Consumable Opening Stock (3 Bundles)');
    return defaultItem;
  }

  /// Deducts consumed paper sheets from the A4 Paper inventory balance.
  /// Returns the remaining stock in sheets.
  static Future<int> deductPaperSheets(
    int sheetsToDeduct, {
    required String reason,
    String? shopId,
  }) async {
    if (sheetsToDeduct <= 0) {
      final cur = getA4PaperItem();
      return (cur?['stock'] as num?)?.toInt() ?? 0;
    }

    final item = await findOrCreateA4PaperItem();
    final itemKey = item['_key'];
    final oldStock = (item['stock'] as num?)?.toInt() ?? 0;
    final newStock = (oldStock - sheetsToDeduct).clamp(0, 9999999);

    item['stock'] = newStock;
    item.remove('_key');
    if (itemKey != null) {
      await Db.items.put(itemKey, item);
      await Db.stockMove(
        itemKey,
        defaultA4Name,
        -sheetsToDeduct,
        '$reason: Auto-deducted $sheetsToDeduct sheet${sheetsToDeduct == 1 ? '' : 's'}',
      );
    }

    // Sync to Firestore if shopId is provided
    if (shopId != null && shopId.isNotEmpty) {
      try {
        final query = await FirebaseFirestore.instance
            .collection('shops')
            .doc(shopId)
            .collection('items')
            .where('isMultiUnit', isEqualTo: true)
            .limit(1)
            .get();

        if (query.docs.isNotEmpty) {
          final doc = query.docs.first;
          await doc.reference.update({
            'stock': FieldValue.increment(-sheetsToDeduct),
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      } catch (e) {
        debugPrint('Consumable Firestore sync notice: $e');
      }
    }

    return newStock;
  }

  /// Calculates total sheets to deduct from a cart of sold items.
  static int calculateTotalSheetsForCart(List<dynamic> cartItems) {
    int totalSheets = 0;
    for (final line in cartItems) {
      String name = '';
      String category = '';
      int qty = 1;

      if (line is Map) {
        name = '${line['name'] ?? ''}';
        category = '${line['category'] ?? ''}';
        qty = (line['qty'] as num?)?.toInt() ?? (line['quantity'] as num?)?.toInt() ?? 1;
      } else {
        // e.g. PosCartItem
        try {
          name = line.item.name;
          category = line.item.category;
          qty = line.qty;
        } catch (_) {}
      }

      if (isPhotostatItem(name, category)) {
        final perItem = sheetsConsumedPerItem(name);
        totalSheets += perItem * qty;
      }
    }
    return totalSheets;
  }
}
