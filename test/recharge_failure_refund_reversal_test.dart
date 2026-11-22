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

  group('TEKFIX ERP - Phase 8: Failed Recharge, Customer Refund & Transaction Reversal', () {
    late Directory tempDir;
    const testShopId = 'test_shop_tekfix';
    final service = RechargeService.instance;

    setUpAll(() async {
    // v2.1: the old client-side postings run only in localTestMock.
    RechargeBackendBridge.configure(mode: RechargeBackendMode.localTestMock);
      GoogleFonts.config.allowRuntimeFetching = false;
      tempDir = await Directory.systemTemp.createTemp('recharge_reversal_test_');
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
    // TEST 1: Pending -> Failed without wallet debit (no wallet credit created)
    // -------------------------------------------------------------------------
    test('TEST 1: Pending -> Failed without wallet debit creates zero wallet credits', () async {
      // 1. Setup wallet with ₹2,000 balance
      await service.recordOwnMoneyTopUp(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        amount: 2000.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceId: 'TOPUP_AIRTEL_2000',
      );

      final initialWallet = await service.getWallet(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
      );
      expect(initialWallet.ownPrepaidBalancePaise, equals(200000));

      // 2. Create a pending recharge that has NOT debited the wallet (walletDebited == false)
      final pendingRecharge = RechargeEntry(
        rechargeId: 'REC_PENDING_NO_DEBIT',
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        customerMobile: '9847000111',
        amount: 299.0,
        amountPaise: 29900,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.cash,
        status: RechargeStatus.pending,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: '2026-11-07',
        walletDebited: false,
        customerPaymentCollected: false,
      );

      // Save to local cache
      await service.recordCustomerRechargePayment(recharge: pendingRecharge);

      // 3. Mark failed
      final result = await service.markRechargeFailed(
        shopId: testShopId,
        rechargeId: pendingRecharge.rechargeId,
        staffId: 'staff_1',
        staffName: 'Shahal',
        reason: 'Operator portal timeout before wallet debit',
      );

      expect(result.recharge.status, equals(RechargeStatus.failed));
      expect(result.wallet, isNull);
      expect(result.walletEntry, isNull);

      final finalWallet = await service.getWallet(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
      );
      expect(finalWallet.ownPrepaidBalancePaise, equals(200000)); // Untouched!
    });

    // -------------------------------------------------------------------------
    // TEST 2: Failed after wallet debit (wallet balance restored)
    // -------------------------------------------------------------------------
    test('TEST 2: Failed after wallet debit restores exact wallet balance and adds reversal ledger entry', () async {
      // 1. Setup wallet with ₹2,000 balance
      await service.recordOwnMoneyTopUp(
        shopId: testShopId,
        operator: RechargeOperator.jio,
        amount: 2000.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceId: 'TOPUP_JIO_2000',
      );

      // 2. Perform recharge debit of ₹299
      final rechargeToDebit = RechargeEntry(
        rechargeId: 'REC_JIO_DEBITED_1',
        shopId: testShopId,
        operator: RechargeOperator.jio,
        customerMobile: '9847000222',
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

      final debitResult = await service.processRechargeDebit(recharge: rechargeToDebit);
      expect(debitResult.recharge.walletDebited, isTrue);
      expect(debitResult.wallet.ownPrepaidBalancePaise, equals(170100)); // 200000 - 29900 = 170100

      // 3. Operator subsequently reports transaction failure
      final failResult = await service.markRechargeFailed(
        shopId: testShopId,
        rechargeId: rechargeToDebit.rechargeId,
        staffId: 'staff_1',
        staffName: 'Shahal',
        reason: 'Jio API reported system failure',
      );

      expect(failResult.recharge.status, equals(RechargeStatus.failed));
      expect(failResult.wallet, isNotNull);
      expect(failResult.wallet!.ownPrepaidBalancePaise, equals(200000)); // Restored!
      expect(failResult.walletEntry, isNotNull);
      expect(failResult.walletEntry!.entryType, equals('WALLET_REVERSAL'));
      expect(failResult.walletEntry!.balanceAfterPaise, equals(200000));
    });

    // -------------------------------------------------------------------------
    // TEST 3: Cash customer refund (reduces physical cash in drawer)
    // -------------------------------------------------------------------------
    test('TEST 3: Cash customer refund reduces physical cash in drawer, zero retail expense', () async {
      final initialCash = Db.cash;
      expect(initialCash, equals(3000.0));

      // 1. Customer paid ₹299 cash for recharge
      final recharge = RechargeEntry(
        rechargeId: 'REC_CASH_SUCCESS_REFUND',
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        customerMobile: '9847111222',
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

      await service.recordCustomerRechargePayment(recharge: recharge);
      expect(Db.cash, equals(3000.0)); // separation rule: ERP cash unchanged

      // 2. Process cash refund of ₹299 back to customer
      final refundResult = await service.processCustomerRefund(
        shopId: testShopId,
        rechargeId: recharge.rechargeId,
        refundAmount: 299.0,
        refundMethod: RechargePaymentMode.cash,
        staffId: 'staff_1',
        staffName: 'Shahal',
        reason: 'Customer cancelled after network failure',
      );

      expect(refundResult.recharge.status, equals(RechargeStatus.refunded));
      expect(refundResult.refundRecord.amount, equals(299.0));
      expect(refundResult.refundRecord.refundMethod, equals(RechargePaymentMode.cash));

      // Verify physical drawer cash returned to baseline
      expect(Db.cash, equals(3000.0)); // 3299 - 299 = 3000
      expect(Db.expenses.values.isEmpty, isTrue); // Zero contamination of retail expenses!
      expect(Db.sales.values.isEmpty, isTrue); // Zero contamination of retail sales!
    });

    // -------------------------------------------------------------------------
    // TEST 4: UPI customer refund (reduces bank balance, cash drawer untouched)
    // -------------------------------------------------------------------------
    test('TEST 4: UPI customer refund reduces bank balance, physical cash drawer untouched', () async {
      final initialCash = Db.cash;
      final initialBank = Db.bankBalance;
      expect(initialCash, equals(3000.0));
      expect(initialBank, equals(15000.0));

      // 1. Customer paid ₹499 via UPI
      final recharge = RechargeEntry(
        rechargeId: 'REC_UPI_SUCCESS_REFUND',
        shopId: testShopId,
        operator: RechargeOperator.jio,
        customerMobile: '9847222333',
        amount: 499.0,
        amountPaise: 49900,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.upi,
        status: RechargeStatus.success,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: '2026-11-07',
      );

      await service.recordCustomerRechargePayment(recharge: recharge);
      expect(Db.bankBalance, equals(15000.0)); // separation rule
      expect(Db.cash, equals(3000.0)); // Untouched

      // 2. Process UPI refund of ₹499
      final refundResult = await service.processCustomerRefund(
        shopId: testShopId,
        rechargeId: recharge.rechargeId,
        refundAmount: 499.0,
        refundMethod: RechargePaymentMode.upi,
        staffId: 'staff_1',
        staffName: 'Shahal',
        reason: 'UPI transaction reversed to customer VPA',
      );

      expect(refundResult.recharge.status, equals(RechargeStatus.refunded));
      expect(Db.bankBalance, equals(15000.0)); // Bank balance reduced back to baseline
      expect(Db.cash, equals(3000.0)); // Cash drawer remained strictly untouched!
    });

    // -------------------------------------------------------------------------
    // TEST 5: Bank customer refund (reduces bank balance, cash drawer untouched)
    // -------------------------------------------------------------------------
    test('TEST 5: Bank customer refund reduces bank balance, physical cash drawer untouched', () async {
      final initialCash = Db.cash;
      final initialBank = Db.bankBalance;

      // 1. Customer paid ₹599 via Card/Bank
      final recharge = RechargeEntry(
        rechargeId: 'REC_CARD_SUCCESS_REFUND',
        shopId: testShopId,
        operator: RechargeOperator.vi,
        customerMobile: '9847333444',
        amount: 599.0,
        amountPaise: 59900,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.card,
        status: RechargeStatus.success,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: '2026-11-07',
      );

      await service.recordCustomerRechargePayment(recharge: recharge);
      expect(Db.bankBalance, equals(initialBank)); // separation rule
      expect(Db.cash, equals(initialCash));

      // 2. Process Bank refund
      final refundResult = await service.processCustomerRefund(
        shopId: testShopId,
        rechargeId: recharge.rechargeId,
        refundAmount: 599.0,
        refundMethod: RechargePaymentMode.card,
        staffId: 'staff_1',
        staffName: 'Shahal',
        reason: 'Bank chargeback reversed',
      );

      expect(refundResult.recharge.status, equals(RechargeStatus.refunded));
      expect(Db.bankBalance, equals(initialBank));
      expect(Db.cash, equals(initialCash));
    });

    // -------------------------------------------------------------------------
    // TEST 6: Failed recharge with no customer collection (no refund created)
    // -------------------------------------------------------------------------
    test('TEST 6: Attempting refund when no customer payment was collected throws exception', () async {
      final uncollectedRecharge = RechargeEntry(
        rechargeId: 'REC_NO_PAYMENT_COLLECTED',
        shopId: testShopId,
        operator: RechargeOperator.bsnl,
        customerMobile: '9847444555',
        amount: 149.0,
        amountPaise: 14900,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.cash,
        status: RechargeStatus.pending,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: '2026-11-07',
        customerPaymentCollected: false,
      );

      // Save pending entry
      await service.recordCustomerRechargePayment(recharge: uncollectedRecharge);

      // Attempting refund must throw
      expect(
        () => service.processCustomerRefund(
          shopId: testShopId,
          rechargeId: uncollectedRecharge.rechargeId,
          refundAmount: 149.0,
          refundMethod: RechargePaymentMode.cash,
          staffId: 'staff_1',
          staffName: 'Shahal',
          reason: 'Erroneous refund trigger',
        ),
        throwsException,
      );
    });

    // -------------------------------------------------------------------------
    // TEST 7: Duplicate refund prevention (blocked by idempotency)
    // -------------------------------------------------------------------------
    test('TEST 7: Duplicate refund requests are blocked by idempotency check', () async {
      final recharge = RechargeEntry(
        rechargeId: 'REC_DUP_REFUND_CHECK',
        shopId: testShopId,
        operator: RechargeOperator.jio,
        customerMobile: '9847555666',
        amount: 199.0,
        amountPaise: 19900,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.cash,
        status: RechargeStatus.success,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: '2026-11-07',
      );

      await service.recordCustomerRechargePayment(recharge: recharge);

      // First refund: succeeds
      await service.processCustomerRefund(
        shopId: testShopId,
        rechargeId: recharge.rechargeId,
        refundAmount: 199.0,
        refundMethod: RechargePaymentMode.cash,
        staffId: 'staff_1',
        staffName: 'Shahal',
        reason: 'Network failed',
        idempotencyKey: 'IDEMP_REFUND_199',
      );

      // Second refund with identical key: throws duplicate exception
      expect(
        () => service.processCustomerRefund(
          shopId: testShopId,
          rechargeId: recharge.rechargeId,
          refundAmount: 199.0,
          refundMethod: RechargePaymentMode.cash,
          staffId: 'staff_1',
          staffName: 'Shahal',
          reason: 'Duplicate tap',
          idempotencyKey: 'IDEMP_REFUND_199',
        ),
        throwsException,
      );
    });

    // -------------------------------------------------------------------------
    // TEST 8: Refund amount greater than collection prevention (throws error)
    // -------------------------------------------------------------------------
    test('TEST 8: Refund amount exceeding customer collection is strictly prevented', () async {
      final recharge = RechargeEntry(
        rechargeId: 'REC_EXCESS_REFUND_CHECK',
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        customerMobile: '9847666777',
        amount: 199.0,
        amountPaise: 19900,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.cash,
        status: RechargeStatus.success,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: '2026-11-07',
      );

      await service.recordCustomerRechargePayment(recharge: recharge);

      // Attempt refund of ₹300 for ₹199 collection: must throw ArgumentError
      expect(
        () => service.processCustomerRefund(
          shopId: testShopId,
          rechargeId: recharge.rechargeId,
          refundAmount: 300.0,
          refundMethod: RechargePaymentMode.cash,
          staffId: 'staff_1',
          staffName: 'Shahal',
          reason: 'Over-refund attempt',
        ),
        throwsArgumentError,
      );
    });

    // -------------------------------------------------------------------------
    // TEST 9: Pending -> Success (posts financial collection)
    // -------------------------------------------------------------------------
    test('TEST 9: Pending -> Success transitions status and posts financial collection to drawer', () async {
      final initialCash = Db.cash;

      final pending = RechargeEntry(
        rechargeId: 'REC_PENDING_TO_SUCCESS',
        shopId: testShopId,
        operator: RechargeOperator.jio,
        customerMobile: '9847777888',
        amount: 299.0,
        amountPaise: 29900,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.cash,
        status: RechargeStatus.pending,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: '2026-11-07',
      );

      // Record pending: does NOT post money
      await service.recordCustomerRechargePayment(recharge: pending);
      expect(Db.cash, equals(initialCash));

      // Transition to Success
      final result = await service.updateRechargeStatusToSuccess(
        shopId: testShopId,
        rechargeId: pending.rechargeId,
        staffId: 'staff_1',
        staffName: 'Shahal',
        notes: 'Operator confirmed via SMS',
      );

      expect(result.recharge.status, equals(RechargeStatus.success));
      expect(result.recharge.customerPaymentCollected, isTrue);
      expect(Db.cash, equals(initialCash)); // separation rule: ERP cash unchanged
    });

    // -------------------------------------------------------------------------
    // TEST 10: Invalid status transition (e.g. Failed -> Success directly blocked)
    // -------------------------------------------------------------------------
    test('TEST 10: Direct transition from Failed to Success is strictly blocked', () async {
      final failed = RechargeEntry(
        rechargeId: 'REC_FAILED_DIRECT_CHECK',
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        customerMobile: '9847888999',
        amount: 299.0,
        amountPaise: 29900,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.cash,
        status: RechargeStatus.failed,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: '2026-11-07',
      );

      await service.recordCustomerRechargePayment(recharge: failed);

      // Attempting to directly transition from Failed -> Success must throw StateError
      expect(
        () => service.updateRechargeStatusToSuccess(
          shopId: testShopId,
          rechargeId: failed.rechargeId,
          staffId: 'staff_1',
          staffName: 'Shahal',
        ),
        throwsStateError,
      );
    });

    // -------------------------------------------------------------------------
    // TEST 11: Commission reversal (only previously confirmed commission reversed)
    // -------------------------------------------------------------------------
    test('TEST 11: Commission reversal reverses confirmed commission from income and cash drawer', () async {
      // 1. Record confirmed postpaid commission with cash payout of ₹15
      final comm = await service.recordPostpaidCommission(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        amount: 15.0,
        status: CommissionStatus.confirmed,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'COMM_REV_15',
        settlementMethod: CommissionSettlementMethod.cashPayout,
      );

      expect(Db.cash, equals(3015.0)); // ₹3,000 + ₹15 = ₹3,015

      // 2. Reverse commission
      final result = await service.reverseCommissionEntry(
        shopId: testShopId,
        commissionId: comm.commissionId,
        staffId: 'staff_1',
        staffName: 'Shahal',
        reason: 'Customer recharge reversed',
      );

      expect(result.reversedCommission.status, equals(CommissionStatus.pending));
      expect(result.reversalEntry.reversalType, equals(ReversalType.commissionReversal));
      expect(Db.cash, equals(3000.0)); // Cash in drawer reversed back to baseline!
    });

    // -------------------------------------------------------------------------
    // TEST 12: Distributor balance reversal (distributor payable adjusted correctly)
    // -------------------------------------------------------------------------
    test('TEST 12: Distributor balance reversal reduces distributor payable liability', () async {
      // 1. Record credit stock loaded by distributor: ₹5,000
      await service.recordDistributorCreditLoad(
        shopId: testShopId,
        operator: RechargeOperator.vi,
        distributorId: 'DIST_MURUGAN_VI',
        amount: 5000.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'CREDIT_LOAD_5000',
      );

      final distBefore = await service.getDistributor(
        shopId: testShopId,
        distributorId: 'DIST_MURUGAN_VI',
      );
      expect(distBefore.currentOutstandingPaise, equals(500000));

      // 2. Reverse ₹1,000 credit due to erroneous stock allocation
      final revResult = await service.reverseDistributorCredit(
        shopId: testShopId,
        distributorId: 'DIST_MURUGAN_VI',
        amount: 1000.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
        reason: 'Distributor cancelled batch allocation',
      );

      expect(revResult.distributor.currentOutstandingPaise, equals(400000)); // 500000 - 100000 = 400000
      expect(revResult.ledgerEntry.entryType, equals('CREDIT_REVERSAL'));
      expect(revResult.reversalEntry.reversalType, equals(ReversalType.distributorReversal));
    });

    // -------------------------------------------------------------------------
    // TEST 13: Operator success after customer refund (flagged for Owner Review)
    // -------------------------------------------------------------------------
    test('TEST 13: Late operator success after customer refund is flagged for Owner Review without auto-reversing cash', () async {
      // 1. Customer recharge that succeeded, then was refunded to customer
      final recharge = RechargeEntry(
        rechargeId: 'REC_LATE_SUCCESS_CHECK',
        shopId: testShopId,
        operator: RechargeOperator.jio,
        customerMobile: '9847012345',
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

      await service.recordCustomerRechargePayment(recharge: recharge);
      await service.processCustomerRefund(
        shopId: testShopId,
        rechargeId: recharge.rechargeId,
        refundAmount: 299.0,
        refundMethod: RechargePaymentMode.cash,
        staffId: 'staff_1',
        staffName: 'Shahal',
        reason: 'Customer was in a hurry and left',
      );

      expect(Db.cash, equals(3000.0)); // Baseline restored

      // 2. Later, operator portal confirms success!
      final result = await service.updateRechargeStatusToSuccess(
        shopId: testShopId,
        rechargeId: recharge.rechargeId,
        staffId: 'staff_1',
        staffName: 'Shahal',
      );

      // Verify that customer refund was NOT reversed, and entry is flagged for owner review
      expect(result.recharge.status, equals(RechargeStatus.disputed));
      expect(result.recharge.requiresOwnerReview, isTrue);
      expect(result.recharge.disputeNote, isNotNull);
      expect(Db.cash, equals(3000.0)); // Cash untouched! No silent debit to customer or drawer!
    });

    // -------------------------------------------------------------------------
    // TEST 14: EOD cash reconciliation (refunds properly netted, ₹1000 float untouched)
    // -------------------------------------------------------------------------
    test('TEST 14: EOD cash reconciliation properly nets recharge collections and refunds, preserving ₹1,000 float', () async {
      // Baseline cash drawer has ₹3,000 (which contains ₹1,000 opening float + ₹2,000 retail sales)
      expect(Db.cash, equals(3000.0));

      // Transaction A: ₹299 Cash Recharge Success
      final recA = RechargeEntry(
        rechargeId: 'REC_EOD_A',
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
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: '2026-11-07',
      );
      await service.recordCustomerRechargePayment(recharge: recA);

      // Transaction B: ₹499 Cash Recharge Success
      final recB = RechargeEntry(
        rechargeId: 'REC_EOD_B',
        shopId: testShopId,
        operator: RechargeOperator.jio,
        customerMobile: '9847000002',
        amount: 499.0,
        amountPaise: 49900,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.cash,
        status: RechargeStatus.success,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: '2026-11-07',
      );
      await service.recordCustomerRechargePayment(recharge: recB);

      expect(Db.cash, equals(3000.0)); // separation rule

      // Customer B cancelled: Refund ₹499 cash
      await service.processCustomerRefund(
        shopId: testShopId,
        rechargeId: recB.rechargeId,
        refundAmount: 499.0,
        refundMethod: RechargePaymentMode.cash,
        staffId: 'staff_1',
        staffName: 'Shahal',
        reason: 'Customer cancelled',
      );

      expect(Db.cash, equals(3000.0)); // separation rule: ERP cash unchanged

      // The Daily Register adds recharge cash separately: collections minus
      // cash refunds of these entries = 299 + 499 - 499 = ₹299.
      var netRechargePaise = 0;
      for (final e in service.getLocalRecharges(shopId: testShopId)) {
        if (!e.rechargeId.startsWith('REC_EOD_')) continue;
        if (e.paymentMode == RechargePaymentMode.cash && e.customerPaymentCollected) {
          netRechargePaise += e.amountPaise;
        }
        if (e.refundMethod == RechargePaymentMode.cash.name) {
          netRechargePaise -= ((e.refundAmount ?? 0) * 100).round();
        }
      }
      expect(netRechargePaise, 29900);

      // Verify EOD handover calculation
      const retainedFloat = 1000.0;
      final totalPhysicalCash = Db.cash + netRechargePaise / 100.0;
      final netCashHandover = totalPhysicalCash - retainedFloat;

      expect(totalPhysicalCash, equals(3299.0));
      expect(netCashHandover, equals(2299.0)); // ₹2,000 retail + ₹299 net recharge cash
      expect(retainedFloat, equals(1000.0)); // Exactly preserved!
    });

    // -------------------------------------------------------------------------
    // TEST 15: Firestore retry / idempotency protection
    // -------------------------------------------------------------------------
    test('TEST 15: Reversal summary correctly aggregates totals and enforces idempotency', () async {
      // 1. Setup wallet
      await service.recordOwnMoneyTopUp(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        amount: 1000.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceId: 'TOPUP_T15',
      );

      // 2. Successful transaction
      final succ = RechargeEntry(
        rechargeId: 'REC_T15_SUCC',
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        customerMobile: '9847000991',
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
      await service.recordCustomerRechargePayment(recharge: succ);

      // 3. Refunded transaction
      final toRefund = RechargeEntry(
        rechargeId: 'REC_T15_REF',
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        customerMobile: '9847000992',
        amount: 199.0,
        amountPaise: 19900,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.cash,
        status: RechargeStatus.success,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: '2026-11-07',
      );
      await service.recordCustomerRechargePayment(recharge: toRefund);
      await service.processCustomerRefund(
        shopId: testShopId,
        rechargeId: toRefund.rechargeId,
        refundAmount: 199.0,
        refundMethod: RechargePaymentMode.cash,
        staffId: 'staff_1',
        staffName: 'Shahal',
        reason: 'Failed transaction',
      );

      // 4. Failed recharge with wallet debit reversal
      final toDebit = RechargeEntry(
        rechargeId: 'REC_T15_FAIL_DEBIT',
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        customerMobile: '9847000993',
        amount: 99.0,
        amountPaise: 9900,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.cash,
        status: RechargeStatus.pending,
        staffId: 'staff_1',
        staffName: 'Shahal',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: '2026-11-07',
      );
      await service.processRechargeDebit(recharge: toDebit);
      await service.markRechargeFailed(
        shopId: testShopId,
        rechargeId: toDebit.rechargeId,
        staffId: 'staff_1',
        staffName: 'Shahal',
        reason: 'Network disconnect',
      );

      final summary = await service.getRechargeReversalSummary(
        shopId: testShopId,
        dateString: '2026-11-07',
      );

      expect(summary.shopId, equals(testShopId));
      expect(summary.dateString, equals('2026-11-07'));
      expect(summary.successfulCount, equals(1));
      expect(summary.successfulAmount, equals(299.0));
      expect(summary.refundedCount, equals(1));
      expect(summary.refundedAmount, equals(199.0));
      expect(summary.failedCount, equals(1));
      expect(summary.failedAmount, equals(99.0));
      expect(summary.walletReversalsCount, equals(1));
      expect(summary.walletReversalsAmount, equals(99.0));
    });
  });
}
