import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
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
    tempDir = await Directory.systemTemp.createTemp('tekfix_phase16_3_test_');
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

  group('TEKFIX ERP — Phase 16.3 Cross-Backend Financial Recovery & Consistency Tests', () {
    // ------------------------------------------------------------------------
    // 1. Crash after Server Debit: Local Recovery completes settlement
    // ------------------------------------------------------------------------
    test('1. Interrupted settlement after server debit is auto-reconciled', () async {
      await Db.bank.put('cash_in_hand', 1000.0);

      const testKey = 'TEST_CRASH_KEY_001';
      // Simulate crash state: Server confirmed debit, but app crashed before local cash update
      await RechargeRecoveryEngine.recordPendingIntent(
        idempotencyKey: testKey,
        shopId: StagingIdentityService.defaultShopId,
        ownerUid: 'owner_staging_001',
        deviceId: 'DEV_TEST_001',
        mobile: '9847011223',
        operator: 'Jio',
        serviceType: 'Prepaid',
        retailAmount: 299.0,
        costPrice: 290.03,
        paymentMode: 'Cash',
      );
      await RechargeRecoveryEngine.markServerConfirmed(testKey, 'TXN_SERVER_CONFIRMED_001');

      // Verify uncommitted state
      expect(Db.bank.get('cash_in_hand'), equals(1000.0));
      expect(Db.recharges.containsKey(testKey), isFalse);

      // Startup recovery runs
      final recovered = await RechargeRecoveryEngine.reconcilePendingSettlements();
      expect(recovered, equals(1));

      // Verify clean settlement after recovery
      expect(Db.bank.get('cash_in_hand'), equals(1299.0));
      expect(Db.recharges.containsKey(testKey), isTrue);
      expect(Db.rechargeQueue.containsKey(testKey), isFalse);
    });

    // ------------------------------------------------------------------------
    // 2. In-flight transaction timeout: Reconciles idempotently with server
    // ------------------------------------------------------------------------
    test('2. In-flight unconfirmed transaction reconciles idempotently with server', () async {
      await Db.bank.put('bank_balance', 2000.0);

      const testKey = 'TEST_IN_FLIGHT_002';
      // Server already debited on backend
      mockProcessedIdempotencyKeys.add(testKey);

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

      final recovered = await RechargeRecoveryEngine.reconcilePendingSettlements();
      expect(recovered, equals(1));

      expect(Db.bank.get('bank_balance'), equals(2666.0));
      expect(Db.recharges.containsKey(testKey), isTrue);
      expect(Db.rechargeQueue.containsKey(testKey), isFalse);
    });

    // ------------------------------------------------------------------------
    // 3. Duplicate Retry does NOT double-post to local accounting
    // ------------------------------------------------------------------------
    test('3. Replaying an already settled transaction does not double post to Cash/Bank', () async {
      await Db.bank.put('cash_in_hand', 1000.0);

      final entry1 = await QuickRechargeDialog.recordRecharge(
        mobile: '9847123456',
        operator: 'Jio',
        serviceType: 'Prepaid',
        retailAmount: 199.0,
        costPrice: 191.04,
        paymentMode: 'Cash',
      );

      expect(entry1['status'], equals('SUCCESS'));
      expect(Db.bank.get('cash_in_hand'), equals(1199.0));

      // Attempt immediate duplicate replay with the SAME idempotency key
      final replay = await QuickRechargeDialog.recordRecharge(
        mobile: '9847123456',
        operator: 'Jio',
        serviceType: 'Prepaid',
        retailAmount: 199.0,
        costPrice: 191.04,
        paymentMode: 'Cash',
        customIdempotencyKey: entry1['id'],
      );

      expect(replay['idempotentReplay'], isTrue);
      // Cash in hand must still be exactly 1199.0 (NO DOUBLE POSTING)
      expect(Db.bank.get('cash_in_hand'), equals(1199.0));
    });

    // ------------------------------------------------------------------------
    // 4. Cash Recharge Financial Integrity
    // ------------------------------------------------------------------------
    test('4. Cash recharge updates cash_in_hand and strictly leaves Db.sales at 0', () async {
      await Db.bank.put('cash_in_hand', 500.0);

      final entry = await QuickRechargeDialog.recordRecharge(
        mobile: '9876543210',
        operator: 'Jio',
        serviceType: 'Prepaid',
        retailAmount: 299.0,
        costPrice: 290.03,
        paymentMode: 'Cash',
      );

      expect(entry['retailAmount'], equals(299.0));
      expect(entry['costPrice'], equals(290.03));
      expect(entry['commission'], closeTo(8.97, 0.01));

      expect(Db.bank.get('cash_in_hand'), equals(799.0));
      expect(Db.sales.isEmpty, isTrue, reason: 'Recharge principal must never inflate retail sales turnover');
    });

    // ------------------------------------------------------------------------
    // 5. UPI Recharge Financial Integrity
    // ------------------------------------------------------------------------
    test('5. UPI recharge updates bank_balance and strictly leaves Db.sales at 0', () async {
      await Db.bank.put('bank_balance', 1000.0);

      final entry = await QuickRechargeDialog.recordRecharge(
        mobile: '9995551122',
        operator: 'Airtel',
        serviceType: 'Prepaid',
        retailAmount: 666.0,
        costPrice: 647.35,
        paymentMode: 'UPI',
      );

      expect(entry['commission'], closeTo(18.65, 0.01));
      expect(Db.bank.get('bank_balance'), equals(1666.0));
      expect(Db.sales.isEmpty, isTrue, reason: 'Recharge principal must never inflate retail sales turnover');
    });

    // ------------------------------------------------------------------------
    // 6. Credit / Due Recharge Financial Integrity
    // ------------------------------------------------------------------------
    test('6. Credit/Due recharge updates customer receivable party balance and leaves Db.sales at 0', () async {
      final partyKey = await Db.parties.add({
        'name': 'Hassan Koya',
        'phone': '9847112233',
        'balance': 300.0,
      });

      final entry = await QuickRechargeDialog.recordRecharge(
        mobile: '9847112233',
        operator: 'Vi',
        serviceType: 'Prepaid',
        retailAmount: 239.0,
        costPrice: 230.64,
        paymentMode: 'Credit / Due',
        partyKey: partyKey,
        partyName: 'Hassan Koya',
      );

      expect(entry['commission'], closeTo(8.36, 0.01));
      final party = Db.parties.get(partyKey) as Map;
      expect(party['balance'], equals(539.0)); // 300 + 239
      expect(Db.sales.isEmpty, isTrue, reason: 'Recharge principal must never inflate retail sales turnover');
    });

    // ------------------------------------------------------------------------
    // 7. Dead Letter Box for Unmatched Aborted Transactions
    // ------------------------------------------------------------------------
    test('7. Terminal server failures are archived in dead-letter box and do not settle', () async {
      await Db.bank.put('cash_in_hand', 1000.0);

      const failedKey = 'TEST_FAIL_001';
      await RechargeRecoveryEngine.recordPendingIntent(
        idempotencyKey: failedKey,
        shopId: StagingIdentityService.defaultShopId,
        ownerUid: 'owner_staging_001',
        deviceId: 'DEV_TEST_001',
        mobile: '9847000000',
        operator: 'BSNL',
        serviceType: 'Prepaid',
        retailAmount: 100.0,
        costPrice: 95.0,
        paymentMode: 'Cash',
      );

      await RechargeRecoveryEngine.markFailed(failedKey, 'Distributor wallet depleted');

      expect(Db.rechargeQueue.containsKey(failedKey), isFalse);
      expect(Db.rechargeDeadLetter.containsKey(failedKey), isTrue);
      expect(Db.bank.get('cash_in_hand'), equals(1000.0)); // Zero money moved
    });
  });
}

