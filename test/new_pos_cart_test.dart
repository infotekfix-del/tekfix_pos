// New POS (Step 3d): cart rules. Temporary Hive, no Firestore, no saving.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/pos/new_pos/pos_cart_logic.dart';

import 'new_pos_test_utils.dart';

Finder get _qtyField => find.byWidgetPredicate(
    (w) => w is TextField && w.textAlign == TextAlign.center,
    description: 'qty field');

Future<void> _open(WidgetTester t) async {
  await posSize(t, const Size(1366, 900));
  await t.pumpWidget(posApp());
  await posSettle(t);
}

Future<void> _scan(WidgetTester t, String code) async {
  await t.enterText(find.byType(TextField).first, code);
  await t.testTextInput.receiveAction(TextInputAction.search);
  await posSettle(t);
}

Future<void> _typeQty(WidgetTester t, String v) async {
  await t.enterText(_qtyField, v);
  await t.testTextInput.receiveAction(TextInputAction.done);
  await posSettle(t);
}

void main() {
  group('rules', () {
    test('typed qty: 1..stock', () {
      expect(posQtyCheck('3', stock: 10).qty, 3);
      expect(posQtyCheck('10', stock: 10).qty, 10);
      expect(posQtyCheck('11', stock: 10).error, contains('Only 10 in stock'));
      expect(posQtyCheck('0', stock: 10).error, contains('Minimum 1'));
      expect(posQtyCheck('', stock: 10).error, contains('Minimum 1'));
      expect(posQtyCheck('2.5', stock: 10).error, contains('Minimum 1'));
    });
    test('discount percent', () {
      expect(posDiscountPercent(15, 150), '10%');
      expect(posDiscountPercent(20, 300), '6.7%');
      expect(posDiscountPercent(0, 300), '');
      expect(posDiscountPercent(10, 0), '');
    });
    test('IMEI: last 4 only; never twice on a bill', () {
      expect(posImeiMasked('356789012345678'), 'IMEI ••••5678');
      expect(posImeiMasked(''), '');
      final cart = [
        {'key': 'k1', 'imei': '356789012345678'}
      ];
      expect(posImeiAlreadyInCart(cart, 'k1', {'imei': '356789012345678'}),
          isTrue);
      expect(posImeiAlreadyInCart(cart, 'k9', {'imei': '356789012345678'}),
          isTrue); // same IMEI on another record
      expect(posImeiAlreadyInCart(cart, 'k2', {'imei': '111'}), isFalse);
      expect(posImeiAlreadyInCart(cart, 'k1', {'imei': ''}), isFalse);
    });
  });

  setUpAll(() async {
    await posInitHive();
    await posSeed();
    await Hive.box(boxSettings).put('pos_new_ui', 'true');
    await Hive.box(boxItems).put('k_phone', {
      '_id': 'item_phone',
      'name': 'Redmi Note 13 5G',
      'barcode': 'PH001',
      'imei': '356789012345678',
      'stock': 1,
      'costPrice': 14000.0,
      'sellingPrice': 16999.0,
      'category': 'MOBILE',
    });
  });

  testWidgets('typed qty within stock; over stock refused; 0 removes',
      (t) async {
    await _open(t);
    await _scan(t, 'TF200601');
    await _typeQty(t, '5');
    expect(find.text('₹750'), findsWidgets); // line total + subtotal
    await _typeQty(t, '50');
    expect(find.textContaining('Insufficient stock'), findsOneWidget);
    expect(find.textContaining('Available: 10'), findsOneWidget);
    expect((t.widget<TextField>(_qtyField)).controller!.text, '5');
    await _typeQty(t, '0');
    expect(find.text('weva screen gurd'), findsNothing); // line removed
    expect(find.text('Removed (മാറ്റി): weva screen gurd'), findsOneWidget);
  });

  testWidgets('remove has Undo (no confirm dialog)', (t) async {
    await _open(t);
    await _scan(t, 'TF200601');
    await t.tap(find.byTooltip('Remove (മാറ്റുക)').last);
    await posSettle(t);
    expect(find.text('₹150 each'), findsNothing);
    expect(find.text('weva screen gurd'), findsNothing);
    expect(find.text('Removed (മാറ്റി): weva screen gurd'), findsOneWidget);
    await t.tap(find.text('UNDO (തിരികെ)'));
    await posSettle(t);
    expect(find.text('weva screen gurd'), findsOneWidget);
  });

  testWidgets('IMEI item: one unit, last 4 shown, never added twice',
      (t) async {
    await _open(t);
    await _scan(t, 'PH001');
    expect(find.text('IMEI ••••5678'), findsOneWidget);
    expect(_qtyField, findsNothing); // no qty for IMEI lines
    expect(find.text('356789012345678'), findsNothing);
    await _scan(t, 'PH001');
    expect(find.textContaining('already in the bill'), findsOneWidget);
    expect(find.text('Redmi Note 13 5G'), findsOneWidget); // still one line
  });

  testWidgets('discount shows amount and %; clear asks first', (t) async {
    await _open(t);
    await _scan(t, 'TF200601');
    await posType(t, 'Discount ₹ (കിഴിവ്)', '15');
    expect(find.text('10%'), findsOneWidget); // field suffix
    expect(find.text('Discount (കിഴിവ്) 10%'), findsOneWidget);
    expect(find.text('− ₹15'), findsOneWidget);

    await t.tap(find.byTooltip('Clear bill (മാറ്റുക)'));
    await posSettle(t);
    expect(find.textContaining('Clear all items'), findsOneWidget);
    await t.tap(find.widgetWithText(FilledButton, 'Clear (മാറ്റുക)'));
    await posSettle(t);
    expect(find.text('weva screen gurd'), findsNothing);
    expect(t.takeException(), isNull);
  });
}
