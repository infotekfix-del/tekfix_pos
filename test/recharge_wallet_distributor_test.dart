import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/recharge/recharge_models.dart';
import 'package:tekfix_erp_pos/recharge/recharge_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const testShopId = 'test_shop_tekfix';
  final service = RechargeService.instance;

  setUp(() {
    service.resetLocalCacheForTesting();
    service.disableOpeningBalanceGateForTesting();
  });

  group('TEKFIX ERP - Phase 3: Operator Wallet & Distributor Credit Ledger', () {
    // -------------------------------------------------------------------------
    // TEST 1: ₹5,000 Own Money Top-up
    // -------------------------------------------------------------------------
    test('1. Record ₹5,000 Own Money Top-up (Asset Transfer, Expense = ₹0)',
        () async {
      final res = await service.recordOwnMoneyTopUp(
        shopId: testShopId,
        operator: RechargeOperator.jio,
        amount: 5000.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceId: 'TOPUP_JIO_5000',
        description: 'Bank Transfer to Jio POS Plus Wallet',
      );

      // Verify Wallet Balance
      expect(res.wallet.ownPrepaidBalance, 5000.0);
      expect(res.wallet.ownPrepaidBalancePaise, 500000);
      expect(res.wallet.distributorCreditBalance, 0.0);
      expect(res.wallet.totalBalance, 5000.0);

      // Verify Ledger Entry
      expect(res.entry.entryType, 'TOPUP');
      expect(res.entry.fundingType, RechargeFundingType.ownMoney);
      expect(res.entry.amountPaise, 500000);
      expect(res.entry.balanceBeforePaise, 0);
      expect(res.entry.balanceAfterPaise, 500000);

      // Distributor Payable must be completely unaffected
      final dist = await service.getDistributor(
          shopId: testShopId, distributorId: 'DIST_JIO_AGENCY');
      expect(dist.currentOutstanding, 0.0);
    });

    // -------------------------------------------------------------------------
    // TEST 2: ₹10,000 Distributor Credit Load
    // -------------------------------------------------------------------------
    test(
        '2. Record ₹10,000 Distributor Credit (Wallet +₹10,000, Payable +₹10,000)',
        () async {
      final res = await service.recordDistributorCreditLoad(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        distributorId: 'DIST_APEX_AIRTEL',
        amount: 10000.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'CREDIT_AIRTEL_10000',
        notes: 'Airtel Mitra 10k credit load',
      );

      // Verify Wallet Balances
      expect(res.wallet.distributorCreditBalance, 10000.0);
      expect(res.wallet.distributorCreditBalancePaise, 1000000);
      expect(res.wallet.ownPrepaidBalance, 0.0);
      expect(res.wallet.totalBalance, 10000.0);

      // Verify Distributor Liability
      expect(res.distributor.currentOutstanding, 10000.0);
      expect(res.distributor.currentOutstandingPaise, 1000000);
      expect(res.distributor.totalCreditReceived, 10000.0);

      // Verify Immutable Ledger Entries
      expect(res.walletEntry.entryType, 'CREDIT_LOAD');
      expect(res.walletEntry.fundingType, RechargeFundingType.distributorCredit);
      expect(res.distributorEntry.entryType, 'CREDIT_RECEIVED');
      expect(res.distributorEntry.outstandingAfterPaise, 1000000);
    });

    // -------------------------------------------------------------------------
    // TEST 3: ₹299 Recharge using Own Money
    // -------------------------------------------------------------------------
    test('3. Process ₹299 Recharge using Own Money (Debits Own Prepaid Balance)',
        () async {
      // Setup ₹5,000 own money in Jio wallet
      await service.recordOwnMoneyTopUp(
        shopId: testShopId,
        operator: RechargeOperator.jio,
        amount: 5000.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      final recharge = RechargeEntry(
        rechargeId: 'REC_JIO_299',
        shopId: testShopId,
        operator: RechargeOperator.jio,
        customerMobile: '9847123456',
        amount: 299.0,
        amountPaise: 29900,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.cash,
        status: RechargeStatus.success,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: '2026_11_07',
      );

      final res = await service.processRechargeDebit(recharge: recharge);

      // Wallet own prepaid balance: ₹5,000 - ₹299 = ₹4,701
      expect(res.wallet.ownPrepaidBalance, 4701.0);
      expect(res.wallet.ownPrepaidBalancePaise, 470100);
      // Distributor credit balance must be untouched (₹0)
      expect(res.wallet.distributorCreditBalance, 0.0);

      expect(res.entry.entryType, 'RECHARGE_DEBIT');
      expect(res.entry.balanceBeforePaise, 500000);
      expect(res.entry.balanceAfterPaise, 470100);
    });

    // -------------------------------------------------------------------------
    // TEST 4: ₹299 Recharge using Distributor Credit
    // -------------------------------------------------------------------------
    test(
        '4. Process ₹299 Recharge using Distributor Credit (Debits Credit Balance)',
        () async {
      // Setup ₹10,000 credit in Airtel wallet
      await service.recordDistributorCreditLoad(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        distributorId: 'DIST_APEX_AIRTEL',
        amount: 10000.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      final recharge = RechargeEntry(
        rechargeId: 'REC_AIRTEL_299',
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        customerMobile: '9447098765',
        amount: 299.0,
        amountPaise: 29900,
        fundingType: RechargeFundingType.distributorCredit,
        distributorId: 'DIST_APEX_AIRTEL',
        paymentMode: RechargePaymentMode.upi,
        status: RechargeStatus.success,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: '2026_11_07',
      );

      final res = await service.processRechargeDebit(recharge: recharge);

      // Wallet distributor credit balance: ₹10,000 - ₹299 = ₹9,701
      expect(res.wallet.distributorCreditBalance, 9701.0);
      expect(res.wallet.distributorCreditBalancePaise, 970100);
      // Own prepaid balance must remain ₹0
      expect(res.wallet.ownPrepaidBalance, 0.0);

      expect(res.entry.entryType, 'RECHARGE_DEBIT');
      expect(res.entry.balanceBeforePaise, 1000000);
      expect(res.entry.balanceAfterPaise, 970100);

      // Distributor liability remains ₹10,000 until settlement payment
      final dist = await service.getDistributor(
          shopId: testShopId, distributorId: 'DIST_APEX_AIRTEL');
      expect(dist.currentOutstanding, 10000.0);
    });

    // -------------------------------------------------------------------------
    // TEST 5: Partial Distributor Payment
    // -------------------------------------------------------------------------
    test(
        '5. Record Partial Payment of ₹4,000 to Distributor (Outstanding decreases to ₹6,000)',
        () async {
      // Setup ₹10,000 credit
      await service.recordDistributorCreditLoad(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        distributorId: 'DIST_APEX_AIRTEL',
        amount: 10000.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      // Pay ₹4,000 Cash to distributor
      final res = await service.recordDistributorPayment(
        shopId: testShopId,
        distributorId: 'DIST_APEX_AIRTEL',
        amount: 4000.0,
        paymentMode: 'CASH',
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'VOUCH_PARTIAL_4000',
        notes: 'Partial settlement to Apex agent',
      );

      expect(res.isFullSettlement, false);
      expect(res.distributor.currentOutstanding, 6000.0);
      expect(res.distributor.currentOutstandingPaise, 600000);
      expect(res.distributor.totalPaymentsMade, 4000.0);

      expect(res.entry.entryType, 'PAYMENT_MADE');
      expect(res.entry.outstandingBeforePaise, 1000000);
      expect(res.entry.outstandingAfterPaise, 600000);
    });

    // -------------------------------------------------------------------------
    // TEST 6: Full Distributor Settlement
    // -------------------------------------------------------------------------
    test(
        '6. Record Full Settlement of remaining ₹6,000 (Outstanding becomes exact ₹0.00)',
        () async {
      // Setup ₹10,000 credit
      await service.recordDistributorCreditLoad(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        distributorId: 'DIST_APEX_AIRTEL',
        amount: 10000.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      // Partial pay ₹4,000
      await service.recordDistributorPayment(
        shopId: testShopId,
        distributorId: 'DIST_APEX_AIRTEL',
        amount: 4000.0,
        paymentMode: 'CASH',
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      // Settle remaining ₹6,000 via Bank Transfer
      final res = await service.recordDistributorPayment(
        shopId: testShopId,
        distributorId: 'DIST_APEX_AIRTEL',
        amount: 6000.0,
        paymentMode: 'BANK',
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'VOUCH_FULL_6000',
        notes: 'Final settlement to Apex agent',
      );

      expect(res.isFullSettlement, true);
      expect(res.distributor.currentOutstanding, 0.0);
      expect(res.distributor.currentOutstandingPaise, 0);
      expect(res.distributor.totalPaymentsMade, 10000.0);
      expect(res.entry.outstandingAfterPaise, 0);
    });

    // -------------------------------------------------------------------------
    // TEST 7: Duplicate Transaction Prevention & Insufficient Balance Guards
    // -------------------------------------------------------------------------
    test(
        '7. Enforce Idempotency & Insufficient Balance Protection',
        () async {
      // Top-up ₹100 own money
      await service.recordOwnMoneyTopUp(
        shopId: testShopId,
        operator: RechargeOperator.vi,
        amount: 100.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceId: 'TOPUP_VI_100',
      );

      // Attempting recharge of ₹299 must throw Insufficient Balance
      final overRecharge = RechargeEntry(
        rechargeId: 'REC_VI_299_FAIL',
        shopId: testShopId,
        operator: RechargeOperator.vi,
        customerMobile: '9745511223',
        amount: 299.0,
        amountPaise: 29900,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.cash,
        status: RechargeStatus.pending,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: '2026_11_07',
      );

      expect(
        () => service.processRechargeDebit(recharge: overRecharge),
        throwsA(isA<Exception>()),
      );

      // Duplicate submission of same recharge ID must be rejected
      final validRecharge = RechargeEntry(
        rechargeId: 'REC_VI_50_PASS',
        shopId: testShopId,
        operator: RechargeOperator.vi,
        customerMobile: '9745511223',
        amount: 50.0,
        amountPaise: 5000,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.cash,
        status: RechargeStatus.success,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: '2026_11_07',
      );

      await service.processRechargeDebit(recharge: validRecharge);

      // Second attempt with exact same ID
      expect(
        () => service.processRechargeDebit(recharge: validRecharge),
        throwsA(isA<Exception>()),
      );
    });
  });
}

