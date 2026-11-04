import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/expenses/expense_models.dart';
import 'package:tekfix_erp_pos/expenses/expense_service.dart';
import 'package:tekfix_erp_pos/owner/owner_finance_models.dart';
import 'package:tekfix_erp_pos/owner/owner_finance_service.dart';
import 'package:tekfix_erp_pos/pos/daily_register_models.dart';
import 'package:tekfix_erp_pos/pos/daily_register_service.dart';

void main() {
  group('Owner Salary (₹20,000 Base) & Excess Drawings Tracking Tests', () {
    late Directory tempDir;
    const testShopId = 'shop_test_owner_finance';

    setUpAll(() async {
      GoogleFonts.config.allowRuntimeFetching = false;
      tempDir = await Directory.systemTemp.createTemp('owner_test_');
      Hive.init(tempDir.path);

      for (final b in allBoxes) {
        await Hive.openBox(b);
      }

      final settingsBox = Hive.box(boxSettings);
      await settingsBox.put('store_state_code', '32');
      await settingsBox.put('shop_id', testShopId);
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
      await Db.settings.clear();
      await Db.bank.clear();
      await Db.bank.put('cash_in_hand', 30000.0);
      await Db.bank.put('bank_balance', 80000.0);
      await Db.bank.put('txn_log', <Map<String, dynamic>>[]);

      await Db.settings.put('store_state_code', '32');
      await Db.settings.put('shop_id', testShopId);
      await Db.settings.put('shop_name', 'TEKFIX DIGITAL HUB');

      // Base Config: ₹20,000 monthly limit (2000000 paise)
      final defaultSettings = OwnerSalarySettings(
        monthlySalaryLimit: 20000.0,
        monthlySalaryLimitPaise: 2000000,
        ownerName: 'Store Owner',
        effectiveDate: DateTime(2026, 1, 1),
      );
      await Db.settings.put('owner_salary_settings', defaultSettings.toMap());
    });

    // -------------------------------------------------------------------------
    // TEST 1: Withdrawal within quota (100% OPEX Salary)
    // -------------------------------------------------------------------------
    test('1. Withdrawal within ₹20,000 quota is 100% Owner Salary (OPEX)',
        () async {
      final initialCash = (Db.bank.get('cash_in_hand') as num).toDouble();
      final initialBank = (Db.bank.get('bank_balance') as num).toDouble();

      final nov10 = DateTime(2026, 11, 10);
      final item = await OwnerFinanceService.instance.recordWithdrawal(
        shopId: testShopId,
        amount: 5000.0,
        paymentMode: 'CASH',
        recordedByUid: 'owner_uid',
        recordedByName: 'Store Owner',
        date: nov10,
        notes: 'November 1st tranche salary',
      );

      // Verify Auto-Classification
      expect(item.totalAmount, 5000.0);
      expect(item.totalAmountPaise, 500000);
      expect(item.salaryPortion, 5000.0);
      expect(item.salaryPortionPaise, 500000);
      expect(item.drawingsPortion, 0.0);
      expect(item.drawingsPortionPaise, 0);
      expect(item.hasSalary, true);
      expect(item.hasDrawings, false);
      expect(item.isSplit, false);

      // Verify Linked Expense in Db.expenses (for P&L)
      expect(item.expenseId != null, true);
      final expRaw = Db.expenses.get(item.expenseId);
      expect(expRaw != null, true);
      final exp = ExpenseItem.fromMap(tekM(expRaw), item.expenseId!);
      expect(exp.amount, 5000.0);
      expect(exp.category, 'Shop Owner Salary');
      expect(exp.isOwnerWithdrawal, true);

      // Verify Cash debited by ₹5,000 and Bank untouched
      expect((Db.bank.get('cash_in_hand') as num).toDouble(),
          initialCash - 5000.0);
      expect((Db.bank.get('bank_balance') as num).toDouble(), initialBank);

      // Verify Quota Metrics
      final metrics = await OwnerFinanceService.instance.getQuotaMetrics(
        shopId: testShopId,
        forDate: nov10,
      );
      expect(metrics.usedSalaryThisMonth, 5000.0);
      expect(metrics.remainingSalaryThisMonth, 15000.0);
      expect(metrics.excessDrawingsThisMonth, 0.0);
      expect(metrics.isQuotaFull, false);
    });

    // -------------------------------------------------------------------------
    // TEST 2: Withdrawal crossing the threshold midway (Auto-Split)
    // -------------------------------------------------------------------------
    test('2. Withdrawal crossing ₹20,000 threshold midway splits automatically',
        () async {
      final nov12 = DateTime(2026, 11, 12);

      // Step 1: Pre-withdraw ₹18,000 (remaining quota becomes ₹2,000)
      await OwnerFinanceService.instance.recordWithdrawal(
        shopId: testShopId,
        amount: 18000.0,
        paymentMode: 'CASH',
        recordedByUid: 'owner_uid',
        recordedByName: 'Store Owner',
        date: nov12,
      );

      final metricsBefore = await OwnerFinanceService.instance.getQuotaMetrics(
        shopId: testShopId,
        forDate: nov12,
      );
      expect(metricsBefore.usedSalaryThisMonth, 18000.0);
      expect(metricsBefore.remainingSalaryThisMonth, 2000.0);

      final cashBefore = (Db.bank.get('cash_in_hand') as num).toDouble();

      // Step 2: Now withdraw ₹5,000 (must split: ₹2,000 Salary + ₹3,000 Excess Drawings)
      final splitItem = await OwnerFinanceService.instance.recordWithdrawal(
        shopId: testShopId,
        amount: 5000.0,
        paymentMode: 'CASH',
        recordedByUid: 'owner_uid',
        recordedByName: 'Store Owner',
        date: nov12,
        notes: 'Mid-month personal withdrawal',
      );

      // Verify Auto-Split calculation
      expect(splitItem.totalAmount, 5000.0);
      expect(splitItem.salaryPortion, 2000.0);
      expect(splitItem.salaryPortionPaise, 200000);
      expect(splitItem.drawingsPortion, 3000.0);
      expect(splitItem.drawingsPortionPaise, 300000);
      expect(splitItem.isSplit, true);
      expect(splitItem.hasSalary, true);
      expect(splitItem.hasDrawings, true);

      // Cash debited by full ₹5,000 (single financial debit)
      final cashAfter = (Db.bank.get('cash_in_hand') as num).toDouble();
      expect(cashAfter, cashBefore - 5000.0);

      // Linked expense created ONLY for the ₹2,000 salary portion
      final expRaw = Db.expenses.get(splitItem.expenseId);
      expect(expRaw != null, true);
      final exp = ExpenseItem.fromMap(tekM(expRaw), splitItem.expenseId!);
      expect(exp.amount, 2000.0); // Only salary portion in P&L
      expect(exp.amountPaise, 200000);

      // Verify Quota Metrics: Salary capped at ₹20,000, Drawings = ₹3,000
      final metricsAfter = await OwnerFinanceService.instance.getQuotaMetrics(
        shopId: testShopId,
        forDate: nov12,
      );
      expect(metricsAfter.usedSalaryThisMonth, 20000.0);
      expect(metricsAfter.remainingSalaryThisMonth, 0.0);
      expect(metricsAfter.excessDrawingsThisMonth, 3000.0);
      expect(metricsAfter.totalWithdrawnThisMonth, 23000.0);
      expect(metricsAfter.isQuotaFull, true);
    });

    // -------------------------------------------------------------------------
    // TEST 3: Pure Excess Drawings after quota full (Non-expense Equity)
    // -------------------------------------------------------------------------
    test(
        '3. Withdrawal when quota is already full is 100% Owner Drawings (Equity)',
        () async {
      final nov15 = DateTime(2026, 11, 15);

      // Exhaust full ₹20,000 quota
      await OwnerFinanceService.instance.recordWithdrawal(
        shopId: testShopId,
        amount: 20000.0,
        paymentMode: 'CASH',
        recordedByUid: 'owner_uid',
        recordedByName: 'Store Owner',
        date: nov15,
      );

      // Now withdraw an additional ₹4,000
      final drawingsItem = await OwnerFinanceService.instance.recordWithdrawal(
        shopId: testShopId,
        amount: 4000.0,
        paymentMode: 'CASH',
        recordedByUid: 'owner_uid',
        recordedByName: 'Store Owner',
        date: nov15,
        notes: 'Excess personal drawings',
      );

      // Verify classification
      expect(drawingsItem.totalAmount, 4000.0);
      expect(drawingsItem.salaryPortion, 0.0);
      expect(drawingsItem.drawingsPortion, 4000.0);
      expect(drawingsItem.drawingsPortionPaise, 400000);
      expect(drawingsItem.hasSalary, false);
      expect(drawingsItem.hasDrawings, true);
      expect(drawingsItem.expenseId, null); // No expense record created!

      // Metrics verification
      final metrics = await OwnerFinanceService.instance.getQuotaMetrics(
        shopId: testShopId,
        forDate: nov15,
      );
      expect(metrics.usedSalaryThisMonth, 20000.0);
      expect(metrics.excessDrawingsThisMonth, 4000.0);
      expect(metrics.totalWithdrawnThisMonth, 24000.0);
    });

    // -------------------------------------------------------------------------
    // TEST 4: Bank / UPI Owner Withdrawal
    // -------------------------------------------------------------------------
    test(
        '4. Bank withdrawal debits bank_balance and leaves cash_in_hand untouched',
        () async {
      final initialCash = (Db.bank.get('cash_in_hand') as num).toDouble();
      final initialBank = (Db.bank.get('bank_balance') as num).toDouble();

      final nov18 = DateTime(2026, 11, 18);
      final item = await OwnerFinanceService.instance.recordWithdrawal(
        shopId: testShopId,
        amount: 3000.0,
        paymentMode: 'BANK',
        recordedByUid: 'owner_uid',
        recordedByName: 'Store Owner',
        date: nov18,
      );

      expect(item.isBank, true);
      expect(item.isCash, false);

      // Verify Bank balance decremented by ₹3,000
      expect((Db.bank.get('bank_balance') as num).toDouble(),
          initialBank - 3000.0);

      // Verify Cash in hand remains untouched
      expect((Db.bank.get('cash_in_hand') as num).toDouble(), initialCash);

      // Check transaction log
      final txnLog = (Db.bank.get('txn_log') as List).cast<Map>();
      final lastTxn = txnLog.last;
      expect(lastTxn['account'] ?? lastTxn['mode'], 'Bank');
      expect(lastTxn['amount'], -3000.0);
    });

    // -------------------------------------------------------------------------
    // TEST 5: Voiding a withdrawal reverses balances and quota
    // -------------------------------------------------------------------------
    test(
        '5. Voiding an owner withdrawal restores cash/bank balance and reverses quota',
        () async {
      final nov20 = DateTime(2026, 11, 20);

      final item = await OwnerFinanceService.instance.recordWithdrawal(
        shopId: testShopId,
        amount: 6000.0,
        paymentMode: 'CASH',
        recordedByUid: 'owner_uid',
        recordedByName: 'Store Owner',
        date: nov20,
      );

      final cashBeforeVoid = (Db.bank.get('cash_in_hand') as num).toDouble();

      // Void the withdrawal
      final voided = await OwnerFinanceService.instance.voidWithdrawal(
        shopId: testShopId,
        withdrawalId: item.id,
        voidedByUid: 'owner_uid',
        voidedByName: 'Owner',
        voidReason: 'Mistaken withdrawal entry',
      );

      expect(voided.isVoided, true);
      expect(voided.voidReason, 'Mistaken withdrawal entry');

      // Cash balance restored (+₹6,000)
      final cashAfterVoid = (Db.bank.get('cash_in_hand') as num).toDouble();
      expect(cashAfterVoid, cashBeforeVoid + 6000.0);

      // Linked expense marked isVoided = true
      if (item.expenseId != null) {
        final expRaw = Db.expenses.get(item.expenseId);
        expect(expRaw != null, true);
        expect(tekM(expRaw)['isVoided'], true);
      }

      // Quota is freed up again
      final metrics = await OwnerFinanceService.instance.getQuotaMetrics(
        shopId: testShopId,
        forDate: nov20,
      );
      expect(metrics.usedSalaryThisMonth, 0.0);
      expect(metrics.remainingSalaryThisMonth, 20000.0);
    });

    // -------------------------------------------------------------------------
    // TEST 6: EOD Closing Reconciliation with Owner Withdrawals
    // -------------------------------------------------------------------------
    test(
        '6. EOD Closing reconciles cash salary and cash drawings with zero discrepancy',
        () {
      final businessDate = DateTime(2026, 11, 25);

      final sales = [
        {
          'invoice': 'INV-2026-901',
          'createdAt': '2026-11-25T11:00:00',
          'subtotal': 10000.0,
          'discount': 0.0,
          'total': 10000.0,
          'cash': 10000.0,
          'upi': 0.0,
          'card': 0.0,
          'due': 0.0,
          'status': 'SOLD',
          'items': [
            {
              'name': 'Screen Replacement',
              'category': 'Repairs',
              'qty': 1,
              'lineTotal': 10000.0
            }
          ],
        },
      ];

      // Opening Cash: ₹5,000
      // Cash Sales: ₹10,000
      // Cash Rent Paid: ₹300
      // Other Cash Expenses: ₹200
      // Cash Owner Salary Drawn: ₹2,000
      // Cash Owner Excess Drawings: ₹3,000
      // Total Cash Expenses (Rent + Salary + Other) = 300 + 2000 + 200 = ₹2,500
      // Expected Closing Cash = 5,000 + 10,000 - 0 - 2,500 (expenses) - 3,000 (drawings) = ₹9,500

      final summary = DailyRegisterService.instance.computeDailySummary(
        sales: sales,
        date: businessDate,
        openingCash: 5000.0,
        refunds: 0.0,
        totalCashExpenses: 2500.0, // Rent + Owner Salary + Tea
        totalBankExpenses: 0.0,
        cashRentPaid: 300.0,
        bankRentPaid: 0.0,
        ownerSalaryDrawnToday: 2000.0,
        ownerExcessDrawingsToday: 3000.0,
        ownerCashSalaryDrawn: 2000.0,
        ownerCashDrawingsDrawn: 3000.0,
        physicalCashCount: 9500.0,
      );

      expect(summary.totalCash, 10000.0);
      expect(summary.cashRentPaid, 300.0);
      expect(summary.ownerCashSalaryDrawn, 2000.0);
      expect(summary.ownerCashDrawingsDrawn, 3000.0);
      expect(summary.otherCashExpenses, 200.0); // 2500 - 300 - 2000 = 200
      expect(
          summary.totalCashOutflows, 300.0 + 200.0 + 2000.0 + 3000.0); // 5500.0
      expect(summary.expectedClosingCash, 9500.0);
      expect(summary.physicalCashCount, 9500.0);
      expect(summary.cashDiscrepancy, 0.0); // Exact match!
      expect(summary.cashOverOrShort, 0.0);
    });

    // -------------------------------------------------------------------------
    // TEST 7: Monthly Quota Rollover
    // -------------------------------------------------------------------------
    test('7. Monthly quota resets dynamically for the new calendar month',
        () async {
      // November: Full ₹20,000 drawn
      await OwnerFinanceService.instance.recordWithdrawal(
        shopId: testShopId,
        amount: 20000.0,
        paymentMode: 'CASH',
        recordedByUid: 'owner_uid',
        recordedByName: 'Store Owner',
        date: DateTime(2026, 11, 28),
      );

      final novMetrics = await OwnerFinanceService.instance.getQuotaMetrics(
        shopId: testShopId,
        forDate: DateTime(2026, 11, 28),
      );
      expect(novMetrics.usedSalaryThisMonth, 20000.0);
      expect(novMetrics.isQuotaFull, true);

      // December 1: Starts fresh with ₹20,000 available
      final decMetrics = await OwnerFinanceService.instance.getQuotaMetrics(
        shopId: testShopId,
        forDate: DateTime(2026, 12, 1),
      );
      expect(decMetrics.usedSalaryThisMonth, 0.0);
      expect(decMetrics.remainingSalaryThisMonth, 20000.0);
      expect(decMetrics.excessDrawingsThisMonth, 0.0);
      expect(decMetrics.isQuotaFull, false);
    });
  });
}
