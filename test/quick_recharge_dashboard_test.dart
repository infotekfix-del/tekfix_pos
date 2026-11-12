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

  testWidgets('QuickRechargeScreen Phase 1 Dashboard UI Test',
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
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1.0;

    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: auth,
        child: const MaterialApp(
          home: QuickRechargeScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 1. Verify Top App Bar & Title
    expect(find.text('Recharge & Utility Management'), findsOneWidget);
    expect(find.text('PHASE 1 PREVIEW'), findsOneWidget);
    expect(find.text('Live Float Active'), findsOneWidget);

    // 2. Verify Funding Source Selector
    expect(find.text('Active Funding Source / ഫണ്ടിംഗ് രീതി:'), findsOneWidget);
    expect(find.text('MODE A'), findsOneWidget);
    expect(find.text('MODE B'), findsOneWidget);
    expect(find.textContaining('Distributor Credit'), findsOneWidget);
    expect(find.textContaining('Own Money / Prepaid'), findsOneWidget);

    // 3. Verify KPI Dashboard Cards
    expect(find.text("Today's Recharge"), findsOneWidget);
    expect(find.text('Cash Collection'), findsOneWidget);
    expect(find.text('UPI Collection'), findsOneWidget);
    expect(find.text('Total Transactions'), findsOneWidget);
    expect(find.text('Distributor Due'), findsOneWidget);
    expect(find.text('Available Float'), findsOneWidget);

    // 4. Verify Operator Cards
    expect(find.text('Reliance Jio'), findsOneWidget);
    expect(find.text('Bharti Airtel'), findsOneWidget);
    expect(find.text('Vodafone Idea (Vi)'), findsOneWidget);
    expect(find.text('BSNL Mobile'), findsOneWidget);
    expect(find.text('DTH & Utilities'), findsOneWidget);

    // 5. Verify Distributor Settlement Card
    expect(
        find.text('Distributor Settlement & Outstandings'), findsOneWidget);
    expect(find.text('Pay Distributor'), findsOneWidget);
    expect(find.text('Total Stock Received'), findsOneWidget);
    expect(find.text('Amount Settled / Paid'), findsOneWidget);
    expect(find.text('Remaining Outstanding'), findsOneWidget);
    expect(find.text('Last Payment Date'), findsOneWidget);

    // 6. Verify 8 Navigation Cards
    expect(find.text('Quick Recharge'), findsOneWidget);
    expect(find.text('Wallet Management'), findsOneWidget);
    expect(find.text('Distributor Directory'), findsOneWidget);
    expect(find.text('Distributor Ledger'), findsOneWidget);
    expect(find.text('Distributor Payment'), findsOneWidget);
    expect(find.text('Recharge History'), findsOneWidget);
    expect(find.text('Commission Report'), findsOneWidget);
    expect(find.text('Float Recovery (Contra)'), findsOneWidget);

    // 7. Verify Interactive Toggle between Funding Modes
    await tester.tap(find.textContaining('Own Money / Prepaid'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 8. Verify Operator Card Tap
    await tester.tap(find.text('Bharti Airtel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Bharti Airtel'), findsWidgets); // In dialog & card
    await tester.tap(find.text('Close'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 9. Verify Distributor Payout Preview Dialog
    await tester.tap(find.text('Pay Distributor'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Distributor Payout Settlement'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  });
}

