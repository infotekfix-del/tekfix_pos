import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tekfix_erp_pos/recharge/recharge_backend_bridge.dart';
import 'package:tekfix_erp_pos/recharge/supabase_recharge_bridge_client.dart';

void main() {
  group('TEKFIX ERP - PHASE 14.9.2: SECURE ALL-ENDPOINT HARDWARE INTEGRATION TESTS', () {
    const testShopId = 'shop_test_149';
    const testOwnerUid = 'uid_owner_149';
    const testToken = 'valid_firebase_id_token_149';
    const testDeviceId = 'DEV_TEST_ANDROID';
    const testNonce = 'NONCE_TEST_12345';
    const testSignature = 'VALID_ECDSA_DER_SIG';

    late MockClient mockHttpClient;
    late SupabaseRechargeBridgeClient bridgeClient;

    final Map<String, dynamic> dbWallets = {
      'WALLET_AIRTEL': {
        'shop_id': testShopId,
        'wallet_id': 'WALLET_AIRTEL',
        'operator': 'airtel',
        'own_prepaid_balance_paise': 50000,
        'distributor_credit_balance_paise': 20000,
        'total_balance_paise': 70000,
        'last_updated_at': DateTime.now().toIso8601String(),
      },
    };

    final Map<String, dynamic> dbDistributors = {
      'DIST_001': {
        'shop_id': testShopId,
        'distributor_id': 'DIST_001',
        'name': 'Airtel Agency',
        'outstanding_balance_paise': 20000,
      },
    };

    setUp(() {
      mockHttpClient = MockClient((request) async {
        final path = request.url.path;
        final body = jsonDecode(request.body) as Map<String, dynamic>;

        // Verify Firebase JWT Header
        final authHeader = request.headers['Authorization'] ?? '';
        if (authHeader != 'Bearer $testToken') {
          return http.Response(jsonEncode({'error': 'Unauthorized: Invalid token'}), 401);
        }

        // Verify Hardware Security on every financial modification endpoint
        if (path.endsWith('/process-topup') ||
            path.endsWith('/process-distributor-load') ||
            path.endsWith('/process-distributor-settlement') ||
            path.endsWith('/process-refund') ||
            path.endsWith('/process-reversal') ||
            path.endsWith('/process-reconciliation') ||
            path.endsWith('/process-debit')) {
          final dId = body['deviceId'];
          final sig = body['deviceSignature'];
          final nonce = body['nonce'];

          if (dId == null || dId.toString().isEmpty || sig == null || nonce == null) {
            return http.Response(jsonEncode({'error': 'Trusted Device Error: deviceId, nonce, and deviceSignature required'}), 403);
          }

          if (dId == 'REVOKED_DEVICE') {
            return http.Response(jsonEncode({'error': 'Device has been revoked'}), 403);
          }

          if (sig == 'INVALID_SIG') {
            return http.Response(jsonEncode({'error': 'Cryptographic signature verification failed'}), 403);
          }
        }

        // Endpoint: get-wallet (Read-Only)
        if (path.endsWith('/get-wallet')) {
          final wId = body['walletId'];
          if (dbWallets.containsKey(wId)) {
            return http.Response(jsonEncode({'success': true, 'wallet': dbWallets[wId]}), 200);
          }
          return http.Response(jsonEncode({'success': true, 'wallet': null}), 200);
        }

        // Endpoint: process-topup
        if (path.endsWith('/process-topup')) {
          final wId = body['walletId'] as String;
          final amountPaise = body['amountPaise'] as int;
          final w = dbWallets[wId];
          final before = w['total_balance_paise'] as int;
          w['own_prepaid_balance_paise'] = (w['own_prepaid_balance_paise'] as int) + amountPaise;
          w['total_balance_paise'] = (w['own_prepaid_balance_paise'] as int) + (w['distributor_credit_balance_paise'] as int);

          return http.Response(jsonEncode({
            'success': true,
            'wallet_id': wId,
            'balance_before_paise': before,
            'balance_after_paise': w['total_balance_paise'],
          }), 200);
        }

        // Endpoint: process-distributor-load
        if (path.endsWith('/process-distributor-load')) {
          final wId = body['walletId'] as String;
          final distId = body['distributorId'] as String;
          final amountPaise = body['amountPaise'] as int;
          final w = dbWallets[wId];
          final dist = dbDistributors[distId];

          w['distributor_credit_balance_paise'] = (w['distributor_credit_balance_paise'] as int) + amountPaise;
          w['total_balance_paise'] = (w['own_prepaid_balance_paise'] as int) + (w['distributor_credit_balance_paise'] as int);
          dist['outstanding_balance_paise'] = (dist['outstanding_balance_paise'] as int) + amountPaise;

          return http.Response(jsonEncode({
            'success': true,
            'wallet_id': wId,
            'distributor_id': distId,
            'distributor_credit_balance_paise': w['distributor_credit_balance_paise'],
            'outstanding_balance_paise': dist['outstanding_balance_paise'],
          }), 200);
        }

        // Endpoint: process-refund
        if (path.endsWith('/process-refund')) {
          final txnKey = body['txnKey'] as String;
          if (txnKey == 'TXN_ALREADY_REVERSED') {
            return http.Response(jsonEncode({'error': 'Transaction is already reversed; cannot refund'}), 400);
          }
          return http.Response(jsonEncode({
            'success': true,
            'txn_key': txnKey,
            'amount_paise': 29900,
          }), 200);
        }

        // Endpoint: process-reversal
        if (path.endsWith('/process-reversal')) {
          final txnKey = body['txnKey'] as String;
          if (txnKey == 'TXN_ALREADY_REFUNDED') {
            return http.Response(jsonEncode({'error': 'Transaction is already refunded; cannot reverse'}), 400);
          }
          return http.Response(jsonEncode({
            'success': true,
            'txn_key': txnKey,
            'amount_paise': 19900,
          }), 200);
        }

        // Endpoint: register-device (Cross-Signing Check)
        if (path.endsWith('/register-device')) {
          final authorizingDeviceId = body['authorizingDeviceId'];
          if (authorizingDeviceId == null && body['deviceId'] == 'DEV_SECOND_DEVICE') {
            return http.Response(jsonEncode({'error': 'Secondary Enrollment Gate: Enrolling a second device requires mutual cross-signing'}), 403);
          }
          return http.Response(jsonEncode({'success': true, 'message': 'Device registered'}), 200);
        }

        return http.Response(jsonEncode({'error': 'Not found'}), 404);
      });

      bridgeClient = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: 'https://test-project.supabase.co/functions/v1/recharge-bridge',
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

    test('TEST 1: Missing hardware signature on topup is strictly rejected (HTTP 403)', () async {
      expect(
        () => bridgeClient.processTopup(
          shopId: testShopId,
          walletId: 'WALLET_AIRTEL',
          amountPaise: 25000,
          deviceId: '', // Missing
          deviceSignature: '',
          nonce: '',
        ),
        throwsStateError,
      );
    });

    test('TEST 2: Stolen owner token calling refund without device signature is blocked (HTTP 403)', () async {
      expect(
        () => bridgeClient.processRefund(
          shopId: testShopId,
          txnKey: 'TXN_TARGET',
          reason: 'Unauthorized attempt',
          deviceId: '', // No hardware key
          deviceSignature: '',
          nonce: '',
        ),
        throwsStateError,
      );
    });

    test('TEST 3: Revoked device attempting topup is immediately rejected (HTTP 403)', () async {
      expect(
        () => bridgeClient.processTopup(
          shopId: testShopId,
          walletId: 'WALLET_AIRTEL',
          amountPaise: 25000,
          deviceId: 'REVOKED_DEVICE',
          deviceSignature: testSignature,
          nonce: testNonce,
        ),
        throwsStateError,
      );
    });

    test('TEST 4: Tampered/Invalid signature on distributor load is rejected (HTTP 403)', () async {
      expect(
        () => bridgeClient.processDistributorLoad(
          shopId: testShopId,
          walletId: 'WALLET_AIRTEL',
          distributorId: 'DIST_001',
          amountPaise: 25000,
          deviceId: testDeviceId,
          deviceSignature: 'INVALID_SIG',
          nonce: testNonce,
        ),
        throwsStateError,
      );
    });

    test('TEST 5: Legitimate topup with valid hardware signature succeeds', () async {
      final res = await bridgeClient.processTopup(
        shopId: testShopId,
        walletId: 'WALLET_AIRTEL',
        amountPaise: 25000,
        deviceId: testDeviceId,
        deviceSignature: testSignature,
        nonce: testNonce,
      );

      expect(res['success'], true);
      expect(res['balance_after_paise'], 95000);
    });

    test('TEST 6: Second device enrollment without existing device cross-signing is rejected (HTTP 403)', () async {
      expect(
        () => bridgeClient.registerDevice(
          shopId: testShopId,
          deviceId: 'DEV_SECOND_DEVICE',
          deviceType: 'laptop',
          platform: 'windows',
          deviceModel: 'HP EliteBook',
          publicKeyPem: 'PUBLIC_KEY_PEM',
          // Omit authorizingDeviceId
        ),
        throwsStateError,
      );
    });

    test('TEST 7: Refund on already-reversed transaction is rejected by SQL procedure (Double-Restitution Blocked)', () async {
      expect(
        () => bridgeClient.processRefund(
          shopId: testShopId,
          txnKey: 'TXN_ALREADY_REVERSED',
          reason: 'Customer request',
          deviceId: testDeviceId,
          deviceSignature: testSignature,
          nonce: testNonce,
        ),
        throwsArgumentError,
      );
    });

    test('TEST 8: Reversal on already-refunded transaction is rejected by SQL procedure (Double-Restitution Blocked)', () async {
      expect(
        () => bridgeClient.processReversal(
          shopId: testShopId,
          txnKey: 'TXN_ALREADY_REFUNDED',
          reason: 'Operator failed',
          deviceId: testDeviceId,
          deviceSignature: testSignature,
          nonce: testNonce,
        ),
        throwsArgumentError,
      );
    });
  });
}
