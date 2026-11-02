import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/expenses/expense_models.dart';
import 'package:tekfix_erp_pos/expenses/expense_service.dart';
import 'package:tekfix_erp_pos/pos/daily_register_models.dart';
import 'package:tekfix_erp_pos/pos/daily_register_service.dart';
import 'package:tekfix_erp_pos/rent/rent_models.dart';
import 'package:tekfix_erp_pos/rent/rent_service.dart';

void main() {
  group('Daily Shop Rent Management Module Tests', () {
    late Directory tempDir;
    const testShopId = 'shop_test_rent';

    setUpAll(() async {
      GoogleFonts.config.allowRuntimeFetching = false;
      tempDir = await Directory.systemTemp.createTemp('rent_test_');
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
      await Db.bank.put('cash_in_hand', 10000.0);
      await Db.bank.put('bank_balance', 50000.0);
      await Db.bank.put('txn_log', <Map<String, dynamic>>[]);

      await Db.settings.put('store_state_code', '32');
      await Db.settings.put('shop_id', testShopId);
      await Db.settings.put('shop_name', 'TEKFIX DIGITAL HUB');

      // Default Rent Settings: ₹300/day, effective 2026-01-01
      final defaultSettings = DailyRentSettings(
        dailyRentAmount: 300.0,
        dailyRentAmountPaise: 30000,
        currency: 'INR',
        landlordName: 'Haji Mohammed',
        defaultPaymentMode: ExpensePaymentMode.cash,
        effectiveDate: DateTime(2026, 1, 1),
        scheduleType: RentScheduleType.everyDay,
        isActive: true,
      );
      await Db.settings.put('daily_rent_config', defaultSettings.toMap());
    });

    // -------------------------------------------------------------------------
    // TEST A: Cash Rent Payment
    // -------------------------------------------------------------------------
    test('Test A: Cash Rent - Debits cash_in_hand by ₹300, bank untouched, creates ledger entry', () async {
      final initialCash = (Db.bank.get('cash_in_hand') as num).toDouble();
      final initialBank = (Db.bank.get('bank_balance') as num).toDouble();
      expect(initialCash, 10000.0);
      expect(initialBank, 50000.0);

      const dateKey = '2026-11-02';
      final record = await RentService.instance.recordRentPayment(
        shopId: testShopId,
        dateKey: dateKey,
        paidAmount: 300.0,
        paymentMode: ExpensePaymentMode.cash,
        recordedByUid: 'staff_anoop',
        recordedByName: 'Anoop Kumar',
        landlordName: 'Haji Mohammed',
        notes: 'November 2 Daily Rent paid in cash',
      );

      expect(record.dateKey, dateKey);
      expect(record.paidAmount, 300.0);
      expect(record.paidAmountPaise, 30000);
      expect(record.paymentMode, ExpensePaymentMode.cash);
      expect(record.isPaid, true);
      expect(record.isVoided, false);

      // Verify Cash in hand decremented by exactly ₹300
      final updatedCash = (Db.bank.get('cash_in_hand') as num).toDouble();
      expect(updatedCash, initialCash - 300.0); // 9700.0

      // Verify Bank balance remained completely untouched
      final updatedBank = (Db.bank.get('bank_balance') as num).toDouble();
      expect(updatedBank, initialBank); // 50000.0

      // Verify ledger transaction log
      final txnLog = (Db.bank.get('txn_log') as List).cast<Map>();
      expect(txnLog.isNotEmpty, true);
      final lastTxn = txnLog.last;
      expect(lastTxn['account'] ?? lastTxn['mode'], 'Cash');
      expect(lastTxn['amount'], -300.0);
      expect(lastTxn['note'].toString().contains('Shop Daily Rent: 2026-11-02'), true);

      // Verify EOD closing calculation
      final summary = DailyRegisterService.instance.computeDailySummary(
        sales: [],
        date: DateTime(2026, 11, 2),
        openingCash: 5000.0,
        totalCashExpenses: 300.0, // rent as cash expense
        totalBankExpenses: 0.0,
        cashRentPaid: 300.0,
        bankRentPaid: 0.0,
      );
      expect(summary.cashRentPaid, 300.0);
      expect(summary.otherCashExpenses, 0.0);
      expect(summary.totalCashOutflows, 300.0);
      expect(summary.expectedClosingCash, 5000.0 - 300.0); // 4700.0
    });

    // -------------------------------------------------------------------------
    // TEST B: Bank / UPI Rent Payment
    // -------------------------------------------------------------------------
    test('Test B: Bank Rent - Debits bank_balance by ₹400, cash untouched, reports as bank expense', () async {
      final initialCash = (Db.bank.get('cash_in_hand') as num).toDouble();
      final initialBank = (Db.bank.get('bank_balance') as num).toDouble();

      const dateKey = '2026-11-03';
      final record = await RentService.instance.recordRentPayment(
        shopId: testShopId,
        dateKey: dateKey,
        paidAmount: 400.0,
        paymentMode: ExpensePaymentMode.bank,
        recordedByUid: 'staff_rahul',
        recordedByName: 'Rahul',
        landlordName: 'Haji Mohammed',
        paymentReference: 'UPI-REF-987654321',
        notes: 'GPay payment to landlord',
      );

      expect(record.paidAmount, 400.0);
      expect(record.paidAmountPaise, 40000);
      expect(record.paymentMode, ExpensePaymentMode.bank);
      expect(record.isPaid, true);

      // Verify Bank balance decremented by ₹400
      final updatedBank = (Db.bank.get('bank_balance') as num).toDouble();
      expect(updatedBank, initialBank - 400.0); // 49600.0

      // Verify Cash in hand remains untouched
      final updatedCash = (Db.bank.get('cash_in_hand') as num).toDouble();
      expect(updatedCash, initialCash); // 10000.0

      // Verify EOD summary reports Bank Rent and does NOT deduct from Closing Cash Drawer
      final summary = DailyRegisterService.instance.computeDailySummary(
        sales: [],
        date: DateTime(2026, 11, 3),
        openingCash: 5000.0,
        totalCashExpenses: 0.0,
        totalBankExpenses: 400.0,
        cashRentPaid: 0.0,
        bankRentPaid: 400.0,
      );
      expect(summary.cashRentPaid, 0.0);
      expect(summary.bankRentPaid, 400.0);
      expect(summary.expectedClosingCash, 5000.0); // Bank rent does not reduce drawer cash!
    });

    // -------------------------------------------------------------------------
    // TEST C & D: Duplicate Prevention & Deterministic Key Uniqueness
    // -------------------------------------------------------------------------
    test('Test C & D: Duplicate Prevention - Throws DuplicateRentPaymentException on same dateKey', () async {
      const dateKey = '2026-11-04';

      // 1st recording succeeds
      await RentService.instance.recordRentPayment(
        shopId: testShopId,
        dateKey: dateKey,
        paidAmount: 300.0,
        paymentMode: ExpensePaymentMode.cash,
        recordedByUid: 'staff_1',
        recordedByName: 'Staff 1',
      );

      final cashAfterFirst = (Db.bank.get('cash_in_hand') as num).toDouble();

      // 2nd recording for same dateKey MUST throw DuplicateRentPaymentException
      expect(
        () async => await RentService.instance.recordRentPayment(
          shopId: testShopId,
          dateKey: dateKey,
          paidAmount: 300.0,
          paymentMode: ExpensePaymentMode.cash,
          recordedByUid: 'staff_2',
          recordedByName: 'Staff 2',
        ),
        throwsA(isA<DuplicateRentPaymentException>()),
      );

      // Cash balance must remain identical (no second debit)
      final cashAfterSecond = (Db.bank.get('cash_in_hand') as num).toDouble();
      expect(cashAfterSecond, cashAfterFirst);
    });

    // -------------------------------------------------------------------------
    // TEST E: Unpaid Rent Handling
    // -------------------------------------------------------------------------
    test('Test E: Unpaid Rent - Leaves status PENDING, never debits cash or bank', () async {
      final initialCash = (Db.bank.get('cash_in_hand') as num).toDouble();
      final initialBank = (Db.bank.get('bank_balance') as num).toDouble();

      // Do not record rent for 2026-11-05
      final dt = DateTime(2026, 11, 5);
      final metrics = await RentService.instance.computeRentMetrics(
        shopId: testShopId,
        forDate: dt,
      );

      expect(metrics.todayStatus, 'PENDING');
      expect(metrics.todayPaid, 0.0);
      expect(metrics.todayExpected, 300.0);
      expect(metrics.monthUnpaidDays >= 1, true);

      // Cash in hand and bank balance MUST remain unchanged
      expect((Db.bank.get('cash_in_hand') as num).toDouble(), initialCash);
      expect((Db.bank.get('bank_balance') as num).toDouble(), initialBank);
    });

    // -------------------------------------------------------------------------
    // TEST F: EOD Reminder & Closing Flow
    // -------------------------------------------------------------------------
    test('Test F: EOD Closing with Pending Rent - Reports warning, Skip does not create financial txn', () {
      final summaryWithPendingRent = DailyRegisterService.instance.computeDailySummary(
        sales: [],
        date: DateTime(2026, 11, 6),
        openingCash: 5000.0,
        totalCashExpenses: 0.0,
        totalBankExpenses: 0.0,
        cashRentPaid: 0.0,
        bankRentPaid: 0.0,
        rentPendingWarning: true,
      );

      expect(summaryWithPendingRent.rentPendingWarning, true);
      // Because rent was skipped, cash remains exactly openingCash
      expect(summaryWithPendingRent.expectedClosingCash, 5000.0);
      expect(summaryWithPendingRent.cashRentPaid, 0.0);
      expect(summaryWithPendingRent.otherCashExpenses, 0.0);
      expect(summaryWithPendingRent.totalCashOutflows, 0.0);
    });

    // -------------------------------------------------------------------------
    // TEST G: Monthly History & Aggregations
    // -------------------------------------------------------------------------
    test('Test G: Monthly History - 25 paid days @ ₹300 results in ₹7,500 total paid', () async {
      // Record 25 distinct days in October 2026
      for (int day = 1; day <= 25; day++) {
        final dateKey = '2026-10-${day.toString().padLeft(2, '0')}';
        await RentService.instance.recordRentPayment(
          shopId: testShopId,
          dateKey: dateKey,
          paidAmount: 300.0,
          paymentMode: ExpensePaymentMode.cash,
          recordedByUid: 'staff_test',
          recordedByName: 'Tester',
        );
      }

      final history = await RentService.instance.getRentHistory(
        shopId: testShopId,
        startDate: DateTime(2026, 10, 1),
        endDate: DateTime(2026, 10, 31),
      );

      final paidRecords = history.where((r) => r.isPaid).toList();
      expect(paidRecords.length, 25);

      final totalPaid = paidRecords.fold<double>(0.0, (sum, r) => sum + r.paidAmount);
      expect(totalPaid, 7500.0);

      final unpaidRecords = history.where((r) => r.status == 'PENDING').toList();
      expect(unpaidRecords.length, 31 - 25); // 6 days unpaid
    });

    // -------------------------------------------------------------------------
    // TEST H: Rent Rate Change & Historical Rates
    // -------------------------------------------------------------------------
    test('Test H: Rent Rate Adjustment - Historical records retain old rate, future uses new rate', () async {
      // Current configured rate: ₹300/day
      final settings = await RentService.instance.getSettings(shopId: testShopId);
      expect(settings.getRentForDate(DateTime(2026, 11, 10)), 300.0);

      // Owner updates rate to ₹400/day starting from 2026-12-01
      final updatedSettings = settings.copyWith(
        dailyRentAmount: 400.0,
        dailyRentAmountPaise: 40000,
        effectiveDate: DateTime(2026, 12, 1),
      );

      await RentService.instance.saveSettings(
        shopId: testShopId,
        newSettings: updatedSettings,
        staffId: 'admin_owner',
        staffName: 'Store Owner',
      );

      final reloaded = await RentService.instance.getSettings(shopId: testShopId);
      expect(reloaded.dailyRentAmount, 400.0);

      // Historical date (November 2026) still expects ₹300
      expect(reloaded.getRentForDate(DateTime(2026, 11, 15)), 300.0);

      // Future date on or after 2026-12-01 expects ₹400
      expect(reloaded.getRentForDate(DateTime(2026, 12, 1)), 400.0);
      expect(reloaded.getRentForDate(DateTime(2026, 12, 15)), 400.0);
    });

    // -------------------------------------------------------------------------
    // TEST I: General Expense Integration (Single Effective Debit)
    // -------------------------------------------------------------------------
    test('Test I: General Expense Integration - Creates linked expense without double ledger debit', () async {
      const dateKey = '2026-11-20';
      final rentRecord = await RentService.instance.recordRentPayment(
        shopId: testShopId,
        dateKey: dateKey,
        paidAmount: 300.0,
        paymentMode: ExpensePaymentMode.cash,
        recordedByUid: 'staff_anoop',
        recordedByName: 'Anoop Kumar',
      );

      // Check linked expense exists in Db.expenses with isDailyRent = true
      final linkedExpRaw = Db.expenses.get(rentRecord.expenseId);
      expect(linkedExpRaw != null, true);
      final linkedExp = ExpenseItem.fromMap(tekM(linkedExpRaw), rentRecord.expenseId!);
      expect(linkedExp.isDailyRent, true);
      expect(linkedExp.rentRecordId, dateKey);
      expect(linkedExp.amount, 300.0);
      expect(linkedExp.category, ExpenseCategory.rentAndMaintenance);

      // Total ledger debit is exactly ₹300 (no duplicate debit from Expense module)
      final txnLog = (Db.bank.get('txn_log') as List).cast<Map>();
      final rentDebits = txnLog.where((t) => t['note'].toString().contains('Daily Rent: 2026-11-20')).toList();
      expect(rentDebits.length, 1);
      expect(rentDebits.first['amount'], -300.0);
    });

    // -------------------------------------------------------------------------
    // TEST J: Reversal / Void
    // -------------------------------------------------------------------------
    test('Test J: Void Rent Payment - Restores cash balance and marks record VOIDED', () async {
      const dateKey = '2026-11-21';
      await RentService.instance.recordRentPayment(
        shopId: testShopId,
        dateKey: dateKey,
        paidAmount: 300.0,
        paymentMode: ExpensePaymentMode.cash,
        recordedByUid: 'staff_1',
        recordedByName: 'Staff 1',
      );

      final cashAfterPayment = (Db.bank.get('cash_in_hand') as num).toDouble();

      // Void the payment
      final voidedRecord = await RentService.instance.voidRentPayment(
        shopId: testShopId,
        dateKey: dateKey,
        voidedByUid: 'admin_owner',
        voidedByName: 'Owner',
        voidReason: 'Mistakenly entered twice by staff',
      );

      expect(voidedRecord.status, 'VOIDED');
      expect(voidedRecord.isVoided, true);
      expect(voidedRecord.voidReason, 'Mistakenly entered twice by staff');

      // Cash in hand must be restored (+₹300)
      final cashAfterVoid = (Db.bank.get('cash_in_hand') as num).toDouble();
      expect(cashAfterVoid, cashAfterPayment + 300.0);

      // Linked expense in Db.expenses must also be marked isVoided = true
      final expRaw = Db.expenses.get('EXP_RENT_$dateKey');
      expect(expRaw != null, true);
      expect(tekM(expRaw)['isVoided'], true);
    });

    // -------------------------------------------------------------------------
    // TEST K: Operating Days Schedule Type
    // -------------------------------------------------------------------------
    test('Test K: Operating Days Schedule - Non-operating days marked NOT_SCHEDULED', () async {
      // Configure shop to only operate Monday through Saturday (1 to 6). Sunday (7) is closed.
      final operatingSettings = DailyRentSettings(
        dailyRentAmount: 350.0,
        dailyRentAmountPaise: 35000,
        effectiveDate: DateTime(2026, 1, 1),
        scheduleType: RentScheduleType.operatingDaysOnly,
        operatingDays: [1, 2, 3, 4, 5, 6], // Sunday excluded
        isActive: true,
      );
      await Db.settings.put('daily_rent_config', operatingSettings.toMap());

      // 2026-11-08 is a Sunday
      final sunday = DateTime(2026, 11, 8);
      expect(sunday.weekday, 7); // Sunday
      expect(operatingSettings.isScheduledForDate(sunday), false);

      // 2026-11-09 is a Monday
      final monday = DateTime(2026, 11, 9);
      expect(monday.weekday, 1); // Monday
      expect(operatingSettings.isScheduledForDate(monday), true);

      final history = await RentService.instance.getRentHistory(
        shopId: testShopId,
        startDate: sunday,
        endDate: monday,
      );

      final sundayRecord = history.firstWhere((r) => r.dateKey == '2026-11-08');
      final mondayRecord = history.firstWhere((r) => r.dateKey == '2026-11-09');

      expect(sundayRecord.status, 'NOT_SCHEDULED');
      expect(mondayRecord.status, 'PENDING');
    });
  });
}
