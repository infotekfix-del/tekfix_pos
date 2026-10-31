import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/purchases/purchase_bill_service.dart';
import 'package:tekfix_erp_pos/purchases/purchase_models.dart';

void main() {
  group('Unified Item Addition & Auto Barcode Generation Tests', () {
    late Directory tempDir;

    setUpAll(() async {
      tempDir = await Directory.systemTemp.createTemp('direct_item_test_hive_');
      Hive.init(tempDir.path);

      for (final b in allBoxes) {
        await Hive.openBox(b);
      }

      final settingsBox = Hive.box(boxSettings);
      await settingsBox.put('store_state_code', '32');
      await settingsBox.put('shop_id', 'test_shop_direct');
    });

    tearDownAll(() async {
      try {
        await Hive.close();
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    test('Purchase bill item with blank barcode auto-generates TKF barcode and saves directly without Quick Register block', () async {
      final vendorKey = await Db.parties.add({
        'name': 'Direct Tech Wholesale',
        'phone': '9847123456',
        'gstin': '32AABCT1234E1Z5',
        'state': 'Kerala',
        'state_code': '32',
      });

      // Item created directly without pre-existing catalog entry or barcode
      final item1 = PurchaseBillItem(
        id: 'ROW_DIRECT_1',
        name: 'AMOLED Display iPhone 14 Pro Max',
        quantity: 5,
        purchaseRate: 7500.0,
        sellingPrice: 9900.0,
        mrp: 12000.0,
        taxPercent: 18.0,
        taxAmount: (5 * 7500.0) * 0.18,
        lineTotal: (5 * 7500.0) * 1.18,
        isNewProduct: true,
        isStagedReady: true, // Directly ready, no Quick Register needed!
        warrantyDuration: '6 Months',
      );

      final bill = await PurchaseBillService.instance.confirmPurchaseBill(
        billNumber: 'PB-2026-DIR01',
        vendorInvoiceNumber: 'INV-DIR-001',
        vendorKey: vendorKey,
        vendorName: 'Direct Tech Wholesale',
        vendorPhone: '9847123456',
        purchaseDate: DateTime.now(),
        items: [item1],
        initialPaidAmount: 0.0,
        staffId: 'ADMIN_1',
        staffName: 'Admin',
      );

      expect(bill, isNotNull);
      expect(bill.items.length, equals(1));
      expect(bill.items.first.name, equals('AMOLED Display iPhone 14 Pro Max'));
      expect(bill.items.first.warrantyDuration, equals('6 Months'));
      expect(bill.items.first.quantity, equals(5));

      // Verify item was created directly in Db.items with stock and auto-generated TKF barcode
      dynamic foundKey;
      Map? foundItem;
      for (final k in Db.items.keys) {
        final raw = Db.items.get(k);
        if (raw is Map && raw['name'] == 'AMOLED Display iPhone 14 Pro Max') {
          foundKey = k;
          foundItem = raw;
          break;
        }
      }

      expect(foundKey, isNotNull);
      expect(foundItem, isNotNull);
      expect(foundItem!['stock'], equals(5));
      expect(foundItem['costPrice'], equals(7500.0));
      expect(foundItem['warranty'], equals('6 Months'));
      expect(foundItem['barcode'], isNotEmpty);
      expect(foundItem['barcode'].toString().startsWith('TKF'), isTrue);
    });

    test('Modifying item details inline updates bill correctly without requiring Quick Register', () async {
      final vendorKey = await Db.parties.add({
        'name': 'Anker Accessories Dist.',
        'phone': '9847999888',
        'state_code': '32',
      });

      final item = PurchaseBillItem(
        id: 'ROW_DIRECT_2',
        name: 'Anker PowerBank 20000mAh',
        sku: '', // Blank barcode
        quantity: 10,
        purchaseRate: 2200.0,
        sellingPrice: 3200.0,
        taxPercent: 18.0,
        taxAmount: (10 * 2200.0) * 0.18,
        lineTotal: (10 * 2200.0) * 1.18,
        isNewProduct: true,
        isStagedReady: true,
        warrantyDuration: 'No Warranty',
      );

      final originalBill = await PurchaseBillService.instance.confirmPurchaseBill(
        billNumber: 'PB-2026-DIR02',
        vendorInvoiceNumber: 'INV-DIR-002',
        vendorKey: vendorKey,
        vendorName: 'Anker Accessories Dist.',
        vendorPhone: '9847999888',
        purchaseDate: DateTime.now(),
        items: [item],
        initialPaidAmount: 0.0,
        staffId: 'ADMIN_1',
        staffName: 'Admin',
      );

      // Now update the bill inline: change quantity to 15, rate to 2100, warranty to 12 Months
      final updatedItem = item.copyWith(
        quantity: 15,
        purchaseRate: 2100.0,
        warrantyDuration: '12 Months',
        isStagedReady: true,
      );

      final updatedBill = await PurchaseBillService.instance.updateConfirmedPurchaseBill(
        originalBill: originalBill,
        vendorInvoiceNumber: 'INV-DIR-002-REV',
        vendorKey: vendorKey,
        vendorName: 'Anker Accessories Dist.',
        vendorPhone: '9847999888',
        purchaseDate: DateTime.now(),
        staffId: 'ADMIN_1',
        staffName: 'Admin',
        items: [updatedItem],
        notes: 'Updated directly inline',
      );

      expect(updatedBill.items.first.quantity, equals(15));
      expect(updatedBill.items.first.purchaseRate, equals(2100.0));
      expect(updatedBill.items.first.warrantyDuration, equals('12 Months'));
      expect(updatedBill.vendorInvoiceNumber, equals('INV-DIR-002-REV'));
    });
  });
}
