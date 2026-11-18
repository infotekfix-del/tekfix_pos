import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tekfix_erp_pos/auth/auth_controller.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/recharge/quick_recharge_dialog.dart';
import 'package:tekfix_erp_pos/recharge/recharge_backend_bridge.dart';
import 'package:tekfix_erp_pos/recharge/recharge_recovery_engine.dart';
import 'package:tekfix_erp_pos/recharge/supabase_recharge_bridge_client.dart';
import 'package:tekfix_erp_pos/security/device_security_service.dart';
import 'package:tekfix_erp_pos/security/staging_identity_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  const channelName = 'com.example.tekfix_pos/keystore';
  bool androidKeyExists = false;

  late int mockWalletBalancePaise;
  late Set<String> mockProcessedIdempotencyKeys;
  late Set<String> mockActiveNonces;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('tekfix_phase16_4_test_');
    Hive.init(tempDir.path);
    for (final b in allBoxes) {
      if (!Hive.isBoxOpen(b)) await Hive.openBox(b);
    }
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), null);
    try {
      await Hive.close().timeout(const Duration(seconds: 2), onTimeout: () => null);
    } catch (_) {}
    if (tempDir.existsSync()) {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  });

  setUp(() async {
    androidKeyExists = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), (MethodCall call) async {
      switch (call.method) {
        case 'getSecurityLevel':
          return 'hardware_strongbox';
        case 'generateKey':
          androidKeyExists = true;
          return {
            'publicKeyPem': '-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEandroid_mock_public_key_point\n-----END PUBLIC KEY-----',
            'securityLevel': 'hardware_strongbox',
          };
        case 'signPayload':
          final derBytes = Uint8List.fromList([0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02]);
          return base64Encode(derBytes);
        case 'hasKey':
          return androidKeyExists;
        case 'deleteKey':
          androidKeyExists = false;
          return true;
        default:
          return null;
      }
    });

    await Db.settings.clear();
    await Db.bank.clear();
    await Db.parties.clear();
    await Db.recharges.clear();
    await Db.rechargeQueue.clear();
    await Db.rechargeDeadLetter.clear();
    await Db.sales.clear();

    mockWalletBalancePaise = 500000; // ₹5,000.00
    mockProcessedIdempotencyKeys = {};
    mockActiveNonces = {};

    final mockHttpClient = MockClient((request) async {
      final path = request.url.path;

      if (path.endsWith('/request-challenge')) {
        final nonce = 'NONCE_${DateTime.now().microsecondsSinceEpoch}';
        mockActiveNonces.add(nonce);
        return http.Response(
          jsonEncode({'nonce': nonce, 'expiresAt': DateTime.now().add(const Duration(seconds: 300)).toIso8601String()}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (path.endsWith('/process-debit')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final idempotencyKey = body['idempotencyKey']?.toString() ?? '';
        final amountPaise = (body['amountPaise'] as num?)?.toInt() ?? 0;

        if (mockProcessedIdempotencyKeys.contains(idempotencyKey)) {
          return http.Response(
            jsonEncode({
              'success': true,
              'idempotentReplay': true,
              'txn_key': idempotencyKey,
              'rechargeId': idempotencyKey,
              'amountPaise': amountPaise,
              'totalBalancePaise': mockWalletBalancePaise,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }

        mockWalletBalancePaise -= amountPaise;
        mockProcessedIdempotencyKeys.add(idempotencyKey);

        return http.Response(
          jsonEncode({
            'success': true,
            'idempotentReplay': false,
            'txn_key': idempotencyKey,
            'rechargeId': idempotencyKey,
            'amountPaise': amountPaise,
            'balanceBeforePaise': mockWalletBalancePaise + amountPaise,
            'balanceAfterPaise': mockWalletBalancePaise,
            'totalBalancePaise': mockWalletBalancePaise,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      return http.Response('{"error": "Not Found"}', 404);
    });

    final bridgeClient = SupabaseRechargeBridgeClient(
      edgeFunctionBaseUrl: 'https://mwhsvidbrfkryuiwhnev.supabase.co/functions/v1/recharge-bridge',
      getFirebaseIdToken: () async => 'VALID_STAGING_MOCK_JWT_TOKEN',
      httpClient: mockHttpClient,
    );

    RechargeBackendBridge.configure(
      mode: RechargeBackendMode.supabaseEdgeFunction,
      supabaseClient: bridgeClient,
    );

    final auth = AuthController.instance;
    await auth.signIn(
      StagingIdentityService.defaultShopId,
      'staging-owner@tekfix.internal',
      AuthController.defaultStagingPassword,
    );

    final sec = DeviceSecurityService.instance;
    await sec.init();
    await sec.setEnrolledLocally(true);
  });

  group('TEKFIX ERP — Phase 16.4 Adversarial Financial Integrity & Hardware Security Tests', () {
    // ------------------------------------------------------------------------
    // 1. Crash between Cash update and ReadModel cache
    // ------------------------------------------------------------------------
    test('1. Crash between Cash update and Db.recharges does not cause double credit on recovery', () async {
      await Db.bank.put('cash_in_hand', 1000.0);
      const testKey = 'TEST_CRASH_MID_CASH_001';

      // 1. Journal initiated and server confirmed
      await RechargeRecoveryEngine.recordPendingIntent(
        idempotencyKey: testKey,
        shopId: StagingIdentityService.defaultShopId,
        ownerUid: 'owner_staging_001',
        deviceId: 'DEV_TEST_001',
        mobile: '9847111222',
        operator: 'Jio',
        serviceType: 'Prepaid',
        retailAmount: 299.0,
        costPrice: 290.03,
        paymentMode: 'Cash',
      );
      await RechargeRecoveryEngine.markServerConfirmed(testKey, 'TXN_SERVER_001');

      // 2. Simulate partial write: Money WAS moved into Cash
      await Db.moveMoney('Cash', 299.0, 'Recharge Sale: Jio 9847111222 (Txn: $testKey)');
      await RechargeRecoveryEngine.markMoneySettled(testKey);

      expect(Db.bank.get('cash_in_hand'), equals(1299.0));
      // But Db.recharges write was interrupted by crash!
      expect(Db.recharges.containsKey(testKey), isFalse);

      // 3. Restart and run recovery engine
      final recovered = await RechargeRecoveryEngine.reconcilePendingSettlements();
      expect(recovered, equals(1));

      // 4. Verification: Cash MUST still be 1299.0 (NOT 1598.0!)
      expect(Db.bank.get('cash_in_hand'), equals(1299.0), reason: 'Must not double-credit cash on recovery');
      expect(Db.recharges.containsKey(testKey), isTrue);
      expect(Db.rechargeQueue.containsKey(testKey), isFalse);
    });

    // ------------------------------------------------------------------------
    // 2. Crash between Bank update and ReadModel cache
    // ------------------------------------------------------------------------
    test('2. Crash between Bank update and Db.recharges does not cause double credit on recovery', () async {
      await Db.bank.put('bank_balance', 5000.0);
      const testKey = 'TEST_CRASH_MID_BANK_002';

      await RechargeRecoveryEngine.recordPendingIntent(
        idempotencyKey: testKey,
        shopId: StagingIdentityService.defaultShopId,
        ownerUid: 'owner_staging_001',
        deviceId: 'DEV_TEST_001',
        mobile: '9995551122',
        operator: 'Airtel',
        serviceType: 'Prepaid',
        retailAmount: 666.0,
        costPrice: 647.35,
        paymentMode: 'UPI',
      );
      await RechargeRecoveryEngine.markServerConfirmed(testKey, 'TXN_SERVER_002');

      // Partial write: Bank moved
      await Db.moveMoney('Bank', 666.0, 'Recharge UPI: Airtel 9995551122 (Txn: $testKey)');
      await RechargeRecoveryEngine.markMoneySettled(testKey);

      expect(Db.bank.get('bank_balance'), equals(5666.0));
      expect(Db.recharges.containsKey(testKey), isFalse);

      final recovered = await RechargeRecoveryEngine.reconcilePendingSettlements();
      expect(recovered, equals(1));

      expect(Db.bank.get('bank_balance'), equals(5666.0), reason: 'Must not double-credit bank on recovery');
      expect(Db.recharges.containsKey(testKey), isTrue);
    });

    // ------------------------------------------------------------------------
    // 3. Invalid partyKey for Credit / Due recharge
    // ------------------------------------------------------------------------
    test('3. Invalid partyKey flags MANUAL_REVIEW_REQUIRED and NEVER redirects to general receivables', () async {
      await expectLater(
        () => QuickRechargeDialog.recordRecharge(
          mobile: '9847000111',
          operator: 'Vi',
          serviceType: 'Prepaid',
          retailAmount: 239.0,
          costPrice: 230.64,
          paymentMode: 'Credit / Due',
          partyKey: 'NON_EXISTENT_PARTY_KEY',
          partyName: 'Unknown Ghost Customer',
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('MANUAL_REVIEW_REQUIRED'))),
      );

      // Verify journal state
      final queueKeys = Db.rechargeQueue.keys.toList();
      expect(queueKeys.isNotEmpty, isTrue);
      final flaggedEntry = Db.rechargeQueue.get(queueKeys.first) as Map;
      expect(flaggedEntry['status'], equals(RechargeRecoveryEngine.statusManualReviewRequired));
      expect(flaggedEntry['partyName'], equals('Unknown Ghost Customer'));

      // Verify general receivables or cash were NOT touched
      expect(Db.bank.get('cash_in_hand') ?? 0.0, equals(0.0));
      expect(Db.sales.isEmpty, isTrue);
    });

    // ------------------------------------------------------------------------
    // 4. Deleted party record during recovery
    // ------------------------------------------------------------------------
    test('4. Deleted customer during post-crash recovery is held for manual review', () async {
      const testKey = 'TEST_DELETED_PARTY_003';

      await RechargeRecoveryEngine.recordPendingIntent(
        idempotencyKey: testKey,
        shopId: StagingIdentityService.defaultShopId,
        ownerUid: 'owner_staging_001',
        deviceId: 'DEV_TEST_001',
        mobile: '9847223344',
        operator: 'BSNL',
        serviceType: 'Prepaid',
        retailAmount: 199.0,
        costPrice: 191.04,
        paymentMode: 'Credit / Due',
        partyKey: 'DELETED_PARTY_KEY_99',
        partyName: 'Deleted Customer Record',
      );
      await RechargeRecoveryEngine.markServerConfirmed(testKey, 'TXN_SERVER_003');

      // Attempt recovery: party is missing
      final recovered = await RechargeRecoveryEngine.reconcilePendingSettlements();
      expect(recovered, equals(0)); // Skipped and flagged for manual review

      final entry = Db.rechargeQueue.get(testKey) as Map;
      expect(entry['status'], equals(RechargeRecoveryEngine.statusManualReviewRequired));
      expect(entry['reviewReason'], contains('Customer party record missing/deleted'));
    });

    // ------------------------------------------------------------------------
    // 5. Normal Credit recharge updates party balance exactly once
    // ------------------------------------------------------------------------
    test('5. Valid Credit recharge updates customer balance exactly once and leaves Db.sales at 0', () async {
      final pKey = await Db.parties.add({
        'name': 'Moosa Haji',
        'phone': '9847334455',
        'balance': 500.0,
      });

      final entry = await QuickRechargeDialog.recordRecharge(
        mobile: '9847334455',
        operator: 'Jio',
        serviceType: 'Prepaid',
        retailAmount: 299.0,
        costPrice: 290.03,
        paymentMode: 'Credit / Due',
        partyKey: pKey,
        partyName: 'Moosa Haji',
      );

      expect(entry['status'], equals('SUCCESS'));
      final p = Db.parties.get(pKey) as Map;
      expect(p['balance'], equals(799.0)); // 500 + 299
      expect(Db.sales.isEmpty, isTrue, reason: 'Db.sales must remain 0');

      // Replay must not double add
      final replay = await QuickRechargeDialog.recordRecharge(
        mobile: '9847334455',
        operator: 'Jio',
        serviceType: 'Prepaid',
        retailAmount: 299.0,
        costPrice: 290.03,
        paymentMode: 'Credit / Due',
        partyKey: pKey,
        partyName: 'Moosa Haji',
        customIdempotencyKey: entry['id'],
      );

      expect(replay['idempotentReplay'], isTrue);
      final pAfter = Db.parties.get(pKey) as Map;
      expect(pAfter['balance'], equals(799.0), reason: 'Party balance must not be double adjusted on retry');
    });

    // ------------------------------------------------------------------------
    // 6. Device Security: Owner on any device succeeds (enrollment gate removed)
    // ------------------------------------------------------------------------
    test('6. Owner on unenrolled device succeeds - device enrollment no longer required', () async {
      final sec = DeviceSecurityService.instance;
      await sec.setEnrolledLocally(false); // Not enrolled

      // Owner auth is now the sole authorization mechanism
      final entry = await QuickRechargeDialog.recordRecharge(
        mobile: '9847999888',
        operator: 'Jio',
        serviceType: 'Prepaid',
        retailAmount: 199.0,
        costPrice: 191.04,
        paymentMode: 'Cash',
      );

      expect(entry['status'], equals('SUCCESS'),
          reason: 'Owner can recharge from any device without enrollment');
    });

    // ------------------------------------------------------------------------
    // 7. Role Security: Staff user rejection (Fail-closed)
    // ------------------------------------------------------------------------
    test('7. Staff user is rejected fail-closed before server call', () async {
      final auth = AuthController.instance;
      await auth.signOut(); // Ensure not owner

      expect(
        () => QuickRechargeDialog.recordRecharge(
          mobile: '9847999888',
          operator: 'Jio',
          serviceType: 'Prepaid',
          retailAmount: 199.0,
          costPrice: 191.04,
          paymentMode: 'Cash',
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('Owner authorization required'))),
      );
    });
  });
}
