import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/recharge/recharge_models.dart';
import 'package:tekfix_erp_pos/recharge/recharge_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TEKFIX ERP - Phase 6: Recharge Commission Accounting', () {
    late Directory tempDir;
    const testShopId = 'test_shop_tekfix';
    final service = RechargeService.instance;

    setUpAll(() async {
      GoogleFonts.config.allowRuntimeFetching = false;
      tempDir = await Directory.systemTemp.createTemp('comm_acc_test_');
      Hive.init(tempDir.path);

      for (final b in allBoxes) {
        await Hive.openBox(b);
      }

      final settingsBox = Hive.box(boxSettings);
      await settingsBox.put('shop_id', testShopId);
      await settingsBox.put('shop_name', 'TEKFIX DIGITAL HUB');
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
      await Db.bank.clear();
      await Db.sales.clear();
      await Db.expenses.clear();

      // Standard retail accounts baseline
      await Db.bank.put('cash_in_hand', 3000.0); // Baseline cash drawer: ₹3,000
      await Db.bank.put('bank_balance', 15000.0); // Baseline bank account: ₹15,000
      await Db.bank.put('txn_log', <Map<String, dynamic>>[]);
    });

    // -------------------------------------------------------------------------
    // TEST 1: Prepaid Commission (Load Margin)
    // -------------------------------------------------------------------------
    test(
        'TEST 1: ₹1,000 bank debit, ₹1,030 wallet credit, ₹30 commission. Verify no double counting and cash = 0.',
        () async {
      final initialBank = (Db.bank.get('bank_balance') as num).toDouble();
      final initialCash = (Db.bank.get('cash_in_hand') as num).toDouble();

      final result = await service.recordPrepaidTopUpCommission(
        shopId: testShopId,
        operator: RechargeOperator.jio,
        bankDebitAmount: 1000.0,
        walletCreditAmount: 1030.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'PREPAID_TOPUP_1000',
        notes: 'Jio POS Plus ₹1000 Load with 3% margin',
      );

      // A. Bank Balance decreases by exactly the money transferred (₹1,000)
      final updatedBank = (Db.bank.get('bank_balance') as num).toDouble();
      expect(updatedBank, initialBank - 1000.0,
          reason: 'Bank must debit only the actual ₹1,000 paid out');

      // B. Physical Cash Drawer is completely untouched
      final updatedCash = (Db.bank.get('cash_in_hand') as num).toDouble();
      expect(updatedCash, initialCash,
          reason: 'Prepaid bank top-up must never affect physical cash drawer');

      // C. Operator Wallet Balance reflects ₹1,030
      expect(result.wallet.ownPrepaidBalance, 1030.0);
      expect(result.wallet.ownPrepaidBalancePaise, 103000);

      // D. Commission Income = ₹30
      expect(result.commission.amount, 30.0);
      expect(result.commission.amountPaise, 3000);
      expect(result.commission.commissionType, RechargeCommissionType.prepaid);
      expect(result.commission.status, CommissionStatus.confirmed);

      // E. Verify No Double Counting in Wallet
      // The wallet was credited with ₹1,030 (which includes the ₹30 margin).
      // Verify wallet total balance is exactly ₹1,030, NOT ₹1,060!
      expect(result.wallet.totalBalance, 1030.0);

      // F. Verify Dashboard Summary
      final summary = await service.getCommissionDashboardSummary(
        shopId: testShopId,
      );
      expect(summary.todayConfirmed, 30.0);
      expect(summary.jioCommission, 30.0);
      expect(summary.pendingCommission, 0.0);
    });

    // -------------------------------------------------------------------------
    // TEST 2: Postpaid Commission (₹299 recharge, ₹6 actual commission)
    // -------------------------------------------------------------------------
    test(
        'TEST 2: ₹299 recharge, ₹6 actual postpaid commission. Verify commission income = ₹6.',
        () async {
      // 1. Process customer recharge payment of ₹299 (Pass-through)
      final recharge = RechargeEntry(
        rechargeId: 'REC_JIO_POST_299',
        shopId: testShopId,
        operator: RechargeOperator.jio,
        customerMobile: '9847000001',
        amount: 299.0,
        amountPaise: 29900,
        fundingType: RechargeFundingType.distributorCredit,
        paymentMode: RechargePaymentMode.upi,
        referenceNumber: 'UPI_REC_299',
        status: RechargeStatus.success,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: '2026-11-07',
      );

      await service.recordCustomerRechargePayment(recharge: recharge);

      // Customer recharge principal is strictly non-revenue pass-through
      expect(Db.sales.length, 0,
          reason: 'Recharge principal is NEVER retail sales revenue');

      // 2. Record ₹6 backend commission earned
      final commission = await service.recordPostpaidCommission(
        shopId: testShopId,
        operator: RechargeOperator.jio,
        amount: 6.0,
        status: CommissionStatus.confirmed,
        staffId: 'staff_1',
        staffName: 'Shahal',
        rechargeId: 'REC_JIO_POST_299',
        referenceNumber: 'COMM_JIO_6',
        notes: '2% postpaid commission for ₹299 plan',
      );

      // Verify commission income
      expect(commission.amount, 6.0);
      expect(commission.status, CommissionStatus.confirmed);
      expect(commission.commissionType, RechargeCommissionType.postpaid);

      final summary = await service.getCommissionDashboardSummary(
        shopId: testShopId,
      );
      expect(summary.todayConfirmed, 6.0);
      expect(summary.confirmedCommission, 6.0);
    });

    // -------------------------------------------------------------------------
    // TEST 3: Pending Commission Excluded from Confirmed Income
    // -------------------------------------------------------------------------
    test(
        'TEST 3: Pending commission ₹20. Verify it is excluded from confirmed income.',
        () async {
      // Record ₹20 as pending commission (e.g. unverified distributor backend incentive)
      await service.recordPostpaidCommission(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        amount: 20.0,
        status: CommissionStatus.pending,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'PENDING_COMM_20',
        notes: 'Unverified Airtel DTH backend target incentive',
      );

      final summary = await service.getCommissionDashboardSummary(
        shopId: testShopId,
      );

      // Confirmed income must strictly be ₹0
      expect(summary.todayConfirmed, 0.0,
          reason: 'Pending commission must NOT appear in today confirmed income');
      expect(summary.confirmedCommission, 0.0,
          reason: 'Pending commission must NOT appear in total confirmed income');

      // Pending total must be ₹20
      expect(summary.pendingCommission, 20.0,
          reason: 'Pending commission bucket must hold the ₹20 accrual');
    });

    // -------------------------------------------------------------------------
    // TEST 4: Duplicate Commission Submission Blocked
    // -------------------------------------------------------------------------
    test('TEST 4: Duplicate commission submission. Verify only one entry is recorded.',
        () async {
      await service.recordPostpaidCommission(
        shopId: testShopId,
        operator: RechargeOperator.vi,
        amount: 15.0,
        status: CommissionStatus.confirmed,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'IDEMPOTENT_COMM_15',
      );

      // Attempt second submission with exact same reference
      expect(
        () => service.recordPostpaidCommission(
          shopId: testShopId,
          operator: RechargeOperator.vi,
          amount: 15.0,
          status: CommissionStatus.confirmed,
          staffId: 'staff_1',
          staffName: 'Shahal',
          referenceNumber: 'IDEMPOTENT_COMM_15',
        ),
        throwsA(isA<Exception>()),
      );

      final report = await service.getCommissionReport(
        shopId: testShopId,
        operator: RechargeOperator.vi,
      );
      expect(report.length, 1, reason: 'Exactly one commission record must exist');
    });

    // -------------------------------------------------------------------------
    // TEST 5: Cash Drawer Isolation & Explicit Cash Realization
    // -------------------------------------------------------------------------
    test(
        'TEST 5: Verify commission does not affect physical cash unless separately received in cash.',
        () async {
      final initialCash = (Db.bank.get('cash_in_hand') as num).toDouble();

      // Case A: Distributor Discount / Wallet margin does NOT increase cash drawer
      await service.recordPostpaidCommission(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        amount: 50.0,
        status: CommissionStatus.confirmed,
        settlementMethod: CommissionSettlementMethod.distributorDiscount,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'COMM_DISC_50',
      );

      expect((Db.bank.get('cash_in_hand') as num).toDouble(), initialCash,
          reason: 'Distributor discount commission must NEVER inflate physical cash');

      // Case B: Explicit Physical Cash Payout increases cash drawer
      await service.recordPostpaidCommission(
        shopId: testShopId,
        operator: RechargeOperator.bsnl,
        amount: 40.0,
        status: CommissionStatus.confirmed,
        settlementMethod: CommissionSettlementMethod.cashPayout,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'COMM_CASH_40',
      );

      expect((Db.bank.get('cash_in_hand') as num).toDouble(), initialCash + 40.0,
          reason: 'Physical cash received commission correctly increases drawer cash');
    });

    // -------------------------------------------------------------------------
    // TEST 6: Operator-wise Commission Breakdown
    // -------------------------------------------------------------------------
    test('TEST 6: Operator-wise commission reporting across all operators.',
        () async {
      await service.recordPostpaidCommission(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        amount: 100.0,
        status: CommissionStatus.confirmed,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'COMM_AIRTEL_100',
      );
      await service.recordPostpaidCommission(
        shopId: testShopId,
        operator: RechargeOperator.jio,
        amount: 80.0,
        status: CommissionStatus.confirmed,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'COMM_JIO_80',
      );
      await service.recordPostpaidCommission(
        shopId: testShopId,
        operator: RechargeOperator.vi,
        amount: 60.0,
        status: CommissionStatus.confirmed,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'COMM_VI_60',
      );
      await service.recordPostpaidCommission(
        shopId: testShopId,
        operator: RechargeOperator.bsnl,
        amount: 40.0,
        status: CommissionStatus.confirmed,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'COMM_BSNL_40',
      );

      final summary = await service.getCommissionDashboardSummary(
        shopId: testShopId,
      );

      expect(summary.airtelCommission, 100.0);
      expect(summary.jioCommission, 80.0);
      expect(summary.viCommission, 60.0);
      expect(summary.bsnlCommission, 40.0);
      expect(summary.todayConfirmed, 280.0);
    });

    // -------------------------------------------------------------------------
    // TEST 7: Transitioning Pending Commission to Confirmed
    // -------------------------------------------------------------------------
    test('TEST 7: Confirm pending commission updates confirmed totals.',
        () async {
      final pendingEntry = await service.recordPostpaidCommission(
        shopId: testShopId,
        operator: RechargeOperator.jio,
        amount: 75.0,
        status: CommissionStatus.pending,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'PENDING_TO_CONFIRM_75',
      );

      var summary = await service.getCommissionDashboardSummary(
        shopId: testShopId,
      );
      expect(summary.pendingCommission, 75.0);
      expect(summary.todayConfirmed, 0.0);

      // Confirm the pending commission
      final confirmed = await service.confirmPendingCommission(
        shopId: testShopId,
        commissionId: pendingEntry.commissionId,
        staffId: 'staff_admin',
        staffName: 'Admin',
      );

      expect(confirmed.status, CommissionStatus.confirmed);

      summary = await service.getCommissionDashboardSummary(
        shopId: testShopId,
      );
      expect(summary.pendingCommission, 0.0);
      expect(summary.todayConfirmed, 75.0);
    });
  });
}

