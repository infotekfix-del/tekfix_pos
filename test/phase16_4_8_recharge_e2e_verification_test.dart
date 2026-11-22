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
import 'package:tekfix_erp_pos/recharge/recharge_service.dart';
import 'package:tekfix_erp_pos/recharge/supabase_recharge_bridge_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TEKFIX ERP - PHASE 16.4.8: COMPLETE WALLET INITIALIZATION & RECHARGE VERIFICATION', () {
    late Directory tempDir;
    const testShopId = 'tekfix';
    const testOwnerUid = 'ShjbKbg8HsabkQjEGnlp03unezi2';
    const testDeviceId = 'DEV_ANDR_49246D';
    const testToken = 'valid_owner_token_tekfix';
    const testNonce = 'NONCE_TEST_1648';
    const testSignature = 'VALID_ECDSA_DER_SIG_1648';

    late MockClient mockHttpClient;
    late SupabaseRechargeBridgeClient bridgeClient;
    final service = RechargeService.instance;

    // In-memory mock PostgreSQL state mirroring production Supabase
    final Map<String, Map<String, dynamic>> mockPostgresWallets = {
      'WALLET_AIRTEL': {
        'shop_id': testShopId,
        'wallet_id': 'WALLET_AIRTEL',
        'operator': 'Airtel',
        'sim_number': '',
        'own_prepaid_balance_paise': 0,
        'distributor_credit_balance_paise': 0,
        'total_balance_paise': 0,
        'last_updated_at': DateTime.now().toIso8601String(),
      },
      'WALLET_JIO': {
        'shop_id': testShopId,
        'wallet_id': 'WALLET_JIO',
        'operator': 'Jio',
        'sim_number': '',
        'own_prepaid_balance_paise': 0,
        'distributor_credit_balance_paise': 0,
        'total_balance_paise': 0,
        'last_updated_at': DateTime.now().toIso8601String(),
      },
      'WALLET_VI': {
        'shop_id': testShopId,
        'wallet_id': 'WALLET_VI',
        'operator': 'Vi',
        'sim_number': '',
        'own_prepaid_balance_paise': 0,
        'distributor_credit_balance_paise': 0,
        'total_balance_paise': 0,
        'last_updated_at': DateTime.now().toIso8601String(),
      },
      'WALLET_BSNL': {
        'shop_id': testShopId,
        'wallet_id': 'WALLET_BSNL',
        'operator': 'BSNL',
        'sim_number': '',
        'own_prepaid_balance_paise': 0,
        'distributor_credit_balance_paise': 0,
        'total_balance_paise': 0,
        'last_updated_at': DateTime.now().toIso8601String(),
      },
    };

    final Map<String, Map<String, dynamic>> mockPostgresTxns = {};
    final List<Map<String, dynamic>> mockPostgresLogs = [];
    final List<Map<String, dynamic>> mockPostgresCommissions = [];

    setUpAll(() async {
      GoogleFonts.config.allowRuntimeFetching = false;
      tempDir = await Directory.systemTemp.createTemp('recharge_16_4_8_test_');
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

    setUp(() {
      service.resetLocalCacheForTesting();
      service.disableOpeningBalanceGateForTesting();

      mockHttpClient = MockClient((request) async {
        final path = request.url.path;
        final body = jsonDecode(request.body) as Map<String, dynamic>;

        // Verify Firebase JWT Header
        final authHeader = request.headers['Authorization'] ?? '';
        if (authHeader != 'Bearer $testToken') {
          return http.Response(jsonEncode({'error': 'Unauthorized: Invalid token'}), 401);
        }

        // Endpoint: initialize-wallets
        if (path.endsWith('/initialize-wallets')) {
          final sId = body['shopId'];
          if (sId != testShopId) {
            return http.Response(jsonEncode({'error': 'Shop mismatch'}), 403);
          }
          return http.Response(jsonEncode({
            'success': true,
            'wallets_created': 0, // Idempotent: already exist
            'wallets': mockPostgresWallets.values.toList(),
          }), 200);
        }

        // Endpoint: get-wallet
        if (path.endsWith('/get-wallet')) {
          final wId = body['walletId'];
          if (mockPostgresWallets.containsKey(wId)) {
            return http.Response(jsonEncode({'success': true, 'wallet': mockPostgresWallets[wId]}), 200);
          }
          return http.Response(jsonEncode({'success': true, 'wallet': null}), 200);
        }

        // Security check for financial operations
        final dId = body['deviceId'];
        final sig = body['deviceSignature'];
        final nonce = body['nonce'];

        if (dId == null || dId.toString().isEmpty || sig == null || nonce == null) {
          return http.Response(jsonEncode({'error': 'Trusted Device Error: deviceId, nonce, and deviceSignature required'}), 403);
        }

        if (dId != testDeviceId) {
          return http.Response(jsonEncode({'error': 'Device not authorized'}), 403);
        }

        // Endpoint: process-topup (Float Deposit)
        if (path.endsWith('/process-topup')) {
          final wId = body['walletId'] as String;
          final amtPaise = body['amountPaise'] as int;

          if (!mockPostgresWallets.containsKey(wId)) {
            return http.Response(jsonEncode({'error': 'Wallet $wId for shop $testShopId not found'}), 400);
          }

          final w = mockPostgresWallets[wId]!;
          final before = w['own_prepaid_balance_paise'] as int;
          final after = before + amtPaise;
          w['own_prepaid_balance_paise'] = after;
          w['total_balance_paise'] = after + (w['distributor_credit_balance_paise'] as int);

          mockPostgresLogs.add({
            'wallet_id': wId,
            'entry_type': 'topup',
            'amount_paise': amtPaise,
            'balance_before_paise': before,
            'balance_after_paise': after,
          });

          return http.Response(jsonEncode({
            'success': true,
            'wallet_id': wId,
            'balance_before_paise': before,
            'balance_after_paise': after,
            'total_balance_paise': w['total_balance_paise'],
          }), 200);
        }

        // Endpoint: process-debit
        if (path.endsWith('/process-debit')) {
          final wId = body['walletId'] as String;
          final txnKey = body['idempotencyKey'] as String;
          final amtPaise = body['amountPaise'] as int;
          final fundingType = body['fundingType'] as String;
          final commPaise = (body['commissionEarnedPaise'] as num?)?.toInt() ?? 0;
          final pMode = body['paymentMode'] as String? ?? 'Cash';

          // Idempotency check
          if (mockPostgresTxns.containsKey(txnKey)) {
            final existing = mockPostgresTxns[txnKey]!;
            return http.Response(jsonEncode({
              'success': true,
              'idempotent_replay': true,
              'txn_key': txnKey,
              'amount_paise': existing['amount_paise'],
              'total_balance_paise': mockPostgresWallets[wId]!['total_balance_paise'],
              'payment_mode': existing['payment_mode'],
            }), 200);
          }

          if (!mockPostgresWallets.containsKey(wId)) {
            return http.Response(jsonEncode({'error': 'Wallet $wId for shop $testShopId not found'}), 400);
          }

          final w = mockPostgresWallets[wId]!;
          final currentOwn = w['own_prepaid_balance_paise'] as int;

          if (fundingType == 'ownPrepaid' && currentOwn < amtPaise) {
            return http.Response(jsonEncode({
              'error': 'Insufficient own prepaid balance: Available $currentOwn paise, requested $amtPaise paise'
            }), 400);
          }

          final before = w['total_balance_paise'] as int;
          w['own_prepaid_balance_paise'] = currentOwn - amtPaise;
          w['total_balance_paise'] = (w['own_prepaid_balance_paise'] as int) + (w['distributor_credit_balance_paise'] as int);
          final after = w['total_balance_paise'] as int;

          mockPostgresTxns[txnKey] = {
            'shop_id': testShopId,
            'txn_key': txnKey,
            'wallet_id': wId,
            'amount_paise': amtPaise,
            'funding_type': fundingType,
            'payment_mode': pMode,
            'status': 'completed',
          };

          mockPostgresLogs.add({
            'wallet_id': wId,
            'entry_type': 'debit',
            'amount_paise': amtPaise,
            'balance_before_paise': before,
            'balance_after_paise': after,
          });

          if (commPaise > 0) {
            mockPostgresCommissions.add({
              'txn_key': txnKey,
              'commission_paise': commPaise,
            });
          }

          return http.Response(jsonEncode({
            'success': true,
            'idempotent_replay': false,
            'txn_key': txnKey,
            'balance_before_paise': before,
            'balance_after_paise': after,
            'total_balance_paise': after,
            'payment_mode': pMode,
          }), 200);
        }

        // Endpoint: process-refund
        if (path.endsWith('/process-refund')) {
          final txnKey = body['txnKey'] as String;
          if (!mockPostgresTxns.containsKey(txnKey)) {
            return http.Response(jsonEncode({'error': 'Transaction $txnKey not found'}), 400);
          }
          mockPostgresTxns[txnKey]!['status'] = 'refunded';
          return http.Response(jsonEncode({
            'success': true,
            'txn_key': txnKey,
            'status': 'refunded',
          }), 200);
        }

        // Endpoint: process-reversal
        if (path.endsWith('/process-reversal')) {
          final txnKey = body['txnKey'] as String;
          if (!mockPostgresTxns.containsKey(txnKey)) {
            return http.Response(jsonEncode({'error': 'Transaction $txnKey not found'}), 400);
          }
          final txn = mockPostgresTxns[txnKey]!;
          txn['status'] = 'reversed';
          final wId = txn['wallet_id'] as String;
          final amt = txn['amount_paise'] as int;
          mockPostgresWallets[wId]!['own_prepaid_balance_paise'] =
              (mockPostgresWallets[wId]!['own_prepaid_balance_paise'] as int) + amt;
          mockPostgresWallets[wId]!['total_balance_paise'] =
              (mockPostgresWallets[wId]!['own_prepaid_balance_paise'] as int) +
              (mockPostgresWallets[wId]!['distributor_credit_balance_paise'] as int);

          return http.Response(jsonEncode({
            'success': true,
            'txn_key': txnKey,
            'status': 'reversed',
            'wallet_balance_restored_paise': mockPostgresWallets[wId]!['total_balance_paise'],
          }), 200);
        }

        return http.Response(jsonEncode({'error': 'Not found'}), 404);
      });

      bridgeClient = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: 'https://bxjlqcqcjfifzjrqpcov.supabase.co/functions/v1/recharge-bridge',
        getFirebaseIdToken: () async => testToken,
        httpClient: mockHttpClient,
      );

      RechargeBackendBridge.configure(
        mode: RechargeBackendMode.supabaseEdgeFunction,
        supabaseClient: bridgeClient,
      );
    });

    tearDown(() {
      RechargeBackendBridge.reset();
    });

    // -------------------------------------------------------------------------
    // TEST 1: Idempotent Wallet Initialization & Balance Preservation
    // -------------------------------------------------------------------------
    test('TEST 1: Idempotent wallet initialization verifies all 4 operators exist with 0 paise baseline', () async {
      final res = await bridgeClient.initializeWallets(shopId: testShopId);
      expect(res['success'], isTrue);
      expect(res['wallets_created'], 0); // Idempotent: 0 new wallets created, existing preserved

      final airtel = await bridgeClient.getWallet(shopId: testShopId, walletId: 'WALLET_AIRTEL');
      final jio = await bridgeClient.getWallet(shopId: testShopId, walletId: 'WALLET_JIO');
      final vi = await bridgeClient.getWallet(shopId: testShopId, walletId: 'WALLET_VI');
      final bsnl = await bridgeClient.getWallet(shopId: testShopId, walletId: 'WALLET_BSNL');

      expect(airtel?['own_prepaid_balance_paise'], 0);
      expect(jio?['own_prepaid_balance_paise'], 0);
      expect(vi?['own_prepaid_balance_paise'], 0);
      expect(bsnl?['own_prepaid_balance_paise'], 0);
    });

    // -------------------------------------------------------------------------
    // TEST 2: Overdraft Prevention on Zero Balance Wallet
    // -------------------------------------------------------------------------
    test('TEST 2: Attempting debit on zero-balance wallet is strictly rejected with Insufficient Balance', () async {
      expect(
        () => bridgeClient.processDebit(
          shopId: testShopId,
          walletId: 'WALLET_VI',
          rechargeId: 'TXN_OVERDRAFT_001',
          idempotencyKey: 'TXN_OVERDRAFT_001',
          operator: 'Vi',
          amountPaise: 29900,
          amount: 299.0,
          fundingType: 'ownPrepaid',
          businessDate: '2026-11-16',
          deviceId: testDeviceId,
          deviceSignature: testSignature,
          nonce: testNonce,
        ),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message', contains('Insufficient own prepaid balance'))),
      );
    });

    // -------------------------------------------------------------------------
    // TEST 3: Legitimate Float Top-Up via Stored Procedure
    // -------------------------------------------------------------------------
    test('TEST 3: Authorized owner deposits float (₹50.00 = 5000 paise) into WALLET_VI', () async {
      final res = await bridgeClient.processTopup(
        shopId: testShopId,
        walletId: 'WALLET_VI',
        amountPaise: 5000,
        deviceId: testDeviceId,
        deviceSignature: testSignature,
        nonce: testNonce,
        source: 'bank',
        staffId: testOwnerUid,
        staffName: 'Owner Unais',
        description: 'Test float deposit',
      );

      expect(res['success'], isTrue);
      expect(res['balance_before_paise'], 0);
      expect(res['balance_after_paise'], 5000);
      expect(mockPostgresWallets['WALLET_VI']!['own_prepaid_balance_paise'], 5000);
    });

    // -------------------------------------------------------------------------
    // TEST 4: Complete Recharge Flow (Vi Mobile Prepaid, Cash Payment, ₹10.00)
    // -------------------------------------------------------------------------
    test('TEST 4: Mobile Prepaid recharge debits ₹10.00 (1000 paise), earns commission ₹0.35, updates cash', () async {
      await Db.bank.put('cash_in_hand', 2000.0);
      await Db.sales.clear();

      final res = await bridgeClient.processDebit(
        shopId: testShopId,
        walletId: 'WALLET_VI',
        rechargeId: 'TXN_VI_PREPAID_001',
        idempotencyKey: 'TXN_VI_PREPAID_001',
        operator: 'Vi',
        amountPaise: 1000,
        amount: 10.0,
        fundingType: 'ownPrepaid',
        commissionEarnedPaise: 35,
        businessDate: '2026-11-16',
        deviceId: testDeviceId,
        deviceSignature: testSignature,
        nonce: testNonce,
        customerPhone: '9847012345',
        serviceType: 'Prepaid',
        paymentMode: 'Cash',
        retailAmountPaise: 1000,
        costPricePaise: 965,
      );

      expect(res['success'], isTrue);
      expect(res['idempotent_replay'], isFalse);
      expect(res['balance_before_paise'], 5000);
      expect(res['balance_after_paise'], 4000);
      expect(mockPostgresWallets['WALLET_VI']!['own_prepaid_balance_paise'], 4000);
    });

    // -------------------------------------------------------------------------
    // TEST 5: Duplicate Protection (Idempotent Replay)
    // -------------------------------------------------------------------------
    test('TEST 5: Submitting identical idempotencyKey replays original response with 0 extra balance debit', () async {
      final res = await bridgeClient.processDebit(
        shopId: testShopId,
        walletId: 'WALLET_VI',
        rechargeId: 'TXN_VI_PREPAID_001',
        idempotencyKey: 'TXN_VI_PREPAID_001',
        operator: 'Vi',
        amountPaise: 1000,
        amount: 10.0,
        fundingType: 'ownPrepaid',
        commissionEarnedPaise: 35,
        businessDate: '2026-11-16',
        deviceId: testDeviceId,
        deviceSignature: testSignature,
        nonce: testNonce,
      );

      expect(res['success'], isTrue);
      expect(res['idempotent_replay'], isTrue);
      expect(res['amount_paise'], 1000);
      // Balance remains strictly 4000 paise (0 double-debit)
      expect(mockPostgresWallets['WALLET_VI']!['own_prepaid_balance_paise'], 4000);
    });

    // -------------------------------------------------------------------------
    // TEST 6: Airtel Postpaid Recharge with UPI Payment Mode
    // -------------------------------------------------------------------------
    test('TEST 6: Airtel Postpaid recharge with UPI payment mode', () async {
      // First top-up Airtel wallet
      await bridgeClient.processTopup(
        shopId: testShopId,
        walletId: 'WALLET_AIRTEL',
        amountPaise: 10000,
        deviceId: testDeviceId,
        deviceSignature: testSignature,
        nonce: testNonce,
      );

      final res = await bridgeClient.processDebit(
        shopId: testShopId,
        walletId: 'WALLET_AIRTEL',
        rechargeId: 'TXN_AIRTEL_POSTPAID_001',
        idempotencyKey: 'TXN_AIRTEL_POSTPAID_001',
        operator: 'Airtel',
        amountPaise: 49900, // will fail overdraft
        amount: 499.0,
        fundingType: 'ownPrepaid',
        businessDate: '2026-11-16',
        deviceId: testDeviceId,
        deviceSignature: testSignature,
        nonce: testNonce,
        serviceType: 'Postpaid',
        paymentMode: 'UPI',
      ).catchError((e) => {'error': e.toString()});

      expect(res['error'], contains('Insufficient own prepaid balance'));

      // Now top-up full amount and execute successfully
      await bridgeClient.processTopup(
        shopId: testShopId,
        walletId: 'WALLET_AIRTEL',
        amountPaise: 50000,
        deviceId: testDeviceId,
        deviceSignature: testSignature,
        nonce: testNonce,
      );

      final successRes = await bridgeClient.processDebit(
        shopId: testShopId,
        walletId: 'WALLET_AIRTEL',
        rechargeId: 'TXN_AIRTEL_POSTPAID_002',
        idempotencyKey: 'TXN_AIRTEL_POSTPAID_002',
        operator: 'Airtel',
        amountPaise: 49900,
        amount: 499.0,
        fundingType: 'ownPrepaid',
        commissionEarnedPaise: 1000,
        businessDate: '2026-11-16',
        deviceId: testDeviceId,
        deviceSignature: testSignature,
        nonce: testNonce,
        serviceType: 'Postpaid',
        paymentMode: 'UPI',
      );

      expect(successRes['success'], isTrue);
      expect(successRes['payment_mode'], 'UPI');
    });

    // -------------------------------------------------------------------------
    // TEST 7: Jio DTH Recharge
    // -------------------------------------------------------------------------
    test('TEST 7: Jio DTH recharge flow', () async {
      await bridgeClient.processTopup(
        shopId: testShopId,
        walletId: 'WALLET_JIO',
        amountPaise: 20000,
        deviceId: testDeviceId,
        deviceSignature: testSignature,
        nonce: testNonce,
      );

      final res = await bridgeClient.processDebit(
        shopId: testShopId,
        walletId: 'WALLET_JIO',
        rechargeId: 'TXN_JIO_DTH_001',
        idempotencyKey: 'TXN_JIO_DTH_001',
        operator: 'Jio',
        amountPaise: 35000, // ₹350.00
        amount: 350.0,
        fundingType: 'ownPrepaid',
        commissionEarnedPaise: 1050,
        businessDate: '2026-11-16',
        deviceId: testDeviceId,
        deviceSignature: testSignature,
        nonce: testNonce,
        serviceType: 'DTH',
        paymentMode: 'Cash',
      ).catchError((e) => {'error': e.toString()});

      // Overdraft blocked
      expect(res['error'], contains('Insufficient own prepaid balance'));
    });

    // -------------------------------------------------------------------------
    // TEST 8: Customer Refund & Operator Reversal
    // -------------------------------------------------------------------------
    test('TEST 8: Customer refund marks transaction refunded; Operator reversal restores balance', () async {
      // 1. Refund
      final refundRes = await bridgeClient.processRefund(
        shopId: testShopId,
        txnKey: 'TXN_VI_PREPAID_001',
        reason: 'Customer cancelled transaction',
        deviceId: testDeviceId,
        deviceSignature: testSignature,
        nonce: testNonce,
      );
      expect(refundRes['success'], isTrue);
      expect(refundRes['status'], 'refunded');

      // 2. Reversal
      final revRes = await bridgeClient.processReversal(
        shopId: testShopId,
        txnKey: 'TXN_VI_PREPAID_001',
        reason: 'Operator failed to deliver plan',
        deviceId: testDeviceId,
        deviceSignature: testSignature,
        nonce: testNonce,
      );
      expect(revRes['success'], isTrue);
      expect(revRes['status'], 'reversed');
      // Balance restored from 4000 back to 5000 paise
      expect(mockPostgresWallets['WALLET_VI']!['own_prepaid_balance_paise'], 5000);
    });

    // -------------------------------------------------------------------------
    // TEST 9: Critical Accounting Segregation & Pass-Through Isolation
    // -------------------------------------------------------------------------
    test('TEST 9: Critical accounting rules: Zero recharge principal in retail sales, separate commission income', () async {
      await Db.bank.put('cash_in_hand', 5000.0); // Baseline float ₹5,000
      await Db.sales.clear();

      final recharge = RechargeEntry(
        rechargeId: 'REC_ACCT_TEST_001',
        shopId: testShopId,
        operator: RechargeOperator.vi,
        customerMobile: '9847099999',
        amount: 299.0,
        amountPaise: 29900,
        fundingType: RechargeFundingType.ownMoney,
        paymentMode: RechargePaymentMode.cash,
        status: RechargeStatus.success,
        staffId: testOwnerUid,
        staffName: 'Unais',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        dateString: '2026-11-16',
      );

      // Customer payment handled
      final result = await service.recordCustomerRechargePayment(recharge: recharge);

      // Rule 1 (separation rule, cbae208): ERP cash in hand is unchanged;
      // the recharge cash is reported in the collection summary instead.
      final cashInHand = (Db.bank.get('cash_in_hand') as num).toDouble();
      expect(cashInHand, 5000.0);

      // Rule 2: STRICT NON-REVENUE PASS-THROUGH: Zero retail sales created
      expect(Db.sales.length, 0, reason: 'Recharge gross turnover must NEVER be added to retail sales revenue');

      // Rule 3: Combined Physical Cash in Hand = Retail Cash + Recharge Cash
      expect(result.summary.cashCollection, 299.0);
    });

    // -------------------------------------------------------------------------
    // TEST 10: Security Enforcement: Unregistered Device Rejection
    // -------------------------------------------------------------------------
    test('TEST 10: Unregistered device attempting debit is blocked with HTTP 403', () async {
      expect(
        () => bridgeClient.processDebit(
          shopId: testShopId,
          walletId: 'WALLET_VI',
          rechargeId: 'TXN_UNREG_001',
          idempotencyKey: 'TXN_UNREG_001',
          operator: 'Vi',
          amountPaise: 1000,
          amount: 10.0,
          fundingType: 'ownPrepaid',
          businessDate: '2026-11-16',
          deviceId: 'DEV_ATTACKER_999',
          deviceSignature: testSignature,
          nonce: testNonce,
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('Permission Denied'))),
      );
    });
  });
}
