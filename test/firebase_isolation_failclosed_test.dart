import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/firebase_options.dart';

void main() {
  group('Phase 16.4.7.4: Fail-Closed Android Firebase Isolation Unit Tests', () {
    test('1. Production ID (tekfix-45b38) in UAT mode must throw StateError', () {
      expect(
        () => DefaultFirebaseOptions.enforceProductionIsolation(
          projectId: 'tekfix-45b38',
          force: true, // force simulates UAT mode enforcement regardless of runtime flag
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('tekfix-45b38'),
        )),
      );

      // Embedded in URL / domain format
      expect(
        () => DefaultFirebaseOptions.enforceProductionIsolation(
          projectId: 'tekfix-45b38.firebaseio.com',
          force: true,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('2. Unknown project ID in UAT mode must throw StateError', () {
      expect(
        () => DefaultFirebaseOptions.enforceProductionIsolation(
          projectId: 'unknown-rogue-project-id',
          force: true,
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Unknown or unauthorized Firebase project ID'),
        )),
      );
    });

    test('3. Unknown project ID in Production mode must throw StateError', () {
      // In production mode (when force=false and isUatMode is false, or direct test),
      // only tekfix-45b38 is accepted. Any unknown ID throws.
      if (!DefaultFirebaseOptions.isUatMode) {
        expect(
          () => DefaultFirebaseOptions.enforceProductionIsolation(
            projectId: 'random-unauthorized-project',
          ),
          throwsA(isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Unknown or unauthorized Firebase project ID'),
          )),
        );
      }
    });

    test('4. Empty, whitespace, or null-like project ID must throw StateError immediately', () {
      expect(
        () => DefaultFirebaseOptions.enforceProductionIsolation(
          projectId: '',
          force: true,
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('cannot be empty or null'),
        )),
      );

      expect(
        () => DefaultFirebaseOptions.enforceProductionIsolation(
          projectId: '   ',
          force: true,
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('cannot be empty or null'),
        )),
      );
    });

    test('5. Staging options validation: missing or malformed options must throw StateError', () {
      // Empty API key
      expect(
        () => DefaultFirebaseOptions.resolveStagingPlatformForTesting(
          platform: TargetPlatform.android,
          apiKey: '',
          appId: '1:000000000000:android:0000000000000000000000',
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('invalid or unconfigured'),
        )),
      );

      // Empty App ID
      expect(
        () => DefaultFirebaseOptions.resolveStagingPlatformForTesting(
          platform: TargetPlatform.android,
          apiKey: 'AIzaSyFakeKeyValidFormat',
          appId: '',
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('invalid or unconfigured'),
        )),
      );

      // Placeholder API key
      expect(
        () => DefaultFirebaseOptions.resolveStagingPlatformForTesting(
          platform: TargetPlatform.android,
          apiKey: 'PLACEHOLDER_KEY',
          appId: '1:000000000000:android:0000000000000000000000',
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('invalid or unconfigured'),
        )),
      );
    });

    test('6. Environment conflict & resolution: unknown TEKFIX_ENV must fail closed', () {
      // Unknown environment string throws StateError
      expect(
        () => DefaultFirebaseOptions.parseEnvironment('unknown_flavor_conflict'),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Unknown TEKFIX_ENV'),
        )),
      );

      expect(
        () => DefaultFirebaseOptions.parseEnvironment('prod_staging_conflict'),
        throwsA(isA<StateError>()),
      );

      expect(
        () => DefaultFirebaseOptions.parseEnvironment(''),
        throwsA(isA<StateError>()),
      );

      // Recognized environments resolve correctly
      expect(
        DefaultFirebaseOptions.parseEnvironment('production'),
        equals(TekFixEnvironment.production),
      );
      expect(
        DefaultFirebaseOptions.parseEnvironment('staging_uat'),
        equals(TekFixEnvironment.stagingUat),
      );
      expect(
        DefaultFirebaseOptions.parseEnvironment('staging'),
        equals(TekFixEnvironment.staging),
      );
      expect(
        DefaultFirebaseOptions.parseEnvironment('development'),
        equals(TekFixEnvironment.development),
      );
    });

    test('7. Staging Supabase reference mismatch must throw StateError', () {
      // In UAT mode, foreign or rogue endpoints must be rejected
      expect(
        () => DefaultFirebaseOptions.validateStagingSupabaseReference(
          'https://attacker-supabase-instance.supabase.co/functions/v1/recharge-bridge',
        ),
        DefaultFirebaseOptions.isUatMode
            ? throwsA(isA<StateError>().having(
                (e) => e.message,
                'message',
                contains('Staging Supabase reference mismatch'),
              ))
            : returnsNormally,
      );
    });

    test('8. Fail-closed guarantee: exception thrown before initializeApp prevents init', () {
      bool initializeAppCalled = false;

      void guardedInit({required String candidateProjectId, required bool forceUat}) {
        // This mirrors the exact structure in lib/main.dart line 478
        DefaultFirebaseOptions.enforceProductionIsolation(
          projectId: candidateProjectId,
          force: forceUat,
        );
        // If the guard fails closed, this line is never reached
        initializeAppCalled = true;
      }

      // Attack scenario: production ID presented during UAT run
      expect(
        () => guardedInit(candidateProjectId: 'tekfix-45b38', forceUat: true),
        throwsA(isA<StateError>()),
      );
      expect(initializeAppCalled, isFalse, reason: 'Firebase.initializeApp must NEVER be called');

      // Attack scenario: empty/null candidate ID
      initializeAppCalled = false;
      expect(
        () => guardedInit(candidateProjectId: '', forceUat: true),
        throwsA(isA<StateError>()),
      );
      expect(initializeAppCalled, isFalse, reason: 'Firebase.initializeApp must NEVER be called');

      // Attack scenario: unknown candidate ID
      initializeAppCalled = false;
      expect(
        () => guardedInit(candidateProjectId: 'rogue-project-id', forceUat: true),
        throwsA(isA<StateError>()),
      );
      expect(initializeAppCalled, isFalse, reason: 'Firebase.initializeApp must NEVER be called');
    });
  });
}

