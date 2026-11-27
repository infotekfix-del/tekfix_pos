// ignore_for_file: avoid_print
// TEKFIX ERP - Multi-Device Owner Recharge Test
// Verifies: Owner can recharge from ANY device without trusted-device enrollment.
// Security: Staff still blocked. Financial isolation preserved.
// Implements: User requirement "Remove Trusted Device Restriction Permanently"

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
import 'package:tekfix_erp_pos/recharge/supabase_recharge_bridge_client.dart';
import 'package:tekfix_erp_pos/security/device_security_service.dart';
import 'package:tekfix_erp_pos/security/staging_identity_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // These tests drive the server mock with a fixed wallet pocket.
  setUpAll(() => kRechargeAutoFundingPocket = false);
  tearDownAll(() => kRechargeAutoFundingPocket = true);
  late Directory tempDir;

  late int mockWalletBalancePaise;
  late Set<String> mockProcessedKeys;
  late Set<String> mockActiveNonces;
  bool androidKeyExists = false;

  const channelName = 'com.example.tekfix_pos/keystore';

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('multi_device_owner_test_');
    Hive.init(tempDir.path);
    for (final b in allBoxes) {
      if (!Hive.isBoxOpen(b)) await Hive.openBox(b);
    }
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), null);
    DeviceSecurityService.overridePlatformForTesting = null;
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
    DeviceSecurityService.overridePlatformForTesting = null;
    androidKeyExists = false;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), (MethodCall call) async {
      switch (call.method) {
        case 'getSecurityLevel':
          return 'hardware_strongbox';
        case 'generateKey':
          androidKeyExists = true;
          return {
            'publicKeyPem': '-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEtest\n-----END PUBLIC KEY-----',
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
    await Db.sales.clear();

    mockWalletBalancePaise = 5000000; // ₹50,000 starting balance
    mockProcessedKeys = <String>{};
    mockActiveNonces = <String>{};

    final mockHttpClient = MockClient((request) async {
      final path = request.url.path;
      final body = jsonDecode(request.body) as Map<String, dynamic>;

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
        final nonce = body['nonce']?.toString() ?? '';
        final idempotencyKey = body['idempotencyKey']?.toString() ?? '';
        final amountPaise = (body['amountPaise'] as num?)?.toInt() ?? 0;

        mockActiveNonces.remove(nonce);

        if (mockProcessedKeys.contains(idempotencyKey)) {
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

        mockProcessedKeys.add(idempotencyKey);
        mockWalletBalancePaise -= amountPaise;

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

      return http.Response('{"error":"Not Found"}', 404);
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
  });

  group('TEKFIX – Trusted Device Removal: Owner Multi-Device Recharge', () {
    // -------------------------------------------------------------------------
    // TEST 1: Owner from Windows (not enrolled) can recharge
    // -------------------------------------------------------------------------
    test('1. Owner from Windows laptop WITHOUT enrollment executes recharge successfully', () async {
      DeviceSecurityService.overridePlatformForTesting = DevicePlatformType.windows;
      final sec = DeviceSecurityService.instance;
      await sec.init();
      await sec.setEnrolledLocally(false); // Explicitly NOT enrolled

      final entry = await QuickRechargeDialog.recordRecharge(
        mobile: '9876500001',
        operator: 'Airtel',
        serviceType: 'Prepaid',
        retailAmount: 299.0,
        costPrice: 290.03,
        paymentMode: 'Cash',
      );

      expect(entry['status'], equals('SUCCESS'),
          reason: 'Owner on unenrolled Windows device must succeed');
      expect(entry['serverConfirmed'], isTrue,
          reason: 'Transaction must be server-confirmed, not local fallback');
      expect(entry['amount'], equals(299.0));
      print('[PASS] Test 1: Owner Windows unenrolled -> recharge SUCCESS');
    });

    // -------------------------------------------------------------------------
    // TEST 2: Owner from Android (not enrolled) can recharge
    // -------------------------------------------------------------------------
    test('2. Owner from Android phone WITHOUT enrollment executes recharge successfully', () async {
      DeviceSecurityService.overridePlatformForTesting = DevicePlatformType.android;
      final sec = DeviceSecurityService.instance;
      await sec.init();
      await sec.setEnrolledLocally(false); // Explicitly NOT enrolled

      final entry = await QuickRechargeDialog.recordRecharge(
        mobile: '9876500002',
        operator: 'Jio',
        serviceType: 'Prepaid',
        retailAmount: 666.0,
        costPrice: 647.02,
        paymentMode: 'UPI',
      );

      expect(entry['status'], equals('SUCCESS'),
          reason: 'Owner on unenrolled Android device must succeed');
      expect(entry['serverConfirmed'], isTrue);
      print('[PASS] Test 2: Owner Android unenrolled -> recharge SUCCESS');
    });

    // -------------------------------------------------------------------------
    // TEST 3: Owner from a second / new laptop (unenrolled) executes recharge
    // -------------------------------------------------------------------------
    test('3. Owner from a second / new laptop (unenrolled) executes recharge — no two-device limit', () async {
      DeviceSecurityService.overridePlatformForTesting = DevicePlatformType.windows;
      final sec = DeviceSecurityService.instance;
      await sec.init();
      await sec.setEnrolledLocally(false); // Fresh device — NEVER enrolled

      final entry = await QuickRechargeDialog.recordRecharge(
        mobile: '9876500003',
        operator: 'Vi',
        serviceType: 'Prepaid',
        retailAmount: 399.0,
        costPrice: 387.03,
        paymentMode: 'Bank',
      );

      expect(entry['status'], equals('SUCCESS'),
          reason: 'No two-device limit — Owner can use any new laptop');
      expect(entry['serverConfirmed'], isTrue);
      print('[PASS] Test 3: Owner second laptop unenrolled -> recharge SUCCESS');
    });

    // -------------------------------------------------------------------------
    // TEST 4: Staff CANNOT recharge regardless of device enrollment status
    // -------------------------------------------------------------------------
    test('4. Staff account is ALWAYS rejected — Owner-only backend authorization preserved', () async {
      final auth = AuthController.instance;
      await auth.signOut(); // No longer owner

      final sec = DeviceSecurityService.instance;
      await sec.setEnrolledLocally(true);

      expect(
        () => QuickRechargeDialog.recordRecharge(
          mobile: '9876500004',
          operator: 'BSNL',
          serviceType: 'Prepaid',
          retailAmount: 149.0,
          costPrice: 144.53,
          paymentMode: 'Cash',
        ),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('Owner authorization required'))),
        reason: 'Staff must NEVER access recharge, enrollment state irrelevant',
      );
      print('[PASS] Test 4: Staff rejected -> Owner-only security INTACT');
    });

    // -------------------------------------------------------------------------
    // TEST 5: No enrollment prompt: isEnrolledLocally false does NOT block recordRecharge
    // -------------------------------------------------------------------------
    test('5. No enrollment prompt: isEnrolledLocally false does NOT block recordRecharge for owners', () async {
      final auth = AuthController.instance;
      if (!auth.isOwner) {
        await auth.signIn(
          StagingIdentityService.defaultShopId,
          'staging-owner@tekfix.internal',
          AuthController.defaultStagingPassword,
        );
      }

      DeviceSecurityService.overridePlatformForTesting = DevicePlatformType.windows;
      final sec = DeviceSecurityService.instance;
      await sec.init();
      await sec.setEnrolledLocally(false);

      final result = await QuickRechargeDialog.recordRecharge(
        mobile: '9876500005',
        operator: 'Airtel',
        serviceType: 'Prepaid',
        retailAmount: 199.0,
        costPrice: 193.03,
        paymentMode: 'Cash',
        customIdempotencyKey: 'test-no-prompt-${DateTime.now().millisecondsSinceEpoch}',
      );

      expect(result['status'], equals('SUCCESS'));
      print('[PASS] Test 5: No enrollment prompt -> recharge succeeds silently for Owner');
    });

    // -------------------------------------------------------------------------
    // TEST 6: Financial isolation: recharge amount NEVER added to Cash in Hand or Bank Balance
    // -------------------------------------------------------------------------
    test('6. Financial isolation: recharge amount NEVER added to Cash in Hand or Bank Balance', () async {
      DeviceSecurityService.overridePlatformForTesting = DevicePlatformType.windows;
      final sec = DeviceSecurityService.instance;
      await sec.init();
      await sec.setEnrolledLocally(false);

      await Db.bank.put('cash_in_hand', 1000.0);
      await Db.bank.put('bank_balance', 5000.0);

      await QuickRechargeDialog.recordRecharge(
        mobile: '9876500006',
        operator: 'Jio',
        serviceType: 'Prepaid',
        retailAmount: 999.0,
        costPrice: 969.03,
        paymentMode: 'Cash',
        customIdempotencyKey: 'test-isolation-${DateTime.now().millisecondsSinceEpoch}',
      );

      // Financial isolation: normal cash_in_hand and bank_balance must NOT be modified
      expect(Db.bank.get('cash_in_hand'), equals(1000.0),
          reason: 'Cash in Hand must not be inflated by recharge amount ₹999');
      expect(Db.bank.get('bank_balance'), equals(5000.0),
          reason: 'Bank Balance must not be inflated by recharge amount ₹999');
      print('[PASS] Test 6: Financial isolation intact -> Cash/Bank unchanged by recharge principal');
    });
  });
}
