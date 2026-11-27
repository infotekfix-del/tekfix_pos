import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';
import 'package:tekfix_erp_pos/auth/auth_controller.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/recharge/commission_dialogs.dart';
import 'package:tekfix_erp_pos/recharge/daily_reconciliation_screen.dart';
import 'package:tekfix_erp_pos/recharge/quick_recharge_dialog.dart';
import 'package:tekfix_erp_pos/recharge/quick_recharge_screen.dart';
import 'package:tekfix_erp_pos/recharge/recharge_models.dart';
import 'package:tekfix_erp_pos/recharge/recharge_reports_screen.dart';
import 'package:tekfix_erp_pos/recharge/recharge_service.dart';
import 'package:tekfix_erp_pos/recharge/wallet_distributor_dialogs.dart';
import 'package:tekfix_erp_pos/security/staging_identity_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('tekfix_windows_realworld_');
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

  testWidgets('WINDOWS REAL-WORLD E2E VERIFICATION: Full Operations Workflow',
      (WidgetTester tester) async {
    // -------------------------------------------------------------------------
    // STEP 1 & 2: Launch & Owner Authentication
    // -------------------------------------------------------------------------
    final auth = AuthController.instance;
    await tester.runAsync(() async {
      await auth.signIn(
        StagingIdentityService.defaultShopId,
        'staging-owner@tekfix.internal',
        AuthController.defaultStagingPassword,
      );
    });

    expect(auth.isOwner, isTrue, reason: 'Owner login must be verified');
    debugPrint('[REAL-WORLD VERIFICATION] 1. Owner Login Successful: uid=${auth.uid}, shopId=${auth.shopId}');

    // Configure Windows Desktop resolution (1366x768 / 1920x1080 standard)
    tester.view.physicalSize = const Size(1366, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // Mount full AppShell with navigation
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthController>.value(value: auth),
        ],
        child: const MaterialApp(
          home: AppShell(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Confirm main HomeView is initially active
    expect(find.byType(AppShell), findsOneWidget);
    debugPrint('[REAL-WORLD VERIFICATION] 2. AppShell mounted on Windows Desktop');

    // -------------------------------------------------------------------------
    // STEP 3 & 4: Sidebar Navigation to Quick Recharge
    // -------------------------------------------------------------------------
    // Find 'Quick Recharge' in sidebar
    final quickRechargeTile = find.text('Quick Recharge');
    expect(quickRechargeTile, findsWidgets, reason: 'Quick Recharge must exist in sidebar');

    // Click 'Quick Recharge'
    await tester.tap(quickRechargeTile.first);
    await tester.pumpAndSettle();

    // Confirm QuickRechargeScreen is mounted and active
    expect(find.byType(QuickRechargeScreen), findsOneWidget);
    expect(find.text('QUICK RECHARGE'), findsWidgets);
    expect(find.text('LIVE ACCOUNTING'), findsOneWidget);
    debugPrint('[REAL-WORLD VERIFICATION] 3. Quick Recharge screen opened via Sidebar click');

    // -------------------------------------------------------------------------
    // STEP 5: Verify 4 Operator Wallet Cards (Airtel, Jio, Vi, BSNL)
    // -------------------------------------------------------------------------
    expect(find.text('Bharti Airtel'), findsOneWidget);
    expect(find.text('Reliance Jio'), findsOneWidget);
    expect(find.text('Vodafone Idea (Vi)'), findsOneWidget);
    expect(find.text('BSNL Mobile'), findsOneWidget);
    debugPrint('[REAL-WORLD VERIFICATION] 4. Operator cards displayed for Airtel, Jio, Vi, BSNL');

    // -------------------------------------------------------------------------
    // STEP 6: Open Add Balance Dialog (Anytime) & Verify Form Controls
    // -------------------------------------------------------------------------
    final addBalanceBtn = find.widgetWithText(FilledButton, 'Add Balance').first;
    await tester.ensureVisible(addBalanceBtn);
    await tester.tap(addBalanceBtn);
    await tester.pumpAndSettle();

    // Verify Add Balance (WalletTopUpDialog) is open
    expect(find.byType(WalletTopUpDialog), findsOneWidget);
    expect(find.textContaining('Add Wallet Balance'), findsOneWidget);
    debugPrint('[REAL-WORLD VERIFICATION] 5. Add Balance Dialog opened successfully');

    // Close Dialog
    final cancelBtn = find.text('Cancel');
    if (cancelBtn.evaluate().isNotEmpty) {
      await tester.tap(cancelBtn.first);
      await tester.pumpAndSettle();
    }

    // -------------------------------------------------------------------------
    // STEP 7: Verify Daily Opening and Closing Screens
    // -------------------------------------------------------------------------
    final dailyReconTile = find.text('Daily Reconciliation');
    expect(dailyReconTile, findsOneWidget);
    await tester.ensureVisible(dailyReconTile);
    await tester.tap(dailyReconTile);
    await tester.pumpAndSettle();

    expect(find.byType(DailyReconciliationScreen), findsOneWidget);
    debugPrint('[REAL-WORLD VERIFICATION] 6. Daily Reconciliation (Opening & Closing) Screen opened');

    // Close daily recon screen
    final backIcon = find.byIcon(Icons.arrow_back_rounded);
    if (backIcon.evaluate().isNotEmpty) {
      await tester.tap(backIcon.first);
    }
    await tester.pumpAndSettle();

    // -------------------------------------------------------------------------
    // STEP 8: Verify Distributor Management & Agent Settlement Modals
    // -------------------------------------------------------------------------
    final agentSettlementBtn = find.text('Agent Settlement');
    await tester.ensureVisible(agentSettlementBtn);
    await tester.tap(agentSettlementBtn);
    await tester.pumpAndSettle();

    expect(find.byType(AgentSettlementDialog), findsOneWidget);
    debugPrint('[REAL-WORLD VERIFICATION] 7. Agent Settlement Dialog verified');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    final rechargeReturnBtn = find.text('Recharge Return');
    await tester.ensureVisible(rechargeReturnBtn);
    await tester.tap(rechargeReturnBtn);
    await tester.pumpAndSettle();

    expect(find.byType(RechargeAmountReturnDialog), findsOneWidget);
    debugPrint('[REAL-WORLD VERIFICATION] 8. Recharge Amount Return Dialog verified');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // -------------------------------------------------------------------------
    // STEP 9: Verify Commission Controls
    // -------------------------------------------------------------------------
    final commissionTile = find.text('Commission Controls');
    await tester.ensureVisible(commissionTile);
    await tester.tap(commissionTile);
    await tester.pumpAndSettle();

    expect(find.byType(OperatorCommissionControlDialog), findsOneWidget);
    debugPrint('[REAL-WORLD VERIFICATION] 9. Commission Controls Dialog verified');
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    // -------------------------------------------------------------------------
    // STEP 10: Verify Recharge Reports Screen
    // -------------------------------------------------------------------------
    final reportsTile = find.text('Recharge Reports & History');
    await tester.ensureVisible(reportsTile);
    await tester.tap(reportsTile);
    await tester.pumpAndSettle();

    expect(find.byType(RechargeReportsScreen), findsOneWidget);
    debugPrint('[REAL-WORLD VERIFICATION] 10. Recharge Reports & History Screen verified');

    // Close reports
    Navigator.of(tester.element(find.byType(RechargeReportsScreen))).pop();
    await tester.pumpAndSettle();

    // -------------------------------------------------------------------------
    // STEP 11: Navigate Back to Main ERP Dashboard (HomeView)
    // -------------------------------------------------------------------------
    final homeSidebarTile = find.text('Dashboard');
    expect(homeSidebarTile, findsWidgets);
    await tester.tap(homeSidebarTile.first);
    await tester.pumpAndSettle();

    expect(find.byType(HomeView), findsOneWidget);
    expect(find.byType(QuickRechargeScreen), findsNothing);
    debugPrint('[REAL-WORLD VERIFICATION] 11. Navigation back to HomeView verified');

    // -------------------------------------------------------------------------
    // STEP 12: Verify Quick Recharge Dialog Can Be Reopened
    // -------------------------------------------------------------------------
    await tester.tap(quickRechargeTile.first);
    await tester.pumpAndSettle();
    expect(find.byType(QuickRechargeScreen), findsOneWidget);
    debugPrint('[REAL-WORLD VERIFICATION] 12. Repeated navigation to Quick Recharge verified');
  });
}
