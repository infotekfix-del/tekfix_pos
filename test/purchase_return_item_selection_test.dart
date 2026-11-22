import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/purchases/purchase_bill_service.dart';
import 'package:tekfix_erp_pos/purchases/purchase_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;
  final svc = PurchaseBillService.instance;

  setUpAll(() async {
    PurchaseBillService.ownerCheckForTesting = true;
    tempDir = await Directory.systemTemp.createTemp('tekfix_purchase_return_test_');
    Hive.init(tempDir.path);
    for (final b in allBoxes) {
      await Hive.openBox(b);
    }
    await Hive.box(boxSettings).put('shop_id', 'test_shop_return');
  });

  tearDownAll(() async {
    PurchaseBillService.ownerCheckForTesting = null;
    try {
      await Hive.close();
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('Purchase Return with Item Selection and Stock Reduction', () {
    test('recordPurchaseReturn reduces stock and records stock movement for returned items', () async {
      // 1. Create product in Db.items with initial stock 10
      final itemKey = await Db.items.add({
        'name': 'Samsung Screen',
        'barcode': 'SAM-SCR-001',
        'stock': 10,
        'costPrice': 1500.0,
        'sellingPrice': 2200.0,
      });

      // 2. Create supplier with initial balance -15000 (we owe 15,000)
      final vendorKey = await Db.parties.add({
        'name': 'Screen Depot',
        'phone': '9876543220',
        'type': 'Supplier',
        'balance': -15000.0,
      });

      // 3. Confirm purchase bill with 5 screens
      final bill = await svc.confirmPurchaseBill(
        billNumber: 'PB-RET-001',
        vendorInvoiceNumber: 'INV-RET-001',
        vendorKey: vendorKey,
        vendorName: 'Screen Depot',
        vendorPhone: '9876543220',
        purchaseDate: DateTime(2026, 11, 22),
        items: [
          PurchaseBillItem(
            id: 'scr_1',
            itemKey: itemKey,
            itemId: '$itemKey',
            name: 'Samsung Screen',
            quantity: 5,
            purchaseRate: 1500.0,
          ),
        ],
        staffId: 'S1',
        staffName: 'Owner',
      );

      // Stock should now be 10 + 5 = 15
      final stockAfterConfirm = (Db.items.get(itemKey) as Map)['stock'];
      expect(stockAfterConfirm, 15);

      // 4. Return 2 screens out of 5 with Credit Note
      final returnItem = PurchaseBillItem(
        id: 'scr_1',
        itemKey: itemKey,
        itemId: '$itemKey',
        name: 'Samsung Screen',
        quantity: 2,
        purchaseRate: 1500.0,
      );

      final paymentRecord = await svc.recordPurchaseReturn(
        vendorKey: vendorKey,
        vendorName: 'Screen Depot',
        billKey: bill.key,
        billNumber: bill.billNumber,
        returnAmountPaise: 300000, // ₹3,000.00
        returnReference: 'PR-RET-001',
        reason: 'Defective touch layer',
        paymentMethod: 'Credit Note',
        items: [returnItem],
        staffId: 'S1',
        staffName: 'Owner',
      );

      expect(paymentRecord.isReturn, isTrue);
      expect(paymentRecord.amount, 3000.0);

      // 5. Stock must be reduced from 15 to 13
      final stockAfterReturn = (Db.items.get(itemKey) as Map)['stock'];
      expect(stockAfterReturn, 13);

      // 6. Stock movement must be recorded
      final stockMoves = Db.stockMoves.values.toList();
      final returnMove = stockMoves.where((m) =>
          (m as Map)['reason']?.toString().contains('PR-RET-001') ?? false).firstOrNull;
      expect(returnMove, isNotNull);
      expect((returnMove as Map)['delta'], -2);

      // 7. Vendor balance should have increased by ₹3,000 (from -22,500 to -19,500)
      final vendor = Db.parties.get(vendorKey) as Map;
      expect((vendor['balance'] as num).toDouble(), -19500.0);
    });

    test('recordPurchaseReturn allows amount lower than item sum (e.g. restocking fee)', () async {
      final itemKey = await Db.items.add({
        'name': 'Tempered Glass',
        'barcode': 'TG-001',
        'stock': 20,
        'costPrice': 50.0,
        'sellingPrice': 100.0,
      });

      final vendorKey = await Db.parties.add({
        'name': 'Glass Supplier',
        'phone': '9876543221',
        'type': 'Supplier',
        'balance': 0.0,
      });

      final bill = await svc.confirmPurchaseBill(
        billNumber: 'PB-RET-002',
        vendorInvoiceNumber: 'INV-RET-002',
        vendorKey: vendorKey,
        vendorName: 'Glass Supplier',
        vendorPhone: '9876543221',
        purchaseDate: DateTime(2026, 11, 22),
        items: [
          PurchaseBillItem(
            id: 'tg_1',
            itemKey: itemKey,
            itemId: '$itemKey',
            name: 'Tempered Glass',
            quantity: 10,
            purchaseRate: 50.0,
          ),
        ],
        staffId: 'S1',
        staffName: 'Owner',
      );

      // Return 4 glasses (sum = ₹200), but credit note accepted is ₹180 (₹20 handling charge)
      final paymentRecord = await svc.recordPurchaseReturn(
        vendorKey: vendorKey,
        vendorName: 'Glass Supplier',
        billKey: bill.key,
        billNumber: bill.billNumber,
        returnAmountPaise: 18000, // ₹180.00
        returnReference: 'PR-RET-002',
        reason: 'Surplus return with 10% restocking deduction',
        paymentMethod: 'Credit Note',
        items: [
          PurchaseBillItem(
            id: 'tg_1',
            itemKey: itemKey,
            itemId: '$itemKey',
            name: 'Tempered Glass',
            quantity: 4,
            purchaseRate: 50.0,
          ),
        ],
        staffId: 'S1',
        staffName: 'Owner',
      );

      expect(paymentRecord.amount, 180.0);
      final stockAfter = (Db.items.get(itemKey) as Map)['stock'];
      // Original 20 + 10 = 30; after returning 4 = 26
      expect(stockAfter, 26);
    });

    test('recordPurchaseReturn throws if return exceeds bill total', () async {
      final vendorKey = await Db.parties.add({
        'name': 'Limit Supplier',
        'phone': '9876543222',
        'type': 'Supplier',
        'balance': 0.0,
      });

      final bill = await svc.confirmPurchaseBill(
        billNumber: 'PB-RET-003',
        vendorInvoiceNumber: 'INV-RET-003',
        vendorKey: vendorKey,
        vendorName: 'Limit Supplier',
        vendorPhone: '9876543222',
        purchaseDate: DateTime(2026, 11, 22),
        items: [
          PurchaseBillItem(
            id: 'lim_1',
            name: 'Limit Item',
            quantity: 1,
            purchaseRate: 100.0,
          ),
        ],
        staffId: 'S1',
        staffName: 'Owner',
      );

      expect(
        () => svc.recordPurchaseReturn(
          vendorKey: vendorKey,
          vendorName: 'Limit Supplier',
          billKey: bill.key,
          billNumber: bill.billNumber,
          returnAmountPaise: 15000, // ₹150 > ₹100
          staffId: 'S1',
          staffName: 'Owner',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
