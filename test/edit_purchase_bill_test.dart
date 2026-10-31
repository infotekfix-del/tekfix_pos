import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/purchases/purchase_bill_service.dart';
import 'package:tekfix_erp_pos/purchases/purchase_models.dart';

void main() {
  group('Edit Purchase Bill & Inventory Reconciliation Tests', () {
    late Directory tempDir;

    setUpAll(() async {
      tempDir = await Directory.systemTemp.createTemp('edit_purchase_test_hive_');
      Hive.init(tempDir.path);

      for (final b in allBoxes) {
        await Hive.openBox(b);
      }

      final settingsBox = Hive.box(boxSettings);
      await settingsBox.put('store_state_code', '32');
      await settingsBox.put('shop_id', 'test_shop');
    });

    tearDownAll(() async {
      try {
        await Hive.close();
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    test('Confirm purchase bill then edit warranty, quantity, and prices with stock reconciliation', () async {
      // 1. Create a product in Db.items
      final prodKey = await Db.items.add({
        'name': 'Samsung Galaxy S24 Ultra',
        'sku': 'SAM-S24U-256',
        'barcode': '8806091234567',
        'stock': 10,
        'costPrice': 80000.0,
        'sellingPrice': 95000.0,
        'mrp': 109999.0,
        'warranty': 'No Warranty',
      });

      // 2. Create a vendor in Db.parties
      final vendorKey = await Db.parties.add({
        'name': 'Samsung India Electronics Pvt Ltd',
        'phone': '9847012345',
        'balance': 0.0,
      });

      // 3. Confirm an initial purchase bill (Qty: 5, No Warranty, unpaid)
      final initialItem = PurchaseBillItem(
        id: 'item_1',
        itemKey: prodKey,
        name: 'Samsung Galaxy S24 Ultra',
        sku: 'SAM-S24U-256',
        quantity: 5,
        purchaseRate: 80000.0,
        taxPercent: 18.0,
        mrp: 109999.0,
        sellingPrice: 95000.0,
        warrantyDuration: 'No Warranty',
      );

      final confirmedBill = await PurchaseBillService.instance.confirmPurchaseBill(
        billNumber: 'PB-2026-TEST01',
        vendorInvoiceNumber: 'INV-SAM-001',
        vendorKey: vendorKey,
        vendorName: 'Samsung India Electronics Pvt Ltd',
        vendorPhone: '9847012345',
        purchaseDate: DateTime(2026, 3, 1),
        items: [initialItem],
        initialPaidAmount: 0.0,
        staffId: 'STAFF_01',
        staffName: 'Admin',
      );

      // Verify initial state:
      // Stock should have increased from 10 to 15 (+5)
      var itemData = Db.items.get(prodKey) as Map;
      expect(itemData['stock'], equals(15));
      expect(itemData['warranty'], equals('No Warranty'));
      expect(confirmedBill.grandTotal, equals(472000.0)); // 5 * 80000 = 400000 + 18% = 472000
      expect(confirmedBill.balanceDue, equals(472000.0));

      // Vendor debt should be -472000.0
      var partyData = Db.parties.get(vendorKey) as Map;
      expect(partyData['balance'], equals(-472000.0));

      // 4. NOW EDIT THE BILL:
      // - Change quantity from 5 to 7 (stock diff: +2)
      // - Change warranty from 'No Warranty' to '12 Months'
      // - Update vendor invoice number to 'INV-SAM-001-REV1'
      // - Add bill notes
      final editedItem = initialItem.copyWith(
        quantity: 7,
        warrantyDuration: '12 Months',
        taxPercent: 18.0,
        lineTotal: 7 * 80000.0 * 1.18,
      );

      final updatedBill = await PurchaseBillService.instance.updateConfirmedPurchaseBill(
        originalBill: confirmedBill,
        vendorInvoiceNumber: 'INV-SAM-001-REV1',
        vendorKey: vendorKey,
        vendorName: 'Samsung India Electronics Pvt Ltd',
        vendorPhone: '9847012345',
        purchaseDate: DateTime(2026, 3, 1),
        items: [editedItem],
        staffId: 'STAFF_01',
        staffName: 'Admin',
        notes: 'Updated warranty to 12 months & increased qty to 7',
      );

      // 5. VERIFY RECONCILIATION:
      // A. Stock reconciliation:
      // Stock was 15, should now be 17 (10 initial + 7 new = 17)
      itemData = Db.items.get(prodKey) as Map;
      expect(itemData['stock'], equals(17));

      // B. Warranty reconciliation:
      // Item in Db.items must now have warranty updated to '12 Months'
      expect(itemData['warranty'], equals('12 Months'));
      expect(updatedBill.items.first.warrantyDuration, equals('12 Months'));
      expect(updatedBill.items.first.warrantyAvailable, isTrue);
      expect(updatedBill.items.first.warrantyExpiryDate, isNotNull);

      // C. Totals & GST Recalculation:
      // 7 * 80000 = 560000 + 18% GST (100800) = 660800
      expect(updatedBill.subtotal, equals(560000.0));
      expect(updatedBill.totalTax, equals(100800.0));
      expect(updatedBill.grandTotal, equals(660800.0));
      expect(updatedBill.balanceDue, equals(660800.0));
      expect(updatedBill.vendorInvoiceNumber, equals('INV-SAM-001-REV1'));
      expect(updatedBill.notes, contains('Updated warranty'));

      // D. Vendor Ledger Reconciliation:
      // Previous debt: 472000, new debt: 660800 -> party balance should now be -660800.0
      partyData = Db.parties.get(vendorKey) as Map;
      expect(partyData['balance'], equals(-660800.0));

      // E. Hive persistence:
      final persistedBill = PurchaseBillService.instance.getPurchaseBill(confirmedBill.billNumber);
      expect(persistedBill, isNotNull);
      expect(persistedBill!.grandTotal, equals(660800.0));
      expect(persistedBill.items.first.quantity, equals(7));
      expect(persistedBill.items.first.warrantyDuration, equals('12 Months'));
    });

    test('Edit purchase bill with item quantity reduction and item removal', () async {
      // 1. Setup item in Db.items with initial stock 20
      final prodKey = await Db.items.add({
        'name': 'Apple AirPods Pro 2',
        'sku': 'APP-APP2',
        'stock': 20,
        'costPrice': 18000.0,
      });

      final vendorKey = await Db.parties.add({
        'name': 'Apple Authorised Distributor',
        'balance': 0.0,
      });

      // Confirm purchase of 10 units (stock becomes 30)
      final bill = await PurchaseBillService.instance.confirmPurchaseBill(
        billNumber: 'PB-2026-TEST02',
        vendorInvoiceNumber: 'INV-APP-099',
        vendorKey: vendorKey,
        vendorName: 'Apple Authorised Distributor',
        vendorPhone: '9847099999',
        purchaseDate: DateTime(2026, 3, 2),
        items: [
          PurchaseBillItem(
            id: 'item_airpods',
            itemKey: prodKey,
            name: 'Apple AirPods Pro 2',
            sku: 'APP-APP2',
            quantity: 10,
            purchaseRate: 18000.0,
            taxPercent: 18.0,
          ),
        ],
        staffId: 'STAFF_01',
        staffName: 'Admin',
      );

      var item = Db.items.get(prodKey) as Map;
      expect(item['stock'], equals(30));

      // Now edit: reduce quantity from 10 to 4 (diff: -6)
      final updatedBill = await PurchaseBillService.instance.updateConfirmedPurchaseBill(
        originalBill: bill,
        vendorInvoiceNumber: 'INV-APP-099-MOD',
        vendorKey: vendorKey,
        vendorName: 'Apple Authorised Distributor',
        vendorPhone: '9847099999',
        purchaseDate: DateTime(2026, 3, 2),
        items: [
          PurchaseBillItem(
            id: 'item_airpods',
            itemKey: prodKey,
            name: 'Apple AirPods Pro 2',
            sku: 'APP-APP2',
            quantity: 4,
            purchaseRate: 18000.0,
            taxPercent: 18.0,
          ),
        ],
        staffId: 'STAFF_01',
        staffName: 'Admin',
      );

      // Verify stock decreased from 30 to 24 (20 initial + 4 new = 24)
      item = Db.items.get(prodKey) as Map;
      expect(item['stock'], equals(24));
      expect(updatedBill.totalQuantity, equals(4));
    });
  });
}

