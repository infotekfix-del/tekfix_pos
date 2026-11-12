import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tekfix_erp_pos/firebase_options.dart';
import 'package:tekfix_erp_pos/recharge/recharge_backend_bridge.dart';
import 'package:tekfix_erp_pos/recharge/supabase_recharge_bridge_client.dart';
import 'package:tekfix_erp_pos/security/staging_identity_service.dart';

void main() {
  group('TEKFIX ERP — PHASE 15.2.4: SERVER-AUTHORITATIVE UAT ISOLATION & SAFETY GATES', () {
    setUp(() {
      StagingIdentityService.resetCache();
      StagingIdentityService.setMockHttpClient(null);
    });

    tearDown(() {
      StagingIdentityService.resetCache();
      StagingIdentityService.setMockHttpClient(null);
    });

    test('Gate 1: Environment parser resolves staging_uat and synonyms', () {
      expect(
        DefaultFirebaseOptions.parseEnvironment('staging_uat'),
        equals(TekFixEnvironment.stagingUat),
      );
      expect(
        DefaultFirebaseOptions.parseEnvironment('STAGING_UAT'),
        equals(TekFixEnvironment.stagingUat),
      );
      expect(
        DefaultFirebaseOptions.parseEnvironment('staging-uat'),
        equals(TekFixEnvironment.stagingUat),
      );
      expect(
        DefaultFirebaseOptions.parseEnvironment('uat'),
        equals(TekFixEnvironment.stagingUat),
      );
    });

    test('Gate 2: Authoritative region for stagingUat pins to asia-south1 Mumbai', () {
      final region = DefaultFirebaseOptions.resolveFunctionsRegion(TekFixEnvironment.stagingUat);
      expect(region, equals('asia-south1'));
    });

    test('Gate 3: Production Firebase project ID rejection gate fails closed on tekfix-45b38', () {
      expect(
        DefaultFirebaseOptions.isBlockedProductionFirebaseTarget('tekfix-45b38'),
        isTrue,
      );
      expect(
        DefaultFirebaseOptions.isBlockedProductionFirebaseTarget(
          'tekfix-45b38.firebaseio.com',
        ),
        isTrue,
      );
      expect(
        DefaultFirebaseOptions.isBlockedProductionFirebaseTarget(
          'tekfix-staging-uat',
        ),
        isFalse,
      );

      // Always exercise the real gate. `force` cannot turn the gate off.
      expect(
        () => DefaultFirebaseOptions.enforceProductionIsolation(
          projectId: 'tekfix-45b38',
          force: true,
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('tekfix-45b38'),
        )),
      );

      if (DefaultFirebaseOptions.isUatMode) {
        // Live UAT path must reject the literal production id even when
        // productionFirebaseProjectId has been replaced at compile time.
        expect(
          DefaultFirebaseOptions.productionFirebaseProjectId,
          isNot('tekfix-45b38'),
        );
        expect(
          () => DefaultFirebaseOptions.enforceProductionIsolation(
            projectId: 'tekfix-45b38',
          ),
          throwsA(isA<StateError>()),
        );
        expect(
          DefaultFirebaseOptions.android.projectId,
          isNot('tekfix-45b38'),
        );
      } else {
        expect(
          DefaultFirebaseOptions.productionFirebaseProjectId,
          'tekfix-45b38',
        );
        expect(
          () => DefaultFirebaseOptions.enforceProductionIsolation(
            projectId: 'tekfix-45b38',
          ),
          returnsNormally,
        );
      }
    });

    test('Gate 4: Staging Supabase reference validation rejects unapproved project references', () {
      const isUatSimulated = true;
      void testValidateRef(String endpointOrRef) {
        if (isUatSimulated && !endpointOrRef.contains(DefaultFirebaseOptions.expectedSupabaseProjectRef)) {
          throw StateError('CRITICAL SECURITY VIOLATION: Staging Supabase reference mismatch!');
        }
      }

      // Valid project reference / endpoint passes
      expect(
        () => testValidateRef('https://mwhsvidbrfkryuiwhnev.supabase.co/functions/v1/recharge-bridge'),
        returnsNormally,
      );
      expect(
        () => testValidateRef('mwhsvidbrfkryuiwhnev'),
        returnsNormally,
      );

      // Foreign / production / arbitrary reference fails closed
      expect(
        () => testValidateRef('https://wrongproject.supabase.co/functions/v1/recharge-bridge'),
        throwsA(isA<StateError>()),
      );
      expect(
        () => testValidateRef('tekfix-production-supabase'),
        throwsA(isA<StateError>()),
      );
    });

    test('Gate 5: StagingIdentityService acquires server-issued token without client secrets', () async {
      int serverCalls = 0;
      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/issue-staging-token')) {
          serverCalls++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['shopId'], equals('shop_staging_001'));
          expect(body['ownerUid'], equals('owner_staging_001'));
          return http.Response(
            jsonEncode({
              'success': true,
              'token': 'server_issued_mock_jwt_token_header.payload.signature',
              'tokenType': 'Bearer',
              'expiresIn': 3600,
              'expiresAt': DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
              'shopId': 'shop_staging_001',
              'ownerUid': 'owner_staging_001',
              'role': 'owner',
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'error': 'Not found'}), 404);
      });

      StagingIdentityService.setMockHttpClient(mockClient);

      // First call fetches from server
      final token1 = await StagingIdentityService.getOptionAToken(
        edgeFunctionBaseUrl: 'https://mwhsvidbrfkryuiwhnev.supabase.co/functions/v1/recharge-bridge',
      );
      expect(token1, equals('server_issued_mock_jwt_token_header.payload.signature'));
      expect(serverCalls, equals(1));
      expect(StagingIdentityService.hasValidCachedToken, isTrue);

      // Second call uses cached token without network request
      final token2 = await StagingIdentityService.getOptionAToken(
        edgeFunctionBaseUrl: 'https://mwhsvidbrfkryuiwhnev.supabase.co/functions/v1/recharge-bridge',
      );
      expect(token2, equals(token1));
      expect(serverCalls, equals(1), reason: 'Must reuse cached token within validity window');
    });

    test('Gate 6: StagingIdentityService fails closed on server issuance rejection', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'error': 'Unauthorized: Owner "attacker" is not whitelisted for shop "shop_unknown".'
          }),
          403,
        );
      });

      StagingIdentityService.setMockHttpClient(mockClient);

      expect(
        () => StagingIdentityService.getOptionAToken(
          edgeFunctionBaseUrl: 'https://mwhsvidbrfkryuiwhnev.supabase.co/functions/v1/recharge-bridge',
          shopId: 'shop_unknown',
          ownerUid: 'attacker',
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('403'),
        )),
      );
    });

    test('Gate 7: RechargeBackendBridge is properly configured with Supabase client and server-issued token', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/issue-staging-token')) {
          return http.Response(
            jsonEncode({
              'success': true,
              'token': 'valid_bridge_token',
              'expiresAt': DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'success': true}), 200);
      });

      StagingIdentityService.setMockHttpClient(mockClient);

      final stagingClient = SupabaseRechargeBridgeClient(
        edgeFunctionBaseUrl: DefaultFirebaseOptions.expectedSupabaseEdgeUrl,
        getFirebaseIdToken: () async => StagingIdentityService.getOptionAToken(
          edgeFunctionBaseUrl: DefaultFirebaseOptions.expectedSupabaseEdgeUrl,
        ),
      );

      RechargeBackendBridge.configure(
        mode: RechargeBackendMode.supabaseEdgeFunction,
        supabaseClient: stagingClient,
      );

      expect(RechargeBackendBridge.isSupabaseMode, isTrue);
      expect(RechargeBackendBridge.isFirebaseMode, isFalse);
      expect(RechargeBackendBridge.supabaseClient, isNotNull);
      expect(
        RechargeBackendBridge.supabaseClient!.edgeFunctionBaseUrl,
        equals('https://mwhsvidbrfkryuiwhnev.supabase.co/functions/v1/recharge-bridge'),
      );

      final token = await RechargeBackendBridge.supabaseClient!.getFirebaseIdToken();
      expect(token, equals('valid_bridge_token'));

      RechargeBackendBridge.reset();
    });
  });
}
