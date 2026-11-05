import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/expenses/expense_models.dart';
import 'package:tekfix_erp_pos/expenses/expense_service.dart';

void main() {
  group('Master Expense Duplication & Integrity Test Suite', () {
    final now = DateTime.now();

    test('1. Single ₹20 Cash expense calculation integrity', () {
      final cashExpense = ExpenseItem(
        id: 'EXP_TEST_001',
        shopId: 'tekfix',
        title: 'Tea & Snacks',
        category: ExpenseCategory.refreshmentsAndFood,
        amount: 20.0,
        amountPaise: 2000,
        paymentMode: ExpensePaymentMode.cash,
        expenseDate: now,
        recordedByUid: 'staff_1',
        recordedByName: 'Staff Member',
        createdAt: now,
      );

      final metrics = ExpenseService.instance.computeMetricsFromList([cashExpense]);

      expect(metrics.todayCount, 1);
      expect(metrics.todayTotal, 20.0);
      expect(metrics.todayCashTotal, 20.0);
      expect(metrics.todayUpiTotal, 0.0);
      expect(metrics.todayBankTotal, 0.0);
      expect(metrics.todayTotalPaise, 2000);
      expect(metrics.todayCashTotalPaise, 2000);
    });

    test('2. Adding ₹100 UPI expense creates accurate segregated totals (₹120 total, ₹20 cash, ₹100 UPI)', () {
      final cashExpense = ExpenseItem(
        id: 'EXP_TEST_001',
        shopId: 'tekfix',
        title: 'Tea & Snacks',
        category: ExpenseCategory.refreshmentsAndFood,
        amount: 20.0,
        amountPaise: 2000,
        paymentMode: ExpensePaymentMode.cash,
        expenseDate: now,
        recordedByUid: 'staff_1',
        recordedByName: 'Staff Member',
        createdAt: now,
      );

      final upiExpense = ExpenseItem(
        id: 'EXP_TEST_002',
        shopId: 'tekfix',
        title: 'Packing Material',
        category: ExpenseCategory.stationeryAndPacking,
        amount: 100.0,
        amountPaise: 10000,
        paymentMode: ExpensePaymentMode.upi,
        expenseDate: now,
        recordedByUid: 'staff_1',
        recordedByName: 'Staff Member',
        createdAt: now,
      );

      final metrics = ExpenseService.instance.computeMetricsFromList([cashExpense, upiExpense]);

      expect(metrics.todayCount, 2);
      expect(metrics.todayTotal, 120.0);
      expect(metrics.todayCashTotal, 20.0);
      expect(metrics.todayUpiTotal, 100.0);
      expect(metrics.todayBankTotal, 0.0);
      expect(metrics.todayTotalPaise, 12000);
      expect(metrics.todayCashTotalPaise, 2000);
      expect(metrics.todayUpiTotalPaise, 10000);
    });

    test('3. Document ID Deduplication: Identical doc IDs merge; distinct doc IDs remain separate', () {
      // Simulate raw stream or Hive events arriving twice for the same doc ID
      final itemDoc1 = ExpenseItem(
        id: 'EXP_SAME_DOC_ID',
        shopId: 'tekfix',
        title: 'Tea & Snacks',
        category: ExpenseCategory.refreshmentsAndFood,
        amount: 20.0,
        amountPaise: 2000,
        paymentMode: ExpensePaymentMode.cash,
        expenseDate: now,
        recordedByUid: 'staff_1',
        recordedByName: 'Staff Member',
        createdAt: now,
      );

      final itemDoc1Duplicate = ExpenseItem(
        id: 'EXP_SAME_DOC_ID',
        shopId: 'tekfix',
        title: 'Tea & Snacks',
        category: ExpenseCategory.refreshmentsAndFood,
        amount: 20.0,
        amountPaise: 2000,
        paymentMode: ExpensePaymentMode.cash,
        expenseDate: now,
        recordedByUid: 'staff_1',
        recordedByName: 'Staff Member',
        createdAt: now,
      );

      // Distinct doc ID for a legitimate second tea purchase
      final legitimateSecondExpense = ExpenseItem(
        id: 'EXP_DISTINCT_DOC_ID',
        shopId: 'tekfix',
        title: 'Tea & Snacks',
        category: ExpenseCategory.refreshmentsAndFood,
        amount: 20.0,
        amountPaise: 2000,
        paymentMode: ExpensePaymentMode.cash,
        expenseDate: now,
        recordedByUid: 'staff_1',
        recordedByName: 'Staff Member',
        createdAt: now.add(const Duration(hours: 3)),
      );

      final rawStreamList = [itemDoc1, itemDoc1Duplicate, legitimateSecondExpense];

      // Standard deduplication map used across screens and services
      final Map<String, ExpenseItem> dedupMap = {};
      for (final exp in rawStreamList) {
        dedupMap[exp.id] = exp;
      }
      final dedupedList = dedupMap.values.toList();

      expect(dedupedList.length, 2);
      expect(dedupedList.any((e) => e.id == 'EXP_SAME_DOC_ID'), isTrue);
      expect(dedupedList.any((e) => e.id == 'EXP_DISTINCT_DOC_ID'), isTrue);

      final metrics = ExpenseService.instance.computeMetricsFromList(dedupedList);
      expect(metrics.todayTotal, 40.0);
      expect(metrics.todayCashTotal, 40.0);
      expect(metrics.todayCount, 2);
    });

    test('4. Voiding an expense removes ONLY that document from totals and sets status = VOIDED', () {
      final cashExpense = ExpenseItem(
        id: 'EXP_TEST_001',
        shopId: 'tekfix',
        title: 'Tea & Snacks',
        category: ExpenseCategory.refreshmentsAndFood,
        amount: 20.0,
        amountPaise: 2000,
        paymentMode: ExpensePaymentMode.cash,
        expenseDate: now,
        recordedByUid: 'staff_1',
        recordedByName: 'Staff Member',
        isVoided: true,
        voidReason: 'Entered by mistake',
        voidedAt: now,
        voidedByUid: 'owner_1',
      );

      final upiExpense = ExpenseItem(
        id: 'EXP_TEST_002',
        shopId: 'tekfix',
        title: 'Packing Material',
        category: ExpenseCategory.stationeryAndPacking,
        amount: 100.0,
        amountPaise: 10000,
        paymentMode: ExpensePaymentMode.upi,
        expenseDate: now,
        recordedByUid: 'staff_1',
        recordedByName: 'Staff Member',
        isVoided: false,
      );

      expect(cashExpense.status, 'VOIDED');
      expect(upiExpense.status, 'ACTIVE');

      final metrics = ExpenseService.instance.computeMetricsFromList([cashExpense, upiExpense]);

      // Only active UPI expense of 100 must count; voided 20 cash must NOT contribute
      expect(metrics.todayCount, 1);
      expect(metrics.todayTotal, 100.0);
      expect(metrics.todayCashTotal, 0.0);
      expect(metrics.todayUpiTotal, 100.0);
      expect(metrics.todayBankTotal, 0.0);
      expect(metrics.todayTotalPaise, 10000);
      expect(metrics.todayCashTotalPaise, 0);
    });

    test('5. Expense serialization and deserialization preserves canonical id, _id and paise', () {
      final original = ExpenseItem(
        id: 'EXP_SERIALIZE_001',
        shopId: 'tekfix',
        title: 'Store Hardware Maintenance',
        category: ExpenseCategory.rentAndMaintenance,
        amount: 350.50,
        amountPaise: 35050,
        paymentMode: ExpensePaymentMode.upi,
        expenseDate: now,
        recordedByUid: 'staff_9',
        recordedByName: 'Technician',
        notes: 'Door hinges and light bulbs',
      );

      final map = original.toMap(forFirestore: false);
      expect(map['id'], 'EXP_SERIALIZE_001');
      expect(map['_id'], 'EXP_SERIALIZE_001');
      expect(map['amountPaise'], 35050);
      expect(map['status'], 'ACTIVE');
      expect(map['paymentMode'], 'UPI');

      final reconstructed = ExpenseItem.fromMap(map, 'dummy_doc_id');
      expect(reconstructed.id, 'EXP_SERIALIZE_001');
      expect(reconstructed.amount, 350.50);
      expect(reconstructed.amountPaise, 35050);
      expect(reconstructed.isUpi, isTrue);
      expect(reconstructed.status, 'ACTIVE');
      expect(reconstructed.isVoided, isFalse);
    });

    test('6. Payment mode normalization supports UPI, BANK, CARD, and CASH', () {
      expect(ExpensePaymentMode.toDisplay(ExpensePaymentMode.cash), 'Cash in Hand (ക്യാഷ്)');
      expect(ExpensePaymentMode.toDisplay(ExpensePaymentMode.upi), 'UPI / GPay / PhonePe (യുപിഐ)');
      expect(ExpensePaymentMode.toDisplay(ExpensePaymentMode.bank), 'Bank Transfer (ബാങ്ക്)');
      expect(ExpensePaymentMode.toDisplay(ExpensePaymentMode.card), 'Card Payment (കാർഡ്)');

      // Ledger routing: UPI/Bank/Card route to digital ledger ('Bank'), Cash to drawer ('Cash')
      expect(ExpensePaymentMode.toLedgerMode('CASH'), 'Cash');
      expect(ExpensePaymentMode.toLedgerMode('UPI'), 'Bank');
      expect(ExpensePaymentMode.toLedgerMode('BANK'), 'Bank');
      expect(ExpensePaymentMode.toLedgerMode('CARD'), 'Bank');
    });
  });
}
