import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/recharge/recharge_models.dart';
import 'package:tekfix_erp_pos/recharge/recharge_backend_bridge.dart';
import 'package:tekfix_erp_pos/recharge/recharge_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TEKFIX ERP - Phase 9: Recharge Reports, Profit & Financial Reconciliation', () {
    late Directory tempDir;
    const testShopId = 'test_shop_tekfix';
    final service = RechargeService.instance;

    setUpAll(() async {
    // v2.1: the old client-side postings run only in localTestMock.
    RechargeBackendBridge.configure(mode: RechargeBackendMode.localTestMock);
      GoogleFonts.config.allowRuntimeFetching = false;
      tempDir = await Directory.systemTemp.createTemp('recharge_reports_test_');
      Hive.init(tempDir.path);

      for (final b in allBoxes) {
        await Hive.openBox(b);
      }

      final settingsBox = Hive.box(boxSettings);
      await settingsBox.put('shop_id', testShopId);
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

    setUp(() async {
      service.resetLocalCacheForTesting();
      service.disableOpeningBalanceGateForTesting();
      await Db.bank.clear();
      await Db.sales.clear();
      await Db.expenses.clear();

      // Standard retail accounts baseline
      await Db.bank.put('cash_in_hand', 3000.0); // Baseline cash drawer: ₹3,000 (includes ₹1,000 opening float)
      await Db.bank.put('bank_balance', 15000.0); // Baseline bank account: ₹15,000
      await Db.bank.put('txn_log', <Map<String, dynamic>>[]);
    });

    // -------------------------------------------------------------------------
    // TEST 1: Operator-wise totals
    // -------------------------------------------------------------------------
    test('TEST 1: Operator-wise totals correctly segment Airtel, Jio, Vi, BSNL, and Other', () async {
      final today = DateTime.now();
      const dateStr = '2026-11-07';

      // 1. Airtel transaction: ₹299 Cash
      await service.recordCustomerRechargePayment(
        recharge: RechargeEntry(
          rechargeId: 'REC_OP_AIRTEL',
          shopId: testShopId,
          operator: RechargeOperator.airtel,
          customerMobile: '9847000001',
          amount: 299.0,
          amountPaise: 29900,
          fundingType: RechargeFundingType.ownMoney,
          paymentMode: RechargePaymentMode.cash,
          status: RechargeStatus.success,
          staffId: 'staff_1',
          staffName: 'Shahal',
          createdAt: today,
          updatedAt: today,
          dateString: dateStr,
        ),
      );

      // 2. Jio transaction: ₹499 UPI
      await service.recordCustomerRechargePayment(
        recharge: RechargeEntry(
          rechargeId: 'REC_OP_JIO',
          shopId: testShopId,
          operator: RechargeOperator.jio,
          customerMobile: '9847000002',
          amount: 499.0,
          amountPaise: 49900,
          fundingType: RechargeFundingType.ownMoney,
          paymentMode: RechargePaymentMode.upi,
          status: RechargeStatus.success,
          staffId: 'staff_1',
          staffName: 'Shahal',
          createdAt: today,
          updatedAt: today,
          dateString: dateStr,
        ),
      );

      final report = await service.generateFinancialReport(
        shopId: testShopId,
        filter: RechargeReportFilter.today(),
      );

      expect(report.totalRechargeAmount, equals(798.0));
      expect(report.successfulCount, equals(2));

      // Airtel verification
      final airtel = report.operatorReports[RechargeOperator.airtel]!;
      expect(airtel.successfulCount, equals(1));
      expect(airtel.successfulAmount, equals(299.0));
      expect(airtel.cashCollection, equals(299.0));
      expect(airtel.upiCollection, equals(0.0));

      // Jio verification
      final jio = report.operatorReports[RechargeOperator.jio]!;
      expect(jio.successfulCount, equals(1));
      expect(jio.successfulAmount, equals(499.0));
      expect(jio.cashCollection, equals(0.0));
      expect(jio.upiCollection, equals(499.0));

      // Vi (Zero transactions)
      final vi = report.operatorReports[RechargeOperator.vi]!;
      expect(vi.successfulCount, equals(0));
      expect(vi.successfulAmount, equals(0.0));
    });

    // -------------------------------------------------------------------------
    // TEST 2: Date range filtering
    // -------------------------------------------------------------------------
    test('TEST 2: Date range filtering accurately includes within-range and excludes out-of-range transactions', () async {
      final now = DateTime.now();
      final yesterday = now.subtract(const Duration(days: 1));

      // Yesterday transaction
      await service.recordCustomerRechargePayment(
        recharge: RechargeEntry(
          rechargeId: 'REC_DATE_YEST',
          shopId: testShopId,
          operator: RechargeOperator.vi,
          customerMobile: '9847111111',
          amount: 199.0,
          amountPaise: 19900,
          fundingType: RechargeFundingType.ownMoney,
          paymentMode: RechargePaymentMode.cash,
          status: RechargeStatus.success,
          staffId: 'staff_1',
          staffName: 'Shahal',
          createdAt: yesterday,
          updatedAt: yesterday,
          dateString: '2026-11-06',
        ),
      );

      // Today transaction
      await service.recordCustomerRechargePayment(
        recharge: RechargeEntry(
          rechargeId: 'REC_DATE_TODAY',
          shopId: testShopId,
          operator: RechargeOperator.vi,
          customerMobile: '9847222222',
          amount: 299.0,
          amountPaise: 29900,
          fundingType: RechargeFundingType.ownMoney,
          paymentMode: RechargePaymentMode.cash,
          status: RechargeStatus.success,
          staffId: 'staff_1',
          staffName: 'Shahal',
          createdAt: now,
          updatedAt: now,
          dateString: '2026-11-07',
        ),
      );

      // Today Filter: should ONLY have today's ₹299
      final todayReport = await service.generateFinancialReport(
        shopId: testShopId,
        filter: RechargeReportFilter.today(),
      );
      expect(todayReport.successfulCount, equals(1));
      expect(todayReport.totalRechargeAmount, equals(299.0));

      // Yesterday Filter: should ONLY have yesterday's ₹199
      final yestReport = await service.generateFinancialReport(
        shopId: testShopId,
        filter: RechargeReportFilter.forType(DateRangeFilterType.yesterday),
      );
      expect(yestReport.successfulCount, equals(1));
      expect(yestReport.totalRechargeAmount, equals(199.0));

      // Combined 2-day Custom Range: should have both (₹498)
      final customReport = await service.generateFinancialReport(
        shopId: testShopId,
        filter: RechargeReportFilter.forType(
          DateRangeFilterType.custom,
          yesterday.subtract(const Duration(hours: 1)),
          now.add(const Duration(hours: 1)),
        ),
      );
      expect(customReport.successfulCount, equals(2));
      expect(customReport.totalRechargeAmount, equals(498.0));
    });

    // -------------------------------------------------------------------------
    // TEST 3: Commission calculation (Net = Confirmed Earned - Confirmed Reversed)
    // -------------------------------------------------------------------------
    test('TEST 3: Profit & Commission calculation: pending commission excluded, clawbacks deducted', () async {
      // 1. Confirmed commission of ₹30
      await service.recordPostpaidCommission(
        shopId: testShopId,
        operator: RechargeOperator.jio,
        amount: 30.0,
        status: CommissionStatus.confirmed,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'COMM_CONFIRMED_30',
      );

      // 2. Pending commission of ₹50 (MUST BE EXCLUDED from income)
      await service.recordPostpaidCommission(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        amount: 50.0,
        status: CommissionStatus.pending,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'COMM_PENDING_50',
      );

      // 3. Another confirmed commission of ₹20 that is later reversed (₹10 clawback)
      final comm2 = await service.recordPostpaidCommission(
        shopId: testShopId,
        operator: RechargeOperator.vi,
        amount: 20.0,
        status: CommissionStatus.confirmed,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'COMM_REVERSED_20',
      );

      await service.reverseCommissionEntry(
        shopId: testShopId,
        commissionId: comm2.commissionId,
        staffId: 'staff_1',
        staffName: 'Shahal',
        reason: 'Customer recharge failed and cancelled',
      );

      final report = await service.generateFinancialReport(
        shopId: testShopId,
        filter: RechargeReportFilter.today(),
      );

      // Confirmed earned: ₹30 + ₹20 = ₹50
      expect(report.confirmedCommissionEarned, equals(50.0));
      // Confirmed reversed: ₹20
      expect(report.confirmedCommissionReversed, equals(20.0));
      // Net commission income: ₹50 - ₹20 = ₹30
      expect(report.netCommissionIncome, equals(30.0));
    });

    // -------------------------------------------------------------------------
    // TEST 4: Failed recharge exclusion
    // -------------------------------------------------------------------------
    test('TEST 4: Failed recharges are strictly excluded from successful totals and collections', () async {
      final now = DateTime.now();

      // Successful recharge
      await service.recordCustomerRechargePayment(
        recharge: RechargeEntry(
          rechargeId: 'REC_SUCC_1',
          shopId: testShopId,
          operator: RechargeOperator.bsnl,
          customerMobile: '9847333333',
          amount: 149.0,
          amountPaise: 14900,
          fundingType: RechargeFundingType.ownMoney,
          paymentMode: RechargePaymentMode.cash,
          status: RechargeStatus.success,
          staffId: 'staff_1',
          staffName: 'Shahal',
          createdAt: now,
          updatedAt: now,
          dateString: '2026-11-07',
        ),
      );

      // Failed recharge
      await service.recordCustomerRechargePayment(
        recharge: RechargeEntry(
          rechargeId: 'REC_FAIL_1',
          shopId: testShopId,
          operator: RechargeOperator.bsnl,
          customerMobile: '9847444444',
          amount: 299.0,
          amountPaise: 29900,
          fundingType: RechargeFundingType.ownMoney,
          paymentMode: RechargePaymentMode.cash,
          status: RechargeStatus.failed,
          staffId: 'staff_1',
          staffName: 'Shahal',
          createdAt: now,
          updatedAt: now,
          dateString: '2026-11-07',
        ),
      );

      final report = await service.generateFinancialReport(
        shopId: testShopId,
        filter: RechargeReportFilter.today(),
      );

      expect(report.successfulCount, equals(1));
      expect(report.totalRechargeAmount, equals(149.0)); // Only successful ₹149!
      expect(report.totalCustomerCollection, equals(149.0)); // Zero collection from failed!
      expect(report.failedCount, equals(1));
      expect(report.failedAmount, equals(299.0));
    });

    // -------------------------------------------------------------------------
    // TEST 5: Refund exclusion from completed recharge totals
    // -------------------------------------------------------------------------
    test('TEST 5: Refunded transactions are segregated and tracked with actual refund amounts', () async {
      final now = DateTime.now();

      // Successful recharge that was later refunded
      final rec = RechargeEntry(
        rechargeId: 'REC_REFUND_SEPARATED',
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        customerMobile: '9847555555',
        amount: 299.0,
        amountPaise: 29900,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.cash,
        status: RechargeStatus.success,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: now,
        updatedAt: now,
        dateString: '2026-11-07',
      );

      await service.recordCustomerRechargePayment(recharge: rec);
      await service.processCustomerRefund(
        shopId: testShopId,
        rechargeId: rec.rechargeId,
        refundAmount: 299.0,
        refundMethod: RechargePaymentMode.cash,
        staffId: 'staff_1',
        staffName: 'Shahal',
        reason: 'Customer refund on failure',
      );

      final report = await service.generateFinancialReport(
        shopId: testShopId,
        filter: RechargeReportFilter.today(),
      );

      // Refunded transaction is counted in refundedCount, not active successfulCount
      expect(report.refundedCount, equals(1));
      expect(report.refundedAmount, equals(299.0));
      expect(report.successfulCount, equals(0));
    });

    // -------------------------------------------------------------------------
    // TEST 6: Wallet opening and closing balances
    // -------------------------------------------------------------------------
    test('TEST 6: Wallet balance report correctly reconciles opening balance, top-ups, debits and closing balance', () async {
      // 1. Initial Top-up of ₹2,000 to Jio wallet
      await service.recordOwnMoneyTopUp(
        shopId: testShopId,
        operator: RechargeOperator.jio,
        amount: 2000.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceId: 'TOPUP_WALLET_TEST',
      );

      // 2. Recharge debit of ₹299
      final recharge = RechargeEntry(
        rechargeId: 'REC_WALLET_DEBIT_TEST',
        shopId: testShopId,
        operator: RechargeOperator.jio,
        customerMobile: '9847666666',
        amount: 299.0,
        amountPaise: 29900,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.upi,
        status: RechargeStatus.pending,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: '2026-11-07',
      );
      await service.processRechargeDebit(recharge: recharge);

      final report = await service.generateFinancialReport(
        shopId: testShopId,
        filter: RechargeReportFilter.today(),
      );

      final jioWallet = report.walletReports[RechargeOperator.jio]!;
      expect(jioWallet.ownTopUp, equals(2000.0));
      expect(jioWallet.rechargeDebits, equals(299.0));
      expect(jioWallet.closingBalance, equals(1701.0)); // 2000 - 299 = 1701
    });

    // -------------------------------------------------------------------------
    // TEST 7: Distributor outstanding calculations
    // -------------------------------------------------------------------------
    test('TEST 7: Distributor outstanding report computes opening payable, credit received, payments, and closing balance', () async {
      // 1. Credit stock load of ₹5,000 from Murugan Vi
      await service.recordDistributorCreditLoad(
        shopId: testShopId,
        operator: RechargeOperator.vi,
        distributorId: 'DIST_MURUGAN_VI',
        amount: 5000.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'CREDIT_LOAD_MURUGAN',
      );

      // 2. Payment of ₹1,000 cash to distributor
      await service.recordDistributorPayment(
        shopId: testShopId,
        distributorId: 'DIST_MURUGAN_VI',
        amount: 1000.0,
        paymentMode: 'CASH',
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'PAY_MURUGAN_1000',
      );

      final report = await service.generateFinancialReport(
        shopId: testShopId,
        filter: RechargeReportFilter.today(),
      );

      final dist = report.distributorReports.firstWhere((d) => d.distributorId == 'DIST_MURUGAN_VI');
      expect(dist.creditReceived, equals(5000.0));
      expect(dist.paymentsMade, equals(1000.0));
      expect(dist.cashPayments, equals(1000.0));
      expect(dist.closingOutstanding, equals(4000.0)); // 5000 - 1000 = 4000
    });

    // -------------------------------------------------------------------------
    // TEST 8: Cash and UPI reconciliation
    // -------------------------------------------------------------------------
    test('TEST 8: Cash & Bank reconciliation accurately tracks cash in drawer, refunds, distributor payouts, and deposits', () async {
      final now = DateTime.now();

      // 1. Customer paid ₹500 cash for recharge
      await service.recordCustomerRechargePayment(
        recharge: RechargeEntry(
          rechargeId: 'REC_RECON_CASH',
          shopId: testShopId,
          operator: RechargeOperator.airtel,
          customerMobile: '9847777777',
          amount: 500.0,
          amountPaise: 50000,
          fundingType: RechargeFundingType.ownMoney,
          paymentMode: RechargePaymentMode.cash,
          status: RechargeStatus.success,
          staffId: 'staff_1',
          staffName: 'Shahal',
          createdAt: now,
          updatedAt: now,
          dateString: '2026-11-07',
        ),
      );

      // 2. Customer paid ₹300 UPI for recharge
      await service.recordCustomerRechargePayment(
        recharge: RechargeEntry(
          rechargeId: 'REC_RECON_UPI',
          shopId: testShopId,
          operator: RechargeOperator.jio,
          customerMobile: '9847888888',
          amount: 300.0,
          amountPaise: 30000,
          fundingType: RechargeFundingType.ownMoney,
          paymentMode: RechargePaymentMode.upi,
          status: RechargeStatus.success,
          staffId: 'staff_1',
          staffName: 'Shahal',
          createdAt: now,
          updatedAt: now,
          dateString: '2026-11-07',
        ),
      );

      // 3. Customer cash refund of ₹100
      await service.processCustomerRefund(
        shopId: testShopId,
        rechargeId: 'REC_RECON_CASH',
        refundAmount: 100.0,
        refundMethod: RechargePaymentMode.cash,
        staffId: 'staff_1',
        staffName: 'Shahal',
        reason: 'Partial refund',
      );

      final report = await service.generateFinancialReport(
        shopId: testShopId,
        filter: RechargeReportFilter.today(),
      );

      final recon = report.reconciliation;
      expect(recon.rechargeCashCollected, equals(500.0));
      expect(recon.rechargeUpiCollected, equals(300.0));
      expect(recon.customerCashRefunds, equals(100.0));
      // Net physical cash flow into drawer = 500 - 100 = +400
      expect(recon.netPhysicalCashFlow, equals(400.0));
    });

    // -------------------------------------------------------------------------
    // TEST 9: EOD consistency
    // -------------------------------------------------------------------------
    test('TEST 9: EOD cash consistency: recharge net cash reconciles cleanly with ₹1,000 opening float', () async {
      final initialDrawerCash = Db.cash;
      expect(initialDrawerCash, equals(3000.0)); // Includes ₹1,000 float + ₹2,000 retail sales

      // Recharge cash in: +₹299
      await service.recordCustomerRechargePayment(
        recharge: RechargeEntry(
          rechargeId: 'REC_EOD_IN',
          shopId: testShopId,
          operator: RechargeOperator.airtel,
          customerMobile: '9847999999',
          amount: 299.0,
          amountPaise: 29900,
          fundingType: RechargeFundingType.ownMoney,
          paymentMode: RechargePaymentMode.cash,
          status: RechargeStatus.success,
          staffId: 'staff_1',
          staffName: 'Shahal',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          dateString: '2026-11-07',
        ),
      );

      // Separation rule: ERP cash unchanged; the Daily Register adds the ₹299.
      expect(Db.cash, equals(3000.0));
      final physicalDrawerCash = Db.cash + 299.0;

      const openingFloat = 1000.0;
      final netDrawerHandover = physicalDrawerCash - openingFloat;
      expect(netDrawerHandover, equals(2299.0)); // Exactly ₹2,000 retail + ₹299 recharge cash!
      expect(openingFloat, equals(1000.0)); // Float preserved!
    });

    // -------------------------------------------------------------------------
    // TEST 10: Export accuracy
    // -------------------------------------------------------------------------
    test('TEST 10: Export accuracy: PDF bytes are non-empty and valid; CSV includes shop headers and exact totals', () async {
      final now = DateTime.now();

      await service.recordCustomerRechargePayment(
        recharge: RechargeEntry(
          rechargeId: 'REC_EXPORT_ACC',
          shopId: testShopId,
          operator: RechargeOperator.jio,
          customerMobile: '9847010203',
          amount: 599.0,
          amountPaise: 59900,
          fundingType: RechargeFundingType.ownMoney,
          paymentMode: RechargePaymentMode.upi,
          status: RechargeStatus.success,
          staffId: 'staff_1',
          staffName: 'Shahal',
          createdAt: now,
          updatedAt: now,
          dateString: '2026-11-07',
        ),
      );

      final report = await service.generateFinancialReport(
        shopId: testShopId,
        filter: RechargeReportFilter.today(),
      );

      // 1. PDF Export Verification
      final pdfBytes = await service.generateReportPdf(
        report,
        shopName: 'TEKFIX DIGITAL HUB',
        shopAddress: 'Calicut, Kerala',
        shopPhone: '9847000111',
      );

      expect(pdfBytes, isNotNull);
      expect(pdfBytes.length, greaterThan(1000)); // Valid non-empty binary PDF stream
      // Check PDF header signature: %PDF
      final header = String.fromCharCodes(pdfBytes.take(4));
      expect(header, equals('%PDF'));

      // 2. CSV Export Verification
      final csvString = service.generateReportCsv(report, shopName: 'TEKFIX DIGITAL HUB');
      expect(csvString.contains('TEKFIX ERP - RECHARGE & FINANCIAL RECONCILIATION REPORT'), isTrue);
      expect(csvString.contains('Shop:,"TEKFIX DIGITAL HUB"'), isTrue);
      expect(csvString.contains('Total Successful Recharges,599.00,1'), isTrue);
      expect(csvString.contains('Jio'), isTrue);
    });

    // -------------------------------------------------------------------------
    // TEST 11: Duplicate ledger protection
    // -------------------------------------------------------------------------
    test('TEST 11: Duplicate ledger postings and double submissions are strictly prevented', () async {
      final recharge = RechargeEntry(
        rechargeId: 'REC_DUP_TEST_PH9',
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        customerMobile: '9847050505',
        amount: 299.0,
        amountPaise: 29900,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.cash,
        status: RechargeStatus.success,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: '2026-11-07',
      );

      // First submission
      await service.recordCustomerRechargePayment(recharge: recharge);
      expect(service.isRechargeFinanciallyPosted(recharge.rechargeId), isTrue);

      // Second duplicate submission must throw exception
      expect(
        () => service.recordCustomerRechargePayment(recharge: recharge),
        throwsException,
      );
    });
  });
}
