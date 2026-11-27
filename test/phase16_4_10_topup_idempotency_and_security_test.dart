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

  group('TEKFIX ERP - PHASE 16.4.10: TOP-UP IDEMPOTENCY & SECURITY TEST SUITE', () {
    late Directory tempDir;
    const testShopId = 'shop_staging_001';
    const testOwnerUid = 'owner_staging_001';
    const testDeviceId = 'DEV_STAGING_MOB_001';
    const testToken = 'valid_staging_owner_jwt';
    const testNonce = 'NONCE_TOPUP_STAGE_123';

    // Hardware signature generation helper
    String generateValidSignature(String canonicalPayload) {
      return 'VALID_SIG_FOR_${canonicalPayload.hashCode}';
    }

    late MockClient mockHttpClient;
    late SupabaseRechargeBridgeClient bridgeClient;
    final service = RechargeService.instance;

    // Simulated PostgreSQL staging state
    final Map<String, Map<String, dynamic>> stageWallets = {
      'WALLET_VI': {
        'shop_id': testShopId,
        'wallet_id': 'WALLET_VI',
        'operator': 'Vi',
        'own_prepaid_balance_paise': 10000, // ₹100.00 baseline
        'distributor_credit_balance_paise': 0,
        'total_balance_paise': 10000,
      }
    };

    final Map<String, Map<String, dynamic>> stageFloatDeposits = {}; // PK: deposit_id
    final Map<String, String> stageUtrMap = {}; // normalized_ref -> deposit_id
    final List<Map<String, dynamic>> stageWalletLogs = [];

    setUpAll(() async {
      GoogleFonts.config.allowRuntimeFetching = false;
      tempDir = await Directory.systemTemp.createTemp('topup_16_4_10_');
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

    setUp(() {
      service.resetLocalCacheForTesting();
      service.disableOpeningBalanceGateForTesting();

      mockHttpClient = MockClient((request) async {
        final path = request.url.path;
        final body = jsonDecode(request.body) as Map<String, dynamic>;

        final authHeader = request.headers['Authorization'] ?? '';
        if (authHeader == 'Bearer staff_token') {
          return http.Response(jsonEncode({'error': 'Unauthorized: Only an authenticated shop owner can perform top-up operations'}), 403);
        }
        if (authHeader != 'Bearer $testToken') {
          return http.Response(jsonEncode({'error': 'Unauthorized: Invalid token'}), 401);
        }

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
          final dId = body['deviceId'] as String?;
          final sig = body['deviceSignature'] as String?;
          final nonce = body['nonce'] as String?;
          final ref = body['referenceId'] as String? ?? 'DEP_AUTO';
          final source = body['source'] as String? ?? 'bank';

          // 1. Device Authorization
          if (dId == 'DEV_UNAUTHORIZED') {
            return http.Response(jsonEncode({'error': 'Device DEV_UNAUTHORIZED is not registered or has been revoked'}), 403);
          }

          // 2. Canonical Signature Verification
          final expectedCanonicalData = '$wId:$amtPaise:$ref:$source';
          final expectedCanonicalPayload = 'PROCESS_TOPUP:$sId:$testOwnerUid:$dId:$nonce:$expectedCanonicalData';
          final validSig = generateValidSignature(expectedCanonicalPayload);

          if (sig != validSig) {
            return http.Response(jsonEncode({
              'error': 'Cryptographic signature verification failed: Invalid key or altered payload'
            }), 403);
          }

          // 3. Normalized UTR Calculation
          final normalizedRef = ref.trim().toUpperCase();

          // 4. Deterministic Idempotency Check
          if (stageFloatDeposits.containsKey(ref) || stageUtrMap.containsKey(normalizedRef)) {
            final existingDepositId = stageFloatDeposits.containsKey(ref) ? ref : stageUtrMap[normalizedRef]!;
            final existing = stageFloatDeposits[existingDepositId]!;

            // Parameter integrity conflict check
            if (existing['amount_paise'] != amtPaise || existing['wallet_id'] != wId) {
              return http.Response(jsonEncode({
                'error': 'Idempotency conflict: Reference $ref already registered with different parameters'
              }), 400);
            }

            // Safe idempotent replay
            return http.Response(jsonEncode({
              'success': true,
              'idempotent_replay': true,
              'wallet_id': wId,
              'amount_paise': amtPaise,
              'balance_before_paise': existing['balance_before_paise'],
              'balance_after_paise': existing['balance_after_paise'],
              'total_balance_paise': stageWallets[wId]!['total_balance_paise'],
              'own_prepaid_balance_paise': stageWallets[wId]!['own_prepaid_balance_paise'],
              'reference_id': existingDepositId,
              'message': 'Idempotent replay: original topup confirmed without duplicate balance credit'
            }), 200);
          }

          // 5. Atomic Deposit Execution
          final wallet = stageWallets[wId]!;
          final before = wallet['own_prepaid_balance_paise'] as int;
          final after = before + amtPaise!;
          wallet['own_prepaid_balance_paise'] = after;
          wallet['total_balance_paise'] = after + (wallet['distributor_credit_balance_paise'] as int);

          stageFloatDeposits[ref] = {
            'deposit_id': ref,
            'wallet_id': wId,
            'amount_paise': amtPaise,
            'balance_before_paise': before,
            'balance_after_paise': after,
            'source': source,
            'reference_no': ref,
            'device_id': dId,
          };
          stageUtrMap[normalizedRef] = ref;

          stageWalletLogs.add({
            'wallet_id': wId,
            'entry_type': 'topup',
            'amount_paise': amtPaise,
            'device_id': dId,
            'reference_no': ref,
          });

          return http.Response(jsonEncode({
            'success': true,
            'idempotent_replay': false,
            'wallet_id': wId,
            'amount_paise': amtPaise,
            'balance_before_paise': before,
            'balance_after_paise': after,
            'own_prepaid_balance_paise': after,
            'total_balance_paise': wallet['total_balance_paise'],
            'reference_id': ref,
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

    tearDown(() {
      RechargeBackendBridge.reset();
    });

    // -------------------------------------------------------------------------
    // TEST 1: Valid Top-Up with Byte-for-Byte Canonical Signature
    // -------------------------------------------------------------------------
    test('TEST 1: Valid top-up with exact 8-part canonical signature succeeds', () async {
      const wId = 'WALLET_VI';
      const amtPaise = 5000;
      const ref = 'UTR_HDFC_998811';
      const source = 'bank';
      final canonicalPayload = 'PROCESS_TOPUP:$testShopId:$testOwnerUid:$testDeviceId:$testNonce:$wId:$amtPaise:$ref:$source';
      final sig = generateValidSignature(canonicalPayload);

      final res = await bridgeClient.processTopup(
        shopId: testShopId,
        walletId: wId,
        amountPaise: amtPaise,
        referenceId: ref,
        source: source,
        deviceId: testDeviceId,
        deviceSignature: sig,
        nonce: testNonce,
      );

      expect(res['success'], isTrue);
      expect(res['idempotent_replay'], isFalse);
      expect(res['balance_before_paise'], 10000);
      expect(res['balance_after_paise'], 15000);
      expect(stageWallets['WALLET_VI']!['own_prepaid_balance_paise'], 15000);
    });

    // -------------------------------------------------------------------------
    // TEST 2: Invalid Signature Rejection
    // -------------------------------------------------------------------------
    test('TEST 2: Invalid signature is rejected with HTTP 403', () async {
      expect(
        () => bridgeClient.processTopup(
          shopId: testShopId,
          walletId: 'WALLET_VI',
          amountPaise: 5000,
          referenceId: 'UTR_NEW_001',
          deviceId: testDeviceId,
          deviceSignature: 'CORRUPTED_OR_SHORT_SIGNATURE',
          nonce: testNonce,
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('Permission Denied'))),
      );
    });

    // -------------------------------------------------------------------------
    // TEST 3: Altered Payload Detection (Amount / Wallet / UTR / Source)
    // -------------------------------------------------------------------------
    test('TEST 3: Altering amount, wallet, UTR, or source invalidates signature', () async {
      const originalPayload = 'PROCESS_TOPUP:$testShopId:$testOwnerUid:$testDeviceId:$testNonce:WALLET_VI:5000:UTR_ALT_001:bank';
      final originalSig = generateValidSignature(originalPayload);

      // A. Altered Amount (5000 -> 10000)
      expect(
        () => bridgeClient.processTopup(
          shopId: testShopId,
          walletId: 'WALLET_VI',
          amountPaise: 10000, // Altered!
          referenceId: 'UTR_ALT_001',
          deviceId: testDeviceId,
          deviceSignature: originalSig,
          nonce: testNonce,
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('Permission Denied'))),
      );

      // B. Altered Wallet (WALLET_VI -> WALLET_JIO)
      expect(
        () => bridgeClient.processTopup(
          shopId: testShopId,
          walletId: 'WALLET_JIO', // Altered!
          amountPaise: 5000,
          referenceId: 'UTR_ALT_001',
          deviceId: testDeviceId,
          deviceSignature: originalSig,
          nonce: testNonce,
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('Permission Denied'))),
      );

      // C. Altered UTR
      expect(
        () => bridgeClient.processTopup(
          shopId: testShopId,
          walletId: 'WALLET_VI',
          amountPaise: 5000,
          referenceId: 'UTR_TAMPERED', // Altered!
          deviceId: testDeviceId,
          deviceSignature: originalSig,
          nonce: testNonce,
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('Permission Denied'))),
      );
    });

    // -------------------------------------------------------------------------
    // TEST 4: Same-Request Retry (Deterministic Idempotent Replay)
    // -------------------------------------------------------------------------
    test('TEST 4: Same request retry returns original result without double-credit', () async {
      const wId = 'WALLET_VI';
      const amtPaise = 5000;
      const ref = 'UTR_HDFC_998811'; // Same UTR as TEST 1
      const source = 'bank';
      final canonicalPayload = 'PROCESS_TOPUP:$testShopId:$testOwnerUid:$testDeviceId:$testNonce:$wId:$amtPaise:$ref:$source';
      final sig = generateValidSignature(canonicalPayload);

      final res = await bridgeClient.processTopup(
        shopId: testShopId,
        walletId: wId,
        amountPaise: amtPaise,
        referenceId: ref,
        source: source,
        deviceId: testDeviceId,
        deviceSignature: sig,
        nonce: testNonce,
      );

      expect(res['success'], isTrue);
      expect(res['idempotent_replay'], isTrue);
      // Balance remains strictly 15000 paise (Zero duplicate credit)
      expect(stageWallets['WALLET_VI']!['own_prepaid_balance_paise'], 15000);
    });

    // -------------------------------------------------------------------------
    // TEST 5: Different-Payload Retry with Same UTR is Rejected
    // -------------------------------------------------------------------------
    test('TEST 5: Retrying same UTR with different amount or wallet throws conflict exception', () async {
      const wId = 'WALLET_VI';
      const ref = 'UTR_HDFC_998811'; // Existing UTR from TEST 1 (5000 paise)
      const alteredAmtPaise = 20000; // Conflicting amount!
      final payload = 'PROCESS_TOPUP:$testShopId:$testOwnerUid:$testDeviceId:$testNonce:$wId:$alteredAmtPaise:$ref:bank';
      final sig = generateValidSignature(payload);

      expect(
        () => bridgeClient.processTopup(
          shopId: testShopId,
          walletId: wId,
          amountPaise: alteredAmtPaise,
          referenceId: ref,
          deviceId: testDeviceId,
          deviceSignature: sig,
          nonce: testNonce,
        ),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message', contains('Idempotency conflict'))),
      );
    });

    // -------------------------------------------------------------------------
    // TEST 6: Normalized Duplicate UTR Rejection (Case-Insensitive & Whitespace)
    // -------------------------------------------------------------------------
    test('TEST 6: Submitting same UTR with lowercase or trailing space is identified as duplicate', () async {
      const wId = 'WALLET_VI';
      const amtPaise = 5000;
      const whitespaceRef = ' utr_hdfc_998811 '; // Normalized to UTR_HDFC_998811
      final payload = 'PROCESS_TOPUP:$testShopId:$testOwnerUid:$testDeviceId:$testNonce:$wId:$amtPaise:$whitespaceRef:bank';
      final sig = generateValidSignature(payload);

      final res = await bridgeClient.processTopup(
        shopId: testShopId,
        walletId: wId,
        amountPaise: amtPaise,
        referenceId: whitespaceRef,
        deviceId: testDeviceId,
        deviceSignature: sig,
        nonce: testNonce,
      );

      expect(res['success'], isTrue);
      expect(res['idempotent_replay'], isTrue);
      expect(stageWallets['WALLET_VI']!['own_prepaid_balance_paise'], 15000);
    });

    // -------------------------------------------------------------------------
    // TEST 7: Unauthorized Device Rejection
    // -------------------------------------------------------------------------
    test('TEST 7: Unauthorized device attempting top-up is blocked with HTTP 403', () async {
      final payload = 'PROCESS_TOPUP:$testShopId:$testOwnerUid:DEV_UNAUTHORIZED:$testNonce:WALLET_VI:5000:UTR_UNAUTH:bank';
      final sig = generateValidSignature(payload);

      expect(
        () => bridgeClient.processTopup(
          shopId: testShopId,
          walletId: 'WALLET_VI',
          amountPaise: 5000,
          referenceId: 'UTR_UNAUTH',
          deviceId: 'DEV_UNAUTHORIZED',
          deviceSignature: sig,
          nonce: testNonce,
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('Permission Denied'))),
      );
    });

    // -------------------------------------------------------------------------
    // TEST 8: Staff Access Denial
    // -------------------------------------------------------------------------
    test('TEST 8: Staff token attempting top-up is strictly rejected with HTTP 403', () async {
      final staffClient = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: 'https://mwhsvidbrfkryuiwhnev.supabase.co/functions/v1/recharge-bridge',
        getFirebaseIdToken: () async => 'staff_token',
        httpClient: mockHttpClient,
      );

      expect(
        () => staffClient.processTopup(
          shopId: testShopId,
          walletId: 'WALLET_VI',
          amountPaise: 5000,
          deviceId: testDeviceId,
          deviceSignature: 'SIG',
          nonce: testNonce,
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('Permission Denied'))),
      );
    });

    // -------------------------------------------------------------------------
    // TEST 9: Existing Wallet Balance Preservation
    // -------------------------------------------------------------------------
    test('TEST 9: Unrelated wallets are strictly untouched during top-up', () async {
      stageWallets['WALLET_AIRTEL'] = {
        'shop_id': testShopId,
        'wallet_id': 'WALLET_AIRTEL',
        'operator': 'Airtel',
        'own_prepaid_balance_paise': 25000,
        'distributor_credit_balance_paise': 10000,
        'total_balance_paise': 35000,
      };

      // Top-up on VI
      const wId = 'WALLET_VI';
      const amtPaise = 3000;
      const ref = 'UTR_ISOLATION_001';
      final payload = 'PROCESS_TOPUP:$testShopId:$testOwnerUid:$testDeviceId:$testNonce:$wId:$amtPaise:$ref:bank';
      final sig = generateValidSignature(payload);

      await bridgeClient.processTopup(
        shopId: testShopId,
        walletId: wId,
        amountPaise: amtPaise,
        referenceId: ref,
        deviceId: testDeviceId,
        deviceSignature: sig,
        nonce: testNonce,
      );

      // Verify AIRTEL was completely preserved
      expect(stageWallets['WALLET_AIRTEL']!['own_prepaid_balance_paise'], 25000);
      expect(stageWallets['WALLET_AIRTEL']!['distributor_credit_balance_paise'], 10000);
      expect(stageWallets['WALLET_AIRTEL']!['total_balance_paise'], 35000);

      // Verify VI increased by exactly 3000
      expect(stageWallets['WALLET_VI']!['own_prepaid_balance_paise'], 18000);
    });

    // -------------------------------------------------------------------------
    // TEST 10: Device ID & Reference Immuntability in Ledger
    // -------------------------------------------------------------------------
    test('TEST 10: Every top-up records device_id and reference_no in ledger logs', () async {
      final lastLog = stageWalletLogs.last;
      expect(lastLog['device_id'], testDeviceId);
      expect(lastLog['reference_no'], 'UTR_ISOLATION_001');
      expect(lastLog['entry_type'], 'topup');
      expect(lastLog['amount_paise'], 3000);
    });
  });
}
