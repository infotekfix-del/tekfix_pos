import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/recharge/recharge_models.dart';
import 'package:tekfix_erp_pos/recharge/recharge_backend_bridge.dart';
import 'package:tekfix_erp_pos/recharge/recharge_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = RechargeService.instance;
  const testShopId = 'SHOP_PHASE11_TEST';
  late Directory tempDir;

  setUpAll(() async {
    // v2.1: the old client-side postings run only in localTestMock.
    RechargeBackendBridge.configure(mode: RechargeBackendMode.localTestMock);
    tempDir = await Directory.systemTemp.createTemp('tekfix_phase11_test_');
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
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  setUp(() async {
    service.resetLocalCacheForTesting();
    service.disableOpeningBalanceGateForTesting();
    for (final b in allBoxes) {
      if (Hive.isBoxOpen(b)) {
        await Hive.box(b).clear();
      }
    }
  });

  group('TEKFIX ERP - Phase 11: Critical Financial Hardening Tests', () {
    // -------------------------------------------------------------------------
    // 1. COMMISSION WALLET REVERSAL & DUPLICATE PROTECTION
    // -------------------------------------------------------------------------
    test('TEST 1: Prepaid wallet-credit commission reversal automatically debits operator wallet and creates immutable ledger entry', () async {
      // Setup: Operator Top-up with Own Money (₹1,000 paid to bank, ₹1,030 credited to wallet including ₹30 commission)
      final topUpResult = await service.recordPrepaidTopUpCommission(
        shopId: testShopId,
        operator: RechargeOperator.jio,
        bankDebitAmount: 1000.0,
        walletCreditAmount: 1030.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'TOPUP_COMM_01',
      );

      final initialWallet = topUpResult.wallet;
      final commEntry = topUpResult.commission;

      expect(initialWallet.ownPrepaidBalance, equals(1030.0));
      expect(commEntry.amount, equals(30.0));
      expect(commEntry.settlementMethod, equals(CommissionSettlementMethod.walletCredit));

      // Initial physical cash is untouched
      final initialCash = Db.cash;

      // Execute Commission Reversal
      final reversalResult = await service.reverseCommissionEntry(
        shopId: testShopId,
        commissionId: commEntry.commissionId,
        staffId: 'staff_admin',
        staffName: 'Admin',
        reason: 'Prepaid topup commission margin clawback by operator',
      );

      // Verify commission status
      expect(reversalResult.reversedCommission.status, equals(CommissionStatus.pending));
      expect(reversalResult.reversedCommission.notes, contains('[REVERSED:'));

      // Verify wallet was debited by exactly ₹30 (₹1,030 - ₹30 = ₹1,000)
      final updatedWallet = await service.getWallet(
        shopId: testShopId,
        operator: RechargeOperator.jio,
      );
      expect(updatedWallet.ownPrepaidBalance, equals(1000.0));
      expect(updatedWallet.ownPrepaidBalancePaise, equals(100000));

      // Verify immutable wallet ledger entry was created
      final walletHistory = service.getLocalWalletLedger(
        walletId: updatedWallet.walletId,
      );
      final reversalLog = walletHistory.firstWhere((e) => e.entryType == 'COMMISSION_WALLET_REVERSAL');
      expect(reversalLog.amount, equals(30.0));
      expect(reversalLog.balanceBeforePaise, equals(103000));
      expect(reversalLog.balanceAfterPaise, equals(100000));
      expect(reversalLog.referenceId, equals(commEntry.commissionId));

      // Verify physical cash drawer was NOT reduced
      expect(Db.cash, equals(initialCash));
    });

    test('TEST 2: Duplicate commission reversal is strictly blocked and throws exception', () async {
      // 1. Setup prepaid commission
      final topUpResult = await service.recordPrepaidTopUpCommission(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        bankDebitAmount: 500.0,
        walletCreditAmount: 515.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'TOPUP_DUP_COMM',
      );

      final commEntry = topUpResult.commission;

      // 2. First reversal succeeds
      await service.reverseCommissionEntry(
        shopId: testShopId,
        commissionId: commEntry.commissionId,
        staffId: 'staff_admin',
        staffName: 'Admin',
        reason: 'First clawback',
      );

      // 3. Second reversal attempt must fail with exception
      expect(
        () => service.reverseCommissionEntry(
          shopId: testShopId,
          commissionId: commEntry.commissionId,
          staffId: 'staff_admin',
          staffName: 'Admin',
          reason: 'Duplicate clawback attempt',
        ),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('Commission already reversed'),
        )),
      );

      // 4. Verify wallet balance debited only once
      final wallet = await service.getWallet(
        shopId: testShopId,
        operator: RechargeOperator.airtel,
      );
      expect(wallet.ownPrepaidBalance, equals(500.0));
    });

    test('TEST 3: Cash payout commission reversal reduces cash drawer and does NOT debit wallet', () async {
      // Setup initial cash drawer
      await Db.moveMoney('Cash', 1000.0, 'Baseline opening cash');

      // Record Postpaid Cash Commission
      final comm = await service.recordPostpaidCommission(
        shopId: testShopId,
        operator: RechargeOperator.vi,
        amount: 25.0,
        status: CommissionStatus.confirmed,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceNumber: 'COMM_CASH_01',
        settlementMethod: CommissionSettlementMethod.cashPayout,
      );

      expect(Db.cash, equals(1025.0));

      // Reverse cash commission
      final rev = await service.reverseCommissionEntry(
        shopId: testShopId,
        commissionId: comm.commissionId,
        staffId: 'staff_1',
        staffName: 'Shahal',
        reason: 'Postpaid commission clawback',
      );

      expect(rev.reversedCommission.status, equals(CommissionStatus.pending));
      // Cash reversed back to 1000
      expect(Db.cash, equals(1000.0));

      // Wallet remains 0 (untouched)
      final wallet = await service.getWallet(
        shopId: testShopId,
        operator: RechargeOperator.vi,
      );
      expect(wallet.ownPrepaidBalance, equals(0.0));
    });

    // -------------------------------------------------------------------------
    // 2. CONCURRENCY & LIVE BALANCE VALIDATION
    // -------------------------------------------------------------------------
    test('TEST 4: Two-device concurrent debit simulation against ₹1,000 wallet rejects insufficient balance', () async {
      // 1. Initialize wallet with ₹1,000
      await service.recordOwnMoneyTopUp(
        shopId: testShopId,
        operator: RechargeOperator.bsnl,
        amount: 1000.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceId: 'TOPUP_CONCURRENCY',
      );

      final rec1 = RechargeEntry(
        rechargeId: 'REC_CONCUR_A',
        shopId: testShopId,
        operator: RechargeOperator.bsnl,
        customerMobile: '9847011111',
        amount: 600.0,
        amountPaise: 60000,
        paymentMode: RechargePaymentMode.cash,
        fundingType: RechargeFundingType.ownMoney,
        staffId: 'staff_dev_A',
        staffName: 'Device A Staff',
        status: RechargeStatus.pending,
        dateString: '2026-11-07',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final rec2 = RechargeEntry(
        rechargeId: 'REC_CONCUR_B',
        shopId: testShopId,
        operator: RechargeOperator.bsnl,
        customerMobile: '9847022222',
        amount: 600.0,
        amountPaise: 60000,
        paymentMode: RechargePaymentMode.cash,
        fundingType: RechargeFundingType.ownMoney,
        staffId: 'staff_dev_B',
        staffName: 'Device B Staff',
        status: RechargeStatus.pending,
        dateString: '2026-11-07',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      dynamic res1;
      dynamic res2;
      dynamic err1;
      dynamic err2;

      await Future.wait([
        () async {
          try {
            res1 = await service.processRechargeDebit(recharge: rec1);
          } catch (e) {
            err1 = e;
          }
        }(),
        () async {
          try {
            res2 = await service.processRechargeDebit(recharge: rec2);
          } catch (e) {
            err2 = e;
          }
        }(),
      ]);

      // Exactly one succeeds, one fails
      final successfulCount = [res1, res2].where((r) => r != null).length;
      final errorCaught = err1 ?? err2;

      expect(successfulCount, equals(1));
      expect(errorCaught, isNotNull);
      expect(errorCaught.toString(), contains('വാലറ്റിൽ ആവശ്യത്തിന് തുകയില്ല'));

      // Final wallet balance must be exactly ₹400 (₹1,000 - ₹600 = ₹400), NEVER negative
      final wallet = await service.getWallet(shopId: testShopId, operator: RechargeOperator.bsnl);
      expect(wallet.ownPrepaidBalance, equals(400.0));
      expect(wallet.ownPrepaidBalancePaise, equals(40000));
    });

    // -------------------------------------------------------------------------
    // 3. OFFLINE HIVE PERSISTENCE & REHYDRATION
    // -------------------------------------------------------------------------
    test('TEST 5: Offline persistence durable storage and rehydrateFromHive on restart', () async {
      // 1. Fund wallet
      await service.recordOwnMoneyTopUp(
        shopId: testShopId,
        operator: RechargeOperator.jio,
        amount: 500.0,
        staffId: 'staff_1',
        staffName: 'Shahal',
        referenceId: 'TOPUP_HIVE_01',
      );

      // 2. Perform recharge debit
      final entry = RechargeEntry(
        rechargeId: 'REC_PERSIST_01',
        shopId: testShopId,
        operator: RechargeOperator.jio,
        customerMobile: '9847055555',
        amount: 299.0,
        amountPaise: 29900,
        paymentMode: RechargePaymentMode.upi,
        fundingType: RechargeFundingType.ownMoney,
        staffId: 'staff_1',
        staffName: 'Shahal',
        status: RechargeStatus.success,
        customerPaymentCollected: true,
        dateString: '2026-11-07',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final debitResult = await service.processRechargeDebit(recharge: entry);
      expect(debitResult.recharge.walletDebited, isTrue);

      // Verify entry is durably saved in Hive Box
      final box = Hive.box(boxRecharges);
      expect(box.containsKey('REC_PERSIST_01'), isTrue);
      final rawMap = box.get('REC_PERSIST_01') as Map;
      expect(rawMap['rechargeId'], equals('REC_PERSIST_01'));
      expect(rawMap['amount'], equals(299.0));

      // 3. Simulate App Restart: Clear in-memory caches
      service.resetLocalCacheForTesting();
      expect(await service.getRecharge(shopId: testShopId, rechargeId: 'REC_PERSIST_01'), isNull);

      // 4. Rehydrate from Hive
      final rehydratedCount = await service.rehydrateFromHive();
      expect(rehydratedCount, greaterThanOrEqualTo(1));

      // 5. Verify restored in-memory state
      final restored = await service.getRecharge(shopId: testShopId, rechargeId: 'REC_PERSIST_01');
      expect(restored, isNotNull);
      expect(restored!.customerMobile, equals('9847055555'));
      expect(restored.amount, equals(299.0));
      expect(restored.walletDebited, isTrue);
    });

    // -------------------------------------------------------------------------
    // 4. DURABLE RETRY QUEUE & FLUSHING
    // -------------------------------------------------------------------------
    test('TEST 6: Durable retry queue buffers offline items and flushOfflineQueue clears queue', () async {
      final queueBox = Hive.box(boxRechargeQueue);
      expect(queueBox.isEmpty, isTrue);

      final offlineRecharge = RechargeEntry(
        rechargeId: 'REC_OFFLINE_QUEUE_01',
        shopId: testShopId,
        operator: RechargeOperator.airtel,
        customerMobile: '9847099999',
        amount: 199.0,
        amountPaise: 19900,
        paymentMode: RechargePaymentMode.cash,
        fundingType: RechargeFundingType.ownMoney,
        staffId: 'staff_1',
        staffName: 'Shahal',
        status: RechargeStatus.success,
        isOfflinePending: true,
        dateString: '2026-11-07',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      // Queue offline item directly into retry queue
      await queueBox.put(
        'Q_REC_OFFLINE_QUEUE_01',
        {
          'queueId': 'Q_REC_OFFLINE_QUEUE_01',
          'opType': 'RECHARGE_DEBIT',
          'payload': offlineRecharge.toMap(forFirestore: false),
          'queuedAt': DateTime.now().toIso8601String(),
          'status': 'pending',
        },
      );

      // Persist to local recharge cache as offline pending
      await Hive.box(boxRecharges).put(offlineRecharge.rechargeId, offlineRecharge.toMap(forFirestore: false));
      await service.rehydrateFromHive();

      final pendingRec = await service.getRecharge(shopId: testShopId, rechargeId: 'REC_OFFLINE_QUEUE_01');
      expect(pendingRec!.isOfflinePending, isTrue);
      expect(queueBox.length, equals(1));

      // Flush retry queue
      final flushedCount = await service.flushOfflineQueue();
      expect(flushedCount, equals(1));
      expect(queueBox.isEmpty, isTrue);

      // Verify offline pending flag is now resolved to false
      final updatedRec = await service.getRecharge(shopId: testShopId, rechargeId: 'REC_OFFLINE_QUEUE_01');
      expect(updatedRec!.isOfflinePending, isFalse);
    });

    // -------------------------------------------------------------------------
    // 5. FIRESTORE SECURITY RULES INTEGRITY VERIFICATION
    // -------------------------------------------------------------------------
    test('TEST 7: Firestore security rules file contains explicit ledger immutability and catch-all exclusion', () {
      final rulesFile = File('lib/firestore.rules');
      expect(rulesFile.existsSync(), isTrue);
      final rulesContent = rulesFile.readAsStringSync();

      // Verify all 10 recharge subcollection sections exist
      expect(rulesContent, contains('match /recharge_wallets/{walletId}'));
      expect(rulesContent, contains('match /recharge_wallet_logs/{logId}'));
      expect(rulesContent, contains('match /recharge_transactions/{txnId}'));
      expect(rulesContent, contains('match /recharge_distributors/{distId}'));
      expect(rulesContent, contains('match /recharge_distributor_ledger/{id}'));
      expect(rulesContent, contains('match /recharge_reversals/{id}'));
      expect(rulesContent, contains('match /recharge_refunds/{id}'));
      expect(rulesContent, contains('match /recharge_commissions/{id}'));
      expect(rulesContent, contains('match /recharge_float_deposits/{id}'));
      expect(rulesContent, contains('match /recharge_daily_collections/{id}'));

      // Verify immutable ledgers reject updates and deletes
      expect(rulesContent, contains('allow update, delete: if false; // Strict financial ledger immutability'));

      // Verify catch-all excludes recharge ledger logs from arbitrary modifications
      expect(rulesContent, contains("!(request.path[5] in ["));
      expect(rulesContent, contains("'recharge_wallets'"));
      expect(rulesContent, contains("'recharge_wallet_logs'"));
      expect(rulesContent, contains("'recharge_distributor_ledger'"));
      expect(rulesContent, contains("'recharge_reversals'"));
      expect(rulesContent, contains("'recharge_refunds'"));
      expect(rulesContent, contains("'recharge_float_deposits'"));
    });

    test('TEST 8: Recharge service rejects uninitialized/zero balance wallet debit without partial writes', () async {
      final uninitRecharge = RechargeEntry(
        rechargeId: 'REC_UNINIT_TEST_01',
        shopId: testShopId,
        customerMobile: '9876543210',
        operator: RechargeOperator.bsnl,
        amount: 150.0,
        amountPaise: 15000,
        paymentMode: RechargePaymentMode.cash,
        fundingType: RechargeFundingType.ownMoney,
        staffId: 'staff_1',
        staffName: 'Staff Member',
        status: RechargeStatus.pending,
        dateString: '2026-11-07',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      // Attempting debit against uninitialized / 0-balance wallet must throw exception
      expect(
        () async => await service.processRechargeDebit(recharge: uninitRecharge),
        throwsA(isA<Exception>()),
      );

      // Ensure no transaction record was persisted
      final persistedRec = await service.getRecharge(shopId: testShopId, rechargeId: 'REC_UNINIT_TEST_01');
      expect(persistedRec, isNull);

      // Ensure no wallet ledger entries were created
      final walletId = RechargeService.getWalletId(RechargeOperator.bsnl);
      final logs = service.getLocalWalletLedger(walletId: walletId);
      expect(logs.where((l) => l.referenceId == 'REC_UNINIT_TEST_01'), isEmpty);
    });
  });
}
