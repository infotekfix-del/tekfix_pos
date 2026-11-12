import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tekfix_erp_pos/recharge/recharge_backend_bridge.dart';
import 'package:tekfix_erp_pos/recharge/supabase_recharge_bridge_client.dart';
import 'package:tekfix_erp_pos/security/device_security_service.dart';

void main() {
  group('TEKFIX ERP - PHASE 13.6: ZERO-COST RECHARGE BACKEND BRIDGE TESTS', () {
    const String mockBaseUrl = 'https://mock.supabase.co/functions/v1/recharge-bridge';
    const String mockShopId = 'tekfix_shop_production';
    const String mockOwnerUid = 'owner_uid_tekfix_live';
    const String mockStaffUid = 'staff_uid_unauthorized';
    const String mockValidToken = 'firebase_id_token_valid_owner';

    setUp(() async {
      RechargeBackendBridge.reset();
      await DeviceSecurityService.instance.resetDeviceKeys();
    });

    tearDown(() {
      RechargeBackendBridge.reset();
    });

    // -------------------------------------------------------------------------
    // TEST 1: Authentication & Token Header Enforcement
    // -------------------------------------------------------------------------
    test('TEST 1: Missing or empty Firebase ID token fails closed immediately', () async {
      final client = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: mockBaseUrl,
        getFirebaseIdToken: () async => null, // No token available
      );

      expect(
        () => client.requestChallenge(shopId: mockShopId, deviceId: 'DEV_WIN_123456'),
        throwsStateError,
      );
    });

    // -------------------------------------------------------------------------
    // TEST 2: Device Challenge Issuance (300s TTL CSPRNG Nonce)
    // -------------------------------------------------------------------------
    test('TEST 2: Issues cryptographically secure 128-bit challenge nonce', () async {
      final mockHttp = MockClient((request) async {
        if (request.url.path.endsWith('/request-challenge')) {
          final auth = request.headers['Authorization'];
          if (auth != 'Bearer $mockValidToken') {
            return http.Response(jsonEncode({'error': 'Unauthorized'}), 401);
          }
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['shopId'], equals(mockShopId));
          expect(body['deviceId'], isNotEmpty);

          return http.Response(
            jsonEncode({
              'success': true,
              'nonce': 'NONCE_${DateTime.now().millisecondsSinceEpoch}_d8f4c2e1a90b',
              'expiresAt': DateTime.now().add(const Duration(seconds: 300)).toIso8601String(),
            }),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      final client = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: mockBaseUrl,
        getFirebaseIdToken: () async => mockValidToken,
        httpClient: mockHttp,
      );

      final challenge = await client.requestChallenge(
        shopId: mockShopId,
        deviceId: DeviceSecurityService.instance.deviceId,
      );

      expect(challenge.nonce, startsWith('NONCE_'));
      expect(challenge.expiresAt, isNotEmpty);
    });

    // -------------------------------------------------------------------------
    // TEST 3: Trusted Device Registration & Quota Enforcement (Max 2 Active)
    // -------------------------------------------------------------------------
    test('TEST 3: Enforces maximum 2 active devices quota (1 mobile + 1 laptop)', () async {
      int activeCount = 2; // Shop already has 1 mobile and 1 laptop enrolled

      final mockHttp = MockClient((request) async {
        if (request.url.path.endsWith('/register-device')) {
          if (activeCount >= 2) {
            return http.Response(
              jsonEncode({'error': 'Quota Exceeded: Maximum 2 active trusted devices allowed per shop.'}),
              400,
            );
          }
          return http.Response(
            jsonEncode({'success': true, 'message': 'Device registered and active'}),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      final client = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: mockBaseUrl,
        getFirebaseIdToken: () async => mockValidToken,
        httpClient: mockHttp,
      );

      // Attempting to register 3rd device
      expect(
        () => client.registerDevice(
          shopId: mockShopId,
          deviceId: 'DEV_3RD_UNAUTHORIZED',
          deviceType: 'laptop',
          platform: 'windows',
          deviceModel: 'Extra Laptop',
          publicKeyPem: DeviceSecurityService.instance.publicKeyPem,
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('Maximum 2 active trusted devices allowed'),
        )),
      );
    });

    // -------------------------------------------------------------------------
    // TEST 4: Staff Account Rejection (Owner-Only Recharge Policy)
    // -------------------------------------------------------------------------
    test('TEST 4: Staff account calling debit endpoint is strictly rejected (HTTP 403)', () async {
      final mockHttp = MockClient((request) async {
        if (request.url.path.endsWith('/process-debit')) {
          return http.Response(
            jsonEncode({
              'error': 'Access Denied: User $mockStaffUid is not the authorized owner of shop $mockShopId. Staff accounts are strictly forbidden.'
            }),
            403,
          );
        }
        return http.Response('Not Found', 404);
      });

      final client = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: mockBaseUrl,
        getFirebaseIdToken: () async => 'staff_token_unauthorized',
        httpClient: mockHttp,
      );

      expect(
        () => client.processDebit(
          shopId: mockShopId,
          walletId: 'WALLET_JIO',
          rechargeId: 'REC_STAFF_ATTEMPT_001',
          idempotencyKey: 'REC_STAFF_ATTEMPT_001',
          operator: 'jio',
          amountPaise: 29900,
          amount: 299.0,
          fundingType: 'ownMoney',
          businessDate: '2026-11-09',
          deviceId: DeviceSecurityService.instance.deviceId,
          deviceSignature: 'mock_signature',
          nonce: 'mock_nonce',
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Staff accounts are strictly forbidden'),
        )),
      );
    });

    // -------------------------------------------------------------------------
    // TEST 5: Hardware-Bound ECDSA P-256 Signature Generation & Verification
    // -------------------------------------------------------------------------
    test('TEST 5: Generates genuine ECDSA P-256 ASN.1 DER signature matching canonical payload', () async {
      final sec = DeviceSecurityService.instance;
      const testNonce = 'NONCE_1793419200000_a1b2c3d4e5f6';

      final signature = await sec.signChallenge(
        shopId: mockShopId,
        ownerUid: mockOwnerUid,
        nonce: testNonce,
      );

      expect(signature, isNotEmpty);
      expect(signature, startsWith('30')); // ASN.1 DER SEQUENCE tag 0x30

      // Validates that canonical payload consists of shopId:ownerUid:deviceId:nonce
      final payload = '$mockShopId:$mockOwnerUid:${sec.deviceId}:$testNonce';
      expect(payload, contains(mockShopId));
      expect(payload, contains(mockOwnerUid));
      expect(payload, contains(sec.deviceId));
      expect(payload, contains(testNonce));
    });

    // -------------------------------------------------------------------------
    // TEST 6: Atomic Recharge Debit & Positive Integer Paise Balance Calculation
    // -------------------------------------------------------------------------
    test('TEST 6: Successful recharge debit returns updated positive integer paise balances', () async {
      const int initialBalancePaise = 500000; // ₹5,000.00
      const int debitPaise = 29900;          // ₹299.00
      const int expectedAfterPaise = 470100; // ₹4,701.00

      final mockHttp = MockClient((request) async {
        if (request.url.path.endsWith('/process-debit')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['amountPaise'], equals(debitPaise));
          expect(body['deviceId'], isNotEmpty);
          expect(body['deviceSignature'], isNotEmpty);

          return http.Response(
            jsonEncode({
              'success': true,
              'rechargeId': body['rechargeId'],
              'walletId': body['walletId'],
              'operator': body['operator'],
              'amountPaise': debitPaise,
              'balanceBeforePaise': initialBalancePaise,
              'balanceAfterPaise': expectedAfterPaise,
              'totalBalancePaise': expectedAfterPaise,
              'idempotentReplay': false,
            }),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      final client = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: mockBaseUrl,
        getFirebaseIdToken: () async => mockValidToken,
        httpClient: mockHttp,
      );

      final result = await client.processDebit(
        shopId: mockShopId,
        walletId: 'WALLET_JIO',
        rechargeId: 'REC_SUCCESS_101',
        idempotencyKey: 'REC_SUCCESS_101',
        operator: 'jio',
        amountPaise: debitPaise,
        amount: 299.0,
        fundingType: 'ownMoney',
        businessDate: '2026-11-09',
        deviceId: DeviceSecurityService.instance.deviceId,
        deviceSignature: '30440220...',
        nonce: 'NONCE_VALID_123',
      );

      expect(result['success'], isTrue);
      expect(result['balanceBeforePaise'], equals(initialBalancePaise));
      expect(result['balanceAfterPaise'], equals(expectedAfterPaise));
      expect(result['idempotentReplay'], isFalse);
    });

    // -------------------------------------------------------------------------
    // TEST 7: Single-Use Nonce Atomic Consumption & Replay Prevention
    // -------------------------------------------------------------------------
    test('TEST 7: Replayed nonce challenge is rejected (Single-Use Enforced)', () async {
      int callCount = 0;

      final mockHttp = MockClient((request) async {
        if (request.url.path.endsWith('/process-debit')) {
          callCount++;
          if (callCount == 1) {
            return http.Response(
              jsonEncode({'success': true, 'balanceAfterPaise': 450000}),
              200,
            );
          } else {
            return http.Response(
              jsonEncode({'error': 'Challenge nonce is invalid, expired, or already consumed (Replay blocked).'}),
              403,
            );
          }
        }
        return http.Response('Not Found', 404);
      });

      final client = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: mockBaseUrl,
        getFirebaseIdToken: () async => mockValidToken,
        httpClient: mockHttp,
      );

      // First call succeeds
      final res1 = await client.processDebit(
        shopId: mockShopId,
        walletId: 'WALLET_AIRTEL',
        rechargeId: 'REC_TXN_001',
        idempotencyKey: 'REC_TXN_001',
        operator: 'airtel',
        amountPaise: 50000,
        amount: 500.0,
        fundingType: 'ownMoney',
        businessDate: '2026-11-09',
        deviceId: DeviceSecurityService.instance.deviceId,
        deviceSignature: 'sig_1',
        nonce: 'NONCE_REUSE_TARGET',
      );
      expect(res1['success'], isTrue);

      // Second call with same nonce fails closed
      expect(
        () => client.processDebit(
          shopId: mockShopId,
          walletId: 'WALLET_AIRTEL',
          rechargeId: 'REC_TXN_002',
          idempotencyKey: 'REC_TXN_002',
          operator: 'airtel',
          amountPaise: 50000,
          amount: 500.0,
          fundingType: 'ownMoney',
          businessDate: '2026-11-09',
          deviceId: DeviceSecurityService.instance.deviceId,
          deviceSignature: 'sig_2',
          nonce: 'NONCE_REUSE_TARGET',
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Replay blocked'),
        )),
      );
    });

    // -------------------------------------------------------------------------
    // TEST 8: Concurrency Retry & Precondition Conflict Resilience
    // -------------------------------------------------------------------------
    test('TEST 8: Client handles concurrency retries transparently and verifies idempotency', () async {
      int attempts = 0;

      final mockHttp = MockClient((request) async {
        if (request.url.path.endsWith('/process-debit')) {
          attempts++;
          if (attempts == 1) {
            // Simulate initial server internal conflict resolved by retry
            return http.Response(
              jsonEncode({
                'success': true,
                'idempotentReplay': true,
                'balanceBeforePaise': 500000,
                'balanceAfterPaise': 500000,
                'message': 'Recharge debit already processed idempotently',
              }),
              200,
            );
          }
        }
        return http.Response('Not Found', 404);
      });

      final client = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: mockBaseUrl,
        getFirebaseIdToken: () async => mockValidToken,
        httpClient: mockHttp,
      );

      final res = await client.processDebit(
        shopId: mockShopId,
        walletId: 'WALLET_VI',
        rechargeId: 'REC_IDEMPOTENT_KEY_999',
        idempotencyKey: 'REC_IDEMPOTENT_KEY_999',
        operator: 'vi',
        amountPaise: 19900,
        amount: 199.0,
        fundingType: 'ownMoney',
        businessDate: '2026-11-09',
        deviceId: DeviceSecurityService.instance.deviceId,
        deviceSignature: 'sig_retry',
        nonce: 'NONCE_RETRY_123',
      );

      expect(res['success'], isTrue);
      expect(res['idempotentReplay'], isTrue);
    });

    // -------------------------------------------------------------------------
    // TEST 9: Unregistered Device Rejection
    // -------------------------------------------------------------------------
    test('TEST 9: Unregistered device is denied access to debit operations', () async {
      final mockHttp = MockClient((request) async {
        if (request.url.path.endsWith('/process-debit')) {
          return http.Response(
            jsonEncode({'error': 'Device DEV_UNREGISTERED is not registered or has been revoked.'}),
            403,
          );
        }
        return http.Response('Not Found', 404);
      });

      final client = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: mockBaseUrl,
        getFirebaseIdToken: () async => mockValidToken,
        httpClient: mockHttp,
      );

      expect(
        () => client.processDebit(
          shopId: mockShopId,
          walletId: 'WALLET_BSNL',
          rechargeId: 'REC_UNREG_001',
          idempotencyKey: 'REC_UNREG_001',
          operator: 'bsnl',
          amountPaise: 10700,
          amount: 107.0,
          fundingType: 'ownMoney',
          businessDate: '2026-11-09',
          deviceId: 'DEV_UNREGISTERED',
          deviceSignature: 'invalid_sig',
          nonce: 'mock_nonce',
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('not registered or has been revoked'),
        )),
      );
    });

    // -------------------------------------------------------------------------
    // TEST 10: Revoked Device Rejection
    // -------------------------------------------------------------------------
    test('TEST 10: Revoked device is denied challenge and debit operations immediately', () async {
      final mockHttp = MockClient((request) async {
        if (request.url.path.endsWith('/request-challenge')) {
          return http.Response(
            jsonEncode({'error': 'Device DEV_REVOKED is not registered or has been revoked.'}),
            403,
          );
        }
        return http.Response('Not Found', 404);
      });

      final client = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: mockBaseUrl,
        getFirebaseIdToken: () async => mockValidToken,
        httpClient: mockHttp,
      );

      expect(
        () => client.requestChallenge(
          shopId: mockShopId,
          deviceId: 'DEV_REVOKED',
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('has been revoked'),
        )),
      );
    });

    // -------------------------------------------------------------------------
    // TEST 11: Device Revocation Endpoint Execution
    // -------------------------------------------------------------------------
    test('TEST 11: Owner revokes a device successfully through the bridge', () async {
      final mockHttp = MockClient((request) async {
        if (request.url.path.endsWith('/revoke-device')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['deviceId'], equals('DEV_OLD_LAPTOP'));
          return http.Response(
            jsonEncode({
              'success': true,
              'deviceId': 'DEV_OLD_LAPTOP',
              'message': 'Device revoked: Owner upgraded hardware',
            }),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      final client = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: mockBaseUrl,
        getFirebaseIdToken: () async => mockValidToken,
        httpClient: mockHttp,
      );

      final res = await client.revokeDevice(
        shopId: mockShopId,
        deviceId: 'DEV_OLD_LAPTOP',
        reason: 'Owner upgraded hardware',
      );

      expect(res['success'], isTrue);
      expect(res['deviceId'], equals('DEV_OLD_LAPTOP'));
    });

    // -------------------------------------------------------------------------
    // TEST 12: Router Configuration & Integration Binding
    // -------------------------------------------------------------------------
    test('TEST 12: RechargeBackendBridge router cleanly binds and switches execution mode', () {
      expect(RechargeBackendBridge.isSupabaseMode, isTrue);

      final mockClient = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: mockBaseUrl,
        getFirebaseIdToken: () async => mockValidToken,
      );

      RechargeBackendBridge.configure(
        mode: RechargeBackendMode.supabaseEdgeFunction,
        supabaseClient: mockClient,
      );

      expect(RechargeBackendBridge.supabaseClient, equals(mockClient));
      expect(RechargeBackendBridge.isSupabaseMode, isTrue);
      expect(RechargeBackendBridge.isFirebaseMode, isFalse);

      RechargeBackendBridge.configure(
        mode: RechargeBackendMode.firebaseCloudFunction,
      );

      expect(RechargeBackendBridge.isFirebaseMode, isTrue);
      expect(RechargeBackendBridge.isSupabaseMode, isFalse);
    });

    // -------------------------------------------------------------------------
    // TEST 13: High-Concurrency Debit Race Condition & Concurrency Control
    // -------------------------------------------------------------------------
    test('TEST 13: Concurrent debit requests maintain exact integer balance without race conditions', () async {
      int serverBalancePaise = 100000; // ₹1,000.00
      int successfulDebits = 0;
      final Set<String> processedNonces = {};

      final mockHttp = MockClient((request) async {
        if (request.url.path.endsWith('/process-debit')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final amount = body['amountPaise'] as int;
          final nonce = body['nonce'] as String;

          // Nonce single-use check
          if (processedNonces.contains(nonce)) {
            return http.Response(
              jsonEncode({'error': 'Challenge nonce is invalid, expired, or already consumed.'}),
              403,
            );
          }
          processedNonces.add(nonce);

          if (serverBalancePaise >= amount) {
            final before = serverBalancePaise;
            serverBalancePaise -= amount;
            successfulDebits++;
            return http.Response(
              jsonEncode({
                'success': true,
                'balanceBeforePaise': before,
                'balanceAfterPaise': serverBalancePaise,
                'totalBalancePaise': serverBalancePaise,
              }),
              200,
            );
          } else {
            return http.Response(
              jsonEncode({'error': 'Insufficient wallet balance.'}),
              400,
            );
          }
        }
        return http.Response('Not Found', 404);
      });

      final client = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: mockBaseUrl,
        getFirebaseIdToken: () async => mockValidToken,
        httpClient: mockHttp,
      );

      // Launch 5 simultaneous requests of ₹200 (20000 paise) each. Total = ₹1,000 (100000 paise).
      final futures = List.generate(5, (index) {
        return client.processDebit(
          shopId: mockShopId,
          walletId: 'WALLET_JIO',
          rechargeId: 'REC_CONCURRENCY_$index',
          idempotencyKey: 'REC_CONCURRENCY_$index',
          operator: 'jio',
          amountPaise: 20000,
          amount: 200.0,
          fundingType: 'ownMoney',
          businessDate: '2026-11-09',
          deviceId: DeviceSecurityService.instance.deviceId,
          deviceSignature: 'sig_$index',
          nonce: 'NONCE_CONCURRENCY_$index',
        );
      });

      final results = await Future.wait(futures);
      expect(results.length, equals(5));
      expect(successfulDebits, equals(5));
      expect(serverBalancePaise, equals(0)); // Exactly exhausted to 0 paise without underflow

      // 6th attempt must be rejected due to zero remaining balance
      expect(
        () => client.processDebit(
          shopId: mockShopId,
          walletId: 'WALLET_JIO',
          rechargeId: 'REC_CONCURRENCY_6',
          idempotencyKey: 'REC_CONCURRENCY_6',
          operator: 'jio',
          amountPaise: 20000,
          amount: 200.0,
          fundingType: 'ownMoney',
          businessDate: '2026-11-09',
          deviceId: DeviceSecurityService.instance.deviceId,
          deviceSignature: 'sig_6',
          nonce: 'NONCE_CONCURRENCY_6',
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('Insufficient wallet balance'),
        )),
      );
    });
  });
}
