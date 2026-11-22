// Shared helpers for the new POS widget tests: temporary Hive only,
// sync engine not started (no Firestore).
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/crm/customer_crm.dart';
import 'package:provider/provider.dart';
import 'package:tekfix_erp_pos/auth/auth_controller.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/sync/sync_engine.dart';

const posKItemsKeys = [
  'subtotal',
  'discount',
  'total',
  'cash',
  'upi',
  'due',
  'profit',
  'gstRate',
  'customerName',
  'status',
  'isBackdated',
];

Future<void> posOpenBoxes() async {
  for (final b in [
    boxItems,
    boxParties,
    boxSales,
    boxPurchases,
    boxExpenses,
    boxBank,
    boxStaff,
    boxSettings,
    boxAudit,
    boxServices,
    boxStockMoves,
    boxSyncQueue,
    boxReturns,
    boxPurchaseBills,
    boxVendorPayments,
  ]) {
    await Hive.openBox(b);
  }
}

Future<void> posSeed() async {
  await Hive.box(boxItems).clear();
  await Hive.box(boxSales).clear();
  await Hive.box(boxBank).clear();
  await Hive.box(boxItems).put('k_glass', {
    '_id': 'item_glass',
    'name': 'weva screen gurd',
    'barcode': 'TF200601',
    'stock': 10,
    'minStock': 3,
    'costPrice': 40.0,
    'sellingPrice': 150.0,
    'category': 'ACCESSORY',
  });
  await Hive.box(boxItems).put('k_out', {
    '_id': 'item_out',
    'name': 'Old charger',
    'barcode': 'TF999999',
    'stock': 0,
    'costPrice': 100.0,
    'sellingPrice': 250.0,
  });
}

/// [dark]: run the app in dark mode (the POS must still be light).
Widget posApp({bool dark = false}) => MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthController>.value(
            value: AuthController.instance),
        // Not started: no Firestore, nothing is pushed.
        ChangeNotifierProvider<SyncEngine>.value(value: SyncEngine.instance),
      ],
      child: MaterialApp(
        theme: dark ? ThemeData.dark() : null,
        home: const SaleView(),
      ),
    );

Future<void> posSize(WidgetTester t, Size s) async {
  t.view.physicalSize = s;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

Future<void> posSettle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 120));
  }
}

/// Hive writes finish on real disk I/O, which the fake test clock never
/// advances: give real time between pumps until the save completes.
Future<void> posSettleIO(WidgetTester t) async {
  for (var i = 0; i < 40; i++) {
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 25)));
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// on = new POS (the only POS in the app); off = classic screen, tests only.
Future<void> posFlag(WidgetTester t, bool on) async {
  debugShowClassicPos = !on;
  await t.runAsync(
      () => Hive.box(boxSettings).put('pos_new_ui', on ? 'true' : 'false'));
}

/// Closes the "bill saved" dialog of either screen (old: അടയ്ക്കുക,
/// new: New bill).
Future<void> posCloseDoneDialog(WidgetTester t) async {
  expect(find.textContaining('ബില്ലിംഗ് പൂർത്തിയായി!'), findsOneWidget);
  final newBill = find.text('New bill (പുതിയ ബിൽ)');
  await t.tap(newBill.evaluate().isNotEmpty ? newBill : find.text('അടയ്ക്കുക'));
  await posSettle(t);
}

/// A TextField by its exact label (the old screen's helper wraps fields, so
/// widgetWithText can land on the wrong one).
Finder posField(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label,
    description: 'TextField "$label"');

/// Sets a field's text and fires its onChanged (same as typing, without
/// depending on which field holds keyboard focus).
Future<void> posType(WidgetTester t, String label, String v) async {
  final f = t.widget<TextField>(posField(label));
  f.controller!.text = v;
  f.onChanged?.call(v);
  await t.pump();
}

Map<String, dynamic> posLastSale() {
  final b = Hive.box(boxSales);
  return Map<String, dynamic>.from(b.get(b.keys.last) as Map);
}

/// Temporary Hive directory + all boxes the POS touches.
Future<void> posInitHive() async {
  GoogleFonts.config.allowRuntimeFetching = false;
  final tmp = await Directory.systemTemp.createTemp('tekfix_new_pos_');
  Hive.init(tmp.path);
  await posOpenBoxes();
}

/// Temporary Hive + items + two customers (one with an old due and a part
/// paid bill) + the real Customer CRM opened on those boxes.
Future<void> posSeedCustomers() async {
  await posInitHive();
  await posSeed();
  await Hive.box(boxSettings).put('pos_new_ui', 'true');
  await Hive.box(boxParties).clear();
  await Hive.box(boxParties).put('p1', {
    '_id': 'c1',
    'name': 'Unais KP',
    'phone': '9847012321',
    'type': 'Customer',
    'balance': 450.0,
  });
  await Hive.box(boxParties).put('p2', {
    '_id': 'c2',
    'name': 'Anu',
    'phone': '9895000011',
    'type': 'Customer',
    'balance': 0.0,
  });
  await Hive.box(boxSales).add({
    '_id': 's1',
    'invoice': 'INV-1',
    'saleDate': DateTime.now()
        .toUtc()
        .subtract(const Duration(days: 3))
        .toIso8601String(),
    'customerId': 'c1',
    'customerPhone': '9847012321',
    'customerName': 'Unais KP',
    'items': [
      {'name': 'Glass', 'qty': 1, 'price': 300.0}
    ],
    'total': 300.0,
    'cash': 100.0,
    'upi': 0.0,
    'due': 200.0,
    'status': 'SOLD',
  });
  await CustomerCrm.open(
      parties: Hive.box(boxParties), sales: Hive.box(boxSales));
}

/// Sets the text of the TextField with this ValueKey and fires onChanged.
Future<void> posTypeKey(WidgetTester t, String key, String v) async {
  final f = t.widget<TextField>(find.byKey(ValueKey(key)));
  f.controller!.text = v;
  f.onChanged?.call(v);
  await t.pump();
}
