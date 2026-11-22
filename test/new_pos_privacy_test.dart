// New POS (Step 3f): Customer View / CustomerDisplayState.
// Temporary Hive, no Firestore, nothing saved.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/pos/new_pos/customer_display.dart';
import 'package:tekfix_erp_pos/pos/new_pos/customer_display_window.dart';
import 'package:tekfix_erp_pos/pos/new_pos/pos_pin.dart';

import 'new_pos_test_utils.dart';

/// A bill line exactly as the existing POS keeps it (with cost, key ...).
final _cartLine = {
  'key': 'k_phone',
  'itemId': 'item_phone',
  'name': 'Redmi Note 13 5G',
  'imei': '356789012345678',
  'price': 16999.0,
  'cost': 14000.0,
  'warranty': '1 Year',
  'qty': 1,
};

CustomerDisplayState _state({double prev = 0, double credit = 0}) =>
    posBuildDisplayState(
      cart: [_cartLine],
      customerName: 'Unais KP',
      previousDue: prev,
      subtotal: 16999,
      discount: 0,
      total: 16999,
      creditThisBill: credit,
      paymentConfirmed: false,
      upiQrPayload: 'upi://pay?pa=Q085585286@ybl&am=16999.00',
    );

void main() {
  group('CustomerDisplayState (data minimisation)', () {
    test('only name / qty / selling price / masked IMEI cross over', () {
      final m = _state().toMap();
      final text = m.toString();
      expect(text, isNot(contains('14000'))); // purchase price
      expect(text, isNot(contains('cost')));
      expect(text, isNot(contains('stock')));
      expect(text, isNot(contains('k_phone'))); // Hive key
      expect(text, isNot(contains('item_phone'))); // item id
      expect(text, isNot(contains('356789012345678'))); // full IMEI
      expect(text, isNot(contains('warranty')));
      final line = (m['lines'] as List).single as Map;
      expect(line.keys.toSet(),
          {'name', 'qty', 'unitPrice', 'lineTotal', 'maskedId'});
      expect(line['maskedId'], 'IMEI ••••5678');
    });

    test('empty bill -> idle welcome', () {
      final s = posBuildDisplayState(
          cart: const [],
          customerName: 'x',
          previousDue: 500,
          subtotal: 0,
          discount: 0,
          total: 0,
          creditThisBill: 0,
          paymentConfirmed: false,
          welcome: 'Hello');
      expect(s.phase, DisplayPhase.idle);
      expect(s.message, 'Hello');
      expect(s.customerName, ''); // nobody's data on the idle screen
      expect(s.previousDue, 0);
    });

    test('old due + this bill on credit = total due after', () {
      expect(_state().totalDueAfterBill, 0);
      expect(_state(prev: 450).totalDueAfterBill, 450);
      expect(_state(prev: 450, credit: 16999).totalDueAfterBill, 17449);
      expect(_state(credit: 1000).totalDueAfterBill, 1000);
    });

    test('QR only until the cashier confirms', () {
      expect(_state().upiQrPayload, isNotNull);
      final confirmed = posBuildDisplayState(
          cart: [_cartLine],
          customerName: '',
          previousDue: 0,
          subtotal: 1,
          discount: 0,
          total: 1,
          creditThisBill: 0,
          paymentConfirmed: true,
          upiQrPayload: 'upi://x');
      expect(confirmed.upiQrPayload, isNull);
      expect(confirmed.paymentStatus, DisplayPayStatus.received);
      expect(_state().paymentStatus, DisplayPayStatus.waiting);
    });

    test('thank-you status from the saved amounts', () {
      expect(
          posThanksState(total: 100, paid: 100, due: 0, customerName: '')
              .paymentStatus,
          DisplayPayStatus.received);
      expect(
          posThanksState(total: 100, paid: 40, due: 60, customerName: '')
              .paymentStatus,
          DisplayPayStatus.partial);
      expect(
          posThanksState(total: 100, paid: 0, due: 100, customerName: '')
              .paymentStatus,
          DisplayPayStatus.due);
      expect(
          posThanksState(
                  total: 100,
                  paid: 0,
                  due: 100,
                  customerName: 'A',
                  previousDue: 50)
              .totalDueAfterBill,
          150);
    });

    test('map round trip (for a second window)', () {
      final s = _state(prev: 450);
      expect(CustomerDisplayState.fromMap(s.toMap()), s);
    });

    test('second window: exactly what goes over the channel (JSON)', () {
      final s = _state(prev: 450, credit: 100);
      final wire = jsonEncode(s.toMap());
      expect(wire, isNot(contains('14000')));
      expect(wire, isNot(contains('356789012345678')));
      final back = CustomerDisplayState.fromMap(
          jsonDecode(wire) as Map<String, dynamic>);
      expect(back, s);
      expect(back.lines.single.maskedId, 'IMEI ••••5678');
    });

    test('display mode setting', () {
      expect(customerDisplayModeFrom('off'), CustomerDisplayMode.off);
      expect(customerDisplayModeFrom('second'), CustomerDisplayMode.second);
      expect(customerDisplayModeFrom(''), CustomerDisplayMode.auto);
      expect(customerDisplayModeFrom('junk'), CustomerDisplayMode.auto);
    });

    test('second screen host never opens a window during tests', () {
      final h = CustomerDisplayHost.instance;
      h.start(CustomerDisplayMode.second);
      h.push(_state());
      expect(h.showing.value, isFalse);
      h.stop();
    });
  });

  group('PIN', () {
    test('4-6 digits, stored only as a hash', () {
      expect(posValidPinFormat('1234'), isTrue);
      expect(posValidPinFormat('123456'), isTrue);
      expect(posValidPinFormat('123'), isFalse);
      expect(posValidPinFormat('12a4'), isFalse);
      final h = posPinHash('2580');
      expect(h, isNot(contains('2580')));
      expect(posPinMatches(h, '2580'), isTrue);
      expect(posPinMatches(h, '2581'), isFalse);
      expect(posPinMatches('', '2580'), isFalse);
      expect(posPinMatches(null, '2580'), isFalse);
    });
  });

  testWidgets('customer screen is read-only and shows the bill', (t) async {
    await posSize(t, const Size(1366, 768));
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: CustomerDisplayView(state: _state(prev: 450)))));
    await t.pump();
    expect(find.text('Redmi Note 13 5G'), findsOneWidget);
    expect(find.text('IMEI ••••5678'), findsOneWidget);
    expect(find.text('Unais KP'), findsOneWidget);
    expect(find.text('Old due (പഴയ ബാക്കി)'), findsOneWidget);
    expect(find.textContaining('Scan to pay by UPI'), findsOneWidget);
    // no controls of any kind
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(ButtonStyleButton), findsNothing);
    expect(find.byType(IconButton), findsNothing);
    expect(find.byType(InkWell), findsNothing);
    expect(t.takeException(), isNull);
  });

  group('Customer View in the POS', () {
    setUpAll(() async {
      await posInitHive();
      await posSeed();
      await Hive.box(boxSettings).put('pos_new_ui', 'true');
      await Hive.box(boxSettings).delete(kPosViewPinSetting);
    });

    testWidgets('no PIN yet: staff are told the owner must set one', (t) async {
      await posSize(t, const Size(1366, 768));
      await t.pumpWidget(posApp());
      await posSettle(t);
      await t.sendKeyEvent(LogicalKeyboardKey.f11);
      await posSettle(t);
      expect(find.textContaining('Owner must set a Customer View PIN'),
          findsOneWidget);
      expect(find.text('TOTAL TO PAY (അടയ്ക്കേണ്ട തുക)'), findsNothing);
      // set a PIN for the next test (as the owner would, hashed)
      await t.runAsync(() =>
          Hive.box(boxSettings).put(kPosViewPinSetting, posPinHash('2580')));
    });

    testWidgets('F11 -> customer screen; Esc + PIN -> same bill', (t) async {
      await posSize(t, const Size(1366, 768));
      await t.pumpWidget(posApp());
      await posSettle(t);
      await t.enterText(find.byType(TextField).first, 'TF200601');
      await t.testTextInput.receiveAction(TextInputAction.search);
      await posSettle(t);

      await t.sendKeyEvent(LogicalKeyboardKey.f11);
      await posSettle(t);
      expect(find.text('TOTAL TO PAY (അടയ്ക്കേണ്ട തുക)'), findsOneWidget);
      expect(find.text('weva screen gurd'), findsOneWidget);
      // nothing from the cashier screen is visible
      expect(find.textContaining('COMPLETE PAYMENT'), findsNothing);
      expect(find.textContaining('Top Selling'), findsNothing);
      expect(find.text('₹40'), findsNothing); // purchase price

      // POS keys do nothing here
      await t.sendKeyEvent(LogicalKeyboardKey.f12);
      await t.sendKeyEvent(LogicalKeyboardKey.f4);
      await posSettle(t);
      expect(find.text('TOTAL TO PAY (അടയ്ക്കേണ്ട തുക)'), findsOneWidget);
      expect(Hive.box(boxSales).length, 0);

      // Esc -> PIN; wrong PIN stays
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await posSettle(t);
      expect(find.text('Staff PIN to leave (സ്റ്റാഫ് PIN)'), findsOneWidget);
      await t.enterText(find.byType(TextField).last, '1111');
      await t.tap(find.text('Leave (പുറത്ത്)'));
      await posSettle(t);
      expect(find.text('Wrong PIN (PIN തെറ്റാണ്)'), findsOneWidget);
      // right PIN -> back to the same bill
      await t.enterText(find.byType(TextField).last, '2580');
      await t.tap(find.text('Leave (പുറത്ത്)'));
      await posSettle(t);
      expect(find.text('TOTAL TO PAY (അടയ്ക്കേണ്ട തുക)'), findsNothing);
      expect(find.textContaining('COMPLETE PAYMENT'), findsOneWidget);
      expect(find.text('₹150 each'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });
}
