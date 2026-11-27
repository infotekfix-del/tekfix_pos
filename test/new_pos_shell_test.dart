// New POS (Step 3a): the POS shell (now the only POS).
// Runs on a temporary Hive (never the shop's data) with no Firestore.
//
// Baseline: the same bill is made on the OLD screen and on the NEW screen;
// both call the same _checkout, so every saved number must match.

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

  testWidgets(
      'new POS at 1366x768: total + Complete visible, no overflow, '
      'no inventory on landing', (t) async {
    await posSize(t, const Size(1366, 768));
    await t.pumpWidget(posApp());
    await posSettle(t);

    expect(find.text('GRAND TOTAL (ആകെ)'), findsOneWidget);
    final btn = find.textContaining('COMPLETE PAYMENT');
    expect(btn, findsOneWidget);
    final r = t.getRect(btn);
    expect(r.bottom, lessThanOrEqualTo(768));
    // Privacy: nothing from the inventory until the cashier searches.
    expect(find.text('weva screen gurd'), findsNothing);
    expect(find.text('Old charger'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('scan: exact barcode + Enter adds to the bill, list closes',
      (t) async {
    await posSize(t, const Size(1366, 768));
    await t.pumpWidget(posApp());
    await posSettle(t);

    await t.enterText(find.byType(TextField).first, 'TF200601');
    await t.testTextInput.receiveAction(TextInputAction.search);
    await posSettle(t);

    expect(find.text('weva screen gurd'), findsOneWidget); // the bill line
    expect(find.text('₹150 each'), findsOneWidget); // the bill line
    expect(find.text('Available (ഉണ്ട്)'), findsNothing); // results closed
    expect(t.takeException(), isNull);
  });

  testWidgets('search shows stock as words, never numbers or cost', (t) async {
    await posSize(t, const Size(1366, 768));
    await t.pumpWidget(posApp());
    await posSettle(t);

    await t.enterText(find.byType(TextField).first, 'charger');
    await posSettle(t);
    expect(find.text('Old charger'), findsOneWidget);
    expect(find.text('Out of stock (ഇല്ല)'), findsOneWidget);
    expect(find.text('₹100'), findsNothing); // cost price hidden
    expect(find.textContaining('Cost'), findsNothing);
  });

  testWidgets('phone width: single column + cart bar', (t) async {
    await posSize(t, const Size(400, 800));
    await t.pumpWidget(posApp());
    await posSettle(t);
    expect(find.text('GRAND TOTAL (ആകെ)'), findsNothing);

    await t.enterText(find.byType(TextField).first, 'TF200601');
    await t.testTextInput.receiveAction(TextInputAction.search);
    await posSettle(t);
    expect(find.textContaining('Cart (1)'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('new POS is the only POS: old setting ignored, no old option',
      (t) async {
    // A PC that once chose "Use old POS" still gets the new POS.
    await t.runAsync(() => Hive.box(boxSettings).put('pos_new_ui', 'false'));
    await posSize(t, const Size(1366, 768));
    await t.pumpWidget(posApp());
    await posSettle(t);
    expect(find.text('GRAND TOTAL (ആകെ)'), findsOneWidget);
    expect(find.text('സെയിൽ & ബില്ലിംഗ് (Sale POS)'), findsNothing);
    expect(find.text('Use old POS (പഴയ POS)'), findsNothing);
    await t.runAsync(() => Hive.box(boxSettings).put('pos_new_ui', 'true'));
  });

  testWidgets('double-tap on Complete saves only one bill', (t) async {
    await posSize(t, const Size(1366, 900));
    await t.pumpWidget(posApp());
    await posSettle(t);
    await t.enterText(find.byType(TextField).first, 'TF200601');
    await t.testTextInput.receiveAction(TextInputAction.search);
    await posSettle(t);
    // CASH is the default payment mode.
    final btn = find.textContaining('COMPLETE PAYMENT');
    await t.tap(btn);
    await t.tap(btn, warnIfMissed: false);
    await posSettleIO(t);
    await posCloseDoneDialog(t);
    expect(Hive.box(boxSales).length, 1);
    await posSettleIO(t);
  });
}
