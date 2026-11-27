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
  // Covers the commission logic, which the shop has switched off in the entry.
  setUpAll(() => kRechargeCommissionInEntry = true);
  tearDownAll(() => kRechargeCommissionInEntry = false);
  late Directory tempDir;

  const channelName = 'com.example.tekfix_pos/keystore';
  bool androidKeyExists = false;

  // Staging mock state
  late int mockWalletBalancePaise;
  late Set<String> mockProcessedIdempotencyKeys;
  late Set<String> mockActiveNonces;
  bool mockRejectSignatures = false;
  bool mockInvalidJwt = false;
  bool mockExpiredNonce = false;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('tekfix_phase16_2_test_');
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
            'publicKeyPem': '-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEandroid_mock_public_key_point\n-----END PUBLIC KEY-----',
            'securityLevel': 'hardware_strongbox',
          };
        case 'signPayload':
          if (!androidKeyExists) {
            throw PlatformException(code: 'KEY_NOT_FOUND', message: 'No key in keystore');
          }
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

    mockWalletBalancePaise = 500000; // ₹5,000.00 wholesale wallet balance
    mockProcessedIdempotencyKeys = {};
    mockActiveNonces = {};
    mockRejectSignatures = false;
    mockInvalidJwt = false;
    mockExpiredNonce = false;

    // Create MockClient that faithfully emulates the Supabase Edge Function & PostgreSQL RPC
    final mockHttpClient = MockClient((request) async {
      final path = request.url.path;

      // 1. JWT validation
      final authHeader = request.headers['Authorization'] ?? '';
      if (mockInvalidJwt || !authHeader.startsWith('Bearer ')) {
        return http.Response(
          jsonEncode({'error': 'JWT verification failed: Invalid token or signature'}),
          401,
          headers: {'content-type': 'application/json'},
        );
      }

      final body = jsonDecode(request.body) as Map<String, dynamic>;

      // Endpoint 1: /request-challenge
      if (path.endsWith('/request-challenge')) {
        final nonce = 'NONCE_${DateTime.now().microsecondsSinceEpoch}';
        mockActiveNonces.add(nonce);
        return http.Response(
          jsonEncode({'nonce': nonce, 'expiresAt': DateTime.now().add(const Duration(seconds: 300)).toIso8601String()}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      // Endpoint 2: /process-debit
      if (path.endsWith('/process-debit')) {
        final nonce = body['nonce']?.toString() ?? '';
        final sig = body['deviceSignature']?.toString() ?? '';
        final idempotencyKey = body['idempotencyKey']?.toString() ?? '';
        final amountPaise = (body['amountPaise'] as num?)?.toInt() ?? 0;

        if (mockExpiredNonce || !mockActiveNonces.contains(nonce)) {
          return http.Response(
            jsonEncode({'error': 'Challenge nonce is invalid, expired, or already consumed'}),
            403,
            headers: {'content-type': 'application/json'},
          );
        }
        mockActiveNonces.remove(nonce); // Single-use consumption

        if (mockRejectSignatures || sig.isEmpty) {
          return http.Response(
            jsonEncode({'error': 'Cryptographic signature verification failed: Invalid key or altered payload.'}),
            403,
            headers: {'content-type': 'application/json'},
          );
        }

        // Server Idempotency Check
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

        // Insufficient Balance Check
        if (mockWalletBalancePaise < amountPaise) {
          return http.Response(
            jsonEncode({'error': 'Insufficient own prepaid balance: Available $mockWalletBalancePaise paise, requested $amountPaise paise'}),
            400,
            headers: {'content-type': 'application/json'},
          );
        }

        // Atomic Debit
        final balanceBefore = mockWalletBalancePaise;
        mockWalletBalancePaise -= amountPaise;
        mockProcessedIdempotencyKeys.add(idempotencyKey);

        return http.Response(
          jsonEncode({
            'success': true,
            'idempotentReplay': false,
            'txn_key': idempotencyKey,
            'rechargeId': idempotencyKey,
            'amountPaise': amountPaise,
            'balanceBeforePaise': balanceBefore,
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
    await sec.setEnrolledLocally(true); // Default enrolled
  });

  group('TEKFIX ERP — Phase 16.2 Recharge Security & Financial Consistency Tests', () {
    // ------------------------------------------------------------------------
    // 1. Owner Enrolled Mobile
    // ------------------------------------------------------------------------
    test('1. Owner enrolled mobile executes server-authoritative recharge', () async {
      DeviceSecurityService.overridePlatformForTesting = DevicePlatformType.android;
      final sec = DeviceSecurityService.instance;
      await sec.init();
      await sec.setEnrolledLocally(true);

      final entry = await QuickRechargeDialog.recordRecharge(
        mobile: '9876543210',
        operator: 'Jio',
        serviceType: 'Prepaid',
        retailAmount: 299.0,
        costPrice: 290.03,
        paymentMode: 'Cash',
      );

      expect(entry['status'], equals('SUCCESS'));
      expect(entry['serverConfirmed'], isTrue);
      expect(entry['idempotentReplay'], isFalse);
      expect(entry['amount'], equals(299.0));
      expect(Db.recharges.containsKey(entry['id']), isTrue);
    });

    // ------------------------------------------------------------------------
    // 2. Owner Enrolled Laptop (Windows)
    // ------------------------------------------------------------------------
    test('2. Owner enrolled laptop executes server-authoritative recharge', () async {
      DeviceSecurityService.overridePlatformForTesting = DevicePlatformType.windows;
      final sec = DeviceSecurityService.instance;
      await sec.init();
      await sec.setEnrolledLocally(true);

      final entry = await QuickRechargeDialog.recordRecharge(
        mobile: '9744112233',
        operator: 'Airtel',
        serviceType: 'Prepaid',
        retailAmount: 719.0,
        costPrice: 698.87,
        paymentMode: 'UPI',
      );

      expect(entry['status'], equals('SUCCESS'));
      expect(entry['serverConfirmed'], isTrue);
      expect(entry['paymentMode'], equals('UPI'));
    });

    // ------------------------------------------------------------------------
    // 3. Owner on unenrolled mobile CAN execute recharge (device enrollment removed)
    // ------------------------------------------------------------------------
    test('3. Owner on any device (unenrolled) can execute recharge - no enrollment gate', () async {
      DeviceSecurityService.overridePlatformForTesting = DevicePlatformType.android;
      final sec = DeviceSecurityService.instance;
      await sec.init();
      await sec.setEnrolledLocally(false); // Not enrolled — must still succeed as Owner

      final entry = await QuickRechargeDialog.recordRecharge(
        mobile: '9876543210',
        operator: 'Jio',
        serviceType: 'Prepaid',
        retailAmount: 299.0,
        costPrice: 290.03,
        paymentMode: 'Cash',
      );

      // Owner auth is the sole gate — device enrollment is irrelevant
      expect(entry['status'], equals('SUCCESS'));
      expect(entry['serverConfirmed'], isTrue);
      expect(entry['amount'], equals(299.0));
    });

    // ------------------------------------------------------------------------
    // 4. Owner on unenrolled laptop CAN execute recharge (device enrollment removed)
    // ------------------------------------------------------------------------
    test('4. Owner on any laptop/desktop (unenrolled) can execute recharge - no enrollment gate', () async {
      DeviceSecurityService.overridePlatformForTesting = DevicePlatformType.windows;
      final sec = DeviceSecurityService.instance;
      await sec.init();
      await sec.setEnrolledLocally(false); // Not enrolled — must still succeed as Owner

      final entry = await QuickRechargeDialog.recordRecharge(
        mobile: '9876543221',
        operator: 'Airtel',
        serviceType: 'Prepaid',
        retailAmount: 199.0,
        costPrice: 193.43,
        paymentMode: 'UPI',
      );

      // Owner auth is the sole gate — device enrollment is irrelevant
      expect(entry['status'], equals('SUCCESS'));
      expect(entry['serverConfirmed'], isTrue);
      expect(entry['paymentMode'], equals('UPI'));
    });

    // ------------------------------------------------------------------------
    // 5. Staff Account Blocked
    // ------------------------------------------------------------------------
    test('5. Staff account is strictly denied authorization', () async {
      final auth = AuthController.instance;
      await auth.signOut(); // Not owner

      expect(
        () => QuickRechargeDialog.recordRecharge(
          mobile: '9876543210',
          operator: 'Jio',
          serviceType: 'Prepaid',
          retailAmount: 299.0,
          costPrice: 290.03,
          paymentMode: 'Cash',
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('Owner authorization required'))),
      );
    });

    // ------------------------------------------------------------------------
    // 6. Invalid JWT Rejected
    // ------------------------------------------------------------------------
    test('6. Invalid or forged JWT rejected by server', () async {
      mockInvalidJwt = true;

      expect(
        () => QuickRechargeDialog.recordRecharge(
          mobile: '9876543210',
          operator: 'Jio',
          serviceType: 'Prepaid',
          retailAmount: 299.0,
          costPrice: 290.03,
          paymentMode: 'Cash',
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('Unauthenticated'))),
      );

      expect(Db.recharges.isEmpty, isTrue);
    });

    // ------------------------------------------------------------------------
    // 7. Invalid ECDSA Signature Rejected
    // ------------------------------------------------------------------------
    test('7. Altered payload / invalid signature rejected by server', () async {
      mockRejectSignatures = true;

      expect(
        () => QuickRechargeDialog.recordRecharge(
          mobile: '9876543210',
          operator: 'Jio',
          serviceType: 'Prepaid',
          retailAmount: 299.0,
          costPrice: 290.03,
          paymentMode: 'Cash',
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('Permission Denied'))),
      );

      expect(Db.recharges.isEmpty, isTrue);
    });

    // ------------------------------------------------------------------------
    // 8. Expired Nonce Rejected (Replay Attack Prevention)
    // ------------------------------------------------------------------------
    test('8. Expired or already consumed challenge nonce rejected', () async {
      mockExpiredNonce = true;

      expect(
        () => QuickRechargeDialog.recordRecharge(
          mobile: '9876543210',
          operator: 'Jio',
          serviceType: 'Prepaid',
          retailAmount: 299.0,
          costPrice: 290.03,
          paymentMode: 'Cash',
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('Permission Denied'))),
      );

      expect(Db.recharges.isEmpty, isTrue);
    });

    // ------------------------------------------------------------------------
    // 9. Duplicate Transaction Replay (Exactly-Once Execution)
    // ------------------------------------------------------------------------
    test('9. Duplicate submission with same idempotencyKey replays safely without double debit', () async {
      await Db.bank.put('cash_in_hand', 1000.0);
      const testIdempotencyKey = 'c3a7f804-6b99-4d8b-9e4a-5f80b1820001';

      // 1. First execution
      final entry1 = await QuickRechargeDialog.recordRecharge(
        mobile: '9876543210',
        operator: 'Jio',
        serviceType: 'Prepaid',
        retailAmount: 299.0,
        costPrice: 290.03,
        paymentMode: 'Cash',
        customIdempotencyKey: testIdempotencyKey,
      );

      expect(entry1['idempotentReplay'], isFalse);
      // Financial separation: recharge must NOT affect cash_in_hand
      expect(Db.bank.get('cash_in_hand'), equals(1000.0));

      // 2. Replay with identical idempotencyKey
      final entry2 = await QuickRechargeDialog.recordRecharge(
        mobile: '9876543210',
        operator: 'Jio',
        serviceType: 'Prepaid',
        retailAmount: 299.0,
        costPrice: 290.03,
        paymentMode: 'Cash',
        customIdempotencyKey: testIdempotencyKey,
      );

      expect(entry2['idempotentReplay'], isTrue);
      // Cash MUST remain 1000.0 (financial isolation preserved)
      expect(Db.bank.get('cash_in_hand'), equals(1000.0));
    });

    // ------------------------------------------------------------------------
    // 10. Insufficient Wallet Balance
    // ------------------------------------------------------------------------
    test('10. Insufficient distributor wallet balance rejected atomically', () async {
      mockWalletBalancePaise = 5000; // Only ₹50.00 in wallet

      expect(
        () => QuickRechargeDialog.recordRecharge(
          mobile: '9876543210',
          operator: 'Jio',
          serviceType: 'Prepaid',
          retailAmount: 299.0, // Cost is ₹290.03 (29003 paise) > 5000 paise
          costPrice: 290.03,
          paymentMode: 'Cash',
        ),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message', contains('Insufficient own prepaid balance'))),
      );

      // Verify wallet balance remained unchanged
      expect(mockWalletBalancePaise, equals(5000));
      expect(Db.recharges.isEmpty, isTrue);
    });

    // ------------------------------------------------------------------------
    // 11. Credit / Due Transaction
    // ------------------------------------------------------------------------
    test('11. Credit / Due recharge updates customer receivables consistently', () async {
      final partyKey = await Db.parties.add({
        'name': 'Faisal Rahman',
        'phone': '9847012345',
        'balance': 150.0,
      });

      final entry = await QuickRechargeDialog.recordRecharge(
        mobile: '9847012345',
        operator: 'BSNL',
        serviceType: 'Prepaid',
        retailAmount: 199.0,
        costPrice: 191.04,
        paymentMode: 'Credit / Due',
        partyKey: partyKey,
        partyName: 'Faisal Rahman',
      );

      expect(entry['status'], equals('SUCCESS'));
      expect(entry['paymentMode'], equals('Credit / Due'));

      // Party balance: 150 + 199 = 349.0
      final party = Db.parties.get(partyKey) as Map;
      expect(party['balance'], equals(349.0));
    });

    // ------------------------------------------------------------------------
    // 12. Cash Transaction
    // ------------------------------------------------------------------------
    test('12. Cash recharge preserves cash_in_hand and does NOT affect Db.sales', () async {
      await Db.bank.put('cash_in_hand', 500.0);

      final entry = await QuickRechargeDialog.recordRecharge(
        mobile: '9895000111',
        operator: 'Jio',
        serviceType: 'Prepaid',
        retailAmount: 239.0,
        costPrice: 231.83,
        paymentMode: 'Cash',
      );

      expect(entry['status'], equals('SUCCESS'));
      // Strict financial separation: recharge money must never affect normal cash in hand
      expect(Db.bank.get('cash_in_hand'), equals(500.0));

      // Turnover invariant: Db.sales must remain completely untouched
      expect(Db.sales.isEmpty, isTrue);
    });

    // ------------------------------------------------------------------------
    // 13. UPI Transaction
    // ------------------------------------------------------------------------
    test('13. UPI recharge preserves bank_balance and does NOT affect Db.sales', () async {
      await Db.bank.put('bank_balance', 2000.0);

      final entry = await QuickRechargeDialog.recordRecharge(
        mobile: '9995551122',
        operator: 'Vi',
        serviceType: 'Prepaid',
        retailAmount: 666.0,
        costPrice: 642.69,
        paymentMode: 'UPI',
      );

      expect(entry['status'], equals('SUCCESS'));
      // Strict financial separation: recharge money must never affect bank balance
      expect(Db.bank.get('bank_balance'), equals(2000.0));
      expect(Db.sales.isEmpty, isTrue);
    });

    // ------------------------------------------------------------------------
    // 14. Commission Accounting Calculation
    // ------------------------------------------------------------------------
    test('14. Commission profit recognized without inflating retail sales', () async {
      final entry = await QuickRechargeDialog.recordRecharge(
        mobile: '9876543210',
        operator: 'Jio',
        serviceType: 'Prepaid',
        retailAmount: 299.0,
        costPrice: 290.03,
        paymentMode: 'Cash',
      );

      final commission = (entry['commission'] as num).toDouble();
      expect(commission, closeTo(8.97, 0.01));
      expect(entry['retailAmount'], equals(299.0));
      expect(entry['costPrice'], equals(290.03));
      expect(Db.sales.isEmpty, isTrue);
    });

    // ------------------------------------------------------------------------
    // 15. Unconfigured Server Throws StateError (No Local Fallback)
    // ------------------------------------------------------------------------
    test('15. Unconfigured client strictly refuses local commit', () async {
      RechargeBackendBridge.configure(
        mode: RechargeBackendMode.supabaseEdgeFunction,
        supabaseClient: null, // Null client!
      );

      expect(
        () => QuickRechargeDialog.recordRecharge(
          mobile: '9876543210',
          operator: 'Jio',
          serviceType: 'Prepaid',
          retailAmount: 299.0,
          costPrice: 290.03,
          paymentMode: 'Cash',
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('Authoritative recharge backend client unconfigured'))),
      );

      expect(Db.recharges.isEmpty, isTrue);
    });

    // ------------------------------------------------------------------------
    // 16. App Restart / Crash Rollback Integrity
    // ------------------------------------------------------------------------
    test('16. Incomplete transaction does not corrupt ledger on restart', () async {
      // Simulate crash during server call by rejecting
      mockRejectSignatures = true;

      try {
        await QuickRechargeDialog.recordRecharge(
          mobile: '9876543210',
          operator: 'Jio',
          serviceType: 'Prepaid',
          retailAmount: 299.0,
          costPrice: 290.03,
          paymentMode: 'Cash',
        );
      } catch (_) {}

      // Re-initialize as on cold restart
      await AuthController.instance.init();

      // Assert zero corrupted or partial records exist
      expect(Db.recharges.isEmpty, isTrue);
      expect(Db.bank.get('cash_in_hand'), isNull);
    });
  });
}
