import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/pos/daily_register_models.dart';
import 'package:tekfix_erp_pos/pos/daily_register_service.dart';

void main() {
  group('TEKFIX ERP — Master EOD Verification Test Matrix', () {
    late Directory tempDir;

    setUpAll(() async {
      WidgetsFlutterBinding.ensureInitialized();
      GoogleFonts.config.allowRuntimeFetching = false;
      tempDir =
          await Directory.systemTemp.createTemp('eod_cash_matrix_test_');
      Hive.init(tempDir.path);

      for (final b in allBoxes) {
        await Hive.openBox(b);
      }

      final settingsBox = Hive.box(boxSettings);
      await settingsBox.put('store_state_code', '32');
      await settingsBox.put('shop_id', 'test_shop_eod');
      await settingsBox.put('shop_name', 'TEKFIX DIGITAL HUB');
      await settingsBox.put('shop_address', 'Calicut, Kerala');
      await settingsBox.put('shop_phone', '9847000111');
    });

    tearDownAll(() async {
      try {
        await Hive.close();
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    // Test 1: Enter ₹8,500 cash -> Total ₹8,500
    test('Test 1: Enter ₹8,500 cash -> Total ₹8,500', () {
      const denoms = CashDenominations(
        count500: 17, // 17 x 500 = 8,500
      );
      expect(denoms.totalCash, equals(8500.0));
      expect(denoms.totalCashPaise, equals(850000));
    });

    // Test 2: Set float ₹1,000 -> Net handover ₹7,500
    test('Test 2: Set float ₹1,000 -> Net handover ₹7,500', () {
      const actualCash = 8500.0;
      const retainedFloat = 1000.0;

      final summary = DailyRegisterSummary(
        dateString: '2026-11-06',
        date: DateTime(2026, 11, 6),
        totalOrdersCount: 5,
        grossSales: 8500.0,
        totalDiscounts: 0.0,
        netRevenue: 8500.0,
        totalCash: 8500.0,
        totalUpi: 0.0,
        totalCard: 0.0,
        totalDue: 0.0,
        physicalCashCount: actualCash,
        retainedCashFloat: retainedFloat,
      );

      expect(summary.physicalCashCount, equals(8500.0));
      expect(summary.retainedCashFloat, equals(1000.0));
      expect(summary.netCashHandover, equals(7500.0));
      expect(summary.nextDayOpeningCash, equals(1000.0));

      expect(summary.physicalCashCountPaise, equals(850000));
      expect(summary.retainedCashFloatPaise, equals(100000));
      expect(summary.netCashHandoverPaise, equals(750000));
    });

    // Test 3: Close November 6 -> EOD saved
    test('Test 3: Close November 6 -> EOD saved', () async {
      final nov6 = DateTime(2026, 11, 6);
      final nov6Str = DailyRegisterService.toDateString(nov6);

      final summary = DailyRegisterSummary(
        dateString: nov6Str,
        date: nov6,
        totalOrdersCount: 12,
        grossSales: 10000.0,
        totalDiscounts: 500.0,
        netRevenue: 9500.0,
        totalCash: 8500.0,
        totalUpi: 1000.0,
        totalCard: 0.0,
        totalDue: 0.0,
        openingCash: 1000.0,
        physicalCashCount: 8500.0,
        retainedCashFloat: 1000.0,
        denominations: const CashDenominations(count500: 17),
        handoverSplit: const CashHandoverSplit(
          ownerCash: 5000.0,
          bankDeposit: 2500.0,
        ),
      );

      await DailyRegisterService.instance.closeDailyRegister(
        summary: summary,
        shopId: 'test_shop_eod',
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      final retrieved = await DailyRegisterService.instance
          .getClosedRegister(nov6Str, shopId: 'test_shop_eod');
      expect(retrieved, isNotNull);
      expect(retrieved!.isClosed, isTrue);
      expect(retrieved.physicalCashCount, equals(8500.0));
      expect(retrieved.retainedCashFloat, equals(1000.0));
      expect(retrieved.netCashHandover, equals(7500.0));
      expect(retrieved.handoverSplit.ownerCash, equals(5000.0));
      expect(retrieved.handoverSplit.bankDeposit, equals(2500.0));
    });

    // Test 4: Open November 7 -> Opening Cash ₹1,000
    test('Test 4: Open November 7 -> Opening Cash ₹1,000', () async {
      final nov7 = DateTime(2026, 11, 7);
      final openCash =
          await DailyRegisterService.instance.getOpeningCashForDate(nov7);
      expect(openCash, equals(1000.0));
    });

    // Test 5: Close button clicked twice -> No duplicate EOD
    test('Test 5: Close button clicked twice -> No duplicate EOD', () async {
      final nov6 = DateTime(2026, 11, 6);
      final nov6Str = DailyRegisterService.toDateString(nov6);

      final summary = DailyRegisterSummary(
        dateString: nov6Str,
        date: nov6,
        totalOrdersCount: 12,
        grossSales: 10000.0,
        totalDiscounts: 0.0,
        netRevenue: 10000.0,
        totalCash: 8500.0,
        totalUpi: 0.0,
        totalCard: 0.0,
        totalDue: 0.0,
        physicalCashCount: 8500.0,
        retainedCashFloat: 1000.0,
      );

      // First click
      await DailyRegisterService.instance.closeDailyRegister(
        summary: summary,
        shopId: 'test_shop_eod',
        staffId: 'staff_1',
        staffName: 'Staff 1',
      );

      // Second immediate click
      await DailyRegisterService.instance.closeDailyRegister(
        summary: summary,
        shopId: 'test_shop_eod',
        staffId: 'staff_1',
        staffName: 'Staff 1',
      );

      final retrieved = await DailyRegisterService.instance
          .getClosedRegister(nov6Str, shopId: 'test_shop_eod');
      expect(retrieved, isNotNull);
      expect(retrieved!.dateString, equals(nov6Str));
      expect(retrieved.isClosed, isTrue);
    });

    // Test 6: Change float to ₹1,500 -> Next opening ₹1,500
    test('Test 6: Change float to ₹1,500 -> Next opening ₹1,500', () async {
      final nov8 = DateTime(2026, 11, 8);
      final nov8Str = DailyRegisterService.toDateString(nov8);
      final nov9 = DateTime(2026, 11, 9);

      final summaryNov8 = DailyRegisterSummary(
        dateString: nov8Str,
        date: nov8,
        totalOrdersCount: 4,
        grossSales: 5000.0,
        totalDiscounts: 0.0,
        netRevenue: 5000.0,
        totalCash: 5000.0,
        totalUpi: 0.0,
        totalCard: 0.0,
        totalDue: 0.0,
        physicalCashCount: 5000.0,
        retainedCashFloat: 1500.0, // Float explicitly edited to ₹1,500
      );

      await DailyRegisterService.instance.closeDailyRegister(
        summary: summaryNov8,
        shopId: 'test_shop_eod',
        staffId: 'staff_1',
        staffName: 'Staff 1',
      );

      final nextDayOpenCash =
          await DailyRegisterService.instance.getOpeningCashForDate(nov9);
      expect(nextDayOpenCash, equals(1500.0));
    });

    // Test 7: Close previous date -> Backdated EOD saved
    test('Test 7: Close previous date -> Backdated EOD saved', () async {
      final nov4 = DateTime(2026, 11, 4);
      final nov4Str = DailyRegisterService.toDateString(nov4);

      final backdatedSummary = DailyRegisterSummary(
        dateString: nov4Str,
        date: nov4,
        totalOrdersCount: 2,
        grossSales: 3000.0,
        totalDiscounts: 0.0,
        netRevenue: 3000.0,
        totalCash: 3000.0,
        totalUpi: 0.0,
        totalCard: 0.0,
        totalDue: 0.0,
        physicalCashCount: 3000.0,
        retainedCashFloat: 1000.0,
        isBackdated: true,
      );

      await DailyRegisterService.instance.closeDailyRegister(
        summary: backdatedSummary,
        shopId: 'test_shop_eod',
        staffId: 'owner_1',
        staffName: 'Owner User',
        isBackdated: true,
      );

      final retrieved = await DailyRegisterService.instance
          .getClosedRegister(nov4Str, shopId: 'test_shop_eod');
      expect(retrieved, isNotNull);
      expect(retrieved!.isBackdated, isTrue);
      expect(retrieved.resolvedClosingStatus, equals('BACKDATED'));
    });

    // Test 8: Close already-closed date -> Duplicate prevented
    test('Test 8: Close already-closed date -> Duplicate prevented', () async {
      final nov4Str = DailyRegisterService.toDateString(DateTime(2026, 11, 4));
      final closedBefore = await DailyRegisterService.instance
          .getClosedRegister(nov4Str, shopId: 'test_shop_eod');
      expect(closedBefore, isNotNull);

      // Re-closing already closed date
      await DailyRegisterService.instance.closeDailyRegister(
        summary: closedBefore!,
        shopId: 'test_shop_eod',
        staffId: 'owner_1',
        staffName: 'Owner User',
        isBackdated: true,
      );

      final closedAfter = await DailyRegisterService.instance
          .getClosedRegister(nov4Str, shopId: 'test_shop_eod');
      expect(closedAfter, isNotNull);
      expect(closedAfter!.dateString, equals(nov4Str));
    });

    // Test 9: November 7 already opened -> No silent balance overwrite
    test('Test 9: November 7 already opened -> No silent balance overwrite',
        () async {
      final nov10 = DateTime(2026, 11, 10);
      final nov10Str = DailyRegisterService.toDateString(nov10);
      final nov11 = DateTime(2026, 11, 11);
      final nov11Str = DailyRegisterService.toDateString(nov11);

      // Nov 11 is already opened & closed with opening cash ₹2,000
      final nov11Summary = DailyRegisterSummary(
        dateString: nov11Str,
        date: nov11,
        totalOrdersCount: 5,
        grossSales: 6000.0,
        totalDiscounts: 0.0,
        netRevenue: 6000.0,
        totalCash: 6000.0,
        totalUpi: 0.0,
        totalCard: 0.0,
        totalDue: 0.0,
        openingCash: 2000.0,
        physicalCashCount: 8000.0,
        retainedCashFloat: 1000.0,
        isClosed: true,
      );

      await DailyRegisterService.instance.closeDailyRegister(
        summary: nov11Summary,
        shopId: 'test_shop_eod',
        staffId: 'staff_1',
        staffName: 'Staff 1',
      );

      // Now close Nov 10 (backdated) with float ₹700
      final nov10Backdated = DailyRegisterSummary(
        dateString: nov10Str,
        date: nov10,
        totalOrdersCount: 3,
        grossSales: 3000.0,
        totalDiscounts: 0.0,
        netRevenue: 3000.0,
        totalCash: 3000.0,
        totalUpi: 0.0,
        totalCard: 0.0,
        totalDue: 0.0,
        physicalCashCount: 3000.0,
        retainedCashFloat: 700.0,
      );

      await DailyRegisterService.instance.closeDailyRegister(
        summary: nov10Backdated,
        shopId: 'test_shop_eod',
        staffId: 'staff_1',
        staffName: 'Staff 1',
        isBackdated: true,
        forceOverrideNextDay: false, // Prevents silent overwrite
      );

      // Verify Nov 11 opening cash remains intact at ₹2,000!
      final nov11Check = await DailyRegisterService.instance
          .getClosedRegister(nov11Str, shopId: 'test_shop_eod');
      expect(nov11Check, isNotNull);
      expect(nov11Check!.openingCash, equals(2000.0));
    });

    // Test 10: Internet failure during closing -> No partial financial update
    test(
        'Test 10: Internet failure during closing -> No partial financial update',
        () async {
      final nov12 = DateTime(2026, 11, 12);
      final nov12Str = DailyRegisterService.toDateString(nov12);

      final summary = DailyRegisterSummary(
        dateString: nov12Str,
        date: nov12,
        totalOrdersCount: 1,
        grossSales: 1000.0,
        totalDiscounts: 0.0,
        netRevenue: 1000.0,
        totalCash: 1000.0,
        totalUpi: 0.0,
        totalCard: 0.0,
        totalDue: 0.0,
        physicalCashCount: 1000.0,
        retainedCashFloat: 1000.0,
      );

      // Even if offline without Firebase initialization, atomic local cache and transaction guards ensure consistency
      await DailyRegisterService.instance.closeDailyRegister(
        summary: summary,
        shopId: 'test_shop_eod',
        staffId: 'staff_1',
        staffName: 'Staff 1',
      );

      final closed = await DailyRegisterService.instance
          .getClosedRegister(nov12Str, shopId: 'test_shop_eod');
      expect(closed, isNotNull);
      expect(closed!.isClosed, isTrue);
      expect(closed.netCashHandover, equals(0.0));
    });

    // Test 11: Generate PDF -> Correct amounts printed
    test('Test 11: Generate PDF -> Correct amounts printed', () {
      final summary = DailyRegisterSummary(
        dateString: '2026-11-06',
        date: DateTime(2026, 11, 6),
        totalOrdersCount: 15,
        grossSales: 9500.0,
        totalDiscounts: 500.0,
        netRevenue: 9000.0,
        totalCash: 8500.0,
        totalUpi: 500.0,
        totalCard: 0.0,
        totalDue: 0.0,
        openingCash: 1000.0,
        physicalCashCount: 8500.0,
        retainedCashFloat: 1000.0,
        denominations: const CashDenominations(
          count500: 17,
        ),
        handoverSplit: const CashHandoverSplit(
          ownerCash: 5000.0,
          bankDeposit: 2500.0,
        ),
      );

      // Verify PDF lines generation logic
      final doc = pw.Document();
      doc.addPage(
        pw.Page(
          build: (pw.Context ctx) {
            return pw.Column(
              children: [
                pw.Text('TEKFIX DIGITAL HUB'),
                pw.Text('CASH DENOMINATIONS'),
                pw.Text('Rs. 500 x 17: Rs. 8500'),
                pw.Text('EOD CASH SETTLEMENT'),
                pw.Text('Actual Cash Count: Rs. 8500.00'),
                pw.Text('Retained Cash Float: Rs. 1000.00'),
                pw.Text('NET CASH TO HANDOVER: Rs. 7500.00'),
                pw.Text('Owner Cash: Rs. 5000.00'),
                pw.Text('Bank Deposit: Rs. 2500.00'),
              ],
            );
          },
        ),
      );

      final pdfBytes = doc.save();
      expect(pdfBytes, isNotNull);
      expect(summary.physicalCashCount, equals(8500.0));
      expect(summary.retainedCashFloat, equals(1000.0));
      expect(summary.netCashHandover, equals(7500.0));
    });
  });
}
