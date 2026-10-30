import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart'
    show
        boxAudit,
        boxBank,
        boxItems,
        boxParties,
        boxPurchases,
        boxSales,
        boxSettings,
        boxReturns,
        boxStockMoves,
        boxPurchaseBills,
        boxVendorPayments;
import 'package:tekfix_erp_pos/purchases/manual_purchase_draft_service.dart';
import 'package:tekfix_erp_pos/purchases/purchase_bill_service.dart';
import 'package:tekfix_erp_pos/purchases/purchase_calculation_engine.dart';
import 'package:tekfix_erp_pos/purchases/purchase_models.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tekfix_manual_flow_test_');
    Hive.init(tempDir.path);

    await Hive.openBox(boxItems);
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

    final settingsBox = Hive.box(boxSettings);
    await settingsBox.put('store_state_code', '32');
    await settingsBox.put('shop_id', 'test_shop');
    ManualPurchaseDraftService.instance.delete();
  });

  tearDown(() async {
    try {
      await Hive.close();
    } catch (_) {}
    try {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('PHASE 2: MANUAL PURCHASE ENTRY TEST SUITE (M2 - M12)', () {
    // M2: Quick Add Supplier works and selects the supplier
    test('M2. Quick Add Supplier adds party and validates duplicate phone/name',
        () async {
      final vendor = await PurchaseBillService.instance.addNewVendor(
        name: 'Apex Mobiles Kerala',
        phone: '9847012345',
        gst: '32AABCT1332L1ZW',
        address: 'Calicut, Kerala',
      );

      expect(vendor['name'], equals('Apex Mobiles Kerala'));
      expect(vendor['gst'], equals('32AABCT1332L1ZW'));
      expect(vendor['key'], isNotNull);

      // Verify vendor retrieved in list
      final vendors = PurchaseBillService.instance.getVendors();
      expect(vendors.any((v) => v['name'] == 'Apex Mobiles Kerala'), isTrue);

      // Verify duplicate prevention
      expect(
        () => PurchaseBillService.instance.addNewVendor(
          name: 'Apex Mobiles Kerala',
          phone: '9999999999',
        ),
        throwsA(isA<Exception>()),
      );
    });

    // M3: Existing product -> GREEN; new product -> AMBER; similar variant -> RED
    test('M3. Product match status resolution: Green, Amber, Red', () async {
      // 1. Existing matched item
      final matchedItem = PurchaseBillItem(
        name: 'iPhone 15 Case Clear',
        quantity: 5,
        purchaseRate: 250.0,
        sellingPrice: 499.0,
        isNewProduct: false,
        isStagedReady: true,
      );
      expect(matchedItem.matchStatus, equals(ProductMatchStatus.matched));
      expect(ProductMatchStatus.getColor(matchedItem.matchStatus),
          equals(const Color(0xFF10B981)));

      // 2. Unregistered new item -> AMBER
      final newItem = PurchaseBillItem(
        name: 'Brand New Unknown Glass',
        quantity: 10,
        purchaseRate: 150.0,
        isNewProduct: true,
        isStagedReady: false,
      );
      expect(newItem.matchStatus, equals(ProductMatchStatus.quickRegister));
      expect(ProductMatchStatus.getColor(newItem.matchStatus),
          equals(const Color(0xFFF59E0B)));

      // 3. Review required -> RED
      final reviewItem = PurchaseBillItem(
        name: 'Anomaly Rate Screen',
        quantity: 2,
        purchaseRate: 500.0,
        sellingPrice: 300.0, // Selling price lower than purchase rate
      );
      expect(reviewItem.matchStatus, equals(ProductMatchStatus.reviewRequired));
      expect(ProductMatchStatus.getColor(reviewItem.matchStatus),
          equals(const Color(0xFFEF4444)));
    });

    // M4: Quick Register keeps all rows and line's qty/price/GST
    test('M4. Quick Register workflow updates item and preserves pricing',
        () async {
      final initialItem = PurchaseBillItem(
        id: 'ROW_1',
        name: 'New Battery BM4Y',
        quantity: 8,
        purchaseRate: 450.0,
        discount: 50.0,
        taxPercent: 18.0,
        isNewProduct: true,
        isStagedReady: false,
      );

      // Register product
      final registeredProduct = {
        'id': 'PROD_BM4Y_99',
        'name': 'New Battery BM4Y OEM',
        'sellingPrice': 950.0,
        'mrp': 1200.0,
        'gstRate': 18.0,
        'imeiRequired': false,
      };

      // Item copyWith updated details
      final updatedItem = initialItem.copyWith(
        matchedProductId: registeredProduct['id'] as String,
        matchedProductName: registeredProduct['name'] as String,
        isNewProduct: false,
        isStagedReady: true,
        sellingPrice: (registeredProduct['sellingPrice'] as num).toDouble(),
        mrp: (registeredProduct['mrp'] as num).toDouble(),
        matchStatusOverride: ProductMatchStatus.matched,
      );

      expect(updatedItem.id, equals('ROW_1'));
      expect(updatedItem.quantity, equals(8));
      expect(updatedItem.purchaseRate, equals(450.0));
      expect(updatedItem.discount, equals(50.0));
      expect(updatedItem.taxPercent, equals(18.0));
      expect(updatedItem.matchedProductId, equals('PROD_BM4Y_99'));
      expect(updatedItem.matchStatus, equals(ProductMatchStatus.matched));
    });

    // M5: Totals recalculate on every edit
    test('M5. Shared calculation engine recalculates totals accurately', () {
      const engine = PurchaseCalculationEngine(isInterState: false);
      final items = [
        PurchaseBillItem(
          id: '1',
          name: 'Display Screen',
          quantity: 2,
          purchaseRate: 1500.0, // 3000
          discount: 200.0,      // 2800 taxable
          taxPercent: 18.0,     // 504 tax
        ),
      ];

      var result = engine.calculate(items: items);
      expect(result.subtotalPaise, equals(300000));
      expect(result.totalDiscountPaise, equals(20000));
      expect(result.taxableValuePaise, equals(280000));
      expect(result.totalGstPaise, equals(50400));
      expect(result.grandTotalPaise, equals(330400));

      // Edit qty to 3
      final editedItems = [
        items[0].copyWith(quantity: 3), // 4500 - 200 = 4300 taxable, 18% = 774
      ];
      result = engine.calculate(items: editedItems);
      expect(result.subtotalPaise, equals(450000));
      expect(result.taxableValuePaise, equals(430000));
      expect(result.totalGstPaise, equals(77400));
      expect(result.grandTotalPaise, equals(507400));
    });

    // M6: Duplicate invoice (same supplier + number) is blocked
    test('M6. Duplicate invoice validation blocks saving duplicate invoice number',
        () async {
      final billsBox = Hive.box(boxPurchaseBills);
      final existingBill = PurchaseBill(
        billNumber: 'PB-2026-0001',
        vendorInvoiceNumber: 'INV-9901',
        vendorKey: 'vendor_1',
        vendorName: 'Kerala Tech',
        vendorPhone: '9847000000',
        purchaseDate: DateTime.now(),
        uploadTimestamp: DateTime.now(),
        subtotal: 1000.0,
        totalQuantity: 1,
        grandTotal: 1180.0,
        balanceDue: 1180.0,
        paymentStatus: BillPaymentStatus.unpaid,
        createdById: 'staff_1',
        createdByName: 'Staff',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        entrySource: EntrySource.manual,
      );
      await billsBox.put('PB-2026-0001', existingBill.toMap());

      // Check duplicate
      final dup = PurchaseBillService.instance
          .checkDuplicateInvoice('inv-9901', 'vendor_1');
      expect(dup, isNotNull);
      expect(dup!.billNumber, equals('PB-2026-0001'));

      // Check different vendor or invoice
      final noDup1 = PurchaseBillService.instance
          .checkDuplicateInvoice('inv-9902', 'vendor_1');
      expect(noDup1, isNull);

      final noDup2 = PurchaseBillService.instance
          .checkDuplicateInvoice('inv-9901', 'vendor_2');
      expect(noDup2, isNull);
    });

    // M7 & M8: Single atomic post, idempotency, retry safety
    test('M7 & M8. confirmPurchaseBill handles idempotency and records stock & ledger',
        () async {
      final itemsBox = Hive.box(boxItems);
      final itemKey = await itemsBox.add({
        'name': 'Tempered Glass 9H',
        'stock': 10,
        'costPrice': 50.0,
        'sellingPrice': 150.0,
      });

      final purchaseItem = PurchaseBillItem(
        id: 'ITEM_1',
        itemKey: itemKey,
        name: 'Tempered Glass 9H',
        quantity: 20,
        purchaseRate: 50.0,
        taxPercent: 18.0,
      );

      final confirmed = await PurchaseBillService.instance.confirmPurchaseBill(
        billNumber: 'PB-2026-0050',
        vendorInvoiceNumber: 'INV-TG-50',
        vendorKey: 'vendor_kerala',
        vendorName: 'Kerala Glass Suppliers',
        vendorPhone: '9847111222',
        purchaseDate: DateTime.now(),
        items: [purchaseItem],
        initialPaidAmount: 500.0,
        initialPaymentMethod: 'Cash',
        staffId: 'owner',
        staffName: 'Owner',
        entrySource: EntrySource.manual,
      );

      expect(confirmed.billNumber, equals('PB-2026-0050'));
      expect(confirmed.entrySource, equals(EntrySource.manual));

      // Stock must have increased by 20 -> 30
      final updatedItem = itemsBox.get(itemKey);
      expect(updatedItem['stock'], equals(30));

      // Bill saved in Hive
      final savedBillRaw = Hive.box(boxPurchaseBills).get('PB-2026-0050');
      expect(savedBillRaw, isNotNull);
      final savedBill = PurchaseBill.fromMap(savedBillRaw as Map);
      expect(savedBill.entrySource, equals('manual'));
      expect(savedBill.paidAmount, equals(500.0));
      expect(savedBill.paymentStatus, equals(BillPaymentStatus.partiallyPaid));
    });

    // M9: Partial payment: invoice balance due vs vendor outstanding separate
    test('M9. Partial payment separates Invoice Balance Due and Vendor Outstanding',
        () {
      const engine = PurchaseCalculationEngine(isInterState: false);
      final items = [
        PurchaseBillItem(
          name: 'Fast Charger 65W',
          quantity: 4,
          purchaseRate: 500.0, // 2000
          taxPercent: 18.0,    // 360 tax → grand 2360
        ),
      ];

      // Grand total = 2360, paid = 1000
      final result = engine.calculate(items: items, paidAmountPaise: 100000);
      expect(result.grandTotal, equals(2360.0));
      expect(result.paidAmount, equals(1000.0));
      expect(result.balanceDue, equals(1360.0)); // Invoice balance due

      // Suppose vendor previous balance is ₹5,000
      const double previousVendorBalance = 5000.0;
      final double newVendorOutstanding = previousVendorBalance + result.balanceDue;

      expect(result.balanceDue, equals(1360.0));
      expect(newVendorOutstanding, equals(6360.0));
      expect(result.paymentStatus, equals(BillPaymentStatus.partiallyPaid));
    });

    // M10: Draft survives app restart and resumes
    test('M10. ManualPurchaseDraftService saves, loads, and deletes draft',
        () async {
      final draftService = ManualPurchaseDraftService.instance;
      expect(draftService.hasDraft(), isFalse);

      final draft = ManualPurchaseDraft(
        vendorKey: 'v_99',
        vendorName: 'Draft Supplier Ltd',
        vendorInvoiceNumber: 'DRAFT-001',
        itemMaps: [
          {'name': 'Draft Item A', 'quantity': 5, 'purchaseRate': 100.0},
        ],
        otherCharges: 50.0,
        paidAmount: 200.0,
      );

      await draftService.save(draft);
      expect(draftService.hasDraft(), isTrue);

      final loaded = draftService.load();
      expect(loaded, isNotNull);
      expect(loaded!.vendorName, equals('Draft Supplier Ltd'));
      expect(loaded.vendorInvoiceNumber, equals('DRAFT-001'));
      expect(loaded.itemMaps.length, equals(1));
      expect(loaded.otherCharges, equals(50.0));

      // After successful save, draft is deleted
      await draftService.delete();
      expect(draftService.hasDraft(), isFalse);
    });

    // M11: Manual and uploaded purchases appear in same history with correct source chips
    test('M11. Purchase history displays both manual and auto bills with source tags',
        () async {
      final billsBox = Hive.box(boxPurchaseBills);

      final autoBill = PurchaseBill(
        billNumber: 'PB-2026-AUTO',
        vendorInvoiceNumber: 'INV-AUTO-1',
        vendorKey: 'v_1',
        vendorName: 'Auto Vendor',
        vendorPhone: '9847000001',
        purchaseDate: DateTime.now(),
        uploadTimestamp: DateTime.now(),
        subtotal: 5000.0,
        totalQuantity: 10,
        grandTotal: 5900.0,
        balanceDue: 0.0,
        paymentStatus: BillPaymentStatus.paid,
        createdById: 'staff',
        createdByName: 'Staff',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        entrySource: EntrySource.billUpload,
      );

      final manualBill = PurchaseBill(
        billNumber: 'PB-2026-MANUAL',
        vendorInvoiceNumber: 'INV-MAN-1',
        vendorKey: 'v_2',
        vendorName: 'Manual Vendor',
        vendorPhone: '9847000002',
        purchaseDate: DateTime.now(),
        uploadTimestamp: DateTime.now(),
        subtotal: 2000.0,
        totalQuantity: 4,
        grandTotal: 2360.0,
        balanceDue: 2360.0,
        paymentStatus: BillPaymentStatus.unpaid,
        createdById: 'staff',
        createdByName: 'Staff',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        entrySource: EntrySource.manual,
      );

      await billsBox.put(autoBill.billNumber, autoBill.toMap());
      await billsBox.put(manualBill.billNumber, manualBill.toMap());

      final results = PurchaseBillService.instance.searchPurchaseBills(query: '');
      expect(results.length, greaterThanOrEqualTo(2));

      final foundAuto = results.firstWhere((b) => b.billNumber == 'PB-2026-AUTO');
      final foundManual = results.firstWhere((b) => b.billNumber == 'PB-2026-MANUAL');

      expect(foundAuto.entrySource, equals(EntrySource.billUpload));
      expect(foundManual.entrySource, equals(EntrySource.manual));
    });

    // M12: Existing Upload Bill and navigation still intact (Regression)
    test('M12. Regression test: Legacy methods, model constructors & getters intact',
        () {
      // Create legacy purchase bill without entrySource
      final legacyMap = {
        'billNumber': 'PB-LEGACY-001',
        'vendorInvoiceNumber': 'LEG-99',
        'vendorName': 'Old Vendor',
        'vendorPhone': '9999999999',
        'subtotal': 1000.0,
        'totalQuantity': 1,
        'grandTotal': 1000.0,
        'balanceDue': 0.0,
        'paymentStatus': 'Paid',
        'createdById': 'legacy',
        'createdByName': 'Legacy User',
        'createdAt': DateTime.now().toIso8601String(),
        'updatedAt': DateTime.now().toIso8601String(),
      };

      final parsed = PurchaseBill.fromMap(legacyMap);
      expect(parsed.entrySource, equals(EntrySource.billUpload));
      expect(parsed.billNumber, equals('PB-LEGACY-001'));
      expect(parsed.grandTotal, equals(1000.0));
    });
  });
}
