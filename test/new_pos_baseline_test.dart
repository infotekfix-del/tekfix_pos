// Baseline: the same bill made on the OLD and the NEW POS screens must save
// identical numbers (both call the same _checkout). Own file = own isolate,
// so its Hive writes never block other tests.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';

import 'new_pos_test_utils.dart';

void main() {
  setUpAll(() async {
    await posInitHive();
  });

  setUp(() async {
    await posSeed();
    await Hive.box(boxSettings).put('pos_new_ui', 'true');
  });

  testWidgets('baseline: old and new screens save identical bills', (t) async {
    await posSize(t, const Size(1366, 900));

    // ---- OLD screen: 2 x glass, discount 20, cash 200 + UPI 80
    // The old screen has known layout errors of its own (product cards
    // overflow, ListTile ink warnings); they are not part of this check, so
    // only during the old-screen part they are collected instead of failing.
    final oldErrors = <String>[];
    final strict = FlutterError.onError;
    FlutterError.onError = (d) => oldErrors.add(d.exceptionAsString());
    t.view.physicalSize = const Size(1366, 1600); // old cart panel scrolls
    late Map<String, dynamic> oldBill;
    late Object? stockAfterOld;
    try {
      await posFlag(t, false);
      await t.pumpWidget(posApp());
      await posSettle(t);
      final card = find.descendant(
          of: find.byType(GridView), matching: find.text('weva screen gurd'));
      await t.tap(card);
      await t.pump();
      await t.tap(card);
      await posSettle(t);
      expect(find.text('In cart 2'), findsOneWidget);
      await posType(t, 'കിഴിവ് (Discount ₹)', '20');
      await posType(t, 'Cash ₹', '200');
      await posType(t, 'UPI / Card ₹', '80');
      await posSettle(t);
      await t.tap(find.text('ബിൽ പൂർത്തിയാക്കുക'));
      await posSettleIO(t);
      await posCloseDoneDialog(t);
      oldBill = posLastSale();
      stockAfterOld = (Hive.box(boxItems).get('k_glass') as Map)['stock'];
    } finally {
      FlutterError.onError = strict; // the new screen is checked strictly
    }
    for (final e in oldErrors) {
      expect(e, anyOf(contains('overflowed'), contains('ink splashes')),
          reason: 'unexpected old-screen error');
    }
    t.view.physicalSize = const Size(1366, 900);

    // ---- NEW screen: same bill
    await posFlag(t, true);
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(posApp());
    await posSettle(t);
    for (var i = 0; i < 2; i++) {
      await t.enterText(find.byType(TextField).first, 'TF200601');
      await t.testTextInput.receiveAction(TextInputAction.search);
      await posSettle(t);
    }
    await posType(t, 'Discount ₹ (കിഴിവ്)', '20');
    await t.tap(find.text('SPLIT')); // Cash + UPI/Card typed by hand
    await posSettle(t);
    await posType(t, 'Cash ₹', '200');
    await posType(t, 'UPI / Card ₹', '80');
    await posSettle(t);
    await t.tap(find.textContaining('COMPLETE PAYMENT'));
    await posSettleIO(t);
    await posCloseDoneDialog(t);
    final newBill = posLastSale();
    final stockAfterNew = (Hive.box(boxItems).get('k_glass') as Map)['stock'];

    expect(Hive.box(boxSales).length, 2);
    for (final k in posKItemsKeys) {
      expect(newBill[k], oldBill[k], reason: k);
    }
    expect(oldBill['total'], 280.0);
    expect(oldBill['due'], 0.0);
    List lines(Map b) => [
          for (final l in b['items'] as List)
            {
              for (final k in ['itemId', 'name', 'price', 'cost', 'qty'])
                k: l[k]
            }
        ];
    expect(lines(newBill), lines(oldBill));
    expect(stockAfterOld, 8);
    expect(stockAfterNew, 6); // each bill deducted 2
    expect(newBill['invoice'], isNot(oldBill['invoice'])); // no duplicate
    await posSettleIO(t); // let queued Hive writes finish before the next test
  });
}
