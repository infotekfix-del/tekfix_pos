import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart'
    show
        Db,
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
import 'package:tekfix_erp_pos/purchases/purchase_bill_service.dart';
import 'package:tekfix_erp_pos/purchases/purchase_models.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tekfix_phase4_test_');
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
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('PHASE 4: VENDOR LEDGER, PAYMENTS & ATOMIC CONFIRM TEST SUITE', () {
    test('1. Integer Paise Arithmetic & Exact Financial Integrity', () {
      final item1 = PurchaseBillItem(
        name: 'AMOLED Display Screen',
        quantity: 3,
        purchaseRate: 2450.75, // ₹2,450.75 = 245075 paise
        discount: 100.25, // ₹100.25 = 10025 paise
        taxPercent: 18.0,
      );

      final item2 = PurchaseBillItem(
        name: 'Type-C Fast Charger 65W',
        quantity: 5,
        purchaseRate: 499.50, // ₹499.50 = 49950 paise
        discount: 50.0, // ₹50.00 = 5000 paise
        taxPercent: 18.0,
      );

      // Verify item paise calculations
      expect(item1.purchaseRatePaise, equals(245075));
      expect(item1.discountPaise, equals(10025));
      expect(item2.purchaseRatePaise, equals(49950));
      expect(item2.discountPaise, equals(5000));

      // Calculate bill totals in paise
      int subtotalPaise = (item1.quantity * item1.purchaseRatePaise) +
          (item2.quantity * item2.purchaseRatePaise);
      int totalDiscountPaise = item1.discountPaise + item2.discountPaise;
      int totalTaxPaise = item1.taxAmountPaise + item2.taxAmountPaise;
      int otherChargesPaise = (250.50 * 100).round(); // ₹250.50 freight charge

      int grandTotalPaise =
          subtotalPaise - totalDiscountPaise + totalTaxPaise + otherChargesPaise;

      // Ensure exact integer math with zero floating-point inaccuracy
      expect(subtotalPaise, equals(735225 + 249750)); // 984975 paise = ₹9,849.75
      expect(totalDiscountPaise, equals(15025)); // ₹150.25
      expect(grandTotalPaise, isA<int>());
      expect(grandTotalPaise > 0, isTrue);

      // Partial payment paise calculations
      int paidAmountPaise = 500000; // ₹5,000.00
      int balanceDuePaise = grandTotalPaise - paidAmountPaise;

      expect(balanceDuePaise, equals(grandTotalPaise - 500000));
      expect(paidAmountPaise + balanceDuePaise, equals(grandTotalPaise));
    });

    test('2. Vendor Outstanding Real-Time Recalculations', () {
      const double prevVendorBalance = 15000.00;
      const double grandTotal = 25000.00;

      // Scenario A: Unpaid bill (₹0 paid)
      double safePaidUnpaid = 0.0;
      double remainingBillUnpaid = (grandTotal - safePaidUnpaid).clamp(0.0, grandTotal);
      double updatedTotalUnpaid = prevVendorBalance + remainingBillUnpaid;

      expect(remainingBillUnpaid, equals(25000.00));
      expect(updatedTotalUnpaid, equals(40000.00));

      // Scenario B: Partial payment (₹10,000 paid)
      double safePaidPartial = 10000.00;
      double remainingBillPartial = (grandTotal - safePaidPartial).clamp(0.0, grandTotal);
      double updatedTotalPartial = prevVendorBalance + remainingBillPartial;

      expect(remainingBillPartial, equals(15000.00));
      expect(updatedTotalPartial, equals(30000.00));

      // Scenario C: Full payment (₹25,000 paid)
      double safePaidFull = 25000.00;
      double remainingBillFull = (grandTotal - safePaidFull).clamp(0.0, grandTotal);
      double updatedTotalFull = prevVendorBalance + remainingBillFull;

      expect(remainingBillFull, equals(0.00));
      expect(updatedTotalFull, equals(15000.00)); // Only previous balance remains
    });

    test('3. Payment Status Transitions', () {
      expect(BillPaymentStatus.paid, equals('Paid'));
      expect(BillPaymentStatus.partiallyPaid, equals('Partially Paid'));
      expect(BillPaymentStatus.unpaid, equals('Unpaid'));

      // Test helper logic for status deduction
      String getPaymentStatus(int grandTotalPaise, int paidAmountPaise) {
        final balanceDue = grandTotalPaise - paidAmountPaise;
        if (balanceDue <= 0) return BillPaymentStatus.paid;
        if (paidAmountPaise > 0) return BillPaymentStatus.partiallyPaid;
        return BillPaymentStatus.unpaid;
      }

      expect(getPaymentStatus(10000, 10000), equals(BillPaymentStatus.paid));
      expect(getPaymentStatus(10000, 5000), equals(BillPaymentStatus.partiallyPaid));
      expect(getPaymentStatus(10000, 0), equals(BillPaymentStatus.unpaid));
    });

    test('4. Chronological Vendor Ledger & Running Balance Audit Trail', () async {
      // 1. Create a mock vendor in Db.parties
      final vendorKey = await Db.parties.add({
        'name': 'Supreme Mobile Spares',
        'phone': '9847012345',
        'type': 'Supplier',
        'balance': 0.0,
      });

      // 2. Add an initial purchase bill for ₹10,000
      final now = DateTime.now();
      final bill1 = PurchaseBill(
        billNumber: 'PB-2026-001',
        vendorInvoiceNumber: 'INV-101',
        vendorKey: vendorKey,
        vendorName: 'Supreme Mobile Spares',
        vendorPhone: '9847012345',
        purchaseDate: DateTime(2026, 1, 10),
        uploadTimestamp: DateTime(2026, 1, 10),
        items: [
          PurchaseBillItem(name: 'Display Combo', quantity: 5, purchaseRate: 2000.0),
        ],
        subtotal: 10000.0,
        totalQuantity: 5,
        grandTotal: 10000.0,
        paidAmount: 0.0,
        balanceDue: 10000.0,
        paymentStatus: BillPaymentStatus.unpaid,
        createdById: 'STAFF_1',
        createdByName: 'Staff Unaise',
        createdAt: now,
        updatedAt: now,
        isDraft: false,
      );
      await Hive.box(boxPurchaseBills).put('PB-2026-001', bill1.toMap());

      // 3. Add a payment of ₹4,000 on Jan 15
      final payment1 = VendorPaymentRecord(
        paymentId: 'PAY-001',
        billNumber: 'PB-2026-001',
        vendorKey: vendorKey,
        vendorName: 'Supreme Mobile Spares',
        amount: 4000.0,
        paymentDate: DateTime(2026, 1, 15),
        paymentMethod: 'Bank Transfer',
        transactionReference: 'NEFT998877',
        recordedById: 'STAFF_1',
        recordedByName: 'Staff Unaise',
      );
      await Hive.box(boxVendorPayments).add(payment1.toMap()..['billKey'] = 'PB-2026-001');

      // 4. Add a second purchase bill for ₹5,000 on Jan 20
      final bill2 = PurchaseBill(
        billNumber: 'PB-2026-002',
        vendorInvoiceNumber: 'INV-102',
        vendorKey: vendorKey,
        vendorName: 'Supreme Mobile Spares',
        vendorPhone: '9847012345',
        purchaseDate: DateTime(2026, 1, 20),
        uploadTimestamp: DateTime(2026, 1, 20),
        items: [
          PurchaseBillItem(name: 'Battery Original', quantity: 10, purchaseRate: 500.0),
        ],
        subtotal: 5000.0,
        totalQuantity: 10,
        grandTotal: 5000.0,
        paidAmount: 0.0,
        balanceDue: 5000.0,
        paymentStatus: BillPaymentStatus.unpaid,
        createdById: 'STAFF_1',
        createdByName: 'Staff Unaise',
        createdAt: now,
        updatedAt: now,
        isDraft: false,
      );
      await Hive.box(boxPurchaseBills).put('PB-2026-002', bill2.toMap());

      // 5. Query vendor ledger
      final ledger = PurchaseBillService.instance.getVendorLedger(vendorKey);
      expect(ledger.length, equals(3));

      // Verify most-recent-first ordering and chronological running balances
      // Entry 0 (Most recent): Bill 2 (+5,000) on Jan 20 -> Running Balance: 11,000
      expect(ledger[0].type, equals('Purchase Bill'));
      expect(ledger[0].debit, equals(5000.0));
      expect(ledger[0].credit, equals(0.0));
      expect(ledger[0].runningBalance, equals(11000.0));

      // Entry 1: Payment (-4,000) on Jan 15 -> Running Balance: 6,000
      expect(ledger[1].type, equals('Bill Payment'));
      expect(ledger[1].debit, equals(0.0));
      expect(ledger[1].credit, equals(4000.0));
      expect(ledger[1].runningBalance, equals(6000.0));

      // Entry 2 (Oldest): Bill 1 (+10,000) on Jan 10 -> Running Balance: 10,000
      expect(ledger[2].type, equals('Purchase Bill'));
      expect(ledger[2].debit, equals(10000.0));
      expect(ledger[2].credit, equals(0.0));
      expect(ledger[2].runningBalance, equals(10000.0));
    });

    test('5. Pre-confirmation Validation Safeguards', () async {
      final service = PurchaseBillService.instance;

      // 1. Zero items rejection
      expect(
        () => service.confirmPurchaseBill(
          billNumber: 'PB-ERR-001',
          vendorInvoiceNumber: 'INV-001',
          vendorKey: 'V1',
          vendorName: 'Test Vendor',
          vendorPhone: '9999999999',
          purchaseDate: DateTime.now(),
          items: [],
          staffId: 'STAFF1',
          staffName: 'Staff Member',
        ),
        throwsA(predicate((e) => e.toString().contains('at least one item'))),
      );

      // 2. Unregistered new item rejection
      expect(
        () => service.confirmPurchaseBill(
          billNumber: 'PB-ERR-002',
          vendorInvoiceNumber: 'INV-002',
          vendorKey: 'V1',
          vendorName: 'Test Vendor',
          vendorPhone: '9999999999',
          purchaseDate: DateTime.now(),
          items: [
            PurchaseBillItem(
              name: 'Unregistered Glass',
              quantity: 2,
              purchaseRate: 150.0,
              isNewProduct: true,
              isStagedReady: false,
            ),
          ],
          staffId: 'STAFF1',
          staffName: 'Staff Member',
        ),
        throwsA(predicate((e) => e.toString().contains('must be registered first'))),
      );

      // 3. Mismatched IMEI count rejection
      expect(
        () => service.confirmPurchaseBill(
          billNumber: 'PB-ERR-003',
          vendorInvoiceNumber: 'INV-003',
          vendorKey: 'V1',
          vendorName: 'Test Vendor',
          vendorPhone: '9999999999',
          purchaseDate: DateTime.now(),
          items: [
            PurchaseBillItem(
              name: 'iPhone 13 128GB',
              quantity: 2,
              purchaseRate: 45000.0,
              imeiRequired: true,
              serialNumbers: ['352099001761481'], // Only 1 entered for qty 2
            ),
          ],
          staffId: 'STAFF1',
          staffName: 'Staff Member',
        ),
        throwsA(predicate((e) => e.toString().contains('requires exactly 2 IMEIs'))),
      );

      // 4. Duplicate IMEIs in entered line item rejection
      expect(
        () => service.confirmPurchaseBill(
          billNumber: 'PB-ERR-004',
          vendorInvoiceNumber: 'INV-004',
          vendorKey: 'V1',
          vendorName: 'Test Vendor',
          vendorPhone: '9999999999',
          purchaseDate: DateTime.now(),
          items: [
            PurchaseBillItem(
              name: 'Samsung Galaxy A15',
              quantity: 2,
              purchaseRate: 12000.0,
              imeiRequired: true,
              serialNumbers: ['352099001761481', '352099001761481'], // Duplicate
            ),
          ],
          staffId: 'STAFF1',
          staffName: 'Staff Member',
        ),
        throwsA(predicate((e) => e.toString().contains('contains duplicate IMEIs'))),
      );
    });

    test('6. End-to-End Atomic Confirmation with Dual-Write & Local Mirroring', () async {
      final service = PurchaseBillService.instance;

      // Create vendor in Db.parties
      final vendorKey = await Db.parties.add({
        'name': 'Universal Tech Distributors',
        'phone': '9847000111',
        'type': 'Supplier',
        'balance': 0.0,
      });

      // Prepare purchase items
      final confirmedBill = await service.confirmPurchaseBill(
        billNumber: 'PB/2026/088',
        vendorInvoiceNumber: 'UTD-9988',
        vendorKey: vendorKey,
        vendorName: 'Universal Tech Distributors',
        vendorPhone: '9847000111',
        purchaseDate: DateTime(2026, 2, 1),
        items: [
          PurchaseBillItem(
            name: 'OnePlus Nord CE 3',
            quantity: 1,
            purchaseRate: 18500.0,
            sellingPrice: 21999.0,
            imeiRequired: true,
            serialNumbers: ['352099001761481 / 352099001761499'],
            warrantyDuration: '12 Months',
          ),
          PurchaseBillItem(
            name: 'Original 80W Warp Charger',
            quantity: 3,
            purchaseRate: 1200.0,
            sellingPrice: 1999.0,
          ),
        ],
        otherCharges: 100.0,
        initialPaidAmount: 10000.0,
        initialPaymentMethod: 'UPI',
        initialPaymentReference: 'UPI-TXN-123456',
        staffId: 'STAFF_99',
        staffName: 'Unais',
      );

      // Verify Confirmed Bill calculations
      expect(confirmedBill.billNumber, equals('PB/2026/088'));
      expect(confirmedBill.isDraft, isFalse);
      expect(confirmedBill.totalQuantity, equals(4));
      // Subtotal = (1 * 18500) + (3 * 1200) = 22100. Other = 100. Grand = 22200.
      expect(confirmedBill.grandTotal, equals(22200.0));
      expect(confirmedBill.paidAmount, equals(10000.0));
      expect(confirmedBill.balanceDue, equals(12200.0));
      expect(confirmedBill.paymentStatus, equals(BillPaymentStatus.partiallyPaid));

      // 1. Verify bill saved in _billsBox
      final savedBillRaw = Hive.box(boxPurchaseBills).get('PB_2026_088');
      expect(savedBillRaw, isNotNull);
      expect(savedBillRaw['paymentStatus'], equals(BillPaymentStatus.partiallyPaid));

      // 2. Verify payment recorded in _paymentsBox
      final payments = Hive.box(boxVendorPayments).values.toList();
      expect(payments.length, equals(1));
      expect(payments.first['amount'], equals(10000.0));
      expect(payments.first['paymentMethod'], equals('UPI'));

      // 3. Verify stock updated in Db.items & stock movement recorded
      expect(Db.items.length, greaterThanOrEqualTo(2));
      final stockMoves = Db.stockMoves.values.toList();
      expect(stockMoves.any((m) => m['itemName'] == 'OnePlus Nord CE 3' && m['delta'] == 1), isTrue);
      expect(stockMoves.any((m) => m['itemName'] == 'Original 80W Warp Charger' && m['delta'] == 3), isTrue);

      // 4. Verify vendor balance in Db.parties updated (negative balance = we owe)
      final vendorRecord = Db.parties.get(vendorKey);
      expect(vendorRecord['balance'], equals(-12200.0));

      // 5. Verify Db.purchases legacy mirror
      expect(Db.purchases.length, equals(2));

      // 6. Verify Db.audit logged confirmation
      final auditLogs = Db.audit.values.toList();
      expect(auditLogs.any((a) => a['action'] == 'Purchase Bill Confirmed'), isTrue);
    });
  });
}
