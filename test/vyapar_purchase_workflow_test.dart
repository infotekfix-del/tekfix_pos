import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/purchases/invoice_parser_service.dart';
import 'package:tekfix_erp_pos/purchases/purchase_bill_service.dart';
import 'package:tekfix_erp_pos/purchases/purchase_models.dart';

void main() {
  group('Vyapar-like Purchase Workflow Test Suite', () {
    late Directory tempDir;

    setUpAll(() async {
      tempDir = await Directory.systemTemp.createTemp('vyapar_test_hive_');
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

    test('1. Automated Bill Parsing extracts vendor details, invoice #, date, and items with MRP', () {
      const sampleTaxInvoice = '''
      TAX INVOICE
      Sold By: SUPREME TELECOM DISTRIBUTORS PVT LTD
      Address: Near Market Gate, Broadway, Cochin, Kerala - 682001
      GSTIN: 32AABCS1429B1Z8
      Phone: 9876543210
      Invoice No: INV/2026/1024
      Date: 28-02-2026

      Item Description                HSN       Qty   Rate       MRP        Tax%   Total
      1. iPhone 15 128GB Black        85171200  2     54999.00   79900.00   18%    129797.64
      2. Apple 20W USB-C Adapter      85044090  5     1299.00    1999.00    18%    7664.10

      Subtotal: 116493.00
      Total Tax: 20968.74
      Grand Total: 137461.74
      ''';

      final parsed = InvoiceParserService.instance.parseInvoiceText(
        sampleTaxInvoice,
        method: 'Vyapar OCR Parser',
      );

      // Verify Header & Vendor
      expect(parsed.invoiceNumber, equals('INV/2026/1024'));
      expect(parsed.invoiceDate, equals(DateTime(2026, 2, 28)));
      expect(parsed.vendorName, contains('SUPREME TELECOM'));
      expect(parsed.vendorGst, equals('32AABCS1429B1Z8'));
      expect(parsed.vendorPhone, equals('9876543210'));
      expect(parsed.vendorAddress, contains('Cochin'));
      expect(parsed.invoiceTotal, equals(137461.74));

      // Verify Line items & MRP
      expect(parsed.hasItems, isTrue);
      expect(parsed.itemCount, equals(2));

      final item1 = parsed.items[0];
      expect(item1.description, contains('iPhone 15 128GB Black'));
      expect(item1.skuOrHsn, equals('85171200'));
      expect(item1.quantity, equals(2));
      expect(item1.unitPrice, equals(54999.00));
      expect(item1.mrp, equals(79900.00));
      expect(item1.taxPercent, equals(18.0));

      // Verify toPurchaseBillItem conversion preserves MRP and calculates selling price
      final billItem1 = item1.toPurchaseBillItem();
      expect(billItem1.mrp, equals(79900.00));
      expect(billItem1.sellingPrice, equals(79900.00));

      final item2 = parsed.items[1];
      expect(item2.description, contains('Apple 20W USB-C Adapter'));
      expect(item2.quantity, equals(5));
      expect(item2.unitPrice, equals(1299.00));
      expect(item2.mrp, equals(1999.00));
    });

    test('2. Single-Step Inventory Update: Increment existing stock and create new items atomically', () async {
      // 1. Seed existing product into Db.items
      await Db.items.put('EXISTING_ITEM_1', {
        'name': 'OnePlus 12R 256GB',
        'sku': 'OP-12R-256',
        'stock': 5,
        'costPrice': 38000.0,
        'sellingPrice': 42999.0,
      });

      final initialStock = (Db.items.get('EXISTING_ITEM_1')['stock'] as num).toInt();
      expect(initialStock, equals(5));

      const billNumber = 'PB_VYAPAR_001';
      final items = [
        // Line 1: Existing item (+4 units)
        PurchaseBillItem(
          id: 'LINE_1',
          itemKey: 'EXISTING_ITEM_1',
          name: 'OnePlus 12R 256GB',
          sku: 'OP-12R-256',
          quantity: 4,
          purchaseRate: 37500.0,
          sellingPrice: 42999.0,
          mrp: 45999.0,
          lineTotal: 150000.0,
          isNewProduct: false,
          isStagedReady: true,
        ),
        // Line 2: Brand new item (+10 units)
        PurchaseBillItem(
          id: 'LINE_2',
          name: 'Spigen Tough Armor Case OP12',
          sku: 'SPG-CASE-01',
          quantity: 10,
          purchaseRate: 850.0,
          sellingPrice: 1499.0,
          mrp: 1999.0,
          lineTotal: 8500.0,
          isNewProduct: false,
          isStagedReady: true,
        ),
      ];

      // Save purchase bill via confirmPurchaseBill
      final confirmed = await PurchaseBillService.instance.confirmPurchaseBill(
        billNumber: billNumber,
        vendorInvoiceNumber: 'INV-TEST-001',
        vendorKey: 'VENDOR_TEST_1',
        vendorName: 'Supreme Telecom',
        vendorPhone: '9876543210',
        purchaseDate: DateTime.now(),
        items: items,
        staffId: 'STAFF_1',
        staffName: 'Admin',
        entrySource: EntrySource.manual,
      );

      expect(confirmed.billNumber, equals(billNumber));

      // 2. Verify Single-Step Inventory Update on Existing Item
      final updatedExisting = Db.items.get('EXISTING_ITEM_1');
      expect((updatedExisting['stock'] as num).toInt(), equals(9)); // 5 + 4 = 9
      expect((updatedExisting['costPrice'] as num).toDouble(), equals(37500.0));

      // 3. Verify Single-Step Inventory Update on Brand New Item
      dynamic createdItem;
      for (final k in Db.items.keys) {
        final val = Db.items.get(k);
        if (val is Map && val['sku'] == 'SPG-CASE-01') {
          createdItem = val;
          break;
        }
      }
      expect(createdItem, isNotNull);
      expect((createdItem['stock'] as num).toInt(), equals(10));
      expect((createdItem['costPrice'] as num).toDouble(), equals(850.0));
      expect((createdItem['sellingPrice'] as num).toDouble(), equals(1499.0));

      // 4. Verify Stock Movements logged in Db.stockMoves
      final moves = Db.stockMoves.values.whereType<Map>().toList();
      final hasMoveForExisting = moves.any((m) =>
          m['reason']?.toString().contains(billNumber) == true &&
          (m['delta'] == 4 || m['qty'] == 4));
      final hasMoveForNew = moves.any((m) =>
          m['reason']?.toString().contains(billNumber) == true &&
          (m['delta'] == 10 || m['qty'] == 10));
      expect(hasMoveForExisting, isTrue);
      expect(hasMoveForNew, isTrue);
    });

    test('3. Vendor-Wise Bill Tracking & History: Summaries and Payments Filter', () async {
      const vendorKey = 'VENDOR_VYAPAR_A';
      const billNum1 = 'PB_VYAPAR_V1';
      const billNum2 = 'PB_VYAPAR_V2';

      // Record Bill 1 with partial payment
      await PurchaseBillService.instance.confirmPurchaseBill(
        billNumber: billNum1,
        vendorInvoiceNumber: 'INV-V1',
        vendorKey: vendorKey,
        vendorName: 'Vyapar Vendor A',
        vendorPhone: '9900112233',
        purchaseDate: DateTime(2026, 3, 1),
        items: [
          PurchaseBillItem(
            name: 'Item A',
            quantity: 2,
            purchaseRate: 5000.0,
            lineTotal: 10000.0,
            isNewProduct: false,
            isStagedReady: true,
          ),
        ],
        initialPaidAmount: 4000.0,
        initialPaymentMethod: 'UPI',
        initialPaymentReference: 'UPI-REF-001',
        staffId: 'STAFF_1',
        staffName: 'Admin',
      );

      // Record Bill 2 with full payment
      await PurchaseBillService.instance.confirmPurchaseBill(
        billNumber: billNum2,
        vendorInvoiceNumber: 'INV-V2',
        vendorKey: vendorKey,
        vendorName: 'Vyapar Vendor A',
        vendorPhone: '9900112233',
        purchaseDate: DateTime(2026, 3, 2),
        items: [
          PurchaseBillItem(
            name: 'Item B',
            quantity: 1,
            purchaseRate: 6000.0,
            lineTotal: 6000.0,
            isNewProduct: false,
            isStagedReady: true,
          ),
        ],
        initialPaidAmount: 6000.0,
        initialPaymentMethod: 'Bank Transfer',
        initialPaymentReference: 'IMPS-REF-002',
        staffId: 'STAFF_1',
        staffName: 'Admin',
      );

      // Verify getVendorSummary
      final summary = PurchaseBillService.instance.getVendorSummary(vendorKey);
      expect(summary['billsCount'], equals(2));
      expect(summary['totalPurchases'], equals(16000.0));
      expect(summary['totalPaid'], equals(10000.0));
      expect(summary['totalOutstanding'], equals(6000.0)); // 16000 - 10000 = 6000

      // Verify getPaymentsForVendor
      final payments = PurchaseBillService.instance.getPaymentsForVendor(vendorKey);
      expect(payments.length, equals(2));
      expect(payments.any((p) => p.amount == 4000.0 && p.paymentMethod == 'UPI'), isTrue);
      expect(payments.any((p) => p.amount == 6000.0 && p.paymentMethod == 'Bank Transfer'), isTrue);

      // Verify searchPurchaseBills filtered by vendorKey
      final vendorBills = PurchaseBillService.instance.searchPurchaseBills(vendorKey: vendorKey);
      expect(vendorBills.length, equals(2));
      expect(vendorBills.every((b) => b.vendorKey == vendorKey), isTrue);
    });
  });
}
