// Vendor payables: purchase bills + vendor payments must keep ONE running
// balance that the vendor ledger, purchase screens and parties screen agree on.
//
// Owner's rule (vendor "G7"): owes ₹5,000 → purchase ₹1,000 → owes ₹6,000 →
// pays ₹500 against the bill → owes ₹5,500.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/purchases/purchase_bill_service.dart';
import 'package:tekfix_erp_pos/purchases/purchase_models.dart';

final _svc = PurchaseBillService.instance;
int _billSeq = 0;

Future<dynamic> _vendor(String name, {double owed = 0}) => Db.parties.add({
      'name': name,
      'phone': '9000000000',
      'type': 'Supplier',
      // TekFix convention: supplier balance is negative when we owe money.
      'balance': -owed,
    });

PurchaseBillItem _item(double rate, {int qty = 1}) => PurchaseBillItem(
      id: 'it_${_billSeq}_$rate',
      name: 'Display ${_billSeq}_$rate',
      quantity: qty,
      purchaseRate: rate,
    );

Future<PurchaseBill> _confirm(dynamic vendorKey, double total,
    {double paid = 0, DateTime? date}) {
  _billSeq++;
  return _svc.confirmPurchaseBill(
    billNumber: 'PB-TEST-$_billSeq',
    vendorInvoiceNumber: 'INV-$_billSeq',
    vendorKey: vendorKey,
    vendorName: '${(Db.parties.get(vendorKey) as Map)['name']}',
    vendorPhone: '9000000000',
    purchaseDate: date ?? DateTime(2026, 11, 1 + _billSeq % 20),
    items: [_item(total)],
    initialPaidAmount: paid,
    staffId: 'S1',
    staffName: 'Owner',
  );
}

Future<PurchaseBill> _pay(PurchaseBill bill, double amount) =>
    _svc.recordBillPayment(
      billKey: bill.key,
      amount: amount,
      paymentDate: DateTime(2026, 11, 25),
      paymentMethod: 'Cash',
      transactionReference: 'PAY-REF',
      staffId: 'S1',
      staffName: 'Owner',
    );

/// Payable in paise from the party record (what the Parties screen shows).
int _partyOwed(dynamic key) =>
    (-((Db.parties.get(key) as Map)['balance'] as num) * 100).round();

/// Asserts every screen's number equals [expectedPaise].
Future<void> _expectAllViews(dynamic key, int expectedPaise) async {
  expect(_partyOwed(key), expectedPaise, reason: 'party balance');
  expect(_svc.getVendorPayablePaise(key), expectedPaise, reason: 'payable');
  // Purchase entry screen "Previous Balance".
  expect(await _svc.fetchVendorBalancePaise(key),
      expectedPaise < 0 ? 0 : expectedPaise,
      reason: 'purchase screen previous balance');
  // Vendor ledger closing balance (most recent entry first).
  final ledger = _svc.getVendorLedger(key);
  expect(ledger, isNotEmpty);
  expect(ledger.first.runningBalancePaise, expectedPaise,
      reason: 'vendor ledger closing balance');
  // Ledger rows must add up to the closing balance.
  final net = ledger.fold<int>(0, (s, e) => s + e.debitPaise - e.creditPaise);
  expect(net, expectedPaise, reason: 'ledger debit - credit');
  // Purchase dashboard vendor "Balance Due".
  final summary = _svc.getVendorSummary(key);
  expect(((summary['totalOutstanding'] as double) * 100).round(),
      expectedPaise < 0 ? 0 : expectedPaise,
      reason: 'vendor summary balance due');
}

