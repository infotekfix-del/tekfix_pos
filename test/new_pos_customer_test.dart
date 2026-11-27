// New POS (Step 3c): customer section. Real Customer CRM on a temporary
// Hive (no shop data, no Firestore). Read-only tests first; tests that save
// (new customer, credit bill) run last.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/pos/new_pos/pos_customer_logic.dart';

import 'new_pos_test_utils.dart';

const _kSearch = 'Phone or name  ·  F3';

Future<void> _open(WidgetTester t) async {
  await posSize(t, const Size(1366, 900));
  await t.pumpWidget(posApp());
  await posSettle(t);
}

Future<void> _type(WidgetTester t, String v) async {
  await posType(t, _kSearch, v);
  await posSettle(t); // 200 ms debounce
}

void main() {
  setUpAll(posSeedCustomers);

  test('phone masking', () {
    expect(posMaskPhone('9847012321'), '98******21');
    expect(posMaskPhone('+91 98470 12321'), '98******21');
    expect(posMaskPhone('123'), '***');
    expect(posMaskPhone(''), '');
    expect(
        posRecentCustomerIds([
          {'customerId': 'a'},
          {'customerId': ''},
          {'customerId': 'b'},
          {'customerId': 'a'},
        ]),
        ['a', 'b']);
  });

  testWidgets('name search: masked phone + due, never the full number',
      (t) async {
    await _open(t);
    await _type(t, 'unais');
    expect(find.text('Unais KP'), findsOneWidget);
    expect(find.text('98******21'), findsOneWidget);
    expect(find.text('9847012321'), findsNothing);
    expect(find.text('Due ₹450'), findsOneWidget);
    expect(
        find.textContaining('New customer (പുതിയ കസ്റ്റമർ)'), findsOneWidget);
  });

  testWidgets('full phone number selects the customer: old due + history',
      (t) async {
    await _open(t);
    await _type(t, '98470 12321');
    expect(find.text('Old due (പഴയ ബാക്കി)'), findsOneWidget);
    expect(find.text('₹450'), findsOneWidget);
    expect(find.text('Purchase history (വാങ്ങിയവ) · 1'), findsOneWidget);
    expect(find.text('Due ₹200'), findsOneWidget); // the past bill's due
    expect(find.text('9847012321'), findsOneWidget); // on the selected card

    await t.tap(find.text('All bills (എല്ലാം) →'));
    await posSettle(t);
    expect(find.textContaining('INV-1'), findsOneWidget);
    expect(find.text('PARTIAL'), findsOneWidget);
    await t.tap(find.byTooltip('Close (അടയ്ക്കുക)'));
    await posSettle(t);

    await t.tap(find.byTooltip('Change customer (കസ്റ്റമറെ മാറ്റുക)'));
    await posSettle(t);
    expect(find.text('Old due (പഴയ ബാക്കി)'), findsNothing);
    expect(find.text('Walk-in / Cash customer (വാക്ക്-ഇൻ)'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('no due shows green "No due"; recent customer chip', (t) async {
    await _open(t);
    // Recent customers come from recent bills (Unais has one).
    await t.tap(find.widgetWithText(ActionChip, 'Unais KP'));
    await posSettle(t);
    expect(find.text('Old due (പഴയ ബാക്കി)'), findsOneWidget);
    await t.tap(find.byTooltip('Change customer (കസ്റ്റമറെ മാറ്റുക)'));
    await posSettle(t);

    await _type(t, 'anu');
    await t.tap(find.text('Anu'));
    await posSettle(t);
    expect(find.text('No due (ബാക്കിയില്ല)'), findsOneWidget);
  });

  testWidgets('new customer with an existing number -> "already exists"',
      (t) async {
    await _open(t);
    await t.tap(find.byTooltip('New customer (പുതിയ കസ്റ്റമർ)'));
    await posSettle(t);
    await posTypeKey(t, 'pos-new-customer-phone', '9895000011');
    await posTypeKey(t, 'pos-new-customer-name', 'Anu Duplicate');
    await t.tap(find.text('Save customer'));
    await posSettle(t);
    expect(find.textContaining('Customer already exists – select?'),
        findsOneWidget);
    await t.tap(find.text('Select (തിരഞ്ഞെടുക്കുക)'));
    await posSettle(t);
    expect(find.text('Anu'), findsOneWidget);
    expect(find.text('No due (ബാക്കിയില്ല)'), findsOneWidget);
    expect(Hive.box(boxParties).length, 2); // nothing created
  });

  testWidgets('credit bill goes to the selected customer (existing rule)',
      (t) async {
    await _open(t);
    await _type(t, '9847012321');
    await t.enterText(find.byType(TextField).first, 'TF200601');
    await t.testTextInput.receiveAction(TextInputAction.search);
    await posSettle(t);
    await t.tap(find.text('CREDIT'));
    await t.pump();
    await t.tap(find.textContaining('COMPLETE PAYMENT'));
    await posSettleIO(t);
    await posCloseDoneDialog(t);
    final bill = posLastSale();
    expect(bill['customerId'], 'c1');
    expect(bill['partyId'], 'c1');
    expect(bill['due'], 150.0);
    final party = Hive.box(boxParties).get('p1') as Map;
    expect(party['balance'], 600.0); // 450 old + 150 this bill
    await posSettleIO(t);
  });
}
