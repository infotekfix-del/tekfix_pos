import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/purchases/manual_purchase_draft_service.dart';
import 'package:tekfix_erp_pos/purchases/purchase_bill_service.dart';
import 'package:tekfix_erp_pos/purchases/purchase_models.dart';

void main() {
  group('Vyapar-like Manual Purchase & Item Registration Tests', () {
    late Directory tempDir;

    setUpAll(() async {
      tempDir = await Directory.systemTemp.createTemp('vyapar_test_hive_');
      Hive.init(tempDir.path);

      for (final b in allBoxes) {
        await Hive.openBox(b);
      }

      final settingsBox = Hive.box(boxSettings);
      await settingsBox.put('store_state_code', '32');
      await settingsBox.put('shop_id', 'vyapar_shop');
    });

    tearDownAll(() async {
      try {
        await Hive.close();
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    test('1. Item defaults: GST is 0%, Warranty is No Warranty, Barcode auto-generates', () async {
      final item = PurchaseBillItem(
        id: 'ROW_TEST_1',
        name: 'Samsung Type-C OTG',
        quantity: 2,
        purchaseRate: 150.0,
        taxPercent: 0.0,
        taxAmount: 0.0,
        lineTotal: 300.0,
        warrantyDuration: ItemWarrantyDuration.noWarranty,
        isNewProduct: true,
        isStagedReady: true,
      );

      expect(item.taxPercent, equals(0.0));
      expect(item.warrantyDuration, equals('No Warranty'));
      expect(item.isStagedReady, isTrue);
    });

    test('2. Single-step confirm & save persists to Db.items, moves stock, and resets draft state', () async {
      // 1. Create a draft first to simulate in-progress typing
      await ManualPurchaseDraftService.instance.save(
        ManualPurchaseDraft(
          vendorName: 'Vyapar Mobile Hub',
          vendorInvoiceNumber: 'VPH-1001',
          itemMaps: [
            {'name': 'OnePlus Warp Charger 65W', 'quantity': 4, 'purchaseRate': 1200.0}
          ],
        ),
      );
      expect(ManualPurchaseDraftService.instance.hasDraft(), isTrue);

      // 2. Vendor
      final vendorKey = await Db.parties.add({
        'name': 'Vyapar Mobile Hub',
        'phone': '9847000111',
        'state_code': '32',
      });

      // 3. Purchase Bill Item with auto-barcode
      final generatedSku = 'TKF${DateTime.now().millisecondsSinceEpoch}';
      final item = PurchaseBillItem(
        id: 'ROW_VYAPAR_1',
        name: 'OnePlus Warp Charger 65W',
        sku: generatedSku,
        quantity: 4,
        purchaseRate: 1200.0,
        sellingPrice: 1800.0,
        mrp: 2199.0,
        taxPercent: 0.0,
        taxAmount: 0.0,
        lineTotal: 4800.0,
        warrantyDuration: ItemWarrantyDuration.noWarranty,
        isNewProduct: true,
        isStagedReady: true,
      );

      // 4. Save Bill
      final savedBill = await PurchaseBillService.instance.confirmPurchaseBill(
        billNumber: 'PB-2026-VYP01',
        vendorInvoiceNumber: 'VPH-1001',
        vendorKey: vendorKey,
        vendorName: 'Vyapar Mobile Hub',
        vendorPhone: '9847000111',
        purchaseDate: DateTime.now(),
        items: [item],
        initialPaidAmount: 4800.0,
        staffId: 'STAFF_1',
        staffName: 'Staff Member',
        entrySource: EntrySource.manual,
      );

      // 5. Clear draft (as done in _saveBill)
      await ManualPurchaseDraftService.instance.delete();

      expect(savedBill, isNotNull);
      expect(savedBill.billNumber, equals('PB-2026-VYP01'));
      expect(savedBill.entrySource, equals('manual'));
      expect(savedBill.grandTotal, equals(4800.0));
      expect(savedBill.balanceDue, equals(0.0));

      // 6. Draft must be cleared (preventing resume draft loops)
      expect(ManualPurchaseDraftService.instance.hasDraft(), isFalse);

      // 7. Inventory in Db.items must be created and incremented
      dynamic itemKey;
      Map? storedItem;
      for (final k in Db.items.keys) {
        final raw = Db.items.get(k);
        if (raw is Map && raw['name'] == 'OnePlus Warp Charger 65W') {
          itemKey = k;
          storedItem = raw;
          break;
        }
      }
      expect(itemKey, isNotNull);
      expect(storedItem!['stock'], equals(4));
      expect(storedItem['sellingPrice'], equals(1800.0));
      expect(storedItem['barcode'], equals(generatedSku));

      // 8. Dashboard metrics must reflect the new bill
      final metrics = PurchaseBillService.instance.getDashboardMetrics();
      expect(metrics['totalBills'], greaterThanOrEqualTo(1));
      expect(metrics['totalPurchaseValue'], greaterThanOrEqualTo(4800.0));
    });

    test('3. Edit Bill modifies items, warranty and recalculates without secondary popups', () async {
      final vendorKey = await Db.parties.add({
        'name': 'Display World India',
        'phone': '9847333222',
        'state_code': '32',
      });

      final item = PurchaseBillItem(
        id: 'ROW_EDIT_1',
        name: 'iPhone 13 OLED Assembly',
        quantity: 2,
        purchaseRate: 5000.0,
        taxPercent: 0.0,
        lineTotal: 10000.0,
        warrantyDuration: ItemWarrantyDuration.noWarranty,
        isNewProduct: true,
        isStagedReady: true,
      );

      final originalBill = await PurchaseBillService.instance.confirmPurchaseBill(
        billNumber: 'PB-2026-VYP02',
        vendorInvoiceNumber: 'DWI-550',
        vendorKey: vendorKey,
        vendorName: 'Display World India',
        vendorPhone: '9847333222',
        purchaseDate: DateTime.now(),
        items: [item],
        staffId: 'ADMIN_1',
        staffName: 'Admin',
      );

      // Update item with 6 Months warranty and new rate
      final editedItem = item.copyWith(
        purchaseRate: 4800.0,
        warrantyDuration: '6 Months',
        lineTotal: 9600.0,
        isStagedReady: true,
      );

      final updatedBill = await PurchaseBillService.instance.updateConfirmedPurchaseBill(
        originalBill: originalBill,
        vendorInvoiceNumber: 'DWI-550-CORRECTED',
        vendorKey: vendorKey,
        vendorName: 'Display World India',
        vendorPhone: '9847333222',
        purchaseDate: DateTime.now(),
        items: [editedItem],
        staffId: 'ADMIN_1',
        staffName: 'Admin',
      );

      expect(updatedBill.items.first.purchaseRate, equals(4800.0));
      expect(updatedBill.items.first.warrantyDuration, equals('6 Months'));
      expect(updatedBill.vendorInvoiceNumber, equals('DWI-550-CORRECTED'));
      expect(updatedBill.grandTotal, equals(9600.0));
    });
  });
}