void main() {
  late Directory tempDir;

  setUpAll(() async {
    PurchaseBillService.ownerCheckForTesting = true;
    tempDir = await Directory.systemTemp.createTemp('tekfix_payables_test_');
    Hive.init(tempDir.path);
    for (final b in allBoxes) {
      await Hive.openBox(b);
    }
    await Hive.box(boxSettings).put('shop_id', 'test_shop');
  });

  tearDownAll(() async {
    PurchaseBillService.ownerCheckForTesting = null;
    try {
      await Hive.close();
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('Vendor payables consistency', () {
    test('G7 example: ₹5,000 owed + ₹1,000 purchase − ₹500 payment = ₹5,500',
        () async {
      final g7 = await _vendor('G7', owed: 5000);
      await _expectAllViews(g7, 500000);

      final bill = await _confirm(g7, 1000);
      expect(bill.balanceDuePaise, 100000);
      await _expectAllViews(g7, 600000);

      final paid = await _pay(bill, 500);
      expect(paid.paidAmountPaise, 50000);
      expect(paid.balanceDuePaise, 50000);
      await _expectAllViews(g7, 550000);

      // Ledger shows the ₹5,000 as an opening balance, then bill, then payment.
      final ledger = _svc.getVendorLedger(g7).reversed.toList();
      expect(ledger.map((e) => e.type).toList(),
          ['Opening Balance', 'Purchase Bill', 'Bill Payment']);
      expect(ledger.map((e) => e.runningBalancePaise).toList(),
          [500000, 600000, 550000]);
    });

    test('new bill fully paid does not change payable', () async {
      final v = await _vendor('Full Pay Co', owed: 2000);
      await _confirm(v, 1500, paid: 1500);
      await _expectAllViews(v, 200000);
    });

    test('new bill partly paid adds only the unpaid part', () async {
      final v = await _vendor('Part Pay Co', owed: 1000);
      await _confirm(v, 1000, paid: 300);
      await _expectAllViews(v, 170000);
    });

    test('new bill unpaid adds full amount; second bill same day stays ordered',
        () async {
      final v = await _vendor('Unpaid Co');
      final d = DateTime(2026, 11, 10);
      await _confirm(v, 400, paid: 400, date: d);
      await _confirm(v, 600, date: d);
      await _expectAllViews(v, 60000);
      // On the same date a bill is listed before its payment, so the running
      // balance never goes negative.
      for (final e in _svc.getVendorLedger(v)) {
        expect(e.runningBalancePaise, greaterThanOrEqualTo(0));
      }
    });

    test('payment on account (advance) reduces payable and shows in ledger',
        () async {
      final v = await _vendor('On Account Co', owed: 5000);
      await _confirm(v, 1000);
      await _svc.recordAdvancePayment(
        vendorKey: v,
        vendorName: 'On Account Co',
        amount: 2500,
        paymentDate: DateTime(2026, 11, 26),
        paymentMethod: 'UPI',
        transactionReference: 'ADV-1',
        staffId: 'S1',
        staffName: 'Owner',
      );
      await _expectAllViews(v, 350000);
    });

    test('payment larger than bill due is rejected (use on-account instead)',
        () async {
      final v = await _vendor('Overpay Co');
      final bill = await _confirm(v, 1000);
      await expectLater(_pay(bill, 1500), throwsException);
      await _expectAllViews(v, 100000);
    });

    test('edit: raising bill total adds only the difference', () async {
      final v = await _vendor('Edit Up Co', owed: 5000);
      final bill = await _confirm(v, 1000, paid: 200);
      await _expectAllViews(v, 580000);
      final edited = await _svc.updateConfirmedPurchaseBill(
        originalBill: bill,
        vendorInvoiceNumber: bill.vendorInvoiceNumber,
        vendorKey: v,
        vendorName: bill.vendorName,
        vendorPhone: bill.vendorPhone,
        purchaseDate: bill.purchaseDate,
        items: [bill.items.first.copyWith(purchaseRate: 1800)],
        staffId: 'S1',
        staffName: 'Owner',
      );
      expect(edited.grandTotalPaise, 180000);
      expect(edited.balanceDuePaise, 160000);
      await _expectAllViews(v, 660000);
    });

    test('edit: extra payment entered on edit is counted once', () async {
      final v = await _vendor('Edit Pay Co', owed: 5000);
      final bill = await _confirm(v, 1000);
      final edited = await _svc.updateConfirmedPurchaseBill(
        originalBill: bill,
        vendorInvoiceNumber: bill.vendorInvoiceNumber,
        vendorKey: v,
        vendorName: bill.vendorName,
        vendorPhone: bill.vendorPhone,
        purchaseDate: bill.purchaseDate,
        items: bill.items,
        paidAmount: 500,
        staffId: 'S1',
        staffName: 'Owner',
      );
      expect(edited.paidAmountPaise, 50000);
      await _expectAllViews(v, 550000);
    });

    test('edit: lowering "paid" cannot un-pay money already paid', () async {
      final v = await _vendor('Edit Unpay Co');
      final bill = await _confirm(v, 1000, paid: 600);
      await _expectAllViews(v, 40000);
      final edited = await _svc.updateConfirmedPurchaseBill(
        originalBill: bill,
        vendorInvoiceNumber: bill.vendorInvoiceNumber,
        vendorKey: v,
        vendorName: bill.vendorName,
        vendorPhone: bill.vendorPhone,
        purchaseDate: bill.purchaseDate,
        items: bill.items,
        paidAmount: 100, // before the fix this raised the payable to ₹900
        staffId: 'S1',
        staffName: 'Owner',
      );
      expect(edited.paidAmountPaise, 60000);
      await _expectAllViews(v, 40000);
    });

    test('edit: total cut below amount paid leaves vendor credit', () async {
      final v = await _vendor('Edit Down Co', owed: 1000);
      final bill = await _confirm(v, 1000, paid: 1000);
      final edited = await _svc.updateConfirmedPurchaseBill(
        originalBill: bill,
        vendorInvoiceNumber: bill.vendorInvoiceNumber,
        vendorKey: v,
        vendorName: bill.vendorName,
        vendorPhone: bill.vendorPhone,
        purchaseDate: bill.purchaseDate,
        items: [bill.items.first.copyWith(purchaseRate: 700)],
        staffId: 'S1',
        staffName: 'Owner',
      );
      expect(edited.balanceDuePaise, 0);
      // Paid ₹1,000 for a ₹700 bill → ₹300 credit against the ₹1,000 owed.
      await _expectAllViews(v, 70000);
    });

    test('edit: changing vendor moves bill AND its payments', () async {
      final a = await _vendor('Vendor A', owed: 2000);
      final b = await _vendor('Vendor B', owed: 3000);
      final bill = await _confirm(a, 1000, paid: 400);
      await _expectAllViews(a, 260000);
      await _svc.updateConfirmedPurchaseBill(
        originalBill: bill,
        vendorInvoiceNumber: bill.vendorInvoiceNumber,
        vendorKey: b,
        vendorName: 'Vendor B',
        vendorPhone: bill.vendorPhone,
        purchaseDate: bill.purchaseDate,
        items: bill.items,
        staffId: 'S1',
        staffName: 'Owner',
      );
      await _expectAllViews(a, 200000);
      await _expectAllViews(b, 360000);
      expect(_svc.getPaymentsForVendor(a), isEmpty);
      expect(_svc.getPaymentsForVendor(b).single.amountPaise, 40000);
    });

    test('draft bill with paid amount touches no balance and no ledger',
        () async {
      final v = await _vendor('Draft Co', owed: 1000);
      await _svc.savePurchaseBill(
        vendorInvoiceNumber: 'DRAFT-1',
        vendorKey: v,
        vendorName: 'Draft Co',
        vendorPhone: '9000000000',
        purchaseDate: DateTime(2026, 11, 5),
        items: [_item(800)],
        initialPaidAmount: 300,
        staffId: 'S1',
        staffName: 'Owner',
        isDraft: true,
      );
      expect(_svc.getPaymentsForVendor(v), isEmpty);
      expect(_svc.getVendorSummary(v)['billsCount'], 0);
      await _expectAllViews(v, 100000);
    });

    test('old Purchases screen credit purchase appears in the vendor ledger',
        () async {
      final v = await _vendor('Legacy Credit Co');
      await Db.purchases.add({
        'createdAt': DateTime(2026, 10, 1).toIso8601String(),
        'supplierKey': v,
        'supplierName': 'Legacy Credit Co',
        'itemName': 'Battery',
        'qty': 2,
        'unitCost': 250.0,
        'total': 500.0,
        'mode': 'Credit',
      });
      await Db.adjustParty(v, -500); // what the old Purchases screen does
      await _confirm(v, 1000, paid: 1000);
      await _expectAllViews(v, 50000);
      final types = _svc.getVendorLedger(v).map((e) => e.type).toList();
      expect(types, contains('Purchase (Credit)'));
      expect(types, isNot(contains('Opening Balance')));
    });

    test('G7 return case: ₹5,000 owed + ₹1,000 bill − ₹500 payment − ₹1,000 return = ₹4,500',
        () async {
      final g7 = await _vendor('G7 Return', owed: 5000);
      await _expectAllViews(g7, 500000);

      final bill = await _confirm(g7, 1000);
      await _expectAllViews(g7, 600000);

      final paid = await _pay(bill, 500);
      expect(paid.balanceDuePaise, 50000);
      await _expectAllViews(g7, 550000);

      // Return ₹1,000 with credit note
      await _svc.recordPurchaseReturn(
        vendorKey: g7,
        vendorName: 'G7 Return',
        billNumber: bill.billNumber,
        billKey: bill.key,
        returnAmountPaise: 100000,
        returnDate: DateTime(2026, 11, 26),
        reason: 'Defective batch returned',
        returnType: 'credit_note',
        staffId: 'S1',
        staffName: 'Owner',
      );
      await _expectAllViews(g7, 450000);

      final ledger = _svc.getVendorLedger(g7).reversed.toList();
      expect(ledger.map((e) => e.type).toList(),
          ['Opening Balance', 'Purchase Bill', 'Bill Payment', 'Purchase Return']);
      expect(ledger.map((e) => e.runningBalancePaise).toList(),
          [500000, 600000, 550000, 450000]);
    });

    test('G7 delete case: ₹5,000 owed + ₹1,000 bill − ₹500 payment, delete bill leaves ₹4,500 owed',
        () async {
      final g7 = await _vendor('G7 Delete', owed: 5000);
      await _expectAllViews(g7, 500000);

      final bill = await _confirm(g7, 1000);
      await _expectAllViews(g7, 600000);

      final paid = await _pay(bill, 500);
      expect(paid.balanceDuePaise, 50000);
      await _expectAllViews(g7, 550000);

      // Delete the bill
      await _svc.deletePurchaseBill(bill.key, reason: 'Wrong invoice entered');
      // ₹5,000 opening + 0 bills − ₹500 payment = ₹4,500 owed
      await _expectAllViews(g7, 450000);

      // Bill payment is preserved as advance credit
      final payments = _svc.getPaymentsForVendor(g7);
      expect(payments.length, 1);
      expect(payments.first.isAdvance, isTrue);
      expect(payments.first.amountPaise, 50000);
    });

    test('delete unpaid bill returns vendor balance exactly to opening', () async {
      final v = await _vendor('Unpaid Delete Co', owed: 5000);
      await _expectAllViews(v, 500000);

      final bill = await _confirm(v, 1000);
      await _expectAllViews(v, 600000);

      await _svc.deletePurchaseBill(bill.key, reason: 'Duplicate bill');
      await _expectAllViews(v, 500000);
      expect(_svc.getPurchaseBill(bill.key)!.isVoided, isTrue);
      expect(_svc.getPurchaseBill(bill.key)!.paymentStatus, 'voided');
    });

    test('delete fully paid bill leaves full advance credit', () async {
      final v = await _vendor('Fully Paid Delete Co', owed: 5000);
      await _expectAllViews(v, 500000);

      final bill = await _confirm(v, 1000, paid: 1000);
      // Fully paid, so vendor balance is still 5,000
      await _expectAllViews(v, 500000);

      await _svc.deletePurchaseBill(bill.key, reason: 'Cancelled purchase');
      // Reverses ₹1,000 bill, ₹1,000 payment becomes advance credit → owes ₹4,000
      await _expectAllViews(v, 400000);

      final payments = _svc.getPaymentsForVendor(v);
      expect(payments.length, 1);
      expect(payments.first.isAdvance, isTrue);
      expect(payments.first.amountPaise, 100000);
    });

    test('deleting draft bill touches no balance and no payments', () async {
      final v = await _vendor('Draft Delete Co', owed: 5000);
      await _expectAllViews(v, 500000);

      final draft = await _svc.savePurchaseBill(
        vendorInvoiceNumber: 'DRAFT-DEL',
        vendorKey: v,
        vendorName: 'Draft Delete Co',
        vendorPhone: '9000000000',
        purchaseDate: DateTime(2026, 11, 5),
        items: [_item(800)],
        staffId: 'S1',
        staffName: 'Owner',
        isDraft: true,
      );
      await _expectAllViews(v, 500000);

      await _svc.deletePurchaseBill(draft.key, reason: 'Discard draft');
      await _expectAllViews(v, 500000);
      expect(_svc.getPurchaseBill(draft.key), isNull);
    });

    test('inventory stock is restored on bill delete and decremented on return', () async {
      final itemKey = await Db.items.add({
        'name': 'OLED Panel',
        'stock': 10,
        'cost': 500.0,
      });

      final v = await _vendor('Stock Co');
      _billSeq++;
      final bill = await _svc.confirmPurchaseBill(
        billNumber: 'PB-STOCK-$_billSeq',
        vendorInvoiceNumber: 'INV-STOCK-$_billSeq',
        vendorKey: v,
        vendorName: 'Stock Co',
        vendorPhone: '9000000000',
        purchaseDate: DateTime(2026, 11, 15),
        items: [
          PurchaseBillItem(
            id: 'oled_1',
            itemKey: itemKey,
            name: 'OLED Panel',
            quantity: 5,
            purchaseRate: 500.0,
          ),
        ],
        staffId: 'S1',
        staffName: 'Owner',
      );

      // Stock was 10 + 5 = 15
      expect((Db.items.get(itemKey) as Map)['stock'], 15);

      // Return 2 items
      await _svc.recordPurchaseReturn(
        vendorKey: v,
        vendorName: 'Stock Co',
        billNumber: bill.billNumber,
        billKey: bill.key,
        returnAmountPaise: 100000,
        reason: '2 panels damaged',
        returnType: 'credit_note',
        staffId: 'S1',
        staffName: 'Owner',
        returnedItems: [
          {'itemId': itemKey, 'quantity': 2},
        ],
      );
      // Stock becomes 15 - 2 = 13
      expect((Db.items.get(itemKey) as Map)['stock'], 13);

      // Now delete the bill (original qty 5)
      await _svc.deletePurchaseBill(bill.key, reason: 'Bill cancelled');
      // Stock reduces by 5 -> 13 - 5 = 8
      expect((Db.items.get(itemKey) as Map)['stock'], 8);
    });

    test('staff refused: deletePurchaseBill and recordPurchaseReturn reject non-owner', () async {
      final v = await _vendor('Staff Reject Co', owed: 1000);
      final bill = await _confirm(v, 500);

      PurchaseBillService.ownerCheckForTesting = false;
      try {
        // Even if caller passes 'S1' or 'owner' or 'admin', non-owner is strictly rejected
        expect(
          () => _svc.deletePurchaseBill(bill.key, staffId: 'S1', staffName: 'owner'),
          throwsA(isA<StateError>()),
        );
        expect(
          () => _svc.deletePurchaseBill(bill.key, staffId: 'admin', staffName: 'admin'),
          throwsA(isA<StateError>()),
        );
        expect(
          () => _svc.deletePurchaseBill(bill.key, staffId: 'emp_01', staffName: 'Staff Emp'),
          throwsA(isA<StateError>()),
        );

        expect(
          () => _svc.recordPurchaseReturn(
            vendorKey: v,
            vendorName: 'Staff Reject Co',
            billNumber: bill.billNumber,
            billKey: bill.key,
            returnAmountPaise: 20000,
            staffId: 'S1',
            staffName: 'owner',
          ),
          throwsA(isA<StateError>()),
        );
        expect(
          () => _svc.recordPurchaseReturn(
            vendorKey: v,
            vendorName: 'Staff Reject Co',
            billNumber: bill.billNumber,
            billKey: bill.key,
            returnAmountPaise: 20000,
            staffId: 'admin',
            staffName: 'admin',
          ),
          throwsA(isA<StateError>()),
        );
        expect(
          () => _svc.recordPurchaseReturn(
            vendorKey: v,
            vendorName: 'Staff Reject Co',
            billNumber: bill.billNumber,
            billKey: bill.key,
            returnAmountPaise: 20000,
            staffId: 'emp_01',
            staffName: 'Staff Emp',
          ),
          throwsA(isA<StateError>()),
        );
      } finally {
        PurchaseBillService.ownerCheckForTesting = true;
      }
    });

    test('void twice: balance and stock are adjusted once only', () async {
      final itemKey = await Db.items.add({
        'name': 'Void Item',
        'stock': 20,
        'cost': 100.0,
      });
      final v = await _vendor('Double Void Co', owed: 5000);
      _billSeq++;
      final bill = await _svc.confirmPurchaseBill(
        billNumber: 'PB-VOID-$_billSeq',
        vendorInvoiceNumber: 'INV-VOID-$_billSeq',
        vendorKey: v,
        vendorName: 'Double Void Co',
        vendorPhone: '9000000000',
        purchaseDate: DateTime(2026, 11, 15),
        items: [
          PurchaseBillItem(
            id: 'void_it_1',
            itemKey: itemKey,
            name: 'Void Item',
            quantity: 5,
            purchaseRate: 100.0,
          ),
        ],
        staffId: 'S1',
        staffName: 'Owner',
      );
      // Stock 20 + 5 = 25, Owed 5000 + 500 = 5500
      expect((Db.items.get(itemKey) as Map)['stock'], 25);
      await _expectAllViews(v, 550000);

      // First void
      await _svc.deletePurchaseBill(bill.key, reason: 'First void');
      expect((Db.items.get(itemKey) as Map)['stock'], 20);
      await _expectAllViews(v, 500000);

      // Second void (must be no-op!)
      await _svc.deletePurchaseBill(bill.key, reason: 'Second void');
      expect((Db.items.get(itemKey) as Map)['stock'], 20);
      await _expectAllViews(v, 500000);
    });

    test('same return ID given twice saves once only (idempotent)', () async {
      final v = await _vendor('Idempotent Return Co', owed: 5000);
      final bill = await _confirm(v, 1000);
      await _expectAllViews(v, 600000);

      const retId = 'PR-2026-TEST-UNIQUE-01';
      // First call
      await _svc.recordPurchaseReturn(
        vendorKey: v,
        vendorName: 'Idempotent Return Co',
        billNumber: bill.billNumber,
        billKey: bill.key,
        returnAmountPaise: 40000,
        returnReference: retId,
        staffId: 'S1',
        staffName: 'Owner',
      );
      await _expectAllViews(v, 560000);

      // Second call with same retId
      await _svc.recordPurchaseReturn(
        vendorKey: v,
        vendorName: 'Idempotent Return Co',
        billNumber: bill.billNumber,
        billKey: bill.key,
        returnAmountPaise: 40000,
        returnReference: retId,
        staffId: 'S1',
        staffName: 'Owner',
      );
      // Still 560,000! Not 520,000!
      await _expectAllViews(v, 560000);
    });

    test('return > bill is refused with exact error message', () async {
      final v = await _vendor('Excess Return Co', owed: 2000);
      final bill = await _confirm(v, 1000);

      // Single return exceeding bill total
      expect(
        () => _svc.recordPurchaseReturn(
          vendorKey: v,
          vendorName: 'Excess Return Co',
          billNumber: bill.billNumber,
          billKey: bill.key,
          returnAmountPaise: 150000, // ₹1,500 > ₹1,000
          staffId: 'S1',
          staffName: 'Owner',
        ),
        throwsA(predicate((e) =>
            e is ArgumentError &&
            e.message.toString().contains('Return exceeds bill'))),
      );

      // Partial return ₹700 (valid)
      await _svc.recordPurchaseReturn(
        vendorKey: v,
        vendorName: 'Excess Return Co',
        billNumber: bill.billNumber,
        billKey: bill.key,
        returnAmountPaise: 70000,
        staffId: 'S1',
        staffName: 'Owner',
      );

      // Second return of ₹400 (700 + 400 = 1100 > 1000, invalid!)
      expect(
        () => _svc.recordPurchaseReturn(
          vendorKey: v,
          vendorName: 'Excess Return Co',
          billNumber: bill.billNumber,
          billKey: bill.key,
          returnAmountPaise: 40000,
          staffId: 'S1',
          staffName: 'Owner',
        ),
        throwsA(predicate((e) =>
            e is ArgumentError &&
            e.message.toString().contains('Return exceeds bill'))),
      );
    });

    test('voided bill is excluded from vendor ledger and payable', () async {
      final v = await _vendor('Voided Omission Co', owed: 3000);
      final bill = await _confirm(v, 1500, paid: 500);
      // Owed = 3000 + 1000 due = 4000
      await _expectAllViews(v, 400000);

      await _svc.deletePurchaseBill(bill.key, reason: 'Mistake');
      // Voiding bill removes 1500 obligation, payment of 500 becomes advance -> owes 2500
      await _expectAllViews(v, 250000);

      final ledger = _svc.getVendorLedger(v);
      for (final e in ledger) {
        expect(e.reference, isNot(bill.billNumber));
        expect(e.type, isNot('Purchase Bill'));
      }
      expect(_svc.getPurchaseBill(bill.key)!.isVoided, isTrue);
      expect(_svc.getPurchaseBill(bill.key)!.paymentStatus, 'voided');
    });
  });
}
