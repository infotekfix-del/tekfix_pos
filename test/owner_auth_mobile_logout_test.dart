import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';
import 'package:tekfix_erp_pos/auth/auth_controller.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/security/staging_identity_service.dart';
import 'package:tekfix_erp_pos/sync/sync_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('tekfix_test_');
    Hive.init(tempDir.path);
    for (final b in allBoxes) {
      if (!Hive.isBoxOpen(b)) await Hive.openBox(b);
    }
    if (!Hive.isBoxOpen('tek_sync_meta')) await Hive.openBox('tek_sync_meta');
    if (!Hive.isBoxOpen('tek_sync_outbox')) await Hive.openBox('tek_sync_outbox');
  });

  tearDownAll(() async {
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
    await Db.settings.clear();
  });

  group('TEKFIX ERP — Phase 15.5 Owner Auth & Mobile Logout Invariant Tests', () {
    test('1. Fresh installation, empty session -> Fail-closed unauthenticated', () async {
      final auth = AuthController.instance;
      await Db.settings.delete('staging_owner_signed_in');
      await Db.settings.delete('auth_role');

      await auth.init();

      expect(auth.signedIn, isFalse, reason: 'Fresh install must not auto-login without password');
      expect(auth.isOwner, isFalse, reason: 'Owner role must not be granted on empty session');
      expect(Db.setting('staging_owner_signed_in'), equals('false'));
    });

    test('2. Unauthenticated access -> AppShell route blocked', () async {
      final auth = AuthController.instance;
      await Db.settings.put('staging_owner_signed_in', 'false');
      await auth.init();

      expect(auth.signedIn, isFalse);
      expect(auth.isOwner, isFalse);

      // Verify routing invariant: Only signedIn && isOwner can access AppShell
      final canAccessAppShell = auth.signedIn && auth.isOwner;
      expect(canAccessAppShell, isFalse, reason: 'AppShell must be strictly blocked for unauthenticated users');
    });

    test('3. Valid owner credentials -> AppShell access granted', () async {
      final auth = AuthController.instance;

      final err = await auth.signIn(
        StagingIdentityService.defaultShopId,
        'staging-owner@tekfix.internal',
        AuthController.defaultStagingPassword,
      );

      expect(err, isNull);
      expect(auth.signedIn, isTrue);
      expect(auth.isOwner, isTrue);
      expect(Db.setting('staging_owner_signed_in'), equals('true'));

      final canAccessAppShell = auth.signedIn && auth.isOwner;
      expect(canAccessAppShell, isTrue, reason: 'Authenticated owner must be granted AppShell access');
    });

    test('4. Sign out -> Invalidates session and sets staging_owner_signed_in to false', () async {
      final auth = AuthController.instance;

      // Ensure signed in first
      await auth.signIn(
        StagingIdentityService.defaultShopId,
        'staging-owner@tekfix.internal',
        AuthController.defaultStagingPassword,
      );
      expect(auth.signedIn, isTrue);

      // Execute sign out
      await auth.signOut();

      expect(auth.signedIn, isFalse);
      expect(auth.isOwner, isFalse);
      expect(Db.setting('staging_owner_signed_in'), equals('false'));
      expect(Db.setting('auth_role'), equals('none'));
    });

    test('5. Cold restart after logout -> Stays unauthenticated', () async {
      final auth = AuthController.instance;

      // Simulate logged out state
      await Db.settings.put('staging_owner_signed_in', 'false');
      await Db.settings.put('auth_role', 'none');

      // Re-initialize as on cold restart
      await auth.init();

      expect(auth.signedIn, isFalse);
      expect(auth.isOwner, isFalse);
      expect(Db.setting('staging_owner_signed_in'), equals('false'));
    });

    test('6. Arbitrary or invalid session values fail closed', () async {
      final auth = AuthController.instance;

      final invalidValues = ['', 'null', 'TRUE', '1', 'yes', 'undefined', 'false', '0', 'none'];
      for (final val in invalidValues) {
        await Db.settings.put('staging_owner_signed_in', val);
        await auth.init();
        expect(auth.signedIn, isFalse, reason: 'Value "$val" must fail closed');
        expect(auth.isOwner, isFalse);
      }
    });

    test('7. Staff login strictly isolates role and denies owner privilege', () async {
      final auth = AuthController.instance;

      await Db.settings.put('staff_logged_in', 'true');
      await Db.settings.put('staff_logged_name', 'Rahul Staff');
      await Db.settings.put('staff_logged_id', 'staff_001');

      expect(auth.isStaffLoggedIn, isTrue);
      expect(auth.isOwner, isFalse, reason: 'Staff must NEVER have isOwner privilege');
      expect(auth.role, equals(Role.staff));

      // AppShell check
      final canAccessAppShell = auth.signedIn && auth.isOwner;
      expect(canAccessAppShell, isFalse, reason: 'Staff must be blocked from AppShell');
    });

    testWidgets('8. Mobile MoreView renders Owner Profile Card, Owner Badge, and Red Logout Card', (tester) async {
      final auth = AuthController.instance;
      await tester.runAsync(() async {
        await auth.signIn(
          StagingIdentityService.defaultShopId,
          'staging-owner@tekfix.internal',
          AuthController.defaultStagingPassword,
        );
      });

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthController>.value(value: auth),
            ChangeNotifierProvider<SyncEngine>.value(value: SyncEngine.instance),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: MoreView(modules: []),
            ),
          ),
        ),
      );
      await tester.pump();

      // Top Owner Profile Card verification
      expect(find.text('OWNER'), findsOneWidget);
      expect(find.byTooltip('Sign Out (ലോഗൗട്ട്)'), findsOneWidget);

      // Bottom Red Logout Card verification
      expect(find.text('ലോഗൗട്ട് ചെയ്യുക (Sign Out)'), findsOneWidget);
      expect(find.text('സെഷൻ അവസാനിപ്പിച്ച് ലോഗിൻ സ്‌ക്രീനിലേക്ക് മടങ്ങുക'), findsOneWidget);
    });

    testWidgets('9. SettingsView renders Account & Session Sign Out tile', (tester) async {
      final auth = AuthController.instance;
      await tester.runAsync(() async {
        await auth.signIn(
          StagingIdentityService.defaultShopId,
          'staging-owner@tekfix.internal',
          AuthController.defaultStagingPassword,
        );
      });

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthController>.value(value: auth),
            ChangeNotifierProvider<SyncEngine>.value(value: SyncEngine.instance),
          ],
          child: const MaterialApp(
            home: SettingsView(),
          ),
        ),
      );
      await tester.pump();

      // Scroll down to find the Account & Session section
      final accountTile = find.text('അക്കൗണ്ട് & സെഷൻ (Account & Session)');
      await tester.scrollUntilVisible(accountTile, 200, scrollable: find.byType(Scrollable).first);
      await tester.pump();

      expect(accountTile, findsOneWidget);
      expect(find.text('ലോഗൗട്ട് ചെയ്യുക (Sign Out)'), findsOneWidget);
    });
  });
}
