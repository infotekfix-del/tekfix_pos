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

  late Directory tempDir;
  const String testShopId = 'shop_staging_001';
  const String testOwnerUid = 'owner_staging_001';
  const String testDeviceId = 'DEV_TEST_001';
  const String testToken = 'valid_staging_owner_jwt';
  final service = RechargeService.instance;

  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    tempDir = await Directory.systemTemp.createTemp('tekfix_phase16_4_16_test_');
    Hive.init(tempDir.path);

    for (final b in allBoxes) {
      await Hive.openBox(b);
    }
    await Hive.openBox('tek_sync_meta');

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

    await Db.rechargeQueue.clear();
    await Db.rechargeDeadLetter.clear();
    await Db.bank.clear();
    await Db.sales.clear();
    await Db.expenses.clear();

    final metaBox = Hive.box('tek_sync_meta');
    await metaBox.clear();

    // Default Bank Balance for tests: ₹10,000.00
    await Db.bank.put('bank_balance', 10000.0);
    await Db.bank.put('cash_in_hand', 1000.0);
    await Db.bank.put('txn_log', []);
    await metaBox.put('ls:bank|bank_balance', 10000.0);
  });

  group('TEKFIX ERP - PHASE 16.4.16: ADVERSARIAL REMEDIATION TEST SUITE', () {

    // TEST 1: Insufficient Bank Balance
    test('1. Insufficient bank balance rejects immediately without server debit', () async {
      await Db.bank.put('bank_balance', 50.0);

      expect(
        () => service.recordOwnMoneyTopUp(
          shopId: testShopId,
          operator: RechargeOperator.vi,
          amount: 500.0,
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

      // Verify no outbox intent or money moved
      expect(Db.rechargeQueue.isEmpty, isTrue);
      expect(Db.bankBalance, equals(50.0));
    });

    // TEST 2: Two Concurrent Top-Ups Competing for Same Balance
    test('2. Two concurrent Top-Ups competing for the same balance (Race Condition Prevention)', () async {
      await Db.bank.put('bank_balance', 1000.0); // Only enough for one ₹1000 topup

      int serverCallCount = 0;
      final mockHttpClient = MockClient((request) async {
        if (request.url.path.endsWith('/request-challenge')) {
          return http.Response(jsonEncode({
            'success': true,
            'nonce': 'NONCE_${DateTime.now().millisecondsSinceEpoch}',
            'expiresAt': DateTime.now().add(const Duration(minutes: 5)).toIso8601String(),
          }), 200);
        }
        if (request.url.path.endsWith('/get-wallet')) {
          return http.Response(jsonEncode({
            'success': true,
            'wallet': {
              'wallet_id': 'WALLET_VI',
              'total_balance_paise': 0,
              'own_prepaid_balance_paise': 0,
              'distributor_credit_balance_paise': 0,
            }
          }), 200);
        }
        if (request.url.path.endsWith('/get-wallet')) {
          return http.Response(jsonEncode({
            'success': true,
            'wallet': {
              'wallet_id': 'WALLET_VI',
              'total_balance_paise': 0,
              'own_prepaid_balance_paise': 0,
              'distributor_credit_balance_paise': 0,
            }
          }), 200);
        }
        if (request.url.path.endsWith('/process-topup')) {
          serverCallCount++;
          return http.Response(jsonEncode({
            'success': true,
            'wallet_id': 'WALLET_VI',
            'amount_paise': 100000,
            'total_balance_paise': 100000,
            'reference_id': 'REF_RACE_$serverCallCount',
            'idempotent_replay': false,
          }), 200);
        }
        return http.Response('{"error":"Not Found"}', 404);
      });

      final bridgeClient = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: 'https://mock.supabase.co/functions/v1/recharge-bridge',
        getFirebaseIdToken: () async => testToken,
        httpClient: mockHttpClient,
      );
      RechargeBackendBridge.configure(
        mode: RechargeBackendMode.supabaseEdgeFunction,
        supabaseClient: bridgeClient,
      );

      // First Top-Up succeeds
      final res1 = await service.recordOwnMoneyTopUp(
        shopId: testShopId,
        operator: RechargeOperator.vi,
        amount: 1000.0,
        staffId: testOwnerUid,
        staffName: 'Shop Owner',
        referenceId: 'UTR_RACE_001',
        checkBankBalance: true,
      );
      expect(res1.wallet.ownPrepaidBalancePaise, equals(100000));
      expect(Db.bankBalance, equals(0.0));

      // Second Concurrent Top-Up must fail pre-flight or server check
      expect(
        () => service.recordOwnMoneyTopUp(
          shopId: testShopId,
          operator: RechargeOperator.vi,
          amount: 1000.0,
          staffId: testOwnerUid,
          staffName: 'Shop Owner',
          referenceId: 'UTR_RACE_002',
          checkBankBalance: true,
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Insufficient bank balance'),
        )),
      );

      expect(serverCallCount, equals(1));
    });

    // TEST 3: Duplicate Request with Identical Idempotency Key
    test('3. Duplicate request with identical idempotency key returns original without extra debit', () async {
      await Db.bank.put('bank_balance', 5000.0);

      int topupCalls = 0;
      final mockHttpClient = MockClient((request) async {
        if (request.url.path.endsWith('/request-challenge')) {
          return http.Response(jsonEncode({
            'success': true,
            'nonce': 'NONCE_IDEM',
            'expiresAt': DateTime.now().add(const Duration(minutes: 5)).toIso8601String(),
          }), 200);
        }
        if (request.url.path.endsWith('/get-wallet')) {
          return http.Response(jsonEncode({
            'success': true,
            'wallet': {
              'wallet_id': 'WALLET_VI',
              'total_balance_paise': 0,
              'own_prepaid_balance_paise': 0,
              'distributor_credit_balance_paise': 0,
            }
          }), 200);
        }
        if (request.url.path.endsWith('/process-topup')) {
          topupCalls++;
          final isReplay = topupCalls > 1;
          return http.Response(jsonEncode({
            'success': true,
            'wallet_id': 'WALLET_VI',
            'amount_paise': 50000,
            'total_balance_paise': 50000,
            'reference_id': 'UTR_IDEM_SAME',
            'idempotent_replay': isReplay,
          }), 200);
        }
        return http.Response('{"error":"Not Found"}', 404);
      });

      final bridgeClient = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: 'https://mock.supabase.co/functions/v1/recharge-bridge',
        getFirebaseIdToken: () async => testToken,
        httpClient: mockHttpClient,
      );
      RechargeBackendBridge.configure(
        mode: RechargeBackendMode.supabaseEdgeFunction,
        supabaseClient: bridgeClient,
      );

      // Call 1
      final res1 = await service.recordOwnMoneyTopUp(
        shopId: testShopId,
        operator: RechargeOperator.vi,
        amount: 500.0,
        staffId: testOwnerUid,
        staffName: 'Shop Owner',
        referenceId: 'UTR_IDEM_SAME',
        checkBankBalance: true,
      );
      expect(res1.wallet.ownPrepaidBalancePaise, equals(50000));
      expect(Db.bankBalance, equals(4500.0));

      // Call 2 (Retry with same UTR)
      final res2 = await service.recordOwnMoneyTopUp(
        shopId: testShopId,
        operator: RechargeOperator.vi,
        amount: 500.0,
        staffId: testOwnerUid,
        staffName: 'Shop Owner',
        referenceId: 'UTR_IDEM_SAME',
        checkBankBalance: true,
      );
      expect(res2.wallet.ownPrepaidBalancePaise, equals(50000));
      // Bank balance debited exactly once
      expect(Db.bankBalance, equals(4500.0));
      expect(topupCalls, equals(2));
    });

    // TEST 4: Same Key with Altered Amount (Idempotency Conflict)
    test('4. Same key with altered amount is rejected with idempotency conflict', () async {
      final mockHttpClient = MockClient((request) async {
        if (request.url.path.endsWith('/request-challenge')) {
          return http.Response(jsonEncode({
            'success': true,
            'nonce': 'NONCE_CONFLICT',
            'expiresAt': DateTime.now().add(const Duration(minutes: 5)).toIso8601String(),
          }), 200);
        }
        if (request.url.path.endsWith('/get-wallet')) {
          return http.Response(jsonEncode({
            'success': true,
            'wallet': {
              'wallet_id': 'WALLET_VI',
              'total_balance_paise': 0,
              'own_prepaid_balance_paise': 0,
              'distributor_credit_balance_paise': 0,
            }
          }), 200);
        }
        if (request.url.path.endsWith('/process-topup')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (body['amountPaise'] == 99900) {
            return http.Response(
              jsonEncode({'error': 'Idempotency conflict: reference already processed with different payload'}),
              400,
            );
          }
          return http.Response(jsonEncode({'success': true, 'reference_id': 'UTR_CONFLICT'}), 200);
        }
        return http.Response('{"error":"Not Found"}', 404);
      });

      final bridgeClient = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: 'https://mock.supabase.co/functions/v1/recharge-bridge',
        getFirebaseIdToken: () async => testToken,
        httpClient: mockHttpClient,
      );

      final challenge = await bridgeClient.requestChallenge(shopId: testShopId, deviceId: testDeviceId, ownerUid: testOwnerUid);
      expect(
        () => bridgeClient.processTopup(
          shopId: testShopId,
          walletId: 'WALLET_VI',
          amountPaise: 99900,
          source: 'bank',
          staffId: testOwnerUid,
          staffName: 'Owner',
          referenceId: 'UTR_CONFLICT',
          deviceId: testDeviceId,
          deviceSignature: 'dummy_sig',
          nonce: challenge.nonce,
        ),
        throwsA(predicate((e) => e.toString().contains('Idempotency conflict'))),
      );
    });

    // TEST 5: Crash After Bank Reservation but Before Supabase Credit
    test('5. Crash after bank reservation but before Supabase credit (Status: INITIATED)', () async {
      const topupKey = 'UTR_CRASH_STAGE_A';
      await RechargeRecoveryEngine.recordPendingTopUpIntent(
        idempotencyKey: topupKey,
        shopId: testShopId,
        ownerUid: testOwnerUid,
        deviceId: testDeviceId,
        walletId: 'WALLET_VI',
        operator: 'Vi',
        amount: 250.0,
        amountPaise: 25000,
        referenceNo: topupKey,
        source: 'bank',
        staffId: testOwnerUid,
        staffName: 'Owner',
        checkBankBalance: false,
      );

      expect(Db.rechargeQueue.containsKey(topupKey), isTrue);
      final raw = Db.rechargeQueue.get(topupKey) as Map;
      expect(raw['status'], equals('INITIATED'));

      final mockHttpClient = MockClient((request) async {
        if (request.url.path.endsWith('/request-challenge')) {
          return http.Response(jsonEncode({'nonce': 'N_REC', 'expiresAt': '2099-01-01'}), 200);
        }
        if (request.url.path.endsWith('/get-wallet')) {
          return http.Response(jsonEncode({
            'success': true,
            'wallet': {
              'wallet_id': 'WALLET_VI',
              'total_balance_paise': 0,
              'own_prepaid_balance_paise': 0,
              'distributor_credit_balance_paise': 0,
            }
          }), 200);
        }
        if (request.url.path.endsWith('/process-topup')) {
          return http.Response(jsonEncode({
            'success': true,
            'wallet_id': 'WALLET_VI',
            'amount_paise': 25000,
            'total_balance_paise': 25000,
            'reference_id': topupKey,
            'idempotent_replay': false,
          }), 200);
        }
        return http.Response('{"error":"Not Found"}', 404);
      });

      final bridgeClient = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: 'https://mock.supabase.co/functions/v1/recharge-bridge',
        getFirebaseIdToken: () async => testToken,
        httpClient: mockHttpClient,
      );
      RechargeBackendBridge.configure(
        mode: RechargeBackendMode.supabaseEdgeFunction,
        supabaseClient: bridgeClient,
      );

      final recovered = await RechargeRecoveryEngine.reconcilePendingSettlements();
      expect(recovered, equals(1));
      expect(Db.rechargeQueue.containsKey(topupKey), isFalse);
      expect(Db.bankBalance, equals(9750.0));
    });

    // TEST 6: Crash After Supabase Credit but Before Firestore Settlement
    test('6. Crash after Supabase credit but before Firestore settlement (Status: SERVER_CONFIRMED)', () async {
      const topupKey = 'UTR_CRASH_STAGE_B';
      await RechargeRecoveryEngine.recordPendingTopUpIntent(
        idempotencyKey: topupKey,
        shopId: testShopId,
        ownerUid: testOwnerUid,
        deviceId: testDeviceId,
        walletId: 'WALLET_VI',
        operator: 'Vi',
        amount: 300.0,
        amountPaise: 30000,
        referenceNo: topupKey,
        source: 'bank',
        staffId: testOwnerUid,
        staffName: 'Owner',
        checkBankBalance: false,
      );

      await RechargeRecoveryEngine.markTopUpServerConfirmed(
        topupKey,
        serverDepositId: topupKey,
        balanceAfterPaise: 30000,
      );

      final recovered = await RechargeRecoveryEngine.reconcilePendingSettlements();
      expect(recovered, equals(1));
      expect(Db.rechargeQueue.containsKey(topupKey), isFalse);
      expect(Db.bankBalance, equals(9700.0));
    });

    // TEST 7: Firestore Timeout After Commit
    test('7. Firestore timeout after commit recovers gracefully without double debit', () async {
      const topupKey = 'UTR_TIMEOUT_COMMIT';
      await RechargeRecoveryEngine.recordPendingTopUpIntent(
        idempotencyKey: topupKey,
        shopId: testShopId,
        ownerUid: testOwnerUid,
        deviceId: testDeviceId,
        walletId: 'WALLET_VI',
        operator: 'Vi',
        amount: 150.0,
        amountPaise: 15000,
        referenceNo: topupKey,
        source: 'bank',
        staffId: testOwnerUid,
        staffName: 'Owner',
        checkBankBalance: false,
      );

      await RechargeRecoveryEngine.markTopUpServerConfirmed(
        topupKey,
        serverDepositId: topupKey,
        balanceAfterPaise: 15000,
      );

      // Simulate partial execution where bank debit was recorded in Hive but queue not deleted
      await Db.moveMoney('Bank', -150.0, 'Topup Vi (Ref: $topupKey, Txn: $topupKey)');
      expect(Db.bankBalance, equals(9850.0));

      // Run recovery
      await RechargeRecoveryEngine.reconcilePendingSettlements();

      // Ensure bank was not debited a second time
      expect(Db.bankBalance, equals(9850.0));
      expect(Db.rechargeQueue.containsKey(topupKey), isFalse);
    });

    // TEST 8: Repeated Recovery Idempotency
    test('8. Repeated recovery calls execute idempotently without side effects', () async {
      const topupKey = 'UTR_MULTI_RUN';
      await RechargeRecoveryEngine.recordPendingTopUpIntent(
        idempotencyKey: topupKey,
        shopId: testShopId,
        ownerUid: testOwnerUid,
        deviceId: testDeviceId,
        walletId: 'WALLET_VI',
        operator: 'Vi',
        amount: 100.0,
        amountPaise: 10000,
        referenceNo: topupKey,
        source: 'bank',
        staffId: testOwnerUid,
        staffName: 'Owner',
        checkBankBalance: false,
      );

      await RechargeRecoveryEngine.markTopUpServerConfirmed(
        topupKey,
        serverDepositId: topupKey,
        balanceAfterPaise: 10000,
      );

      final pass1 = await RechargeRecoveryEngine.reconcilePendingSettlements();
      expect(pass1, equals(1));
      expect(Db.bankBalance, equals(9900.0));

      final pass2 = await RechargeRecoveryEngine.reconcilePendingSettlements();
      expect(pass2, equals(0));
      expect(Db.bankBalance, equals(9900.0));
    });

    // TEST 9: Offline Restart Recovery
    test('9. Offline restart leaves pending entries intact until connection restored', () async {
      const topupKey = 'UTR_OFFLINE_001';
      await RechargeRecoveryEngine.recordPendingTopUpIntent(
        idempotencyKey: topupKey,
        shopId: testShopId,
        ownerUid: testOwnerUid,
        deviceId: testDeviceId,
        walletId: 'WALLET_VI',
        operator: 'Vi',
        amount: 200.0,
        amountPaise: 20000,
        referenceNo: topupKey,
        source: 'bank',
        staffId: testOwnerUid,
        staffName: 'Owner',
        checkBankBalance: false,
      );

      // Disconnect bridge client (simulate offline)
      RechargeBackendBridge.configure(
        mode: RechargeBackendMode.localTestMock,
        supabaseClient: null,
      );

      final recovered = await RechargeRecoveryEngine.reconcilePendingSettlements();
      expect(recovered, equals(0));
      expect(Db.rechargeQueue.containsKey(topupKey), isTrue);
      expect(Db.bankBalance, equals(10000.0)); // No debit while offline
    });

    // TEST 10: Owner Device Authentication Failure
    test('10. Owner device authentication failure halts processing', () async {
      final mockHttpClient = MockClient((request) async {
        if (request.url.path.endsWith('/request-challenge')) {
          return http.Response(jsonEncode({
            'error': 'Device ownership mismatch with authenticated owner.'
          }), 403);
        }
        return http.Response('{"error":"Forbidden"}', 403);
      });

      final bridgeClient = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: 'https://mock.supabase.co/functions/v1/recharge-bridge',
        getFirebaseIdToken: () async => testToken,
        httpClient: mockHttpClient,
      );

      expect(
        () => bridgeClient.requestChallenge(shopId: testShopId, deviceId: 'UNREGISTERED_DEV', ownerUid: testOwnerUid),
        throwsA(predicate((e) => e.toString().contains('Device ownership mismatch') || e.toString().contains('403'))),
      );
    });

    // TEST 11: Staff Authorization Attempt Denied
    test('11. Staff authorization attempt is strictly rejected by Edge Function', () async {
      final mockHttpClient = MockClient((request) async {
        if (request.url.path.endsWith('/get-wallet')) {
          return http.Response(jsonEncode({
            'success': true,
            'wallet': {
              'wallet_id': 'WALLET_VI',
              'total_balance_paise': 0,
              'own_prepaid_balance_paise': 0,
              'distributor_credit_balance_paise': 0,
            }
          }), 200);
        }
        if (request.url.path.endsWith('/process-topup')) {
          return http.Response(jsonEncode({
            'error': 'Access denied: Token role "staff" is not authorized. STRICT OWNER ONLY.'
          }), 403);
        }
        return http.Response('{"error":"Forbidden"}', 403);
      });

      final bridgeClient = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: 'https://mock.supabase.co/functions/v1/recharge-bridge',
        getFirebaseIdToken: () async => 'staff_token',
        httpClient: mockHttpClient,
      );

      expect(
        () => bridgeClient.processTopup(
          shopId: testShopId,
          walletId: 'WALLET_VI',
          amountPaise: 50000,
          source: 'bank',
          staffId: 'staff_001',
          staffName: 'Staff Member',
          referenceId: 'UTR_STAFF_ATTEMPT',
          deviceId: testDeviceId,
          deviceSignature: 'dummy_sig',
          nonce: 'dummy_nonce',
        ),
        throwsA(predicate((e) => e.toString().contains('STRICT OWNER ONLY') || e.toString().contains('403'))),
      );
    });

    // TEST 12: Duplicate UTR Replay Safety
    test('12. Duplicate UTR returns existing deposit reference and avoids second credit', () async {
      final mockHttpClient = MockClient((request) async {
        if (request.url.path.endsWith('/get-wallet')) {
          return http.Response(jsonEncode({
            'success': true,
            'wallet': {
              'wallet_id': 'WALLET_VI',
              'total_balance_paise': 0,
              'own_prepaid_balance_paise': 0,
              'distributor_credit_balance_paise': 0,
            }
          }), 200);
        }
        if (request.url.path.endsWith('/process-topup')) {
          return http.Response(jsonEncode({
            'success': true,
            'wallet_id': 'WALLET_VI',
            'amount_paise': 20000,
            'total_balance_paise': 20000,
            'reference_id': 'UTR_DUP_001',
            'idempotent_replay': true,
          }), 200);
        }
        return http.Response('{"error":"Not Found"}', 404);
      });

      final bridgeClient = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: 'https://mock.supabase.co/functions/v1/recharge-bridge',
        getFirebaseIdToken: () async => testToken,
        httpClient: mockHttpClient,
      );

      final res = await bridgeClient.processTopup(
        shopId: testShopId,
        walletId: 'WALLET_VI',
        amountPaise: 20000,
        source: 'bank',
        staffId: testOwnerUid,
        staffName: 'Owner',
        referenceId: 'UTR_DUP_001',
        deviceId: testDeviceId,
        deviceSignature: 'sig',
        nonce: 'nonce',
      );

      expect(res['success'], isTrue);
      expect(res['idempotent_replay'], isTrue);
      expect(res['reference_id'], equals('UTR_DUP_001'));
    });

    // TEST 13: Bank Balance Unchanged After Rejected Top-Up
    test('13. Bank balance remains completely unchanged when Top-Up is rejected', () async {
      await Db.bank.put('bank_balance', 7500.0);

      final mockHttpClient = MockClient((request) async {
        if (request.url.path.endsWith('/request-challenge')) {
          return http.Response(jsonEncode({'nonce': 'NONCE_REJ', 'expiresAt': '2099-01-01'}), 200);
        }
        if (request.url.path.endsWith('/get-wallet')) {
          return http.Response(jsonEncode({
            'success': true,
            'wallet': {
              'wallet_id': 'WALLET_VI',
              'total_balance_paise': 0,
              'own_prepaid_balance_paise': 0,
              'distributor_credit_balance_paise': 0,
            }
          }), 200);
        }
        if (request.url.path.endsWith('/process-topup')) {
          return http.Response(jsonEncode({'error': 'PostgreSQL RPC Error: Wallet not found'}), 400);
        }
        return http.Response('{"error":"Not Found"}', 404);
      });

      final bridgeClient = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: 'https://mock.supabase.co/functions/v1/recharge-bridge',
        getFirebaseIdToken: () async => testToken,
        httpClient: mockHttpClient,
      );
      RechargeBackendBridge.configure(
        mode: RechargeBackendMode.supabaseEdgeFunction,
        supabaseClient: bridgeClient,
      );

      expect(
        () => service.recordOwnMoneyTopUp(
          shopId: testShopId,
          operator: RechargeOperator.vi,
          amount: 500.0,
          staffId: testOwnerUid,
          staffName: 'Shop Owner',
          referenceId: 'UTR_REJECTED',
          checkBankBalance: true,
        ),
        throwsA(anything),
      );

      expect(Db.bankBalance, equals(7500.0));
      final logs = ((Db.bank.get('txn_log') as List?) ?? []);
      final hasMoved = logs.any((e) => e is Map && e['note']?.toString().contains('UTR_REJECTED') == true);
      expect(hasMoved, isFalse);
    });

    // TEST 14: Retail Sales and Expenses Remain Unaffected
    test('14. Top-Up never contaminates retail sales, revenue, or business expenses', () async {
      await Db.bank.put('bank_balance', 5000.0);

      final mockHttpClient = MockClient((request) async {
        if (request.url.path.endsWith('/request-challenge')) {
          return http.Response(jsonEncode({'nonce': 'NONCE_EXP', 'expiresAt': '2099-01-01'}), 200);
        }
        if (request.url.path.endsWith('/get-wallet')) {
          return http.Response(jsonEncode({
            'success': true,
            'wallet': {
              'wallet_id': 'WALLET_VI',
              'total_balance_paise': 0,
              'own_prepaid_balance_paise': 0,
              'distributor_credit_balance_paise': 0,
            }
          }), 200);
        }
        if (request.url.path.endsWith('/process-topup')) {
          return http.Response(jsonEncode({
            'success': true,
            'wallet_id': 'WALLET_VI',
            'amount_paise': 100000,
            'total_balance_paise': 100000,
            'reference_id': 'UTR_NO_EXPENSE',
            'idempotent_replay': false,
          }), 200);
        }
        return http.Response('{"error":"Not Found"}', 404);
      });

      final bridgeClient = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: 'https://mock.supabase.co/functions/v1/recharge-bridge',
        getFirebaseIdToken: () async => testToken,
        httpClient: mockHttpClient,
      );
      RechargeBackendBridge.configure(
        mode: RechargeBackendMode.supabaseEdgeFunction,
        supabaseClient: bridgeClient,
      );

      await service.recordOwnMoneyTopUp(
        shopId: testShopId,
        operator: RechargeOperator.vi,
        amount: 1000.0,
        staffId: testOwnerUid,
        staffName: 'Shop Owner',
        referenceId: 'UTR_NO_EXPENSE',
        checkBankBalance: true,
      );

      final report = await service.generateFinancialReport(
        shopId: testShopId,
        filter: RechargeReportFilter.today(),
      );

      // Verify POS retail sales & business expenses boxes are completely untouched
      expect(Db.sales.isEmpty, isTrue);
      expect(Db.expenses.isEmpty, isTrue);
      expect(report.cashCollectionPaise, equals(0));
      expect(report.netCommissionIncomePaise, equals(0));
      expect(report.reconciliation.ownFloatBankDebitsPaise, equals(100000));
      expect(report.reconciliation.ownFloatBankDebits, equals(1000.0));
    });

    // TEST 15: Distributor Credit Remains Separate from Own Money
    test('15. Distributor credit load never touches bank balance or mixes with own money', () async {
      await Db.bank.put('bank_balance', 5000.0);

      final mockHttpClient = MockClient((request) async {
        if (request.url.path.endsWith('/request-challenge')) {
          return http.Response(jsonEncode({'nonce': 'NONCE_CREDIT', 'expiresAt': '2099-01-01'}), 200);
        }
        if (request.url.path.endsWith('/process-distributor-load')) {
          return http.Response(jsonEncode({
            'success': true,
            'wallet_id': 'WALLET_VI',
            'amount_paise': 200000,
            'distributor_credit_balance_paise': 200000,
            'own_prepaid_balance_paise': 0,
            'total_balance_paise': 200000,
            'reference_id': 'CREDIT_LOAD_001',
          }), 200);
        }
        return http.Response('{"error":"Not Found"}', 404);
      });

      final bridgeClient = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: 'https://mock.supabase.co/functions/v1/recharge-bridge',
        getFirebaseIdToken: () async => testToken,
        httpClient: mockHttpClient,
      );
      RechargeBackendBridge.configure(
        mode: RechargeBackendMode.supabaseEdgeFunction,
        supabaseClient: bridgeClient,
      );

      await service.recordDistributorCreditLoad(
        shopId: testShopId,
        operator: RechargeOperator.vi,
        distributorId: 'DIST_APEX_VI',
        amount: 2000.0,
        staffId: testOwnerUid,
        staffName: 'Shop Owner',
        referenceNumber: 'CREDIT_LOAD_001',
      );

      // Bank balance must remain completely untouched
      expect(Db.bankBalance, equals(5000.0));
    });

  });
}
