import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/recharge/recharge_backend_bridge.dart';
import 'package:tekfix_erp_pos/recharge/recharge_models.dart';
import 'package:tekfix_erp_pos/recharge/recharge_recovery_engine.dart';
import 'package:tekfix_erp_pos/recharge/recharge_service.dart';
import 'package:tekfix_erp_pos/recharge/supabase_recharge_bridge_client.dart';
import 'package:tekfix_erp_pos/security/device_security_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TEKFIX ERP - PHASE 16.4.13: TOP-UP OUTBOX & RECOVERY TEST SUITE', () {
    late Directory tempDir;
    const testShopId = 'shop_staging_001';
    const testOwnerUid = 'owner_staging_001';
    const testDeviceId = 'DEV_STAGING_MOB_001';
    const testToken = 'valid_staging_owner_jwt';
    const testNonce = 'NONCE_OUTBOX_STAGE_456';

    late MockClient mockHttpClient;
    late SupabaseRechargeBridgeClient bridgeClient;
    final service = RechargeService.instance;

    // Simulated PostgreSQL staging state
    final Map<String, Map<String, dynamic>> stageWallets = {
      'WALLET_VI': {
        'shop_id': testShopId,
        'wallet_id': 'WALLET_VI',
        'operator': 'Vi',
        'own_prepaid_balance_paise': 20000, // ₹200.00 baseline
        'distributor_credit_balance_paise': 0,
        'total_balance_paise': 20000,
      }
    };

    final Map<String, Map<String, dynamic>> stageFloatDeposits = {};
    final Map<String, String> stageUtrMap = {};
    final List<Map<String, dynamic>> stageWalletLogs = [];

    setUpAll(() async {
      GoogleFonts.config.allowRuntimeFetching = false;
      tempDir = await Directory.systemTemp.createTemp('topup_16_4_13_');
      Hive.init(tempDir.path);

      for (final b in allBoxes) {
        await Hive.openBox(b);
      }

      final settingsBox = Hive.box(boxSettings);
      await settingsBox.put('shop_id', testShopId);
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

      // Reset mock state
      stageWallets['WALLET_VI'] = {
        'shop_id': testShopId,
        'wallet_id': 'WALLET_VI',
        'operator': 'Vi',
        'own_prepaid_balance_paise': 20000, // ₹200.00 baseline
        'distributor_credit_balance_paise': 0,
        'total_balance_paise': 20000,
      };
      stageFloatDeposits.clear();
      stageUtrMap.clear();
      stageWalletLogs.clear();

      await Db.bank.clear();
      await Db.rechargeQueue.clear();
      await Db.rechargeDeadLetter.clear();
      await Db.sales.clear();
      await Db.expenses.clear();

      // Set initial Bank Balance to ₹5,000.00
      await Db.bank.put('bank_balance', 5000.0);
      await Db.bank.put('cash_in_hand', 1000.0);
      await Db.bank.put('txn_log', []);

      mockHttpClient = MockClient((request) async {
        final path = request.url.path;
        final body = jsonDecode(request.body) as Map<String, dynamic>;

        if (path.endsWith('/request-challenge')) {
          return http.Response(jsonEncode({'nonce': testNonce, 'expiresAt': '2026-11-16T19:00:00Z'}), 200);
        }

        if (path.endsWith('/get-wallet')) {
          final wId = body['walletId'];
          return http.Response(jsonEncode({'success': true, 'wallet': stageWallets[wId]}), 200);
        }

        if (path.endsWith('/process-topup')) {
          final sId = body['shopId'];
          final wId = body['walletId'] as String?;
          final amtPaise = body['amountPaise'] as int?;
          final ref = body['referenceId'] as String? ?? '';
          final normRef = ref.trim().toUpperCase();

          if (sId != testShopId || wId == null || amtPaise == null || amtPaise <= 0) {
            return http.Response(jsonEncode({'error': 'Invalid topup parameters'}), 400);
          }

          // Check Idempotency
          if (stageUtrMap.containsKey(normRef)) {
            final existingDepId = stageUtrMap[normRef]!;
            final existing = stageFloatDeposits[existingDepId]!;

            if (existing['amount_paise'] != amtPaise) {
              return http.Response(jsonEncode({
                'error': 'Idempotency conflict: Reference $ref already registered with different amount'
              }), 400);
            }

            final wallet = stageWallets[wId]!;
            return http.Response(jsonEncode({
              'success': true,
              'idempotent_replay': true,
              'wallet_id': wId,
              'amount_paise': amtPaise,
              'total_balance_paise': wallet['total_balance_paise'],
              'own_prepaid_balance_paise': wallet['own_prepaid_balance_paise'],
              'distributor_credit_balance_paise': 0,
              'reference_id': existingDepId,
              'message': 'Idempotent replay: original topup confirmed without duplicate balance credit'
            }), 200);
          }

          // Fresh deposit
          final depId = ref.isNotEmpty ? ref : 'DEP_${DateTime.now().millisecondsSinceEpoch}';
          stageFloatDeposits[depId] = {
            'deposit_id': depId,
            'wallet_id': wId,
            'amount_paise': amtPaise,
            'source': body['source'] ?? 'bank',
            'reference_no': ref,
          };
          if (normRef.isNotEmpty) {
            stageUtrMap[normRef] = depId;
          }

          final curWallet = stageWallets[wId]!;
          final beforePaise = curWallet['total_balance_paise'] as int;
          final newOwnPaise = (curWallet['own_prepaid_balance_paise'] as int) + amtPaise;
          final afterPaise = newOwnPaise + (curWallet['distributor_credit_balance_paise'] as int);

          curWallet['own_prepaid_balance_paise'] = newOwnPaise;
          curWallet['total_balance_paise'] = afterPaise;

          stageWalletLogs.add({
            'log_id': 'LOG_$depId',
            'wallet_id': wId,
            'amount_paise': amtPaise,
            'balance_before_paise': beforePaise,
            'balance_after_paise': afterPaise,
          });

          return http.Response(jsonEncode({
            'success': true,
            'idempotent_replay': false,
            'wallet_id': wId,
            'amount_paise': amtPaise,
            'balance_before_paise': beforePaise,
            'balance_after_paise': afterPaise,
            'total_balance_paise': afterPaise,
            'own_prepaid_balance_paise': newOwnPaise,
            'distributor_credit_balance_paise': 0,
            'reference_id': depId,
          }), 200);
        }

        return http.Response(jsonEncode({'error': 'Not found'}), 404);
      });

      bridgeClient = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: 'https://mwhsvidbrfkryuiwhnev.supabase.co/functions/v1/recharge-bridge',
        getFirebaseIdToken: () async => testToken,
        httpClient: mockHttpClient,
      );

      RechargeBackendBridge.configure(
        mode: RechargeBackendMode.supabaseEdgeFunction,
        supabaseClient: bridgeClient,
      );
    });

    test('1. Pre-flight Check: Insufficient bank balance rejects immediately without server debit', () async {
      await Db.bank.put('bank_balance', 50.0); // Only ₹50 in bank

      expect(
        () => service.recordOwnMoneyTopUp(
          shopId: testShopId,
          operator: RechargeOperator.vi,
          amount: 500.0, // Attempt ₹500
          staffId: testOwnerUid,
          staffName: 'Shop Owner',
          referenceId: 'UTR_INSUFF_001',
          checkBankBalance: true,
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Insufficient bank balance'),
        )),
      );

      // Verify no outbox journal entry remains
      expect(Db.rechargeQueue.length, equals(0));
      // Verify bank balance was untouched
      expect(Db.bankBalance, equals(50.0));
      // Verify remote wallet balance was untouched
      expect(stageWallets['WALLET_VI']!['total_balance_paise'], equals(20000));
    });

    test('2. Happy Path: Successful top-up debits bank and creates zero turnover/expense', () async {
      final initialBank = Db.bankBalance;
      expect(initialBank, equals(5000.0));

      final res = await service.recordOwnMoneyTopUp(
        shopId: testShopId,
        operator: RechargeOperator.vi,
        amount: 1000.0, // ₹1,000.00
        staffId: testOwnerUid,
        staffName: 'Shop Owner',
        referenceId: 'UTR_HAPPY_001',
      );

      expect(res.wallet.ownPrepaidBalancePaise, equals(120000)); // 20000 + 100000 = 120000 paise
      // Verify Bank Balance decreased by exactly ₹1,000.00
      expect(Db.bankBalance, equals(4000.0));
      // Verify outbox queue is cleared upon completion
      expect(Db.rechargeQueue.containsKey('UTR_HAPPY_001'), isFalse);
      // Verify Turnover & Expense Isolation: NEVER sales, NEVER expenses!
      expect(Db.sales.length, equals(0));
      expect(Db.expenses.length, equals(0));
    });

    test('3. Crash Recovery: App crashes after server credit (Status: SERVER_CONFIRMED)', () async {
      const topupKey = 'UTR_CRASH_POST_SERVER';
      const topupAmt = 500.0;
      const topupPaise = 50000;

      // Simulate state where Supabase credited the wallet, but phone died before local bank debit
      stageWallets['WALLET_VI']!['own_prepaid_balance_paise'] = 70000;
      stageWallets['WALLET_VI']!['total_balance_paise'] = 70000;
      stageFloatDeposits[topupKey] = {
        'deposit_id': topupKey,
        'wallet_id': 'WALLET_VI',
        'amount_paise': topupPaise,
        'source': 'bank',
        'reference_no': topupKey,
      };
      stageUtrMap[topupKey] = topupKey;

      // Inject interrupted outbox journal into Hive
      await Db.rechargeQueue.put(topupKey, {
        'idempotencyKey': topupKey,
        'type': 'TOPUP',
        'status': RechargeRecoveryEngine.statusServerConfirmed,
        'shopId': testShopId,
        'ownerUid': testOwnerUid,
        'deviceId': testDeviceId,
        'walletId': 'WALLET_VI',
        'operator': 'Vi',
        'amount': topupAmt,
        'amountPaise': topupPaise,
        'referenceNo': topupKey,
        'source': 'bank',
        'staffId': testOwnerUid,
        'staffName': 'Shop Owner',
        'createdAt': DateTime.now().toIso8601String(),
        'serverDepositId': topupKey,
        'settledBank': false,
        'settledVoucher': false,
      });

      expect(Db.bankBalance, equals(5000.0)); // Bank not debited yet!

      // Run startup recovery
      final recoveredCount = await RechargeRecoveryEngine.reconcilePendingSettlements();
      expect(recoveredCount, equals(1));

      // Verify Bank Balance debited by ₹500.00
      expect(Db.bankBalance, equals(4500.0));
      // Verify queue entry was settled and removed
      expect(Db.rechargeQueue.containsKey(topupKey), isFalse);
      // Verify server wallet balance was NOT double credited (remains 70000 paise)
      expect(stageWallets['WALLET_VI']!['total_balance_paise'], equals(70000));
    });

    test('4. Crash Recovery: App crashes before server credit (Status: INITIATED)', () async {
      const topupKey = 'UTR_CRASH_PRE_SERVER';
      const topupAmt = 800.0;
      const topupPaise = 80000;

      // Inject initiated outbox journal into Hive
      await Db.rechargeQueue.put(topupKey, {
        'idempotencyKey': topupKey,
        'type': 'TOPUP',
        'status': RechargeRecoveryEngine.statusInitiated,
        'shopId': testShopId,
        'ownerUid': testOwnerUid,
        'deviceId': testDeviceId,
        'walletId': 'WALLET_VI',
        'operator': 'Vi',
        'amount': topupAmt,
        'amountPaise': topupPaise,
        'referenceNo': topupKey,
        'source': 'bank',
        'staffId': testOwnerUid,
        'staffName': 'Shop Owner',
        'createdAt': DateTime.now().toIso8601String(),
        'serverDepositId': null,
      });

      // Run startup recovery
      final recoveredCount = await RechargeRecoveryEngine.reconcilePendingSettlements();
      expect(recoveredCount, equals(1));

      // Verify server deposit was executed
      expect(stageFloatDeposits.containsKey(topupKey), isTrue);
      // Verify wallet received 80000 paise
      expect(stageWallets['WALLET_VI']!['total_balance_paise'], equals(100000)); // 20000 + 80000
      // Verify bank balance was debited
      expect(Db.bankBalance, equals(4200.0)); // 5000 - 800
      // Verify queue is clean
      expect(Db.rechargeQueue.containsKey(topupKey), isFalse);
    });

    test('5. Deduplication: hasMoneyMoved prevents double bank debit on retry', () async {
      const topupKey = 'UTR_DEDUP_001';
      const topupAmt = 250.0;

      // Simulate that local bank was ALREADY debited in a prior turn
      await Db.moveMoney('Bank', -topupAmt, 'Topup Vi (Ref: $topupKey, Txn: $topupKey)');
      expect(Db.bankBalance, equals(4750.0));

      // Journal remains with status SERVER_CONFIRMED
      await Db.rechargeQueue.put(topupKey, {
        'idempotencyKey': topupKey,
        'type': 'TOPUP',
        'status': RechargeRecoveryEngine.statusServerConfirmed,
        'shopId': testShopId,
        'operator': 'Vi',
        'amount': topupAmt,
        'referenceNo': topupKey,
        'staffId': testOwnerUid,
        'staffName': 'Shop Owner',
      });

      // Execute settlement
      await RechargeRecoveryEngine.executeTopUpSettlement(
        idempotencyKey: topupKey,
        shopId: testShopId,
        operator: 'Vi',
        amount: topupAmt,
        referenceNo: topupKey,
        staffId: testOwnerUid,
        staffName: 'Shop Owner',
      );

      // Verify bank was NOT debited again! Still 4750.0
      expect(Db.bankBalance, equals(4750.0));
      expect(Db.rechargeQueue.containsKey(topupKey), isFalse);
    });

    test('6. Repeated Recovery Execution: Idempotent across multiple runs', () async {
      const topupKey = 'UTR_MULTI_RUN';
      const topupAmt = 300.0;

      await Db.rechargeQueue.put(topupKey, {
        'idempotencyKey': topupKey,
        'type': 'TOPUP',
        'status': RechargeRecoveryEngine.statusServerConfirmed,
        'shopId': testShopId,
        'operator': 'Vi',
        'amount': topupAmt,
        'referenceNo': topupKey,
        'staffId': testOwnerUid,
        'staffName': 'Shop Owner',
      });

      // Run recovery 3 times consecutively
      final run1 = await RechargeRecoveryEngine.reconcilePendingSettlements();
      final run2 = await RechargeRecoveryEngine.reconcilePendingSettlements();
      final run3 = await RechargeRecoveryEngine.reconcilePendingSettlements();

      expect(run1, equals(1));
      expect(run2, equals(0)); // Queue is now empty
      expect(run3, equals(0));
      expect(Db.bankBalance, equals(4700.0)); // Exactly one debit of ₹300
    });

    test('7. Failed Compensation: Unsettled transfer marked MANUAL_REVIEW_REQUIRED without loss', () async {
      const topupKey = 'UTR_MANUAL_REVIEW';
      const reason = 'Local bank write permission error';

      await Db.rechargeQueue.put(topupKey, {
        'idempotencyKey': topupKey,
        'type': 'TOPUP',
        'status': RechargeRecoveryEngine.statusServerConfirmed,
        'shopId': testShopId,
        'amount': 400.0,
      });

      await RechargeRecoveryEngine.markManualReviewRequired(topupKey, reason);

      final entry = Db.rechargeQueue.get(topupKey) as Map;
      expect(entry['status'], equals(RechargeRecoveryEngine.statusManualReviewRequired));
      expect(entry['reviewReason'], equals(reason));

      // Reconcile runner skips manual review entries to prevent loops
      final count = await RechargeRecoveryEngine.reconcilePendingSettlements();
      expect(count, equals(0));
      // Entry remains in queue for owner inspection
      expect(Db.rechargeQueue.containsKey(topupKey), isTrue);
    });

    test('8. Daily Reconciliation: Tracks own float bank debits separately from collections', () async {
      // Record own money top up
      await service.recordOwnMoneyTopUp(
        shopId: testShopId,
        operator: RechargeOperator.vi,
        amount: 500.0,
        staffId: testOwnerUid,
        staffName: 'Shop Owner',
        referenceId: 'UTR_RECON_001',
      );

      final report = await service.generateFinancialReport(
        shopId: testShopId,
        filter: RechargeReportFilter.today(),
      );

      // Verify own float top-ups are reported in recon
      expect(report.reconciliation.ownFloatBankDebitsPaise, equals(50000));
      expect(report.reconciliation.ownFloatBankDebits, equals(500.0));
      // Collections remain 0
      expect(report.reconciliation.rechargeCashCollectedPaise, equals(0));
      expect(report.reconciliation.rechargeUpiCollectedPaise, equals(0));
    });

    test('9. Duplicate Button Taps: Blocked by in-flight operation lock', () async {
      const topupKey = 'UTR_CONC_TAP_001';

      // Start first operation (deliberately holding or executing)
      final fut1 = service.recordOwnMoneyTopUp(
        shopId: testShopId,
        operator: RechargeOperator.vi,
        amount: 100.0,
        staffId: testOwnerUid,
        staffName: 'Shop Owner',
        referenceId: topupKey,
      );

      // Rapid second tap with exact same key while first is in-flight
      expect(
        () => service.recordOwnMoneyTopUp(
          shopId: testShopId,
          operator: RechargeOperator.vi,
          amount: 100.0,
          staffId: testOwnerUid,
          staffName: 'Shop Owner',
          referenceId: topupKey,
        ),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'error',
          contains('Duplicate top-up blocked'),
        )),
      );

      await fut1;
      expect(Db.bankBalance, equals(4900.0)); // 5000 - 100 = 4900
    });

    test('10. Conflicting UTR: Same UTR with altered amount is rejected with idempotency conflict', () async {
      const topupKey = 'UTR_CONFLICT_TEST';

      // First deposit ₹200
      await service.recordOwnMoneyTopUp(
        shopId: testShopId,
        operator: RechargeOperator.vi,
        amount: 200.0,
        staffId: testOwnerUid,
        staffName: 'Shop Owner',
        referenceId: topupKey,
      );

      // Second deposit with same UTR but different amount (₹500)
      expect(
        () => service.recordOwnMoneyTopUp(
          shopId: testShopId,
          operator: RechargeOperator.vi,
          amount: 500.0,
          staffId: testOwnerUid,
          staffName: 'Shop Owner',
          referenceId: topupKey,
        ),
        throwsA(predicate((e) => e.toString().contains('Idempotency conflict'))),
      );

      // Verify wallet only got ₹200, bank was only debited ₹200
      expect(Db.bankBalance, equals(4800.0)); // 5000 - 200 = 4800
    });

    test('11. Distributor Credit Isolation: Own top-up never alters distributor balances or liabilities', () async {
      final initialWallet = await service.getWallet(shopId: testShopId, operator: RechargeOperator.vi);
      expect(initialWallet.distributorCreditBalancePaise, equals(0));

      await service.recordOwnMoneyTopUp(
        shopId: testShopId,
        operator: RechargeOperator.vi,
        amount: 350.0,
        staffId: testOwnerUid,
        staffName: 'Shop Owner',
        referenceId: 'UTR_DIST_ISOLATION',
      );

      final updatedWallet = await service.getWallet(shopId: testShopId, operator: RechargeOperator.vi);
      // Distributor credit remains 0
      expect(updatedWallet.distributorCreditBalancePaise, equals(0));
      // Own prepaid increased
      expect(updatedWallet.ownPrepaidBalancePaise, equals(initialWallet.ownPrepaidBalancePaise + 35000));
    });
  });
}
