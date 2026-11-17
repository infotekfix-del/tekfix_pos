import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tekfix_erp_pos/recharge/recharge_backend_bridge.dart';
import 'package:tekfix_erp_pos/recharge/supabase_recharge_bridge_client.dart';
import 'package:tekfix_erp_pos/security/device_security_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TEKFIX ERP — ANDROID DEVICE RECOVERY & RE-ENROLLMENT VERIFICATION', () {
    const String testShopId = 'tekfix';
    const String testOwnerUid = 'ShjbKbg8HsabkQjEGnlp03unezi2';
    const String testStaffUid = 'staff_unauthorized_user_123';
    const String validOwnerToken = 'valid_owner_token_tekfix';
    const String staffToken = 'valid_staff_token_tekfix';

    // Windows Laptop Device (Unchanged, Authoritative active device)
    const String windowsDeviceId = 'DEV_WIN_886EF8';
    const String windowsPublicKeyPem = 'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAER886EF8_MOCK_WIN_KEY_FOR_TESTING_DATA==';

    // Old uninstalled phone device
    const String oldAndroidDeviceId = 'DEV_ANDR_49246D';

    // New physical handset device generated on TECNO KM9 after reinstallation
    const String newAndroidDeviceId = 'DEV_ANDR_66A1E0';
    const String newAndroidPublicKeyPem = 'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEZ9aUTWkurXb7WYLcUl8l921tog9weA7I5l9tg8KKeO8wLOE+VP8jNb364diaQbbjbgmBd8lWWEvecVxet140Ng==';

    // Server-side state
    final List<Map<String, dynamic>> dbDevices = [
      {
        'device_id': windowsDeviceId,
        'shop_id': testShopId,
        'owner_uid': testOwnerUid,
        'device_type': 'laptop',
        'platform': 'windows',
        'device_model': 'Owner POS Laptop',
        'public_key_pem': windowsPublicKeyPem,
        'is_active': true,
        'is_revoked': false,
        'enrolled_at': '2026-11-17T10:30:00Z',
        'last_verified_at': '2026-11-17T10:30:00Z',
      },
      {
        'device_id': oldAndroidDeviceId,
        'shop_id': testShopId,
        'owner_uid': testOwnerUid,
        'device_type': 'mobile',
        'platform': 'android',
        'device_model': 'TECNO KM9',
        'public_key_pem': 'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAELXtgc87oY2DcWZb5JCL0cj5cV+X6hSpPfD8imPaskLAhfCN3fzMfXlA8T9/SEzhyNAs+qk9NpPMDXJJyj7azUA==',
        'is_active': true,
        'is_revoked': false,
        'enrolled_at': '2026-11-16T12:21:20Z',
        'last_verified_at': '2026-11-17T10:06:03Z',
      },
    ];

    late MockClient mockClient;
    late SupabaseRechargeBridgeClient bridgeClient;

    setUp(() {
      mockClient = MockClient((request) async {
        final authHeader = request.headers['Authorization'] ?? '';
        final isOwnerAuth = authHeader == 'Bearer $validOwnerToken';
        final isStaffAuth = authHeader == 'Bearer $staffToken';

        if (!authHeader.startsWith('Bearer ')) {
          return http.Response(jsonEncode({'error': 'Missing or malformed Authorization header'}), 401);
        }

        final path = request.url.path;
        final body = jsonDecode(request.body.isNotEmpty ? request.body : '{}') as Map<String, dynamic>;

        // 1. GET DEVICES
        if (path.endsWith('/get-devices')) {
          if (!isOwnerAuth) {
            return http.Response(jsonEncode({'error': 'Access Denied: Owner only'}), 403);
          }
          final active = dbDevices.where((d) => d['shop_id'] == body['shopId']).toList();
          return http.Response(jsonEncode({
            'success': true,
            'devices': active.map((d) => {
              'deviceId': d['device_id'],
              'shopId': d['shop_id'],
              'ownerUid': d['owner_uid'],
              'deviceType': d['device_type'],
              'platform': d['platform'],
              'deviceModel': d['device_model'],
              'isActive': d['is_active'],
              'isRevoked': d['is_revoked'],
              'enrolledAt': d['enrolled_at'],
              'lastVerifiedAt': d['last_verified_at'],
            }).toList(),
          }), 200);
        }

        // 2. REQUEST CHALLENGE
        if (path.endsWith('/request-challenge')) {
          if (!isOwnerAuth) {
            return http.Response(jsonEncode({'error': 'Access Denied: Owner only'}), 403);
          }
          return http.Response(jsonEncode({
            'success': true,
            'nonce': 'NONCE_RECOVERY_${DateTime.now().millisecondsSinceEpoch}',
            'expiresAt': DateTime.now().add(const Duration(seconds: 300)).toIso8601String(),
          }), 200);
        }

        // 3. REVOKE DEVICE
        if (path.endsWith('/revoke-device')) {
          if (!isOwnerAuth) {
            return http.Response(jsonEncode({'error': 'Access Denied: Owner only'}), 403);
          }
          final targetId = body['deviceId'] as String?;
          final dev = dbDevices.firstWhere(
            (d) => d['device_id'] == targetId && d['shop_id'] == body['shopId'],
            orElse: () => {},
          );
          if (dev.isEmpty) {
            return http.Response(jsonEncode({'error': 'Device not found'}), 404);
          }
          dev['is_active'] = false;
          dev['is_revoked'] = true;
          dev['last_verified_at'] = DateTime.now().toIso8601String();
          return http.Response(jsonEncode({
            'success': true,
            'deviceId': targetId,
            'status': 'REVOKED',
            'reason': body['reason'] ?? 'Revoked by owner',
          }), 200);
        }

        // 4. REGISTER DEVICE
        if (path.endsWith('/register-device')) {
          if (!isOwnerAuth) {
            return http.Response(jsonEncode({'error': 'Access Denied: Owner only'}), 403);
          }
          final deviceId = body['deviceId'] as String;
          final deviceType = body['deviceType'] as String;
          final platform = body['platform'] as String;
          final pubKey = body['publicKeyPem'] as String;
          final authDevId = body['authorizingDeviceId'] as String?;
          final authSig = body['authorizingSignature'] as String?;
          final nonce = body['nonce'] as String?;

          final activeList = dbDevices.where((d) => d['is_active'] == true && d['is_revoked'] == false).toList();

          // Check if same type active
          final sameType = activeList.firstWhere(
            (d) => d['device_type'] == deviceType && d['device_id'] != deviceId,
            orElse: () => {},
          );
          if (sameType.isNotEmpty) {
            return http.Response(jsonEncode({
              'error': 'Quota Exceeded: A trusted $deviceType (${sameType['device_id']}) is already registered. Revoke it before replacing.',
            }), 400);
          }

          if (activeList.length >= 2) {
            return http.Response(jsonEncode({
              'error': 'Quota Exceeded: Maximum 2 active trusted devices allowed per shop (1 mobile + 1 laptop).',
            }), 400);
          }

          // Case 2: Secondary enrollment gate requires cross-signing from existing device
          if (activeList.length == 1) {
            final existing = activeList[0];
            if (authDevId == null || authSig == null || nonce == null) {
              return http.Response(jsonEncode({
                'error': 'Secondary Enrollment Gate: Enrolling a second device requires mutual cross-signing from existing trusted device ${existing['device_id']}',
              }), 403);
            }
            if (authDevId != existing['device_id']) {
              return http.Response(jsonEncode({'error': 'Authorizing device mismatch'}), 403);
            }
            if (authSig.isEmpty || !authSig.startsWith('VALID_SIG_')) {
              return http.Response(jsonEncode({'error': 'Secondary device authorization failed: Invalid signature'}), 403);
            }
          }

          // Register new device
          dbDevices.add({
            'device_id': deviceId,
            'shop_id': testShopId,
            'owner_uid': testOwnerUid,
            'device_type': deviceType,
            'platform': platform,
            'device_model': body['deviceModel'] ?? 'Unknown',
            'public_key_pem': pubKey,
            'is_active': true,
            'is_revoked': false,
            'enrolled_at': DateTime.now().toIso8601String(),
            'last_verified_at': DateTime.now().toIso8601String(),
          });

          return http.Response(jsonEncode({
            'success': true,
            'deviceId': deviceId,
            'deviceType': deviceType,
            'platform': platform,
            'status': 'ENROLLED',
          }), 200);
        }

        // 5. PROCESS DEBIT (RECHARGE)
        if (path.endsWith('/process-debit')) {
          if (!isOwnerAuth) {
            return http.Response(jsonEncode({'error': 'Access Denied: Owner only'}), 403);
          }
          final devId = body['deviceId'] as String?;
          final activeDev = dbDevices.firstWhere(
            (d) => d['device_id'] == devId && d['is_active'] == true && d['is_revoked'] == false,
            orElse: () => {},
          );
          if (activeDev.isEmpty) {
            return http.Response(jsonEncode({'error': 'Forbidden: Device $devId is not an authorized trusted device'}), 403);
          }
          return http.Response(jsonEncode({
            'success': true,
            'rechargeId': body['rechargeId'],
            'amountPaise': body['amountPaise'],
            'commissionEarnedPaise': body['commissionEarnedPaise'],
            'status': 'SUCCESS',
          }), 200);
        }

        return http.Response(jsonEncode({'error': 'Not Found'}), 404);
      });

      bridgeClient = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: 'https://bxjlqcqcjfifzjrqpcov.supabase.co/functions/v1/recharge-bridge',
        getFirebaseIdToken: () async => validOwnerToken,
        httpClient: mockClient,
      );
      RechargeBackendBridge.configure(
        mode: RechargeBackendMode.supabaseEdgeFunction,
        supabaseClient: bridgeClient,
      );
    });

    test('STEP 1: Initial State Inspection confirms 2 registered devices (1 mobile + 1 laptop)', () async {
      final devices = await bridgeClient.getDevices(shopId: testShopId);
      expect(devices.length, equals(2));

      final mobile = devices.firstWhere((d) => d['deviceType'] == 'mobile');
      expect(mobile['deviceId'], equals(oldAndroidDeviceId));
      expect(mobile['isActive'], isTrue);

      final laptop = devices.firstWhere((d) => d['deviceType'] == 'laptop');
      expect(laptop['deviceId'], equals(windowsDeviceId));
      expect(laptop['isActive'], isTrue);
    });

    test('STEP 2: Attempting to register new phone without revoking old phone is BLOCKED by Quota', () async {
      expect(
        bridgeClient.registerDevice(
          shopId: testShopId,
          deviceId: newAndroidDeviceId,
          deviceType: 'mobile',
          platform: 'android',
          deviceModel: 'TECNO KM9 Reinstalled',
          publicKeyPem: newAndroidPublicKeyPem,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('STEP 3: Active Owner Windows Terminal revokes old uninstalled phone key DEV_ANDR_49246D', () async {
      final res = await bridgeClient.revokeDevice(
        shopId: testShopId,
        deviceId: oldAndroidDeviceId,
        reason: 'Owner phone uninstalled, re-enrolling replacement hardware key',
      );

      expect(res['success'], isTrue);
      expect(res['status'], equals('REVOKED'));

      // Verify active devices count is now exactly 1 (Windows laptop only)
      final devices = await bridgeClient.getDevices(shopId: testShopId);
      final active = devices.where((d) => d['isActive'] == true && d['isRevoked'] == false).toList();
      expect(active.length, equals(1));
      expect(active[0]['deviceId'], equals(windowsDeviceId));
    });

    test('STEP 4: Cross-authorized enrollment of new phone DEV_ANDR_66A1E0 signed by Windows terminal DEV_WIN_886EF8', () async {
      // 1. Request fresh challenge nonce
      final challenge = await bridgeClient.requestChallenge(shopId: testShopId, deviceId: windowsDeviceId);
      expect(challenge.nonce, startsWith('NONCE_RECOVERY_'));

      // 2. Windows terminal cross-signs the enrollment payload
      const authSig = 'VALID_SIG_ENROLL_DEV_ANDR_66A1E0_BY_DEV_WIN_886EF8';

      // 3. Register new device with cross-signing
      final regRes = await bridgeClient.registerDevice(
        shopId: testShopId,
        deviceId: newAndroidDeviceId,
        deviceType: 'mobile',
        platform: 'android',
        deviceModel: 'TECNO KM9 (Recovered)',
        publicKeyPem: newAndroidPublicKeyPem,
        authorizingDeviceId: windowsDeviceId,
        authorizingSignature: authSig,
        nonce: challenge.nonce,
      );

      expect(regRes['success'], isTrue);
      expect(regRes['deviceId'], equals(newAndroidDeviceId));
      expect(regRes['status'], equals('ENROLLED'));

      // Verify active devices is exactly 2: DEV_WIN_886EF8 and DEV_ANDR_66A1E0
      final devices = await bridgeClient.getDevices(shopId: testShopId);
      final active = devices.where((d) => d['isActive'] == true && d['isRevoked'] == false).toList();
      expect(active.length, equals(2));

      final activeIds = active.map((d) => d['deviceId']).toSet();
      expect(activeIds, containsAll([windowsDeviceId, newAndroidDeviceId]));
      expect(activeIds, isNot(contains(oldAndroidDeviceId)));
    });

    test('STEP 5: Both devices (Windows laptop & new Android phone) can perform authorized recharge debits', () async {
      // Debit from Windows laptop
      final winDebit = await bridgeClient.processDebit(
        shopId: testShopId,
        walletId: 'WALLET_AIRTEL',
        rechargeId: 'REC_WIN_001',
        idempotencyKey: 'IDEMP_WIN_001',
        operator: 'Airtel',
        amountPaise: 29900,
        amount: 299.0,
        fundingType: 'prepaid',
        businessDate: '2026-11-17',
        deviceId: windowsDeviceId,
        deviceSignature: 'VALID_SIG_WIN',
        nonce: 'NONCE_WIN_1',
      );
      expect(winDebit['success'], isTrue);

      // Debit from newly enrolled Android phone
      final andrDebit = await bridgeClient.processDebit(
        shopId: testShopId,
        walletId: 'WALLET_JIO',
        rechargeId: 'REC_ANDR_001',
        idempotencyKey: 'IDEMP_ANDR_001',
        operator: 'Jio',
        amountPaise: 23900,
        amount: 239.0,
        fundingType: 'prepaid',
        businessDate: '2026-11-17',
        deviceId: newAndroidDeviceId,
        deviceSignature: 'VALID_SIG_ANDR',
        nonce: 'NONCE_ANDR_1',
      );
      expect(andrDebit['success'], isTrue);
    });

    test('STEP 6: Old revoked Android device DEV_ANDR_49246D is strictly rejected', () async {
      expect(
        bridgeClient.processDebit(
          shopId: testShopId,
          walletId: 'WALLET_VI',
          rechargeId: 'REC_REVOKED_001',
          idempotencyKey: 'IDEMP_REVOKED_001',
          operator: 'Vi',
          amountPaise: 19900,
          amount: 199.0,
          fundingType: 'prepaid',
          businessDate: '2026-11-17',
          deviceId: oldAndroidDeviceId,
          deviceSignature: 'SIG_OLD',
          nonce: 'NONCE_OLD',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('STEP 7: Staff accounts are completely locked out of Recharge Accounting', () async {
      final staffBridgeClient = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: 'https://bxjlqcqcjfifzjrqpcov.supabase.co/functions/v1/recharge-bridge',
        getFirebaseIdToken: () async => staffToken,
        httpClient: mockClient,
      );

      expect(
        staffBridgeClient.getDevices(shopId: testShopId),
        throwsA(isA<StateError>()),
      );

      expect(
        staffBridgeClient.processDebit(
          shopId: testShopId,
          walletId: 'WALLET_BSNL',
          rechargeId: 'REC_STAFF_001',
          idempotencyKey: 'IDEMP_STAFF_001',
          operator: 'BSNL',
          amountPaise: 10700,
          amount: 107.0,
          fundingType: 'prepaid',
          businessDate: '2026-11-17',
          deviceId: newAndroidDeviceId,
          deviceSignature: 'SIG_STAFF',
          nonce: 'NONCE_STAFF',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
