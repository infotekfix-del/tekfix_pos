// Regression: typing in "Product Name" of the "+ Custom / New Item" dialog
// showed matching items in a shrinkWrap ListView inside an AlertDialog,
// which throws "RenderShrinkWrappingViewport does not support returning
// intrinsic dimensions" and paints the dialog as a blank blue box.
// Same pattern in the IMEI / Serial Numbers dialog.

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
import 'package:tekfix_erp_pos/purchases/smart_inventory_search_engine.dart';

void main() {
  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    final tmp = await Directory.systemTemp.createTemp('tekfix_custom_item_');
    Hive.init(tmp.path);
    for (final b in [
      boxItems,
      boxParties,
      boxSales,
      boxPurchases,
      boxBank,
      boxSettings,
      boxAudit,
      boxStockMoves,
      boxReturns,
      boxPurchaseBills,
      boxVendorPayments,
    ]) {
      await Hive.openBox(b);
    }
    await Hive.box(boxSettings).put('store_state_code', '32');
    await Hive.box(boxSettings).put('shop_id', 'test_shop');
    for (var i = 0; i < 3; i++) {
      await Hive.box(boxItems).add({
        '_id': 'item_$i',
        'name': 'Redmi Note 13 Glass $i',
        'stock': 5,
        'costPrice': 100.0,
        'sellingPrice': 150.0,
        'sku': 'SKU$i',
      });
    }
    ManualPurchaseDraftService.instance.delete();
  });

  testWidgets('typing a product name with matches renders the suggestions',
      (tester) async {
    await tester.runAsync(() async {
      try {
        await SmartInventorySearchEngine.instance
            .initialize(shopId: 'test_shop')
            .timeout(const Duration(seconds: 3));
      } catch (_) {/* Firestore unavailable in tests; Hive cache is enough */}
    });
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MultiProvider(
      providers: [ChangeNotifierProvider.value(value: AuthController.instance)],
      child: MaterialApp(
        theme: ThemeData.dark(),
        home: const Scaffold(body: ManualPurchaseEntryScreen()),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    final addBtn = find.text('+ Custom / New Item');
    await tester.ensureVisible(addBtn);
    await tester.tap(addBtn);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('Add Item to Purchase Bill'), findsOneWidget);

    final nameField = find.widgetWithText(TextField, 'Product Name *');
    await tester.enterText(nameField, 'Redmi');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(SmartInventorySearchEngine.instance.search('Redmi'), isNotEmpty,
        reason: 'test needs real suggestions to exercise the list');
    expect(find.text('Select'), findsWidgets);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
