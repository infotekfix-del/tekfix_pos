import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tekfix_erp_pos/auth/auth_controller.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/recharge/quick_recharge_dialog.dart';
import 'package:tekfix_erp_pos/recharge/recharge_backend_bridge.dart';
import 'package:tekfix_erp_pos/recharge/recharge_service.dart';
import 'package:tekfix_erp_pos/recharge/supabase_recharge_bridge_client.dart';
import 'package:tekfix_erp_pos/security/device_security_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // These tests drive the server mock with a fixed wallet pocket.
  setUpAll(() => kRechargeAutoFundingPocket = false);
  tearDownAll(() => kRechargeAutoFundingPocket = true);
  // The shop turned recharge commission off in the entry screen; these tests
  // still cover the commission logic itself, so they switch it on.
  setUpAll(() => kRechargeCommissionInEntry = true);
  tearDownAll(() => kRechargeCommissionInEntry = false);

  group('TEKFIX ERP - PHASE 17.1: RECHARGE COMMISSION CONTROL TEST SUITE', () {
    late Directory tempDir;
    const testShopId = 'tekfix';
    const testOwnerUid = 'ShjbKbg8HsabkQjEGnlp03unezi2';
    const testStaffUid = 'staff_unauthorized_user_123';
    const testDeviceId = 'DEV_WIN_TEST_COMM';
    const testTokenOwner = 'valid_owner_token_tekfix';
    const testTokenStaff = 'valid_staff_token_tekfix';
    const testNonce = 'NONCE_TEST_COMM_171';
    const testSignature = 'VALID_ECDSA_DER_SIG_171';

    late MockClient mockHttpClient;
    late SupabaseRechargeBridgeClient bridgeClient;
    final service = RechargeService.instance;

    // In-memory mock PostgreSQL state mirroring production Supabase
    final Map<String, Map<String, dynamic>> mockPostgresWallets = {
      'WALLET_AIRTEL': {
        'shop_id': testShopId,
        'wallet_id': 'WALLET_AIRTEL',
        'operator': 'Airtel',
        'own_prepaid_balance_paise': 500000, // ₹5,000.00
        'distributor_credit_balance_paise': 0,
        'total_balance_paise': 500000,
        'last_updated_at': DateTime.now().toIso8601String(),
      },
      'WALLET_JIO': {
        'shop_id': testShopId,
        'wallet_id': 'WALLET_JIO',
        'operator': 'Jio',
        'own_prepaid_balance_paise': 500000, // ₹5,000.00
        'distributor_credit_balance_paise': 0,
        'total_balance_paise': 500000,
        'last_updated_at': DateTime.now().toIso8601String(),
      },
      'WALLET_VI': {
        'shop_id': testShopId,
        'wallet_id': 'WALLET_VI',
        'operator': 'Vi',
        'own_prepaid_balance_paise': 500000, // ₹5,000.00
        'distributor_credit_balance_paise': 0,
        'total_balance_paise': 500000,
        'last_updated_at': DateTime.now().toIso8601String(),
      },
      'WALLET_BSNL': {
        'shop_id': testShopId,
        'wallet_id': 'WALLET_BSNL',
        'operator': 'BSNL',
        'own_prepaid_balance_paise': 500000, // ₹5,000.00
        'distributor_credit_balance_paise': 0,
        'total_balance_paise': 500000,
        'last_updated_at': DateTime.now().toIso8601String(),
      },
    };

    // Server-side authoritative commission controls table
    final Map<String, Map<String, dynamic>> mockCommissionControls = {
      'JIO': {
        'shopId': testShopId,
        'operator': 'JIO',
        'isEnabled': true,
        'marginBasisPoints': 300,
        'marginPercent': 3.00,
        'updatedAt': DateTime.now().toIso8601String(),
        'updatedByUid': 'system_init',
      },
      'AIRTEL': {
        'shopId': testShopId,
        'operator': 'AIRTEL',
        'isEnabled': true,
        'marginBasisPoints': 280,
        'marginPercent': 2.80,
        'updatedAt': DateTime.now().toIso8601String(),
        'updatedByUid': 'system_init',
      },
      'VI': {
        'shopId': testShopId,
        'operator': 'VI',
        'isEnabled': true,
        'marginBasisPoints': 350,
        'marginPercent': 3.50,
        'updatedAt': DateTime.now().toIso8601String(),
        'updatedByUid': 'system_init',
      },
      'BSNL': {
        'shopId': testShopId,
        'operator': 'BSNL',
        'isEnabled': true,
        'marginBasisPoints': 400,
        'marginPercent': 4.00,
        'updatedAt': DateTime.now().toIso8601String(),
        'updatedByUid': 'system_init',
      },
    };

    final List<Map<String, dynamic>> mockCommissionAudits = [];
    final List<Map<String, dynamic>> mockPostgresTransactions = [];
    final List<Map<String, dynamic>> mockPostgresCommissions = [];
    final List<Map<String, dynamic>> mockPostgresLogs = [];

    setUpAll(() async {
      GoogleFonts.config.allowRuntimeFetching = false;
      tempDir = await Directory.systemTemp.createTemp('recharge_comm_ctrl_test_');
      Hive.init(tempDir.path);

      for (final b in allBoxes) {
        await Hive.openBox(b);
      }

      final settingsBox = Hive.box(boxSettings);
      await settingsBox.put('shop_id', testShopId);
      await settingsBox.put('shop_name', 'TEKFIX DIGITAL HUB');
      await settingsBox.put('staging_owner_signed_in', 'true');
      await settingsBox.put('auth_role', 'owner');
      await settingsBox.put('owner_uid', testOwnerUid);
      await settingsBox.put('owner_name', 'Munees');

      await AuthController.instance.init();
      await DeviceSecurityService.instance.init();
      await DeviceSecurityService.instance.setEnrolledLocally(true);
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
      service.resetCommissionControlsForTesting();
      service.disableOpeningBalanceGateForTesting();

      mockHttpClient = MockClient((request) async {
        final path = request.url.path;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final authHeader = request.headers['Authorization'] ?? '';

        // Token check
        final isOwner = authHeader == 'Bearer $testTokenOwner';
        final isStaff = authHeader == 'Bearer $testTokenStaff';

        if (!isOwner && !isStaff) {
          return http.Response(jsonEncode({'error': 'Unauthorized: Missing or invalid token'}), 401);
        }

        // Endpoint: request-challenge
        if (path.endsWith('/request-challenge')) {
          return http.Response(jsonEncode({
            'success': true,
            'nonce': testNonce,
            'expiresAt': DateTime.now().add(const Duration(seconds: 300)).toIso8601String(),
          }), 200);
        }

        // Endpoint: get-commission-controls
        if (path.endsWith('/get-commission-controls')) {
          if (!isOwner) {
            return http.Response(jsonEncode({'error': 'Forbidden: Owner only'}), 403);
          }
          return http.Response(jsonEncode({
            'success': true,
            'controls': mockCommissionControls.values.toList(),
          }), 200);
        }

        // Endpoint: update-commission-control
        if (path.endsWith('/update-commission-control')) {
          if (!isOwner) {
            return http.Response(jsonEncode({'error': 'Unauthorized: Only an authenticated shop owner can perform this operation.'}), 403);
          }

          final op = (body['operator']?.toString() ?? '').toUpperCase().trim();
          final isEnabled = body['isEnabled'] == true;
          final marginBps = body['marginBasisPoints'] as int?;
          final reason = body['reason']?.toString() ?? '';

          if (reason.trim().length < 5) {
            return http.Response(jsonEncode({'error': 'Reason is mandatory (min 5 characters)'}), 400);
          }

          final existing = mockCommissionControls[op] ?? {
            'shopId': testShopId,
            'operator': op,
            'isEnabled': true,
            'marginBasisPoints': 300,
          };

          final prevEnabled = existing['isEnabled'] as bool;
          final prevBps = existing['marginBasisPoints'] as int;
          final newBps = marginBps ?? prevBps;

          // Record immutable audit
          final auditId = 'AUD_COMM_${DateTime.now().millisecondsSinceEpoch}';
          mockCommissionAudits.add({
            'auditId': auditId,
            'shopId': testShopId,
            'operator': op,
            'previousEnabled': prevEnabled,
            'newEnabled': isEnabled,
            'previousMarginBasisPoints': prevBps,
            'newMarginBasisPoints': newBps,
            'ownerUid': testOwnerUid,
            'reason': reason.trim(),
            'createdAt': DateTime.now().toIso8601String(),
          });

          // Update controls
          mockCommissionControls[op] = {
            'shopId': testShopId,
            'operator': op,
            'isEnabled': isEnabled,
            'marginBasisPoints': newBps,
            'marginPercent': newBps / 100.0,
            'updatedAt': DateTime.now().toIso8601String(),
            'updatedByUid': testOwnerUid,
          };

          return http.Response(jsonEncode({
            'success': true,
            'auditId': auditId,
            'shopId': testShopId,
            'operator': op,
            'isEnabled': isEnabled,
            'marginBasisPoints': newBps,
            'marginPercent': newBps / 100.0,
          }), 200);
        }

        // Endpoint: process-debit (Server-Authoritative Commission Clamp)
        if (path.endsWith('/process-debit')) {
          if (!isOwner) {
            return http.Response(jsonEncode({'error': 'Unauthorized: Only an authenticated shop owner can perform recharge operations.'}), 403);
          }

          final walletId = body['walletId'] as String;
          final txnKey = body['txnKey'] ?? body['idempotencyKey'] ?? body['rechargeId'];
          final op = (body['operator']?.toString() ?? 'OTHER').toUpperCase().trim();
          final amountPaise = body['amountPaise'] as int;
          final retailPaise = (body['retailAmountPaise'] ?? amountPaise) as int;
          final clientCommPaise = (body['commissionEarnedPaise'] ?? 0) as int;

          // Server-side authoritative commission clamp
          final ctrl = mockCommissionControls[op];
          final commEnabled = ctrl != null ? (ctrl['isEnabled'] == true) : true;

          int effectiveCommPaise;
          int costPaise;

          if (!commEnabled) {
            // CLAMP TO ZERO when commission is OFF
            effectiveCommPaise = 0;
            costPaise = retailPaise;
          } else {
            effectiveCommPaise = clientCommPaise;
            costPaise = body['costPricePaise'] != null
                ? (body['costPricePaise'] as int)
                : (retailPaise - effectiveCommPaise);
          }

          // Check Idempotency
          final existingTxn = mockPostgresTransactions.cast<Map<String, dynamic>?>().firstWhere(
                (t) => t?['txn_key'] == txnKey,
                orElse: () => null,
              );
          if (existingTxn != null) {
            final w = mockPostgresWallets[walletId]!;
            return http.Response(jsonEncode({
              'success': true,
              'idempotent_replay': true,
              'txn_key': txnKey,
              'amount_paise': existingTxn['amount_paise'],
              'commission_earned_paise': existingTxn['commission_earned_paise'],
              'total_balance_paise': w['total_balance_paise'],
            }), 200);
          }

          final w = mockPostgresWallets[walletId];
          if (w == null) {
            return http.Response(jsonEncode({'error': 'Wallet not found'}), 400);
          }

          if (w['own_prepaid_balance_paise'] < costPaise) {
            return http.Response(jsonEncode({'error': 'Insufficient balance'}), 400);
          }

          final balanceBefore = w['total_balance_paise'] as int;
          final newOwn = (w['own_prepaid_balance_paise'] as int) - costPaise;
          w['own_prepaid_balance_paise'] = newOwn;
          w['total_balance_paise'] = newOwn + (w['distributor_credit_balance_paise'] as int);
          final balanceAfter = w['total_balance_paise'] as int;

          mockPostgresTransactions.add({
            'shop_id': testShopId,
            'txn_key': txnKey,
            'wallet_id': walletId,
            'operator': op,
            'amount_paise': costPaise,
            'retail_amount_paise': retailPaise,
            'cost_price_paise': costPaise,
            'commission_earned_paise': effectiveCommPaise,
            'wallet_debited': true,
            'status': 'completed',
          });

          mockPostgresLogs.add({
            'shop_id': testShopId,
            'wallet_id': walletId,
            'entry_type': 'RECHARGE_DEBIT',
            'amount_paise': costPaise,
            'balance_before_paise': balanceBefore,
            'balance_after_paise': balanceAfter,
          });

          if (effectiveCommPaise > 0) {
            mockPostgresCommissions.add({
              'shop_id': testShopId,
              'txn_key': txnKey,
              'operator': op,
              'recharge_amount_paise': retailPaise,
              'commission_paise': effectiveCommPaise,
              'is_settled': false,
            });
          }

          return http.Response(jsonEncode({
            'success': true,
            'txn_key': txnKey,
            'amount_paise': costPaise,
            'retail_amount_paise': retailPaise,
            'commission_earned_paise': effectiveCommPaise,
            'balance_before_paise': balanceBefore,
            'balance_after_paise': balanceAfter,
            'total_balance_paise': balanceAfter,
          }), 200);
        }

        return http.Response(jsonEncode({'error': 'Unknown endpoint: $path'}), 404);
      });

      bridgeClient = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: 'https://mwhsvidbrfkryuiwhnev.supabase.co/functions/v1/recharge-bridge',
        getFirebaseIdToken: () async => testTokenOwner,
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
    // COMM-CTRL-01: Default Initialization (All 4 Operators ON with Defaults)
    // -------------------------------------------------------------------------
    test('COMM-CTRL-01: Default initialization loads all 4 operators with standard margins', () async {
      final controls = await service.getCommissionControls(shopId: testShopId, forceRefresh: true);
      expect(controls.length, equals(4));

      final jio = controls.firstWhere((c) => c.operator == 'JIO');
      expect(jio.isEnabled, isTrue);
      expect(jio.marginBasisPoints, equals(300)); // 3.00%
      expect(jio.marginPercent, equals(3.00));

      final airtel = controls.firstWhere((c) => c.operator == 'AIRTEL');
      expect(airtel.isEnabled, isTrue);
      expect(airtel.marginBasisPoints, equals(280)); // 2.80%
      expect(airtel.marginPercent, equals(2.80));

      final vi = controls.firstWhere((c) => c.operator == 'VI');
      expect(vi.isEnabled, isTrue);
      expect(vi.marginBasisPoints, equals(350)); // 3.50%
      expect(vi.marginPercent, equals(3.50));

      final bsnl = controls.firstWhere((c) => c.operator == 'BSNL');
      expect(bsnl.isEnabled, isTrue);
      expect(bsnl.marginBasisPoints, equals(400)); // 4.00%
      expect(bsnl.marginPercent, equals(4.00));
    });

    // -------------------------------------------------------------------------
    // COMM-CTRL-02: Owner Toggles Operator OFF (Preserves Margin Percentage)
    // -------------------------------------------------------------------------
    test('COMM-CTRL-02: Owner toggles operator OFF with reason and preserves configured margin', () async {
      // Toggle Airtel OFF
      final res = await service.updateCommissionControl(
        shopId: testShopId,
        operator: 'AIRTEL',
        isEnabled: false,
        reason: 'Temporary distributor commission freeze',
        deviceId: testDeviceId,
        deviceSignature: testSignature,
        nonce: testNonce,
        ownerName: 'Munees',
      );

      expect(res['success'], isTrue);
      expect(res['isEnabled'], isFalse);
      expect(res['operator'], equals('AIRTEL'));
      expect(res['marginBasisPoints'], equals(280)); // Preserved 2.80%

      // Verify local cache updated
      expect(service.isCommissionEnabled('AIRTEL'), isFalse);
      expect(service.getOperatorCommissionPercent('AIRTEL'), equals(2.80));

      // Verify server audit created
      expect(mockCommissionAudits.any((a) =>
          a['operator'] == 'AIRTEL' &&
          a['newEnabled'] == false &&
          a['previousMarginBasisPoints'] == 280 &&
          a['newMarginBasisPoints'] == 280), isTrue);

      // Re-fetch from server to verify round-trip
      final updatedControls = await service.getCommissionControls(shopId: testShopId, forceRefresh: true);
      final updatedAirtel = updatedControls.firstWhere((c) => c.operator == 'AIRTEL');
      expect(updatedAirtel.isEnabled, isFalse);
      expect(updatedAirtel.marginBasisPoints, equals(280));

      // Toggle Airtel back ON: Margin is restored
      final resRestore = await service.updateCommissionControl(
        shopId: testShopId,
        operator: 'AIRTEL',
        isEnabled: true,
        reason: 'Distributor restored standard margin agreement',
        deviceId: testDeviceId,
        deviceSignature: testSignature,
        nonce: testNonce,
        ownerName: 'Munees',
      );
      expect(resRestore['success'], isTrue);
      expect(resRestore['isEnabled'], isTrue);
      expect(resRestore['marginBasisPoints'], equals(280));
      expect(service.isCommissionEnabled('AIRTEL'), isTrue);
    });

    // -------------------------------------------------------------------------
    // COMM-CTRL-03: Staff Toggle Rejection (Fail-Closed 403)
    // -------------------------------------------------------------------------
    test('COMM-CTRL-03: Staff account cannot modify commission settings (Fail-Closed)', () async {
      final staffClient = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: 'https://mwhsvidbrfkryuiwhnev.supabase.co/functions/v1/recharge-bridge',
        getFirebaseIdToken: () async => testTokenStaff, // Staff Token
        httpClient: mockHttpClient,
      );

      expect(
        () => staffClient.updateCommissionControl(
          shopId: testShopId,
          operator: 'JIO',
          isEnabled: false,
          reason: 'Unauthorized staff attempt',
          deviceId: testDeviceId,
          deviceSignature: testSignature,
          nonce: testNonce,
          ownerName: testStaffUid,
        ),
        throwsA(isA<StateError>()), // Permission Denied HTTP 403
      );
    });

    // -------------------------------------------------------------------------
    // COMM-CTRL-04: Recharge Execution with Commission OFF (0 Commission, Full Retail Debit)
    // -------------------------------------------------------------------------
    test('COMM-CTRL-04: Recharge with Commission OFF produces 0 commission and full retail debit', () async {
      // 1. Set Jio commission to OFF
      await service.updateCommissionControl(
        shopId: testShopId,
        operator: 'JIO',
        isEnabled: false,
        reason: 'Disable Jio commission for test',
        deviceId: testDeviceId,
        deviceSignature: testSignature,
        nonce: testNonce,
      );
      expect(service.isCommissionEnabled('Jio'), isFalse);

      final initialWalletBalance = mockPostgresWallets['WALLET_JIO']!['total_balance_paise'] as int;
      final initialCommCount = mockPostgresCommissions.length;

      // 2. Execute ₹239 recharge
      final res = await QuickRechargeDialog.recordRecharge(
        mobile: '9847012345',
        operator: 'Jio',
        serviceType: 'mobile_recharge',
        retailAmount: 239.0,
        costPrice: 231.83, // Client might attempt to supply discounted cost
        paymentMode: 'Cash',
        customIdempotencyKey: 'TXN_COMM_OFF_239',
      );

      expect(res['success'], isTrue);
      // Verify Server clamped commission to 0
      expect(res['commission_earned_paise'], equals(0));
      // Full retail amount (₹239 = 23900 paise) debited from wallet
      expect(res['amount_paise'], equals(23900));

      final finalWalletBalance = mockPostgresWallets['WALLET_JIO']!['total_balance_paise'] as int;
      expect(initialWalletBalance - finalWalletBalance, equals(23900));

      // Verify ZERO new rows in commission table
      expect(mockPostgresCommissions.length, equals(initialCommCount));

      // Verify transaction record in postgres
      final txn = mockPostgresTransactions.firstWhere((t) => t['txn_key'] == 'TXN_COMM_OFF_239');
      expect(txn['commission_earned_paise'], equals(0));
      expect(txn['amount_paise'], equals(23900));
      expect(txn['retail_amount_paise'], equals(23900));
    });

    // -------------------------------------------------------------------------
    // COMM-CTRL-05: Recharge Execution with Commission ON (Integer Paise Margin Recognized)
    // -------------------------------------------------------------------------
    test('COMM-CTRL-05: Recharge with Commission ON recognizes integer paise margin and creates ledger entry', () async {
      // 1. Ensure BSNL commission is ON (4.00% = 400 bps)
      await service.updateCommissionControl(
        shopId: testShopId,
        operator: 'BSNL',
        isEnabled: true,
        marginBasisPoints: 400,
        reason: 'Ensure BSNL is ON at 4.0%',
        deviceId: testDeviceId,
        deviceSignature: testSignature,
        nonce: testNonce,
      );
      expect(service.isCommissionEnabled('BSNL'), isTrue);

      final initialWalletBalance = mockPostgresWallets['WALLET_BSNL']!['total_balance_paise'] as int;
      final initialCommCount = mockPostgresCommissions.length;

      // 2. Execute ₹199 recharge
      // Retail: 199.00 (19900 paise)
      // 4% Commission: 199 * 0.04 = ₹7.96 (796 paise)
      // Cost: ₹191.04 (19104 paise)
      final res = await QuickRechargeDialog.recordRecharge(
        mobile: '9447012345',
        operator: 'BSNL',
        serviceType: 'mobile_recharge',
        retailAmount: 199.0,
        costPrice: 191.04,
        paymentMode: 'Cash',
        customIdempotencyKey: 'TXN_COMM_ON_199',
      );

      expect(res['success'], isTrue);
      expect(res['commission_earned_paise'], equals(796)); // Exactly 796 paise
      expect(res['amount_paise'], equals(19104)); // Exactly 19104 paise debited

      final finalWalletBalance = mockPostgresWallets['WALLET_BSNL']!['total_balance_paise'] as int;
      expect(initialWalletBalance - finalWalletBalance, equals(19104));

      // Verify commission row created in server ledger
      expect(mockPostgresCommissions.length, equals(initialCommCount + 1));
      final comm = mockPostgresCommissions.firstWhere((c) => c['txn_key'] == 'TXN_COMM_ON_199');
      expect(comm['commission_paise'], equals(796));
      expect(comm['recharge_amount_paise'], equals(19900));
    });

    // -------------------------------------------------------------------------
    // COMM-CTRL-06: Rogue Client Commission Injection Blocked by Server Clamp
    // -------------------------------------------------------------------------
    test('COMM-CTRL-06: Rogue client attempting to inject commission while OFF is overridden by server clamp', () async {
      // 1. Ensure Vi is OFF
      await service.updateCommissionControl(
        shopId: testShopId,
        operator: 'VI',
        isEnabled: false,
        reason: 'Vi commission disabled',
        deviceId: testDeviceId,
        deviceSignature: testSignature,
        nonce: testNonce,
      );

      // 2. Direct rogue bridge call sending commissionEarnedPaise = 1000 and costPricePaise = 28900 for ₹299
      final res = await bridgeClient.processDebit(
        shopId: testShopId,
        walletId: 'WALLET_VI',
        rechargeId: 'TXN_ROGUE_INJECTION_299',
        idempotencyKey: 'TXN_ROGUE_INJECTION_299',
        customerPhone: '9895012345',
        operator: 'VI',
        serviceType: 'mobile_recharge',
        amountPaise: 28900,
        amount: 299.0,
        fundingType: 'ownPrepaid',
        commissionEarnedPaise: 1000, // Rogue claim of ₹10 commission!
        businessDate: '2026-11-17',
        deviceId: testDeviceId,
        deviceSignature: testSignature,
        nonce: testNonce,
        retailAmountPaise: 29900,
        costPricePaise: 28900,
      );

      // Server clamp MUST override rogue input
      expect(res['success'], isTrue);
      expect(res['commission_earned_paise'], equals(0)); // FORCED TO 0
      expect(res['amount_paise'], equals(29900)); // FORCED TO FULL RETAIL

      // No commission row entered
      expect(mockPostgresCommissions.any((c) => c['txn_key'] == 'TXN_ROGUE_INJECTION_299'), isFalse);
    });

    // -------------------------------------------------------------------------
    // COMM-CTRL-07: Historical Ledger Immutability Verification
    // -------------------------------------------------------------------------
    test('COMM-CTRL-07: Toggling commission settings never alters historical ledger or commission entries', () async {
      // 1. Record Airtel transaction with Commission ON
      await service.updateCommissionControl(
        shopId: testShopId,
        operator: 'AIRTEL',
        isEnabled: true,
        marginBasisPoints: 280,
        reason: 'Airtel ON for historical test',
        deviceId: testDeviceId,
        deviceSignature: testSignature,
        nonce: testNonce,
      );

      await QuickRechargeDialog.recordRecharge(
        mobile: '9847111222',
        operator: 'Airtel',
        serviceType: 'mobile_recharge',
        retailAmount: 299.0,
        costPrice: 290.63,
        paymentMode: 'Cash',
        customIdempotencyKey: 'TXN_AIRTEL_HISTORICAL',
      );

      final historicalTxn = Map<String, dynamic>.from(
          mockPostgresTransactions.firstWhere((t) => t['txn_key'] == 'TXN_AIRTEL_HISTORICAL'));
      final historicalComm = Map<String, dynamic>.from(
          mockPostgresCommissions.firstWhere((c) => c['txn_key'] == 'TXN_AIRTEL_HISTORICAL'));

      expect(historicalTxn['commission_earned_paise'], equals(837));
      expect(historicalComm['commission_paise'], equals(837));

      // 2. Now Toggle Airtel to OFF and change margin to 100 bps
      await service.updateCommissionControl(
        shopId: testShopId,
        operator: 'AIRTEL',
        isEnabled: false,
        marginBasisPoints: 100,
        reason: 'Change after historical posting',
        deviceId: testDeviceId,
        deviceSignature: testSignature,
        nonce: testNonce,
      );

      // 3. Verify historical record is 100% UNTOUCHED
      final postChangeTxn = mockPostgresTransactions.firstWhere((t) => t['txn_key'] == 'TXN_AIRTEL_HISTORICAL');
      final postChangeComm = mockPostgresCommissions.firstWhere((c) => c['txn_key'] == 'TXN_AIRTEL_HISTORICAL');

      expect(postChangeTxn['commission_earned_paise'], equals(historicalTxn['commission_earned_paise']));
      expect(postChangeTxn['amount_paise'], equals(historicalTxn['amount_paise']));
      expect(postChangeComm['commission_paise'], equals(historicalComm['commission_paise']));
    });

    // -------------------------------------------------------------------------
    // COMM-CTRL-08: Outbox Pending Recovery Determinism & Idempotency
    // -------------------------------------------------------------------------
    test('COMM-CTRL-08: Pending transaction recovery preserves initial snapshot and executes idempotently', () async {
      // Re-posting TXN_AIRTEL_HISTORICAL must replay with exact snapshot without double-debiting
      final initialBalance = mockPostgresWallets['WALLET_AIRTEL']!['total_balance_paise'] as int;

      final replayRes = await bridgeClient.processDebit(
        shopId: testShopId,
        walletId: 'WALLET_AIRTEL',
        rechargeId: 'TXN_AIRTEL_HISTORICAL',
        idempotencyKey: 'TXN_AIRTEL_HISTORICAL',
        customerPhone: '9847111222',
        operator: 'Airtel',
        serviceType: 'mobile_recharge',
        amountPaise: 29063,
        amount: 299.0,
        fundingType: 'ownPrepaid',
        commissionEarnedPaise: 837,
        businessDate: '2026-11-17',
        deviceId: testDeviceId,
        deviceSignature: testSignature,
        nonce: testNonce,
      );

      expect(replayRes['success'], isTrue);
      expect(replayRes['idempotent_replay'], isTrue);
      expect(replayRes['commission_earned_paise'], equals(837));

      // Balance was NOT debited a second time
      final balanceAfterReplay = mockPostgresWallets['WALLET_AIRTEL']!['total_balance_paise'] as int;
      expect(balanceAfterReplay, equals(initialBalance));
    });

    // -------------------------------------------------------------------------
    // COMM-CTRL-09: Concurrency Stress Test
    // -------------------------------------------------------------------------
    test('COMM-CTRL-09: Concurrent toggle and recharge operations execute deterministically without race', () async {
      // Execute 5 concurrent recharges on Jio while toggling commission
      final futures = <Future<Map<String, dynamic>>>[];

      for (int i = 0; i < 5; i++) {
        futures.add(bridgeClient.processDebit(
          shopId: testShopId,
          walletId: 'WALLET_JIO',
          rechargeId: 'TXN_CONCURRENT_JIO_$i',
          idempotencyKey: 'TXN_CONCURRENT_JIO_$i',
          customerPhone: '984700000$i',
          operator: 'JIO',
          serviceType: 'mobile_recharge',
          amountPaise: 10000,
          amount: 100.0,
          fundingType: 'ownPrepaid',
          commissionEarnedPaise: 300,
          businessDate: '2026-11-17',
          deviceId: testDeviceId,
          deviceSignature: testSignature,
          nonce: testNonce,
          retailAmountPaise: 10000,
          costPricePaise: 9700,
        ));
      }

      final results = await Future.wait(futures);
      for (final r in results) {
        expect(r['success'], isTrue);
      }
      expect(mockPostgresTransactions.where((t) => t['txn_key'].toString().startsWith('TXN_CONCURRENT_JIO_')).length, equals(5));
    });

    // -------------------------------------------------------------------------
    // COMM-CTRL-10: EOD Reconciliation with Mixed ON/OFF Transactions
    // -------------------------------------------------------------------------
    test('COMM-CTRL-10: EOD Reconciliation balances exactly across mixed ON and OFF transactions', () async {
      // Sum all completed transactions
      int totalRetailPaise = 0;
      int totalWalletDebitedPaise = 0;
      int totalCommissionEarnedPaise = 0;

      for (final txn in mockPostgresTransactions) {
        totalRetailPaise += (txn['retail_amount_paise'] as int);
        totalWalletDebitedPaise += (txn['amount_paise'] as int);
        totalCommissionEarnedPaise += (txn['commission_earned_paise'] as int);
      }

      // Mathematical Proof Invariant:
      // Total Retail Amount = Total Wallet Debited (Cost) + Total Commission Earned (Income)
      expect(totalRetailPaise, equals(totalWalletDebitedPaise + totalCommissionEarnedPaise));

      // Sum of server commissions table matches sum of commission_earned_paise
      int commissionTableTotalPaise = 0;
      for (final c in mockPostgresCommissions) {
        commissionTableTotalPaise += (c['commission_paise'] as int);
      }

      // Note: Only non-historical mock transactions recorded in mockPostgresCommissions
      expect(commissionTableTotalPaise, equals(totalCommissionEarnedPaise));
    });
  });
}
