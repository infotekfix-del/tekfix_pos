import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:tekfix_erp_pos/inventory/consumables_service.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/purchases/purchase_bill_service.dart';
import 'package:tekfix_erp_pos/purchases/purchase_models.dart';
import 'package:tekfix_erp_pos/pos/pos_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tekfix_multi_unit_test_');
    Hive.init(tempDir.path);

    for (final b in allBoxes) {
      if (!Hive.isBoxOpen(b)) await Hive.openBox(b);
    }
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Requirement 1 & 2: Multi-Unit Purchase Conversion & Effective Costing', () {
    test('PurchaseBillItem multi-unit calculation: 3 bundles @ ₹207 = 1500 sheets @ ₹0.414', () {
      final item = PurchaseBillItem(
        itemName: 'A4 Paper 75 GSM',
        category: 'Consumable / Raw Material',
        quantity: 3,
        purchaseRate: 207.0,
        isMultiUnit: true,
        purchaseUnit: 'Bundle',
        baseUnit: 'Sheet',
        conversionFactor: 500,
      );

      // Verify line total
      expect(item.lineTotal, equals(621.0)); // 3 * 207 = 621.0

      // Verify base quantity conversion
      expect(item.baseQuantity, equals(1500)); // 3 * 500 = 1500 sheets

      // Verify effective cost per base unit
      expect(item.effectiveUnitCost, closeTo(0.414, 0.001)); // 207 / 500 = 0.414
    });

    test('PurchaseBillItem serialization preserves multi-unit attributes', () {
      final item = PurchaseBillItem(
        itemName: 'A4 Paper 75 GSM',
        category: 'Consumable / Raw Material',
        quantity: 3,
        purchaseRate: 207.0,
        isMultiUnit: true,
        purchaseUnit: 'Bundle',
        baseUnit: 'Sheet',
        conversionFactor: 500,
      );

      final map = item.toMap();
      expect(map['isMultiUnit'], isTrue);
      expect(map['purchaseUnit'], equals('Bundle'));
      expect(map['baseUnit'], equals('Sheet'));
      expect(map['conversionFactor'], equals(500));
      expect(map['baseQuantity'], equals(1500));
      expect(map['effectiveUnitCost'], closeTo(0.414, 0.001));

      final restored = PurchaseBillItem.fromMap(map);
      expect(restored.isMultiUnit, isTrue);
      expect(restored.purchaseUnit, equals('Bundle'));
      expect(restored.baseUnit, equals('Sheet'));
      expect(restored.conversionFactor, equals(500));
      expect(restored.baseQuantity, equals(1500));
      expect(restored.effectiveUnitCost, closeTo(0.414, 0.001));
    });

    test('formatStockDisplay displays dual base and purchase units clearly', () {
      final display1 = ConsumablesService.formatStockDisplay(
        baseStock: 1500,
        conversionFactor: 500,
        baseUnit: 'Sheet',
        purchaseUnit: 'Bundle',
      );
      expect(display1, equals('1500 Sheet (~3 Bundles)'));

      final display2 = ConsumablesService.formatStockDisplay(
        baseStock: 1240,
        conversionFactor: 500,
        baseUnit: 'Sheet',
        purchaseUnit: 'Bundle',
      );
      expect(display2, equals('1240 Sheet (~2.5 Bundles)'));
    });
  });

  group('Requirement 3: Price Fluctuation & Weighted Average Costing (WAC)', () {
    test('Calculates WAC on initial purchase correctly', () {
      // 0 existing stock + 3 bundles (1500 sheets) @ ₹207
      final wac1 = ConsumablesService.calculateWAC(
        oldStockBase: 0,
        oldUnitCostBase: 0.0,
        newQuantityPurchase: 3,
        newRatePurchase: 207.0,
        conversionFactor: 500,
      );

      expect(wac1, closeTo(0.414, 0.0001));
    });

    test('Calculates WAC on subsequent price fluctuation (₹207 -> ₹220 per bundle)', () {
      // Existing: 1000 sheets remaining @ ₹0.414 (Stock value = ₹414)
      // New: 2 bundles (1000 sheets) @ ₹220 per bundle (Purchase value = ₹440)
      // Combined: 2000 sheets, total value = ₹854
      // New WAC = 854 / 2000 = ₹0.427 per sheet
      final wac2 = ConsumablesService.calculateWAC(
        oldStockBase: 1000,
        oldUnitCostBase: 0.414,
        newQuantityPurchase: 2,
        newRatePurchase: 220.0,
        conversionFactor: 500,
      );

      expect(wac2, closeTo(0.427, 0.0001));
    });

    test('Dynamic paper cost feeds into Photostat profit margin calculation', () {
      // Single Side: selling price ₹5, paper cost ₹0.414
      final marginSingle = ConsumablesService.calculatePhotostatMargin(
        sellingPrice: 5.0,
        paperCostPerSheet: 0.414,
      );
      expect(marginSingle['profit'], closeTo(4.586, 0.001));
      expect(marginSingle['marginPercent'], closeTo(91.72, 0.1));

      // Double Side: selling price ₹7, paper cost ₹0.414
      final marginDouble = ConsumablesService.calculatePhotostatMargin(
        sellingPrice: 7.0,
        paperCostPerSheet: 0.414,
      );
      expect(marginDouble['profit'], closeTo(6.586, 0.001));
      expect(marginDouble['marginPercent'], closeTo(94.08, 0.1));

      // When paper cost increases to ₹0.427
      final marginUpdated = ConsumablesService.calculatePhotostatMargin(
        sellingPrice: 5.0,
        paperCostPerSheet: 0.427,
      );
      expect(marginUpdated['profit'], closeTo(4.573, 0.001));
      expect(marginUpdated['marginPercent'], closeTo(91.46, 0.1));
    });

    test('PurchaseBillService saves bill, increments stock by 1,500 Sheets, and applies WAC', () async {
      // Pre-create item in Db.items with 500 sheets @ ₹0.40
      final itemKey = await Db.items.add({
        'name': 'A4 Paper 75 GSM',
        'category': 'Consumable / Raw Material',
        'itemType': 'Consumable',
        'isMultiUnit': true,
        'purchaseUnit': 'Bundle',
        'baseUnit': 'Sheet',
        'conversionFactor': 500,
        'purchaseRate': 200.0,
        'costPrice': 0.40,
        'stock': 500,
        'minStock': 200,
      });

      final billItem = PurchaseBillItem(
        itemKey: itemKey,
        itemName: 'A4 Paper 75 GSM',
        quantity: 3, // 3 Bundles = 1500 Sheets
        purchaseRate: 207.0, // ₹207 / bundle
        isMultiUnit: true,
        purchaseUnit: 'Bundle',
        baseUnit: 'Sheet',
        conversionFactor: 500,
      );

      await PurchaseBillService.instance.savePurchaseBill(
        billNumber: 'PB-2026-TEST',
        vendorInvoiceNumber: 'INV-ABC-99',
        vendorKey: 'vendor_abc',
        vendorName: 'ABC Company',
        vendorPhone: '9876543210',
        purchaseDate: DateTime.now(),
        items: [billItem],
        initialPaidAmount: 621.0,
        staffId: 'staff_1',
        staffName: 'Staff User',
      );

      // Verify item updated in Db.items
      final updatedItem = Map<String, dynamic>.from(Db.items.get(itemKey) as Map);
      // Stock should increment by 1500 sheets: 500 + 1500 = 2000 sheets
      expect(updatedItem['stock'], equals(2000));

      // WAC: (500 * 0.40 + 3 * 207) / 2000 = (200 + 621) / 2000 = 821 / 2000 = 0.4105
      expect(updatedItem['costPrice'], closeTo(0.4105, 0.001));
      expect(updatedItem['isMultiUnit'], isTrue);
      expect(updatedItem['purchaseUnit'], equals('Bundle'));
      expect(updatedItem['baseUnit'], equals('Sheet'));
    });
  });

  group('Requirement 4: Photostat Linking & Paper Auto-Deduction', () {
    test('Identifies Photostat & Printing service items accurately', () {
      expect(ConsumablesService.isPhotostatItem('Photostat - Single Side (₹5)'), isTrue);
      expect(ConsumablesService.isPhotostatItem('Photostat - Double Side (₹7)'), isTrue);
      expect(ConsumablesService.isPhotostatItem('Xerox Copy', 'Services'), isTrue);
      expect(ConsumablesService.isPhotostatItem('Color Print', 'Printing'), isTrue);
      expect(ConsumablesService.isPhotostatItem('Single Side Print'), isTrue);
      expect(ConsumablesService.isPhotostatItem('iPhone 15 Case', 'Cases'), isFalse);
    });

    test('Calculates total sheets to deduct from cart items', () {
      final cart = [
        {
          'name': 'Photostat - Single Side (₹5)',
          'category': 'Photostat / Printing',
          'qty': 10,
        },
        {
          'name': 'Photostat - Double Side (₹7)',
          'category': 'Photostat / Printing',
          'qty': 5,
        },
        {
          'name': 'Tempered Glass',
          'category': 'Accessories',
          'qty': 2,
        },
      ];

      final totalSheets = ConsumablesService.calculateTotalSheetsForCart(cart);
      // 10 sheets (Single side) + 5 sheets (Double side front & back) = 15 sheets
      expect(totalSheets, equals(15));
    });

    test('deductPaperSheets decrements A4 Paper stock balance in Db.items and logs stockMove', () async {
      // Setup initial paper stock = 1500 sheets
      await Db.items.clear();
      await Db.stockMoves.clear();
      final paperItem = await ConsumablesService.findOrCreateA4PaperItem();
      expect(paperItem['stock'], equals(1500));

      // Deduct 260 sheets (e.g. after customer print job)
      final remaining = await ConsumablesService.deductPaperSheets(260, reason: 'POS Sale #INV-101');
      expect(remaining, equals(1240));

      final refreshed = ConsumablesService.getA4PaperItem();
      expect(refreshed?['stock'], equals(1240));

      // Check stock move logged
      expect(Db.stockMoves.length, greaterThan(0));
      final move = Map<String, dynamic>.from(Db.stockMoves.values.last as Map);
      expect(move['delta'], equals(-260));
    });

    test('Detects low-stock warning threshold when paper falls below 200 sheets', () async {
      await Db.items.clear();
      final paperItem = await ConsumablesService.findOrCreateA4PaperItem();
      final key = paperItem['_key'];

      // Set stock to 180 sheets (< 200 threshold)
      paperItem['stock'] = 180;
      await Db.items.put(key, paperItem);

      final current = ConsumablesService.getA4PaperItem();
      final stock = (current?['stock'] as num?)?.toInt() ?? 0;
      final minStock = (current?['minStock'] as num?)?.toInt() ?? 200;

      final isLow = stock > 0 && stock <= minStock;
      expect(isLow, isTrue);
      expect(stock, equals(180));
    });
  });
}
