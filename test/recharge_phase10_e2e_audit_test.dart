import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/recharge/recharge_models.dart';
import 'package:tekfix_erp_pos/recharge/recharge_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TEKFIX ERP - Phase 10: Complete Recharge Audit & E2E Validation', () {
    late Directory tempDir;
    const testShopId = 'test_shop_tekfix_audit';
    final service = RechargeService.instance;

    setUpAll(() async {
      GoogleFonts.config.allowRuntimeFetching = false;
      tempDir = await Directory.systemTemp.createTemp('recharge_audit_phase10_');
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

      // Standard initial store ledger state
      await Db.bank.put('cash_in_hand', 1000.0); // Exactly ₹1,000 opening float
      await Db.bank.put('bank_balance', 10000.0); // Baseline store bank balance: ₹10,000
      await Db.bank.put('txn_log', <Map<String, dynamic>>[]);
    });

    // -------------------------------------------------------------------------
    // SCENARIO A: OWN MONEY RECHARGE
    // -------------------------------------------------------------------------
    test('SCENARIO A: Own Money Recharge - Bank Debit, Wallet Credit, Recharge Debit, Cash Collection', () async {
      // 1. Initial State: Bank = ₹10,000, Cash = ₹1,000 float
      expect(Db.bankBalance, equals(10000.0));
      expect(Db.cash, equals(1000.0));
      expect(Db.sales.length, equals(0));
      expect(Db.expenses.length, equals(0));

      // 2. Transfer ₹5,000 from Bank to Airtel Operator Wallet
      final topUpResult = await service.recordOwnMoneyTopUp(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        amount: 5000.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceId: 'BANK_TOPUP_5000',
        description: 'Own bank transfer to Airtel wallet',
      );

      // Verify Bank decreases by ₹5,000 and Wallet increases by ₹5,000
      expect(Db.bankBalance, equals(5000.0)); // 10,000 - 5,000 = 5,000
      expect(topUpResult.wallet.ownPrepaidBalance, equals(5000.0));
      expect(topUpResult.wallet.totalBalance, equals(5000.0));
      expect(Db.sales.length, equals(0)); // Zero sales contamination
      expect(Db.expenses.length, equals(0)); // Zero expense contamination

      // 3. Customer performs ₹299 Airtel Recharge (Successful)
      final now = DateTime.now();
      const dateStr = '2026-11-07';
      final recharge = RechargeEntry(
        rechargeId: 'REC_SCENARIO_A_299',
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        customerMobile: '9847112233',
        amount: 299.0,
        amountPaise: 29900,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.cash,
        status: RechargeStatus.success,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: now,
        updatedAt: now,
        dateString: dateStr,
      );

      // 4. Debit Operator Wallet & Collect ₹299 Cash from Customer
      final walletDebitResult = await service.processRechargeDebit(
        recharge: recharge,
      );

      final paymentResult = await service.recordCustomerRechargePayment(
        recharge: recharge,
      );

      // 5. Verification
      // Wallet balance: 5,000 - 299 = ₹4,701
      expect(walletDebitResult.wallet.ownPrepaidBalance, equals(4701.0));
      expect(walletDebitResult.wallet.totalBalance, equals(4701.0));

      // Customer Cash Collection: Physical drawer increases by ₹299 -> 1,000 + 299 = ₹1,299
      expect(Db.cash, equals(1299.0));
      expect(paymentResult.summary.cashCollection, equals(299.0));
      expect(paymentResult.summary.totalCollection, equals(299.0));

      // Retail Sales Revenue MUST remain exactly 0 (Pass-through agency fund)
      expect(Db.sales.length, equals(0));
      expect(Db.expenses.length, equals(0));
    });

    // -------------------------------------------------------------------------
    // SCENARIO B: DISTRIBUTOR CREDIT
    // -------------------------------------------------------------------------
    test('SCENARIO B: Distributor Credit - Credit Load, UPI Collection, Settlement Payout', () async {
      // 1. Receive ₹10,000 distributor credit from Apex Jio
      final creditResult = await service.recordDistributorCreditLoad(
        shopId: testShopId,
        operator: RechargeOperator.jio,
        distributorId: 'DIST_APEX_JIO',
        amount: 10000.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'JIO_CREDIT_LOAD_10000',
        notes: 'Received ₹10,000 credit stock from Jio distributor',
      );

      expect(creditResult.wallet.distributorCreditBalance, equals(10000.0));
      expect(creditResult.wallet.totalBalance, equals(10000.0));
      expect(creditResult.distributor.currentOutstanding, equals(10000.0));
      expect(Db.sales.length, equals(0)); // Liability, NOT revenue!

      // 2. Perform ₹299 Jio recharge
      final now = DateTime.now();
      const dateStr = '2026-11-07';
      final recharge = RechargeEntry(
        rechargeId: 'REC_SCENARIO_B_299',
        shopId: testShopId,
        operator: RechargeOperator.jio,
        customerMobile: '9847223344',
        amount: 299.0,
        amountPaise: 29900,
        fundingType: RechargeFundingType.distributorCredit,
        distributorId: 'DIST_APEX_JIO',
        paymentMode: RechargePaymentMode.upi,
        status: RechargeStatus.success,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: now,
        updatedAt: now,
        dateString: dateStr,
      );

      // Debit Credit Wallet & Collect UPI
      final debitResult = await service.processRechargeDebit(
        recharge: recharge,
      );

      final upiPaymentResult = await service.recordCustomerRechargePayment(
        recharge: recharge,
      );

      // Wallet reduced by ₹299: 10,000 - 299 = ₹9,701
      expect(debitResult.wallet.distributorCreditBalance, equals(9701.0));
      // Bank/UPI increased by ₹299: 10,000 + 299 = ₹10,299
      expect(Db.bankBalance, equals(10299.0));
      expect(upiPaymentResult.summary.upiCollection, equals(299.0));

      // 3. Make ₹1,000 distributor settlement payment (via Cash Drawer)
      // First ensure drawer has enough cash for ₹1,000 payout
      expect(Db.cash, equals(1000.0)); // Opening float is ₹1,000

      final settleResult = await service.recordDistributorPayment(
        shopId: testShopId,
        distributorId: 'DIST_APEX_JIO',
        amount: 1000.0,
        paymentMode: 'CASH',
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'PAY_JIO_DIST_1000',
        notes: 'Partial settlement to Apex Jio',
      );

      // Verify:
      // Distributor payable reduced: 10,000 - 1,000 = ₹9,000
      expect(settleResult.distributor.currentOutstanding, equals(9000.0));
      // Cash drawer reduced by ₹1,000: 1,000 - 1,000 = ₹0
      expect(Db.cash, equals(0.0));
      // Distributor payment is a balance sheet liability reduction, NOT an expense!
      expect(Db.expenses.length, equals(0));
      // Wallet remains ₹9,701
      final currentWallet = await service.getWallet(shopId: testShopId, operator: RechargeOperator.jio);
      expect(currentWallet.distributorCreditBalance, equals(9701.0));
    });

    // -------------------------------------------------------------------------
    // SCENARIO C: FAILED RECHARGE & REVERSALS
    // -------------------------------------------------------------------------
    test('SCENARIO C: Failed Recharge - Wallet Reversal, Customer Cash Refund, Zero Expense', () async {
      // 1. Start with Vi wallet having ₹1,000 own balance
      await service.recordOwnMoneyTopUp(
        shopId: testShopId,
        operator: RechargeOperator.vi,
        amount: 1000.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceId: 'VI_LOAD_1000',
      );

      // Cash drawer has ₹1,000 float
      expect(Db.cash, equals(1000.0));

      // 2. Customer attempts ₹399 Vi recharge with Cash payment
      final now = DateTime.now();
      const dateStr = '2026-11-07';
      final recharge = RechargeEntry(
        rechargeId: 'REC_SCENARIO_C_399',
        shopId: testShopId,
        operator: RechargeOperator.vi,
        customerMobile: '9847334455',
        amount: 399.0,
        amountPaise: 39900,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.cash,
        status: RechargeStatus.pending,
        customerPaymentCollected: true,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: now,
        updatedAt: now,
        dateString: dateStr,
      );

      // Wallet is debited ₹399 -> 1,000 - 399 = ₹601
      await service.processRechargeDebit(
        recharge: recharge,
      );
      // Customer payment collected in drawer -> 1,000 + 399 = ₹1,399
      await service.recordCustomerRechargePayment(recharge: recharge);
      expect(Db.cash, equals(1399.0));

      // 3. Recharge Fails on operator network -> Trigger full failure and customer cash refund workflow
      final failureResult = await service.processRechargeFailureAndReversal(
        shopId: testShopId,
        rechargeId: recharge.rechargeId,
        staffId: 'staff_1',
        staffName: 'Shahal',
        reason: 'Operator timeout: Vi network unreachable',
        refundCustomer: true,
        refundMethod: RechargePaymentMode.cash,
      );

      // 4. Verify Wallet Reversal and Cash Reduction:
      // Status updated to refunded
      expect(failureResult.recharge.status, equals(RechargeStatus.refunded));
      // Wallet balance restored: 601 + 399 = ₹1,000
      expect(failureResult.wallet?.ownPrepaidBalance, equals(1000.0));
      // Cash drawer reduced back to original: 1,399 - 399 = ₹1,000
      expect(Db.cash, equals(1000.0));
      // Zero expense contamination:
      expect(Db.expenses.length, equals(0));
      // Reversal ledger entries tracked
      expect(failureResult.reversals.length, equals(1));
      expect(failureResult.reversals.first.reversalType, equals(ReversalType.customerRefund));
    });

    // -------------------------------------------------------------------------
    // SCENARIO D: COMMISSION ACCOUNTING & CLAWBACK
    // -------------------------------------------------------------------------
    test('SCENARIO D: Commission Accounting - Confirmed Commission, Reversal Clawback, Zero Duplicates', () async {
      // 1. Record confirmed commission of ₹50 for Airtel
      final comm1 = await service.recordPostpaidCommission(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        amount: 50.0,
        status: CommissionStatus.confirmed,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'COMM_D_CONFIRMED_50',
      );

      // 2. Record pending commission of ₹30 for BSNL (Unconfirmed)
      await service.recordPostpaidCommission(
        shopId: testShopId,
        operator: RechargeOperator.bsnl,
        amount: 30.0,
        status: CommissionStatus.pending,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'COMM_D_PENDING_30',
      );

      // 3. Verify net commission income: Pending must be excluded!
      var report = await service.generateFinancialReport(
        shopId: testShopId,
        filter: RechargeReportFilter.today(),
      );
      expect(report.confirmedCommissionEarned, equals(50.0));
      expect(report.netCommissionIncome, equals(50.0));

      // 4. Clawback / Reversal of ₹20 from comm1
      await service.reverseCommissionEntry(
        shopId: testShopId,
        commissionId: comm1.commissionId,
        staffId: 'staff_1',
        staffName: 'Shahal',
        reason: 'Customer cancelled transaction, operator clawback',
      );

      // 5. Verify Net Commission Income = Confirmed - Reversed
      report = await service.generateFinancialReport(
        shopId: testShopId,
        filter: RechargeReportFilter.today(),
      );
      expect(report.confirmedCommissionEarned, equals(50.0));
      expect(report.confirmedCommissionReversed, equals(50.0));
      expect(report.netCommissionIncome, equals(0.0));

      // 6. Duplicate Commission Prevention: Submitting same reference number must fail
      expect(
        () => service.recordPostpaidCommission(
          shopId: testShopId,
          operator: RechargeOperator.airtel,
          amount: 50.0,
          status: CommissionStatus.confirmed,
          staffId: 'staff_1',
          staffName: 'Shahal',
          referenceNumber: 'COMM_D_CONFIRMED_50',
        ),
        throwsException,
      );
    });

    // -------------------------------------------------------------------------
    // SCENARIO E: MASTER EOD CLOSING & PHYSICAL DRAWER RECONCILIATION
    // -------------------------------------------------------------------------
    test('SCENARIO E: EOD Closing - Master Physical Cash Equation & Float Preservation', () async {
      // 1. Initial State: Opening Float = ₹1,000
      const openingFloat = 1000.0;
      expect(Db.cash, equals(openingFloat));

      // 2. Retail Cash Sales: ₹2,500
      await Db.moveMoney('Cash', 2500.0, 'Retail Store Sales');
      const retailCash = 2500.0;

      // 3. Service Cash Collection: ₹1,500
      await Db.moveMoney('Cash', 1500.0, 'Service Repair Inflow');
      const serviceCash = 1500.0;

      // 4. Recharge Cash Inflow: ₹299 (Airtel) + ₹199 (Jio) = ₹498
      final now = DateTime.now();
      const dateStr = '2026-11-07';
      await service.recordCustomerRechargePayment(
        recharge: RechargeEntry(
          rechargeId: 'REC_EOD_1',
          shopId: testShopId,
          operator: RechargeOperator.airtel,
          customerMobile: '9847111111',
          amount: 299.0,
          amountPaise: 29900,
          fundingType: RechargeFundingType.ownMoney,
          paymentMode: RechargePaymentMode.cash,
          status: RechargeStatus.success,
          staffId: 'staff_1',
          staffName: 'Shahal',
          createdAt: now,
          updatedAt: now,
          dateString: dateStr,
        ),
      );
      await service.recordCustomerRechargePayment(
        recharge: RechargeEntry(
          rechargeId: 'REC_EOD_2',
          shopId: testShopId,
          operator: RechargeOperator.jio,
          customerMobile: '9847222222',
          amount: 199.0,
          amountPaise: 19900,
          fundingType: RechargeFundingType.ownMoney,
          paymentMode: RechargePaymentMode.cash,
          status: RechargeStatus.success,
          staffId: 'staff_1',
          staffName: 'Shahal',
          createdAt: now,
          updatedAt: now,
          dateString: dateStr,
        ),
      );
      const rechargeCash = 498.0;

      // 5. Customer Cash Refund: ₹100
      await service.processCustomerRefund(
        shopId: testShopId,
        rechargeId: 'REC_EOD_1',
        refundAmount: 100.0,
        refundMethod: RechargePaymentMode.cash,
        staffId: 'staff_1',
        staffName: 'Shahal',
        reason: 'Network discrepancy refund',
      );
      const customerCashRefund = 100.0;

      // 6. Distributor Cash Payment: ₹500
      await service.recordDistributorPayment(
        shopId: testShopId,
        distributorId: 'DIST_APEX_AIRTEL',
        amount: 500.0,
        paymentMode: 'CASH',
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'PAY_DIST_EOD_500',
      );
      const distributorCashPayment = 500.0;

      // 7. Float Bank Deposit (Contra): ₹200 cash deposited to bank
      await service.recordRechargeFloatDeposit(
        shopId: testShopId,
        amount: 200.0,
        bankAccountId: 'PRIMARY_STORE_BANK',
        bankAccountName: 'State Bank of India',
        staffId: 'staff_1',
        staffName: 'Shahal',
        depositType: FloatDepositType.cashDeposit,
        isConfirmed: true,
        referenceNumber: 'DEP_EOD_200',
      );
      const bankDeposit = 200.0;

      // 8. General Retail Cash Expense: ₹150 (Shop supplies)
      await Db.moveMoney('Cash', -150.0, 'Shop Cleaning Supplies');
      const cashExpenses = 150.0;

      // 9. Master Physical Cash Equation:
      // Opening (1,000)
      // + Retail Cash (2,500)
      // + Service Cash (1,500)
      // + Recharge Cash (498)
      // - Customer Cash Refund (100)
      // - Distributor Cash Payment (500)
      // - Bank Deposit (200)
      // - Cash Expenses (150)
      // = 1,000 + 2,500 + 1,500 + 498 - 100 - 500 - 200 - 150
      // = 4,548.0
      const expectedClosingPhysicalCash = openingFloat +
          retailCash +
          serviceCash +
          rechargeCash -
          customerCashRefund -
          distributorCashPayment -
          bankDeposit -
          cashExpenses;

      expect(Db.cash, equals(expectedClosingPhysicalCash));
      expect(Db.cash, equals(4548.0));

      // 10. EOD Cash Float Closing Handover:
      // The ₹1,000 float remains in the drawer for tomorrow's opening.
      // Net Cash to handover / deposit = Closing Physical Cash - Opening Float
      final netCashHandover = Db.cash - openingFloat;
      expect(netCashHandover, equals(3548.0));
      expect(openingFloat, equals(1000.0)); // Float is preserved and never counted twice!
    });

    // -------------------------------------------------------------------------
    // SECURITY & DATA INTEGRITY TESTS
    // -------------------------------------------------------------------------
    test('SECURITY: Idempotency, Double-Submission Locks, and Late Success Flagging', () async {
      final recharge = RechargeEntry(
        rechargeId: 'REC_SEC_TEST_1',
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
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: '2026-11-07',
      );

      // First submission succeeds
      await service.recordCustomerRechargePayment(recharge: recharge);
      expect(service.isRechargeFinanciallyPosted(recharge.rechargeId), isTrue);

      // Duplicate submission blocked
      expect(
        () => service.recordCustomerRechargePayment(recharge: recharge),
        throwsException,
      );

      // Refund customer ₹299
      await service.processCustomerRefund(
        shopId: testShopId,
        rechargeId: recharge.rechargeId,
        refundAmount: 299.0,
        refundMethod: RechargePaymentMode.cash,
        staffId: 'staff_1',
        staffName: 'Shahal',
        reason: 'Customer complaint',
      );

      // Late Operator Success: Operator network confirms success AFTER customer was already refunded
      // Must NOT auto-reverse cash/bank! Must flag for Owner Review!
      final disputed = await service.resolveOperatorSuccessAfterRefund(
        shopId: testShopId,
        rechargeId: recharge.rechargeId,
        staffId: 'staff_1',
        staffName: 'Shahal',
        disputeNote: 'Operator confirmed success 45 min late',
      );

      expect(disputed.status, equals(RechargeStatus.disputed));
      expect(disputed.requiresOwnerReview, isTrue);
      expect(disputed.disputeNote, contains('Operator confirmed success'));
    });
  });
}
