import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';
import 'package:tekfix_erp_pos/auth/auth_controller.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/recharge/quick_recharge_screen.dart';
import 'package:tekfix_erp_pos/security/staging_identity_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('tekfix_recharge_dash_test_');
    Hive.init(tempDir.path);
    for (final b in allBoxes) {
      if (!Hive.isBoxOpen(b)) await Hive.openBox(b);
    }
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

  testWidgets('QuickRechargeScreen Live Dashboard UI Test',
      (WidgetTester tester) async {
    final auth = AuthController.instance;
    await tester.runAsync(() async {
      await auth.signIn(
        StagingIdentityService.defaultShopId,
        'staging-owner@tekfix.internal',
        AuthController.defaultStagingPassword,
      );
    });

    // Set a wide screen viewport for desktop layout
    tester.view.physicalSize = const Size(1366, 1600);
    tester.view.devicePixelRatio = 1.0;

    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: auth,
        child: const MaterialApp(
          home: Scaffold(
            body: QuickRechargeScreen(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 1. Verify Top Header & Badges
    expect(find.text('QUICK RECHARGE'), findsWidgets);
    expect(find.text('LIVE ACCOUNTING'), findsOneWidget);
    expect(find.text('Add Balance'), findsWidgets);
    expect(find.text('New Recharge'), findsWidgets);

    // 2. Verify 6 Live KPI Metrics Cards
    expect(find.text("Today's Total Recharge"), findsOneWidget);
    expect(find.text("Today's Commission"), findsOneWidget);
    expect(find.text('Available Wallet Float'), findsOneWidget);
    expect(find.text('Distributor Outstanding'), findsOneWidget);
    expect(find.text('Successful Transactions'), findsOneWidget);
    expect(find.text('Failed / Pending Txns'), findsOneWidget);

    // 3. Verify 4 Operator Wallet Cards
    expect(find.text('Bharti Airtel'), findsOneWidget);
    expect(find.text('Reliance Jio'), findsOneWidget);
    expect(find.text('Vodafone Idea (Vi)'), findsOneWidget);
    expect(find.text('BSNL Mobile'), findsOneWidget);

    // 4. Verify Distributor & Agent Settlement Section
    expect(find.text('Distributor Settlement & Outstandings'), findsOneWidget);
    expect(find.text('Agent Settlement'), findsOneWidget);
    expect(find.text('Recharge Return'), findsOneWidget);
    expect(find.text('Direct Pay'), findsOneWidget);

    // 5. Verify Pending Returns Section
    expect(find.textContaining('Pending Recharge Returns from Operators / Agents'), findsOneWidget);

    // 6. Verify Quick Operations Action Grid
    expect(find.text('Daily Reconciliation'), findsOneWidget);
    expect(find.text('Add Wallet Balance'), findsOneWidget);
    expect(find.text('Commission Controls'), findsOneWidget);
    expect(find.text('Distributor Directory & Ledger'), findsOneWidget);
    expect(find.text('Recharge Reports & History'), findsOneWidget);
    expect(find.text('Float Recovery (Contra)'), findsOneWidget);

    // 7. Verify Recent Transactions Section
    expect(find.textContaining("Today's Recharge Transactions"), findsOneWidget);

    // 8. Test Agent Settlement Modal Opening
    await tester.ensureVisible(find.text('Agent Settlement'));
    await tester.tap(find.text('Agent Settlement'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Operator Agent Settlement'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 9. Test Recharge Return Modal Opening
    await tester.ensureVisible(find.text('Recharge Return'));
    await tester.tap(find.text('Recharge Return'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Recharge Amount Return'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('Staff Account is Strictly Blocked from Recharge (Fail-Closed)',
      (WidgetTester tester) async {
    final auth = AuthController.instance;
    await tester.runAsync(() async {
      await Db.settings.put('staff_logged_in', 'true');
      await Db.settings.put('staff_logged_name', 'Rahul Staff');
      await Db.settings.put('staff_logged_id', 'staff_001');
      await Db.settings.put('auth_role', 'staff');
      auth.notify();
    });

    addTearDown(() async {
      await Db.settings.put('staff_logged_in', 'false');
      await Db.settings.put('auth_role', 'owner');
      auth.notify();
    });

    // 1. Verify nav categories for staff do NOT include Quick Recharge
    expect(auth.isOwner, isFalse);
    final staffCategories = getNavCategories(auth.shopId, isOwner: auth.isOwner);
    final staffMods = staffCategories.expand((c) => c.items).toList();
    expect(staffMods.any((m) => m.label == 'Quick Recharge'), isFalse);

    // 2. Verify direct widget mounting fails closed
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: auth,
        child: const MaterialApp(
          home: Scaffold(
            body: QuickRechargeScreen(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('Owner Only Area'), findsOneWidget);
    expect(
      find.textContaining('Recharge Accounting is strictly restricted to Shop Owner.'),
      findsOneWidget,
    );
  });
}
