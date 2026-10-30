import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';
import 'package:tekfix_erp_pos/auth/auth_controller.dart';
import 'package:tekfix_erp_pos/main.dart'
    show
        boxAudit,
        boxBank,
        boxItems,
        boxParties,
        boxPurchases,
        boxSales,
        boxSettings,
        boxReturns,
        boxStockMoves,
        boxPurchaseBills,
        boxVendorPayments;
import 'package:tekfix_erp_pos/purchases/manual_purchase_draft_service.dart';
import 'package:tekfix_erp_pos/purchases/manual_purchase_entry_screen.dart';
import 'package:tekfix_erp_pos/purchases/purchase_bills_dashboard_view.dart';

Widget _buildTestApp(Widget home) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: AuthController.instance),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: Scaffold(body: home),
    ),
  );
}

void main() {
  late Directory tempDir;

  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    tempDir = await Directory.systemTemp.createTemp('tekfix_manual_ui_test_');
    Hive.init(tempDir.path);

    await Hive.openBox(boxItems);
    await Hive.openBox(boxParties);
    await Hive.openBox(boxSales);
    await Hive.openBox(boxPurchases);
    await Hive.openBox(boxBank);
    await Hive.openBox(boxSettings);
    await Hive.openBox(boxAudit);
    await Hive.openBox(boxStockMoves);
    await Hive.openBox(boxReturns);
    await Hive.openBox(boxPurchaseBills);
    await Hive.openBox(boxVendorPayments);
    final settingsBox = Hive.box(boxSettings);
    await settingsBox.put('store_state_code', '32');
    await settingsBox.put('shop_id', 'test_shop');
    ManualPurchaseDraftService.instance.delete();
  });

  group('PHASE 2: MANUAL PURCHASE WIDGET TESTS (M1 & M13)', () {
    // M1: Manual Purchase Entry opens from the Purchase screen
    testWidgets('M1. Manual Purchase Entry button opens screen from Dashboard',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(_buildTestApp(const PurchaseBillsDashboardView()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final manualBtn = find.text('Manual Purchase Entry');
      expect(manualBtn, findsWidgets);

      await tester.tap(manualBtn.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(ManualPurchaseEntryScreen), findsOneWidget);
      expect(find.text('Invoice Details'), findsOneWidget);
      expect(find.text('Supplier'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    // M13: Layout works at phone, tablet, and desktop widths with no overflow
    testWidgets('M13. Responsive rendering at Phone, Tablet, and Desktop widths',
        (tester) async {
      // 1. Phone width (390 x 844)
      await tester.pumpWidget(
        _buildTestApp(
          const SizedBox(
            width: 390,
            height: 844,
            child: ManualPurchaseEntryScreen(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(ManualPurchaseEntryScreen), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 2. Tablet width (768 x 1024)
      await tester.pumpWidget(
        _buildTestApp(
          const SizedBox(
            width: 768,
            height: 1024,
            child: ManualPurchaseEntryScreen(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);

      // 3. Desktop width (1440 x 900)
      await tester.pumpWidget(
        _buildTestApp(
          const SizedBox(
            width: 1440,
            height: 900,
            child: ManualPurchaseEntryScreen(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });
}
