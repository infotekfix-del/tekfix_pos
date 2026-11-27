import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/firebase_options.dart';

void main() {
  group('Phase 13.0.8 Cloud Functions Region & Environment Synchronization', () {
    test('TEST 1: Staging environment resolves to asia-south1', () {
      final region = DefaultFirebaseOptions.resolveFunctionsRegion(TekFixEnvironment.staging);
      expect(region, equals('asia-south1'));
    });

    test('TEST 2: Production environment preserves legacy us-central1', () {
      final region = DefaultFirebaseOptions.resolveFunctionsRegion(TekFixEnvironment.production);
      expect(region, equals('us-central1'));
    });

    test('TEST 3: Development environment defaults to asia-south1', () {
      final region = DefaultFirebaseOptions.resolveFunctionsRegion(TekFixEnvironment.development);
      expect(region, equals('asia-south1'));
    });

    test('TEST 4: Custom region override is respected when provided', () {
      final customStaging = DefaultFirebaseOptions.resolveFunctionsRegion(
        TekFixEnvironment.staging,
        customRegion: 'asia-south1',
      );
      expect(customStaging, equals('asia-south1'));

      final customCustom = DefaultFirebaseOptions.resolveFunctionsRegion(
        TekFixEnvironment.staging,
        customRegion: 'europe-west1',
      );
      expect(customCustom, equals('europe-west1'));
    });

    test('TEST 5: Environment parser correctly resolves valid values', () {
      expect(DefaultFirebaseOptions.parseEnvironment('staging'), equals(TekFixEnvironment.staging));
      expect(DefaultFirebaseOptions.parseEnvironment('STAGING'), equals(TekFixEnvironment.staging));
      expect(DefaultFirebaseOptions.parseEnvironment(' staging '), equals(TekFixEnvironment.staging));

      expect(DefaultFirebaseOptions.parseEnvironment('production'), equals(TekFixEnvironment.production));
      expect(DefaultFirebaseOptions.parseEnvironment('PROD'), equals(TekFixEnvironment.production));
      expect(DefaultFirebaseOptions.parseEnvironment('prod'), equals(TekFixEnvironment.production));

      expect(DefaultFirebaseOptions.parseEnvironment('development'), equals(TekFixEnvironment.development));
      expect(DefaultFirebaseOptions.parseEnvironment('DEV'), equals(TekFixEnvironment.development));
      expect(DefaultFirebaseOptions.parseEnvironment('dev'), equals(TekFixEnvironment.development));
    });

    test('TEST 6: Environment mismatch rejection (Invalid values throw StateError)', () {
      expect(
        () => DefaultFirebaseOptions.parseEnvironment('local'),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Unknown TEKFIX_ENV'),
        )),
      );

      expect(
        () => DefaultFirebaseOptions.parseEnvironment('qa_test'),
        throwsA(isA<StateError>()),
      );

      expect(
        () => DefaultFirebaseOptions.parseEnvironment(''),
        throwsA(isA<StateError>()),
      );
    });

    test('TEST 7: Active compile-time environment preserves production default', () {
      final env = DefaultFirebaseOptions.currentEnvironment;
      if (env == TekFixEnvironment.staging ||
          env == TekFixEnvironment.stagingUat) {
        expect(DefaultFirebaseOptions.functionsRegion, equals('asia-south1'));
        expect(DefaultFirebaseOptions.functionsRegion, isNot('us-central1'));
      } else {
        // Default test runs without --dart-define stay on production.
        expect(env, equals(TekFixEnvironment.production));
        expect(DefaultFirebaseOptions.functionsRegion, equals('us-central1'));
      }
    });

    test('TEST 8: Active compile-time production options point to tekfix-45b38', () {
      if (DefaultFirebaseOptions.isUatMode) {
        expect(
          DefaultFirebaseOptions.android.projectId,
          isNot('tekfix-45b38'),
        );
        expect(
          DefaultFirebaseOptions.windows.projectId,
          isNot('tekfix-45b38'),
        );
        if (DefaultFirebaseOptions.currentEnvironment ==
            TekFixEnvironment.stagingUat) {
          expect(
            () => DefaultFirebaseOptions.currentPlatform,
            throwsA(isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('Production Firebase is disabled'),
            )),
          );
        } else {
          expect(
            DefaultFirebaseOptions.currentPlatform.projectId,
            isNot('tekfix-45b38'),
          );
        }
      } else {
        final options = DefaultFirebaseOptions.currentPlatform;
        expect(options.projectId, equals('tekfix-45b38'));
        expect(options.storageBucket, contains('tekfix-45b38'));
      }
    });

    test('TEST 9: Staging options resolver binds to tekfix-staging', () {
      final stagingOptions = DefaultFirebaseOptions.resolveStagingPlatformForTesting(
        platform: TargetPlatform.android,
        apiKey: 'AIzaSyStagingTestKey123',
        appId: '1:123456789:android:abcdef123456',
        projectId: 'tekfix-staging',
      );
      expect(stagingOptions.projectId, equals('tekfix-staging'));
      expect(stagingOptions.storageBucket, equals('tekfix-staging.firebasestorage.app'));
    });

    test('TEST 10: Missing staging credentials throw StateError and fail closed', () {
      expect(
        () => DefaultFirebaseOptions.resolveStagingPlatformForTesting(
          platform: TargetPlatform.android,
          apiKey: '',
          appId: '',
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('invalid or unconfigured'),
        )),
      );
    });

    test('TEST 11: Placeholder staging credentials throw StateError and fail closed', () {
      expect(
        () => DefaultFirebaseOptions.resolveStagingPlatformForTesting(
          platform: TargetPlatform.android,
          apiKey: 'AIzaSy_STAGING_KEY_PLACEHOLDER',
          appId: '1:000000000000:android:PLACEHOLDER',
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('invalid or unconfigured'),
        )),
      );
    });

    test('TEST 12: Staging never falls back to production project ID', () {
      final stagingOptions = DefaultFirebaseOptions.resolveStagingPlatformForTesting(
        platform: TargetPlatform.android,
        apiKey: 'AIzaSyStagingKeyValid',
        appId: '1:999999999:android:validStagingApp',
      );
      expect(stagingOptions.projectId, isNot(equals('tekfix-45b38')));
      expect(stagingOptions.projectId, equals('tekfix-staging'));
    });
  });
}

