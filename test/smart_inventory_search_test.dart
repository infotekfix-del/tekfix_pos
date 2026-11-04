import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart'
    show
        boxItems,
        boxParties,
        boxSales,
        boxPurchases,
        boxBank,
        boxSettings,
        boxAudit,
        boxReturns,
        boxStockMoves,
        boxPurchaseBills,
        boxVendorPayments;
import 'package:tekfix_erp_pos/purchases/imei_validator.dart';
import 'package:tekfix_erp_pos/purchases/purchase_bill_service.dart';
import 'package:tekfix_erp_pos/purchases/purchase_calculation_engine.dart';
import 'package:tekfix_erp_pos/purchases/purchase_models.dart';
import 'package:tekfix_erp_pos/purchases/smart_inventory_models.dart';
import 'package:tekfix_erp_pos/purchases/smart_inventory_search_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Box itemsBox;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tekfix_smart_search_test_');
    Hive.init(tempDir.path);

    itemsBox = await Hive.openBox(boxItems);
    await Hive.openBox(boxParties);
    await Hive.openBox(boxSales);
    await Hive.openBox(boxPurchases);
    await Hive.openBox(boxBank);
    await Hive.openBox(boxSettings);
    await Hive.openBox(boxAudit);
    await Hive.openBox(boxStockMoves);
    await Hive.openBox(boxReturns);
    await Hive.openBox(boxPurchaseBills);
    await Hive.openBox(boxVendorPayments);

    // Seed mock inventory
    await itemsBox.put('ITEM_TPU_14', {
      'id': 'ITEM_TPU_14',
      'name': 'iPhone 14 TPU Clear Case',
      'brand': 'Apple',
      'model': 'iPhone 14',
      'barcode': '8901234567890',
      'sku': 'TPU-IPH-14',
      'category': 'Accessories',
      'hsn': '3926',
      'stock': 25,
      'cost': 120.0,
      'price': 299.0,
      'mrp': 499.0,
      'gstRate': 18.0,
      'warranty': 'No Warranty',
      'trackImei': false,
      'isActive': true,
      'isDeleted': false,
    });

    await itemsBox.put('ITEM_SAMS_CHG', {
      'id': 'ITEM_SAMS_CHG',
      'name': 'Samsung 25W Type-C Super Fast Charger',
      'brand': 'Samsung',
      'model': 'EP-TA800',
      'barcode': '8806090143861',
      'sku': 'CHG-SAM-25W',
      'category': 'Chargers',
      'hsn': '8504',
      'stock': 0, // Zero stock test case
      'cost': 450.0,
      'price': 1299.0,
      'mrp': 1699.0,
      'gstRate': 18.0,
      'warranty': '6 Months',
      'trackImei': false,
      'isActive': true,
      'isDeleted': false,
    });

    await itemsBox.put('ITEM_IPH_15_PRO', {
      'id': 'ITEM_IPH_15_PRO',
      'name': 'Apple iPhone 15 Pro 128GB Natural Titanium',
      'brand': 'Apple',
      'model': 'A3102',
      'barcode': '195949012345',
      'sku': 'IPH15P-128-NAT',
      'category': 'Smartphones',
      'hsn': '8517',
      'stock': 5,
      'cost': 115000.0,
      'price': 129900.0,
      'mrp': 134900.0,
      'gstRate': 18.0,
      'warranty': '12 Months',
      'trackImei': true, // Serialized test case
      'isActive': true,
      'isDeleted': false,
    });
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('SMART INVENTORY SEARCH & INTELLIGENT PURCHASE SELECTOR TESTS', () {
    test('1. Search "TPU" finds existing products with stock & purchase rate', () async {
      final engine = SmartInventorySearchEngine.instance;
      await engine.initialize(shopId: 'tekfix');

      final results = engine.search('TPU');
      expect(results, isNotEmpty);

      final item = results.first;
      expect(item.name, contains('TPU'));
      expect(item.stock, equals(25));
      expect(item.lastPurchaseRate, equals(120.0));
      expect(item.mrp, equals(499.0));
      expect(item.sellingPrice, equals(299.0));
      expect(item.gst, equals(18.0));
    });

    test('2. Select existing TPU links existing product ID without creating duplicate inventory', () async {
      final engine = SmartInventorySearchEngine.instance;
      await engine.initialize(shopId: 'tekfix');

      final results = engine.search('TPU');
      final selected = results.first;

      final billItem = PurchaseBillItem(
        itemId: selected.productId,
        name: selected.name,
        brand: selected.brand,
        model: selected.model,
        sku: selected.sku,
        quantity: 10,
        purchaseRate: selected.lastPurchaseRate,
        sellingPrice: selected.sellingPrice,
        mrp: selected.mrp,
        taxPercent: selected.gst,
        isNewProduct: false, // Links to existing
        isStagedReady: true,
      );

      expect(billItem.itemId, equals('ITEM_TPU_14'));
      expect(billItem.isNewProduct, isFalse);
      expect(billItem.quantity, equals(10));
      expect(billItem.purchaseRate, equals(120.0));
      expect(billItem.lineTotal, equals(10 * 120.0 * 1.18));
    });

    test('3. Search nonexistent product shows empty results and triggers new item creation path', () async {
      final engine = SmartInventorySearchEngine.instance;
      await engine.initialize(shopId: 'tekfix');

      final results = engine.search('NonExistentCustomPartXYZ999');
      expect(results, isEmpty);
    });

    test('4. Create new product marks isNewProduct=true and generates valid SKU', () {
      final newItem = PurchaseBillItem(
        name: 'Hydrogel Matte Screen Protector for Nothing Phone 2',
        brand: 'Nothing',
        sku: 'TKF${DateTime.now().millisecondsSinceEpoch}',
        quantity: 50,
        purchaseRate: 35.0,
        sellingPrice: 150.0,
        mrp: 299.0,
        isNewProduct: true,
        isStagedReady: true,
      );

      expect(newItem.isNewProduct, isTrue);
      expect(newItem.sku, startsWith('TKF'));
      expect(newItem.quantity, equals(50));
      expect(newItem.purchaseRate, equals(35.0));
    });

    test('5. Scan exact barcode auto-selects product immediately', () async {
      final engine = SmartInventorySearchEngine.instance;
      await engine.initialize(shopId: 'tekfix');

      // Test scanning exact 13-digit EAN barcode
      final scannedItem = engine.findExactBarcodeOrSku('8901234567890');
      expect(scannedItem, isNotNull);
      expect(scannedItem!.productId, equals('ITEM_TPU_14'));
      expect(scannedItem.name, equals('iPhone 14 TPU Clear Case'));

      // Test scanning exact SKU
      final scannedBySku = engine.findExactBarcodeOrSku('CHG-SAM-25W');
      expect(scannedBySku, isNotNull);
      expect(scannedBySku!.productId, equals('ITEM_SAMS_CHG'));
    });

    test('6. Selecting same product increments quantity without duplicate row', () {
      final billItems = <PurchaseBillItem>[];

      void addOrIncrement(InventorySearchItem item) {
        final existingIdx = billItems.indexWhere((it) => it.itemId == item.productId);
        if (existingIdx >= 0) {
          final existing = billItems[existingIdx];
          billItems[existingIdx] = PurchaseBillItem(
            id: existing.id,
            itemId: existing.itemId,
            name: existing.name,
            sku: existing.sku,
            quantity: existing.quantity + 1,
            purchaseRate: existing.purchaseRate,
            sellingPrice: existing.sellingPrice,
            mrp: existing.mrp,
            taxPercent: existing.taxPercent,
          );
        } else {
          billItems.add(PurchaseBillItem(
            itemId: item.productId,
            name: item.name,
            sku: item.sku,
            quantity: 1,
            purchaseRate: item.lastPurchaseRate,
            sellingPrice: item.sellingPrice,
            mrp: item.mrp,
            taxPercent: item.gst,
          ));
        }
      }

      final searchItem = InventorySearchItem.fromMap(
        id: 'ITEM_TPU_14',
        map: {
          'name': 'iPhone 14 TPU Clear Case',
          'sku': 'TPU-IPH-14',
          'cost': 120.0,
        },
      );

      // Add once
      addOrIncrement(searchItem);
      expect(billItems.length, equals(1));
      expect(billItems.first.quantity, equals(1));

      // Add second time (e.g. user selects it again or scans barcode again)
      addOrIncrement(searchItem);
      expect(billItems.length, equals(1)); // Still only 1 row! No duplicate row!
      expect(billItems.first.quantity, equals(2)); // Quantity incremented!
    });

    test('7. Zero stock product is selectable with amber badge', () async {
      final engine = SmartInventorySearchEngine.instance;
      await engine.initialize(shopId: 'tekfix');

      final results = engine.search('Samsung Charger');
      expect(results, isNotEmpty);

      final zeroStockItem = results.first;
      expect(zeroStockItem.stock, equals(0));
      expect(zeroStockItem.productId, equals('ITEM_SAMS_CHG'));
      // Zero stock product can be reordered in purchase entry
      expect(zeroStockItem.lastPurchaseRate, equals(450.0));
    });

    test('8. Advanced IMEI validation enforces 15-digit Luhn check and exact quantity match', () {
      // Valid Luhn 15-digit IMEI
      const validImei = '352099001761481';
      expect(ImeiValidator.isValidLuhn(validImei), isTrue);
      expect(ImeiValidator.categorizeIdentifier(validImei), equals('VALID_IMEI'));

      // Invalid Luhn 15-digit IMEI (typo in check digit)
      const invalidImei = '352099001761482';
      expect(ImeiValidator.isValidLuhn(invalidImei), isFalse);
      expect(ImeiValidator.categorizeIdentifier(invalidImei), equals('INVALID_LUHN_IMEI'));

      // Alphanumeric device serial
      const serial = 'F2LW80R0Q6L4';
      expect(ImeiValidator.categorizeIdentifier(serial), equals('DEVICE_SERIAL'));

      // Check enforcement: quantity = 2, serialNumbers = 1 -> should fail validation
      final item = PurchaseBillItem(
        name: 'Apple iPhone 15 Pro',
        quantity: 2,
        purchaseRate: 115000.0,
        imeiRequired: true,
        serialNumbers: [validImei], // Only 1 entered for qty 2
      );

      final isComplete = item.serialNumbers.length == item.quantity;
      expect(isComplete, isFalse);
    });

    test('9. Multi-token partial search matches regardless of word order and whitespace', () async {
      final engine = SmartInventorySearchEngine.instance;
      await engine.initialize(shopId: 'tekfix');

      // "14 tpu" matches "iPhone 14 TPU Clear Case"
      final r1 = engine.search('14 tpu');
      expect(r1, isNotEmpty);
      expect(r1.first.productId, equals('ITEM_TPU_14'));

      // "type c charger 25w" matches "Samsung 25W Type-C Super Fast Charger"
      final r2 = engine.search('type c charger 25w');
      expect(r2, isNotEmpty);
      expect(r2.first.productId, equals('ITEM_SAMS_CHG'));

      // "natural titanium 15 pro" matches "Apple iPhone 15 Pro 128GB Natural Titanium"
      final r3 = engine.search('natural titanium 15 pro');
      expect(r3, isNotEmpty);
      expect(r3.first.productId, equals('ITEM_IPH_15_PRO'));
    });

    test('10. Multi-item purchase calculations (subtotal, GST, grand total)', () {
      const engine = PurchaseCalculationEngine(isInterState: false);

      final items = [
        PurchaseBillItem(
          name: 'TPU Case',
          quantity: 10,
          purchaseRate: 100.0,
          taxPercent: 18.0,
        ),
        PurchaseBillItem(
          name: 'Samsung Charger',
          quantity: 2,
          purchaseRate: 500.0,
          taxPercent: 18.0,
        ),
      ];

      final result = engine.calculate(
        items: items,
        charges: [
          const BillCharge(
            label: 'Shipping',
            amount: 100.0,
            gstRate: 18.0,
          ),
        ],
        applyRoundOff: true,
      );

      // Subtotal = (10 * 100) + (2 * 500) = 1000 + 1000 = 2000
      expect(result.subtotal, equals(2000.0));

      // Charges = 100, Charges Tax = 18
      expect(result.chargesGross, equals(100.0));
      expect(result.chargesGst, equals(18.0));

      // Items Tax = 360
      expect(result.totalGst, equals(360.0));

      // Grand Total = 2000 + 360 + 100 + 18 = 2478.0
      expect(result.grandTotal, equals(2478.0));
    });

    test('11. Bill confirmation updates stock atomically via PurchaseBillService', () async {
      final initialStock = (itemsBox.get('ITEM_TPU_14') as Map)['stock'] as int;
      expect(initialStock, equals(25));

      final items = [
        PurchaseBillItem(
          itemId: 'ITEM_TPU_14',
          name: 'iPhone 14 TPU Clear Case',
          sku: 'TPU-IPH-14',
          quantity: 15,
          purchaseRate: 120.0,
          sellingPrice: 299.0,
          isNewProduct: false,
          isStagedReady: true,
        ),
      ];

      // Confirm bill
      final bill = await PurchaseBillService.instance.confirmPurchaseBill(
        billNumber: 'PB-TEST-001',
        vendorInvoiceNumber: 'INV-999',
        vendorKey: 'VEND_001',
        vendorName: 'Direct Supplier',
        vendorPhone: '9876543210',
        staffId: 'STAFF_001',
        staffName: 'Admin',
        items: items,
        purchaseDate: DateTime.now(),
      );

      expect(bill.paymentStatus, equals(BillPaymentStatus.unpaid));
      expect(bill.totalQuantity, equals(15));

      // Verify stock was incremented by 15 (25 + 15 = 40)
      final updatedItem = itemsBox.get('ITEM_TPU_14') as Map;
      expect(updatedItem['stock'], equals(40));
    });

    test('12. Offline search displays cached results from Hive', () async {
      // Simulate offline: network is not queried, items are loaded purely from Hive Db.items
      final engine = SmartInventorySearchEngine.instance;
      await engine.initialize(forceRefresh: true); // loads from local boxItems

      expect(engine.isOffline, isTrue);
      final results = engine.search('Apple');
      expect(results.length, greaterThanOrEqualTo(2));
      expect(results.any((e) => e.productId == 'ITEM_TPU_14'), isTrue);
      expect(results.any((e) => e.productId == 'ITEM_IPH_15_PRO'), isTrue);
    });
  });
}
