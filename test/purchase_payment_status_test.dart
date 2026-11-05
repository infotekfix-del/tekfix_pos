import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/purchases/purchase_models.dart';

void main() {
  group('BillPaymentStatus & Dynamic Status Calculation Tests', () {
    test('1. BillPaymentStatus.computeStatus rule verification', () {
      // Rule: isDraft -> Draft
      expect(
        BillPaymentStatus.computeStatus(
          grandTotalPaise: 100000,
          paidAmountPaise: 0,
          isDraft: true,
        ),
        equals(BillPaymentStatus.draft),
      );

      // Rule: paid <= 0 -> Unpaid
      expect(
        BillPaymentStatus.computeStatus(
          grandTotalPaise: 100000,
          paidAmountPaise: 0,
        ),
        equals(BillPaymentStatus.unpaid),
      );
      expect(
        BillPaymentStatus.computeStatus(
          grandTotalPaise: 100000,
          paidAmountPaise: -500,
        ),
        equals(BillPaymentStatus.unpaid),
      );

      // Rule: 0 < paid < grandTotal -> Partial
      expect(
        BillPaymentStatus.computeStatus(
          grandTotalPaise: 100000,
          paidAmountPaise: 50000,
        ),
        equals(BillPaymentStatus.partial),
      );
      expect(
        BillPaymentStatus.computeStatus(
          grandTotalPaise: 100000,
          paidAmountPaise: 1, // 1 paisa paid
        ),
        equals(BillPaymentStatus.partial),
      );

      // Rule: paid >= grandTotal -> Paid
      expect(
        BillPaymentStatus.computeStatus(
          grandTotalPaise: 100000,
          paidAmountPaise: 100000,
        ),
        equals(BillPaymentStatus.paid),
      );
      expect(
        BillPaymentStatus.computeStatus(
          grandTotalPaise: 100000,
          paidAmountPaise: 150000, // overpaid
        ),
        equals(BillPaymentStatus.paid),
      );
    });

    test('2. Helper checkers: isPaid, isPartial, isUnpaid, isDraft', () {
      expect(BillPaymentStatus.isPaid('Paid'), isTrue);
      expect(BillPaymentStatus.isPaid('paid'), isTrue);
      expect(BillPaymentStatus.isPaid('Unpaid'), isFalse);

      expect(BillPaymentStatus.isPartial('Partial'), isTrue);
      expect(BillPaymentStatus.isPartial('Partially Paid'), isTrue);
      expect(BillPaymentStatus.isPartial('partial'), isTrue);
      expect(BillPaymentStatus.isPartial('Paid'), isFalse);

      expect(BillPaymentStatus.isUnpaid('Unpaid'), isTrue);
      expect(BillPaymentStatus.isUnpaid('unpaid'), isTrue);
      expect(BillPaymentStatus.isUnpaid('Partial'), isFalse);

      expect(BillPaymentStatus.isDraft('Draft'), isTrue);
      expect(BillPaymentStatus.isDraft('draft'), isTrue);
      expect(BillPaymentStatus.isDraft('Paid'), isFalse);
    });

    test('3. PurchaseBill dynamic paymentStatus and balanceDue calculation', () {
      final bill = PurchaseBill(
        billNumber: 'PB-2026-0026',
        vendorInvoiceNumber: 'INV-9901',
        vendorName: 'ABC Electronics',
        vendorPhone: '9876543210',
        purchaseDate: DateTime(2026, 11, 1),
        uploadTimestamp: DateTime(2026, 11, 1),
        subtotal: 1000.0,
        totalQuantity: 5,
        grandTotal: 1000.0,
        paidAmount: 0.0,
        balanceDue: 1000.0,
        paymentStatus: BillPaymentStatus.unpaid,
        createdById: 'user_1',
        createdByName: 'Admin',
        createdAt: DateTime(2026, 11, 1),
        updatedAt: DateTime(2026, 11, 1),
      );

      // Initially unpaid
      expect(bill.paidAmountPaise, equals(0));
      expect(bill.grandTotalPaise, equals(100000));
      expect(bill.balanceDuePaise, equals(100000));
      expect(bill.paymentStatus, equals(BillPaymentStatus.unpaid));

      // After partial payment of ₹400
      final partialBill = bill.copyWith(
        paidAmount: 400.0,
      );
      expect(partialBill.paidAmountPaise, equals(40000));
      expect(partialBill.balanceDuePaise, equals(60000));
      expect(partialBill.balanceDue, equals(600.0));
      expect(partialBill.paymentStatus, equals(BillPaymentStatus.partial));

      // After full payment of ₹1000
      final paidBill = partialBill.copyWith(
        paidAmount: 1000.0,
      );
      expect(paidBill.paidAmountPaise, equals(100000));
      expect(paidBill.balanceDuePaise, equals(0));
      expect(paidBill.balanceDue, equals(0.0));
      expect(paidBill.paymentStatus, equals(BillPaymentStatus.paid));
    });

    test('4. PurchaseBill.fromMap overrides stale paymentStatus dynamically', () {
      // Simulate a legacy doc where paymentStatus was saved as 'Unpaid'
      // but paidAmount was actually 1000.0 (fully settled).
      final rawMap = {
        'billNumber': 'PB-2026-0026',
        'vendorInvoiceNumber': 'INV-9901',
        'vendorName': 'ABC Electronics',
        'vendorPhone': '9876543210',
        'purchaseDate': '2026-11-01T10:00:00.000',
        'uploadTimestamp': '2026-11-01T10:00:00.000',
        'subtotal': 1000.0,
        'grandTotal': 1000.0,
        'paidAmount': 1000.0,
        'balanceDue': 0.0,
        'paymentStatus': 'Unpaid', // Stale in database!
        'createdById': 'user_1',
        'createdByName': 'Admin',
        'createdAt': '2026-11-01T10:00:00.000',
        'updatedAt': '2026-11-01T10:00:00.000',
      };

      final reconstructed = PurchaseBill.fromMap(rawMap);
      // It MUST derive 'Paid' dynamically!
      expect(reconstructed.paymentStatus, equals(BillPaymentStatus.paid));
      expect(reconstructed.balanceDuePaise, equals(0));

      // toMap() must emit 'Paid'
      final exported = reconstructed.toMap();
      expect(exported['paymentStatus'], equals(BillPaymentStatus.paid));
      expect(exported['balanceDuePaise'], equals(0));
      expect(exported['paidAmountPaise'], equals(100000));
    });

    test('5. Editing grand total changes status from Paid to Partial', () {
      final bill = PurchaseBill(
        billNumber: 'PB-2026-0026',
        vendorInvoiceNumber: 'INV-9901',
        vendorName: 'ABC Electronics',
        vendorPhone: '9876543210',
        purchaseDate: DateTime(2026, 11, 1),
        uploadTimestamp: DateTime(2026, 11, 1),
        subtotal: 1000.0,
        totalQuantity: 5,
        grandTotal: 1000.0,
        paidAmount: 1000.0,
        balanceDue: 0.0,
        paymentStatus: BillPaymentStatus.paid,
        createdById: 'user_1',
        createdByName: 'Admin',
        createdAt: DateTime(2026, 11, 1),
        updatedAt: DateTime(2026, 11, 1),
      );

      expect(bill.paymentStatus, equals(BillPaymentStatus.paid));

      // Bill is edited: new items added, grandTotal increased to ₹1500
      final editedBill = PurchaseBill(
        billNumber: bill.billNumber,
        vendorInvoiceNumber: bill.vendorInvoiceNumber,
        vendorName: bill.vendorName,
        vendorPhone: bill.vendorPhone,
        purchaseDate: bill.purchaseDate,
        uploadTimestamp: bill.uploadTimestamp,
        subtotal: 1500.0,
        totalQuantity: 8,
        grandTotal: 1500.0,
        paidAmount: bill.paidAmount, // Still ₹1000 paid
        balanceDue: 500.0,
        createdById: bill.createdById,
        createdByName: bill.createdByName,
        createdAt: bill.createdAt,
        updatedAt: DateTime.now(),
      );

      // Now grandTotal is ₹1500, paid is ₹1000 -> status MUST be Partial
      expect(editedBill.paymentStatus, equals(BillPaymentStatus.partial));
      expect(editedBill.balanceDuePaise, equals(50000));
      expect(editedBill.balanceDue, equals(500.0));
    });

    test('6. VendorPaymentRecord and VendorLedgerEntry paise exactness', () {
      final payment = VendorPaymentRecord(
        paymentId: 'PAY_123456',
        billNumber: 'PB-2026-0026',
        vendorName: 'ABC Electronics',
        amount: 250.75,
        paymentDate: DateTime(2026, 11, 5),
        paymentMethod: 'UPI',
        transactionReference: 'UPI/123456789',
        recordedById: 'user_1',
        recordedByName: 'Admin',
      );

      expect(payment.amountPaise, equals(25075));
      final map = payment.toMap();
      expect(map['amountPaise'], equals(25075));
      expect(map['amount'], equals(250.75));

      final ledger = VendorLedgerEntry(
        id: 'VL_123',
        date: DateTime(2026, 11, 5),
        type: 'Payment',
        reference: 'UPI/123456789',
        debit: 0.0,
        credit: 250.75,
        runningBalance: 500.25,
      );

      expect(ledger.creditPaise, equals(25075));
      expect(ledger.runningBalancePaise, equals(50025));
      final lMap = ledger.toMap();
      expect(lMap['creditPaise'], equals(25075));
      expect(lMap['runningBalancePaise'], equals(50025));
    });
  });
}
