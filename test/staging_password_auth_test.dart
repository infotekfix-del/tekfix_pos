import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/auth/auth_controller.dart';
import 'package:tekfix_erp_pos/firebase_options.dart';
import 'package:tekfix_erp_pos/main.dart' show Db, boxSettings;
import 'package:tekfix_erp_pos/security/staging_identity_service.dart';

// Staging password reset / UAT sign-in exist only in UAT builds
// (--dart-define=TEKFIX_ENV=staging_uat or TEKFIX_UAT=true). In the default
// production build they are refused, which test 6 checks.
const _uatOnly = 'staging-only: run with --dart-define=TEKFIX_ENV=staging_uat';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final uat = DefaultFirebaseOptions.isUatMode;
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('tekfix_auth_test_');
    Hive.init(tempDir.path);
    if (!Hive.isBoxOpen(boxSettings)) {
      await Hive.openBox(boxSettings);
    }
  });

  tearDownAll(() async {
    await Hive.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  setUp(() async {
    await Db.settings.clear();
  });

  group('TEKFIX ERP — Staging Owner Password Authentication & Reset', () {
    test('1. Default staging password verifies against default hash', () {
      final auth = AuthController.instance;
      expect(auth.verifyStagingPassword(AuthController.defaultStagingPassword), isTrue);
      expect(auth.verifyStagingPassword('WrongPassword123'), isFalse);
    });

    test('2. Password reset fails closed on invalid master recovery PIN', skip: uat ? false : _uatOnly, () async {
      final auth = AuthController.instance;
      final err = await auth.resetStagingOwnerPassword(
        recoveryPin: '0000',
        newPassword: 'NewSecurePassword2026',
      );
      expect(err, isNotNull);
      expect(err, contains('റിക്കവറി പിൻ തെറ്റാണ്'));
    });

    test('3. Password reset fails closed on short password (< 6 chars)', skip: uat ? false : _uatOnly, () async {
      final auth = AuthController.instance;
      final err = await auth.resetStagingOwnerPassword(
        recoveryPin: '9999',
        newPassword: '123',
      );
      expect(err, isNotNull);
      expect(err, contains('കുറഞ്ഞത് 6 അക്ഷരങ്ങൾ'));
    });

    test('4. Password reset succeeds with PIN 9999 and updates active password', skip: uat ? false : _uatOnly, () async {
      final auth = AuthController.instance;
      const newPass = 'OwnerSecret2026!';

      final err = await auth.resetStagingOwnerPassword(
        recoveryPin: '9999',
        newPassword: newPass,
      );
      expect(err, isNull);

      // New password verifies
      expect(auth.verifyStagingPassword(newPass), isTrue);

      // Old default password no longer verifies
      expect(auth.verifyStagingPassword(AuthController.defaultStagingPassword), isFalse);
    });

    test('5. Staging UAT mode sign-in succeeds with valid credentials and updates session', skip: uat ? false : _uatOnly, () async {
      final auth = AuthController.instance;

      // Attempt with wrong password
      final wrongErr = await auth.signIn(
        StagingIdentityService.defaultShopId,
        'staging-owner@tekfix.internal',
        'wrong_pass',
      );
      expect(wrongErr, isNotNull);
      expect(wrongErr, contains('ഇമെയിൽ / പാസ്‌വേഡ് തെറ്റാണ്'));

      // Reset to known password
      await auth.resetStagingOwnerPassword(
        recoveryPin: '9999',
        newPassword: 'StagingOwnerPass123',
      );

      // Sign in with correct password
      final okErr = await auth.signIn(
        StagingIdentityService.defaultShopId,
        'staging-owner@tekfix.internal',
        'StagingOwnerPass123',
      );
      expect(okErr, isNull);
      expect(auth.signedIn, isTrue);
      expect(auth.isOwner, isTrue);
      expect(auth.role, equals(Role.owner));
      expect(auth.shopId, equals(StagingIdentityService.defaultShopId));
      expect(auth.uid, equals(StagingIdentityService.defaultOwnerUid));

      // Sign out
      await auth.signOut();
      expect(auth.signedIn, isFalse);
      expect(auth.isOwner, isFalse);
    });

    test('6. Regression: Zero Firebase access during UAT Sign-In with Firebase uninitialized', () async {
      final auth = AuthController.instance;

      // Verify that signing in with default staging password does NOT throw [core/no-app]
      final result = await auth.signIn(
        StagingIdentityService.defaultShopId,
        'staging-owner@tekfix.internal',
        AuthController.defaultStagingPassword,
      );

      expect(result, isNull, reason: 'Expected sign-in to succeed without Firebase');
      expect(auth.signedIn, isTrue);
      expect(auth.isOwner, isTrue);

      // Verify session invariants for AppShell routing
      expect(auth.signedIn && auth.isOwner, isTrue, reason: 'AppShell route guard must pass');
    });

    test('6. Production build refuses the staging password reset (fails closed)', skip: uat ? 'production-only check' : false, () async {
      final auth = AuthController.instance;
      final err = await auth.resetStagingOwnerPassword(recoveryPin: '9999', newPassword: 'AnyPassword2026');
      expect(err, contains('prohibited in production'));
      expect(auth.verifyStagingPassword('AnyPassword2026'), isFalse, reason: 'nothing changed');
    });
  });
}

