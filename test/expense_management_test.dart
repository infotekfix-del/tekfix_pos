import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/expenses/expense_models.dart';
import 'package:tekfix_erp_pos/expenses/expense_service.dart';
import 'package:tekfix_erp_pos/pos/daily_register_models.dart';
import 'package:tekfix_erp_pos/pos/daily_register_service.dart';

void main() {
  group('Expense Management Module Tests', () {
    late Directory tempDir;

    setUpAll(() async {
      GoogleFonts.config.allowRuntimeFetching = false;
      tempDir = await Directory.systemTemp.createTemp('expense_test_');
      Hive.init(tempDir.path);

      for (final b in allBoxes) {
        await Hive.openBox(b);
      }

      final settingsBox = Hive.box(boxSettings);
      await settingsBox.put('store_state_code', '32');
      await settingsBox.put('shop_id', 'shop_test_expense');
      await settingsBox.put('shop_name', 'TEKFIX DIGITAL HUB');
      await settingsBox.put('admin_pass', '1234');
    });

    tearDownAll(() async {
      try {
        await Hive.close();
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    setUp(() async {
      await Db.expenses.clear();
      await Db.bank.clear();
      await Db.bank.put('cash_in_hand', 5000.0);
      await Db.bank.put('bank_balance', 25000.0);
      await Db.bank.put('txn_log', <Map<String, dynamic>>[]);
    });

    test('1. Model integrity: amount in INR and integer amountPaise precision',
        () {
      final now = DateTime(2026, 11, 2, 10, 30);
      final expense = ExpenseItem(
        id: 'EXP_TEST_001',
        title: 'Office Tea & Snacks',
        category: ExpenseCategory.foodBeverages,
        amount: 50.0,
        amountPaise: 5000,
        paymentMode: ExpensePaymentMode.cash,
        expenseDate: now,
        recordedByUid: 'staff_anoop',
        recordedByName: 'Anoop Kumar',
        notes: 'Evening tea for staff and customers',
      );

      expect(expense.amount, 50.0);
      expect(expense.amountPaise, 5000);
      expect(ExpenseCategory.toMalayalam(expense.category),
          'ഭക്ഷണം & ചായ ചിലവുകൾ');
      expect(expense.paymentMode, 'CASH');

      final map = expense.toMap();
      expect(map['amount'], 50.0);
      expect(map['amountPaise'], 5000);
      expect(map['paymentMode'], 'CASH');

      final deserialized = ExpenseItem.fromMap(map, 'EXP_TEST_001');
      expect(deserialized.id, 'EXP_TEST_001');
      expect(deserialized.amount, 50.0);
      expect(deserialized.amountPaise, 5000);
      expect(deserialized.paymentMode, ExpensePaymentMode.cash);
      expect(deserialized.category, ExpenseCategory.foodBeverages);
      expect(deserialized.isVoided, false);
    });

    test('2. Cash expense creation debits cash_in_hand and logs transaction',
        () async {
      final initialCash = (Db.bank.get('cash_in_hand') as num).toDouble();
      expect(initialCash, 5000.0);

      final now = DateTime.now();
      final item = ExpenseItem(
        id: 'EXP_CASH_01',
        title: 'Packing Covers & Tape',
        category: ExpenseCategory.shopSupplies,
        amount: 50.0,
        amountPaise: 5000,
        paymentMode: ExpensePaymentMode.cash,
        expenseDate: now,
        recordedByUid: 'staff_1',
        recordedByName: 'Rahul',
      );

      final created = await ExpenseService.instance.createExpense(
        shopId: 'shop_test_expense',
        item: item,
      );

      expect(created.id.startsWith('EXP_'), true);

      // Verify Hive storage
      expect(Db.expenses.containsKey(created.id), true);

      // Verify Cash in hand decremented by ₹50
      final updatedCash = (Db.bank.get('cash_in_hand') as num).toDouble();
      expect(updatedCash, initialCash - 50.0);

      // Verify ledger transaction log
      final txnLog = (Db.bank.get('txn_log') as List).cast<Map>();
      expect(txnLog.isNotEmpty, true);
      final lastTxn = txnLog.last;
      expect(lastTxn['account'] ?? lastTxn['mode'], 'Cash');
      expect(lastTxn['amount'], -50.0);
      expect(
          lastTxn['note'].toString().contains('Packing Covers & Tape'), true);
    });

    test('3. Bank expense creation debits bank_balance and logs transaction',
        () async {
      final initialBank = (Db.bank.get('bank_balance') as num).toDouble();
      expect(initialBank, 25000.0);

      final now = DateTime.now();
      final item = ExpenseItem(
        id: 'EXP_BANK_01',
        title: 'Broadband Internet Bill',
        category: ExpenseCategory.utilities,
        amount: 100.0,
        amountPaise: 10000,
        paymentMode: ExpensePaymentMode.bank,
        expenseDate: now,
        recordedByUid: 'staff_1',
        recordedByName: 'Rahul',
      );

      final created = await ExpenseService.instance.createExpense(
        shopId: 'shop_test_expense',
        item: item,
      );

      // Verify Bank balance decremented by ₹100
      final updatedBank = (Db.bank.get('bank_balance') as num).toDouble();
      expect(updatedBank, initialBank - 100.0);

      // Verify Cash in hand remains untouched
      final cash = (Db.bank.get('cash_in_hand') as num).toDouble();
      expect(cash, 5000.0);

      // Verify ledger transaction log
      final txnLog = (Db.bank.get('txn_log') as List).cast<Map>();
      final lastTxn = txnLog.last;
      expect(lastTxn['account'] ?? lastTxn['mode'], 'Bank');
      expect(lastTxn['amount'], -100.0);
    });

    test('4. Voiding an expense creates reversal entry and restores balance',
        () async {
      final cashBefore = (Db.bank.get('cash_in_hand') as num).toDouble();

      final expense = ExpenseItem(
        id: 'EXP_TO_VOID',
        title: 'Cleaning Supplies Mistake',
        category: ExpenseCategory.repairsMaintenance,
        amount: 75.0,
        amountPaise: 7500,
        paymentMode: ExpensePaymentMode.cash,
        expenseDate: DateTime.now(),
        recordedByUid: 'staff_1',
        recordedByName: 'Rahul',
      );

      final created = await ExpenseService.instance.createExpense(
        shopId: 'shop_test_expense',
        item: expense,
      );

      // Balance was debited by 75
      expect(
          (Db.bank.get('cash_in_hand') as num).toDouble(), cashBefore - 75.0);

      // Void the expense
      final voided = await ExpenseService.instance.voidExpense(
        shopId: 'shop_test_expense',
        expenseId: created.id,
        voidedByUid: 'owner_1',
        voidedByName: 'Store Owner',
        voidReason: 'Duplicate entry entered by mistake',
      );

      expect(voided.isVoided, true);
      expect(voided.voidReason, 'Duplicate entry entered by mistake');
      expect(voided.voidedByUid, 'owner_1');

      // Cash balance must be restored (+₹75)
      final restoredCash = (Db.bank.get('cash_in_hand') as num).toDouble();
      expect(restoredCash, cashBefore);

      // Check reversal entry in transaction log
      final txnLog = (Db.bank.get('txn_log') as List).cast<Map>();
      final reversalTxn = txnLog.last;
      expect(reversalTxn['amount'], 75.0);
      expect(
          reversalTxn['note'].toString().contains('Reversal of Expense'), true);
    });

    test(
        '5. EOD Closing reconciliation deducts cash expenses and reports bank expenses separately',
        () {
      final today = DateTime(2026, 11, 2, 22, 0);

      final sales = [
        {
          'invoice': 'INV-2026-101',
          'createdAt': '2026-11-02T11:00:00',
          'subtotal': 500.0,
          'discount': 0.0,
          'total': 500.0,
          'cash': 500.0,
          'upi': 0.0,
          'card': 0.0,
          'due': 0.0,
          'status': 'SOLD',
          'items': [
            {
              'name': 'Tempered Glass',
              'category': 'Accessories',
              'qty': 2,
              'lineTotal': 500.0
            }
          ],
        },
      ];

      // Opening cash: ₹1000, Cash Sales: ₹500, Cash Expense: ₹50, Bank Expense: ₹100
      final summary = DailyRegisterService.instance.computeDailySummary(
        sales: sales,
        date: today,
        openingCash: 1000.0,
        refunds: 0.0,
        totalCashExpenses: 50.0,
        totalBankExpenses: 100.0,
        physicalCashCount: 1450.0,
      );

      // Formula: (Opening Cash + Cash Sales - Refunds - Cash Expenses) = 1000 + 500 - 0 - 50 = 1450
      expect(summary.totalCash, 500.0);
      expect(summary.totalCashExpenses, 50.0);
      expect(summary.totalBankExpenses, 100.0);
      expect(summary.expectedClosingCash, 1450.0);
      expect(summary.actualCashCount, 1450.0);
      expect(summary.cashDiscrepancy, 0.0); // Exact match
      expect(summary.cashOverOrShort, 0.0);

      // Verify shortage detection: staff counts ₹1400 in physical cash
      final shortSummary = DailyRegisterService.instance.computeDailySummary(
        sales: sales,
        date: today,
        openingCash: 1000.0,
        refunds: 0.0,
        totalCashExpenses: 50.0,
        totalBankExpenses: 100.0,
        physicalCashCount: 1400.0,
      );
      expect(shortSummary.cashDiscrepancy, -50.0); // ₹50 shortage

      // Verify overage detection: staff counts ₹1500 in physical cash
      final overSummary = DailyRegisterService.instance.computeDailySummary(
        sales: sales,
        date: today,
        openingCash: 1000.0,
        refunds: 0.0,
        totalCashExpenses: 50.0,
        totalBankExpenses: 100.0,
        physicalCashCount: 1500.0,
      );
      expect(overSummary.cashDiscrepancy, 50.0); // ₹50 overage
    });

    test(
        '6. Expense metrics computation (Today, Month, Cash Today, Bank Today)',
        () async {
      final today = DateTime.now();
      final yesterday = today.subtract(const Duration(days: 1));
      final lastMonth = DateTime(today.year, today.month - 1, 15);

      final exp1 = ExpenseItem(
        id: 'EXP_T1',
        title: 'Today Cash Tea',
        category: ExpenseCategory.foodBeverages,
        amount: 40.0,
        amountPaise: 4000,
        paymentMode: ExpensePaymentMode.cash,
        expenseDate: today,
        recordedByUid: 'u1',
        recordedByName: 'User 1',
      );

      final exp2 = ExpenseItem(
        id: 'EXP_T2',
        title: 'Today Bank Courier',
        category: ExpenseCategory.deliveryFreight,
        amount: 150.0,
        amountPaise: 15000,
        paymentMode: ExpensePaymentMode.bank,
        expenseDate: today,
        recordedByUid: 'u1',
        recordedByName: 'User 1',
      );

      final expVoid = ExpenseItem(
        id: 'EXP_T3_VOID',
        title: 'Today Voided Cash Expense',
        category: ExpenseCategory.utilities,
        amount: 200.0,
        amountPaise: 20000,
        paymentMode: ExpensePaymentMode.cash,
        expenseDate: today,
        recordedByUid: 'u1',
        recordedByName: 'User 1',
        isVoided: true,
      );

      final expYest = ExpenseItem(
        id: 'EXP_Y1',
        title: 'Yesterday Cash Hardware',
        category: ExpenseCategory.repairsMaintenance,
        amount: 300.0,
        amountPaise: 30000,
        paymentMode: ExpensePaymentMode.cash,
        expenseDate: yesterday,
        recordedByUid: 'u1',
        recordedByName: 'User 1',
      );

      final expOld = ExpenseItem(
        id: 'EXP_OLD',
        title: 'Last Month Rent',
        category: ExpenseCategory.rentProperty,
        amount: 5000.0,
        amountPaise: 500000,
        paymentMode: ExpensePaymentMode.bank,
        expenseDate: lastMonth,
        recordedByUid: 'u1',
        recordedByName: 'User 1',
      );

      await Db.expenses.put(exp1.id, exp1.toMap());
      await Db.expenses.put(exp2.id, exp2.toMap());
      await Db.expenses.put(expVoid.id, expVoid.toMap());
      await Db.expenses.put(expYest.id, expYest.toMap());
      await Db.expenses.put(expOld.id, expOld.toMap());

      final metrics = await ExpenseService.instance
          .computeExpenseMetrics(shopId: 'shop_test_expense');

      // Today: exp1 (40) + exp2 (150) = 190. (expVoid is ignored)
      expect(metrics.totalToday, 190.0);
      expect(metrics.cashToday, 40.0);
      expect(metrics.bankToday, 150.0);

      // This Month: exp1 (40) + exp2 (150) + expYest (if in same month)
      final expectedMonth =
          (yesterday.month == today.month) ? (190.0 + 300.0) : 190.0;
      expect(metrics.totalMonth, expectedMonth);
    });
  });
}
