// New POS: "−  Qty  +" on bill lines. Temporary Hive only, no Firestore.
// Rules: + / − by one, 0 removes, stock counted over all lines of an item,
// IMEI + picks an unused IMEI, IMEI − asks which one, last unit confirmed,
// saved bill = what was on screen, stock taken once at save.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/pos/new_pos/pos_cart_logic.dart';

import 'new_pos_test_utils.dart';

Future<void> _open(WidgetTester t) async {
  await posSize(t, const Size(1366, 900));
  await t.pumpWidget(const SizedBox());
  await t.pumpWidget(posApp());
  await posSettle(t);
}

Future<void> _scan(WidgetTester t, String code) async {
  await t.enterText(find.byType(TextField).first, code);
  await t.testTextInput.receiveAction(TextInputAction.search);
  await posSettle(t);
}

Finder _plus(String key) => find.byKey(ValueKey('pos-qty-plus-$key'));
Finder _minus(String key) => find.byKey(ValueKey('pos-qty-minus-$key'));

String _qty(WidgetTester t, String key) => t
    .widget<TextField>(find.byKey(ValueKey('pos-qty-value-$key')))
    .controller!
    .text;

Future<void> _tap(WidgetTester t, Finder f) async {
  await t.tap(f);
  await posSettle(t);
}

bool _enabled(WidgetTester t, Finder f) =>
    t.widget<IconButton>(f).onPressed != null;

const _ph1 = '356789012345671';
const _ph2 = '356789012345672';
const _ph3 = '356789012345673';

void main() {
  group('rules', () {
    final cart = <Map>[
      {'key': 'a', 'qty': 2, 'name': 'Glass'},
      {'key': 'b', 'qty': 1, 'name': 'Cable'},
      {'key': 'a', 'qty': 3, 'name': 'Glass'}, // same item, second line
    ];
    test('qty counted over all lines of the same item', () {
      expect(posCartQtyOf(cart, 'a'), 5);
      expect(posCartQtyOf(cart, 'a', exceptIndex: 0), 3);
      expect(posQtyRoom(cart, 'a', 6), 1);
      expect(posQtyRoom(cart, 'a', 5), 0);
      expect(posQtyRoom(cart, 'a', 4), 0); // never below 0
    });
    test('typed qty: 0 removes, limit = stock minus other lines', () {
      expect(posLineQtyCheck('0', cart, 0, 6).qty, 0);
      expect(posLineQtyCheck('3', cart, 0, 6).qty, 3);
      final over = posLineQtyCheck('4', cart, 0, 6);
      expect(over.qty, isNull);
      expect(over.error, posStockShortMsg(3));
      expect(posLineQtyCheck('-1', cart, 0, 6).error, isNotNull);
      expect(posLineQtyCheck('x', cart, 0, 6).error, isNotNull);
    });
    test('IMEI candidates: same model, in stock, not on the bill', () {
      final items = <MapEntry<dynamic, Map>>[
        const MapEntry('p1', {'name': 'Redmi 13', 'imei': _ph1, 'stock': 1}),
        const MapEntry('p2', {'name': ' redmi  13 ', 'imei': _ph2, 'stock': 1}),
        const MapEntry('p3', {'name': 'Redmi 13', 'imei': _ph3, 'stock': 0}),
        const MapEntry('p4', {'name': 'Redmi 14', 'imei': '9', 'stock': 1}),
        const MapEntry('g', {'name': 'Redmi 13', 'stock': 5}), // no IMEI
      ];
      final bill = <Map>[
        {'key': 'p1', 'name': 'Redmi 13', 'imei': _ph1, 'qty': 1}
      ];
      final c = posImeiCandidates(items, bill, posModelKey(bill.first));
      expect(c.map((e) => e.key), ['p2']);
      expect(posImeiLinesOf(bill, 'redmi 13', (l) => true), [0]);
    });
    test('IMEI box used as an item code (big stock) is a normal item', () {
      // Real shop data: Photostat has "1" in the IMEI box, stock 2340.
      final photo = {'name': 'PHOTO STAT', 'imei': '1', 'stock': 2340};
      expect(posIsUnitItem(photo, 2340), isFalse);
      expect(posIsUnitItem({'imei': _ph1}, 1), isTrue); // a real phone
      expect(posIsUnitItem({'imei': _ph1}, 0), isTrue); // sold out phone
      expect(posIsUnitItem({'imei': ''}, 1), isFalse);
      final bill = <Map>[
        {'key': 'ps', 'name': 'PHOTO STAT', 'imei': '1', 'qty': 10}
      ];
      expect(posImeiAlreadyInCart(bill, 'ps', photo), isFalse); // add again
      expect(posValidateCart(bill, (k) => 2340), isNull); // qty 10 is fine
    });
    test('final check before save', () {
      int? stock(dynamic k) => {'a': 5, 'b': 1, 'p1': 1}[k];
      expect(posValidateCart(cart, stock), isNull);
      expect(posValidateCart(cart, (k) => k == 'a' ? 4 : 1),
          contains('Available: 4'));
      expect(
          posValidateCart([
            ...cart,
            {'key': 'z', 'qty': 1, 'name': 'Gone'}
          ], stock),
          contains('Gone'));
      expect(
          posValidateCart([
            {'key': 'a', 'qty': 0, 'name': 'Glass'}
          ], stock),
          contains('at least 1'));
      expect(
          posValidateCart([
            {'key': 'p1', 'qty': 2, 'name': 'Phone', 'imei': _ph1}
          ], (k) => 1), // a real phone record: stock 1
          contains('one IMEI is one unit'));
      expect(
          posValidateCart([
            {'key': 'p1', 'qty': 1, 'name': 'Phone', 'imei': _ph1},
            {'key': 'p9', 'qty': 1, 'name': 'Phone', 'imei': _ph1},
          ], (k) => 1),
          contains('IMEI twice'));
    });
  });

  setUpAll(() async {
    await posInitHive();
    await posSeed();
    await Hive.box(boxSettings).put('pos_new_ui', 'true');
    final items = Hive.box(boxItems);
    await items.put('k_cable', {
      '_id': 'item_cable',
      'name': 'Type-C cable',
      'barcode': 'CB001',
      'stock': 3,
      'costPrice': 60.0,
      'sellingPrice': 199.0,
      'category': 'CABLE',
    });
    await items.put('k_photo', {
      '_id': 'item_photo',
      'name': 'PHOTO STAT',
      'barcode': 'PS001',
      'imei': '1', // the shop keeps a short code in the IMEI box
      'stock': 2340,
      'costPrice': 1.0,
      'sellingPrice': 5.0,
      'category': 'ACCESSORY',
    });
    for (final (k, im) in [('k_ph1', _ph1), ('k_ph2', _ph2), ('k_ph3', _ph3)]) {
      await items.put(k, {
        '_id': 'item_$k',
        'name': 'Redmi Note 13 5G',
        'barcode': 'BC$k',
        'imei': im,
        'stock': 1,
        'costPrice': 14000.0,
        'sellingPrice': 16999.0,
        'category': 'MOBILE',
      });
    }
  });

  testWidgets('qty 1->2->3->2->1->0, totals follow, discount kept', (t) async {
    await _open(t);
    await _scan(t, 'TF200601'); // ₹150, stock 10
    await posType(t, 'Discount ₹ (കിഴിവ്)', '15');
    await _tap(t, _plus('k_glass'));
    await _tap(t, _plus('k_glass'));
    expect(_qty(t, 'k_glass'), '3');
    expect(find.text('₹450'), findsWidgets); // line total + subtotal
    expect(find.text('₹435'), findsWidgets); // grand total after ₹15 off
    await _tap(t, _minus('k_glass'));
    expect(_qty(t, 'k_glass'), '2');
    expect(find.text('₹285'), findsWidgets);
    await _tap(t, _minus('k_glass'));
    expect(_qty(t, 'k_glass'), '1');
    expect(posField('Discount ₹ (കിഴിവ്)'), findsOneWidget);
    expect(
        t.widget<TextField>(posField('Discount ₹ (കിഴിവ്)')).controller!.text,
        '15'); // discount unchanged by qty changes
    await _tap(t, _minus('k_glass')); // 1 -> 0 removes (with Undo)
    expect(find.text('weva screen gurd'), findsNothing);
    expect(find.text('Removed (മാറ്റി): weva screen gurd'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('+ stops at stock; two items count separately', (t) async {
    await _open(t);
    await _scan(t, 'CB001'); // stock 3
    await _scan(t, 'TF200601');
    await _tap(t, _plus('k_cable'));
    await _tap(t, _plus('k_cable'));
    expect(_qty(t, 'k_cable'), '3');
    expect(_enabled(t, _plus('k_cable')), isFalse); // limit reached
    expect(find.byTooltip(posStockShortMsg(3)), findsOneWidget);
    expect(_qty(t, 'k_glass'), '1'); // the other line is untouched
    expect(_enabled(t, _plus('k_glass')), isTrue);
    expect(find.text('₹597'), findsWidgets); // 3 × 199
    expect(find.text('₹747'), findsWidgets); // 597 + 150
    await _scan(t, 'CB001'); // scanning again is also refused
    expect(_qty(t, 'k_cable'), '3');
    expect(t.takeException(), isNull);
  });

  testWidgets('IMEI: + needs a picked IMEI; − asks which; last confirmed',
      (t) async {
    await _open(t);
    await _scan(t, 'BCk_ph1');
    expect(find.text('Redmi Note 13 5G'), findsOneWidget);

    // + opens the picker with the other two unsold IMEIs. Cancel = nothing.
    await _tap(t, _plus('k_ph1'));
    expect(find.text('Select IMEI / Serial'), findsOneWidget);
    expect(find.text(_ph2), findsOneWidget);
    expect(find.text(_ph3), findsOneWidget);
    expect(find.text(_ph1), findsNothing); // already on the bill
    await _tap(t, find.text('Cancel (വേണ്ട)'));
    expect(find.text('Redmi Note 13 5G'), findsOneWidget);

    // Pick one -> a second IMEI line, qty shown 1 per IMEI.
    await _tap(t, _plus('k_ph1'));
    await _tap(t, find.text(_ph2));
    expect(find.text('Redmi Note 13 5G'), findsNWidgets(2));
    expect(find.text('IMEI ••••5672'), findsOneWidget);
    expect(find.text('₹33,998'), findsWidgets);

    // − asks which IMEI comes off (never picked silently).
    await _tap(t, _minus('k_ph2'));
    expect(find.text('Which IMEI to remove?'), findsOneWidget);
    await _tap(t, find.text(_ph1));
    expect(find.text('Redmi Note 13 5G'), findsOneWidget);
    expect(find.text('IMEI ••••5671'), findsNothing);
    expect(find.text('IMEI ••••5672'), findsOneWidget);

    // Last unit: confirm first; "No" keeps it.
    await _tap(t, _minus('k_ph2'));
    expect(find.textContaining('Remove the last unit?'), findsOneWidget);
    await _tap(t, find.text('വേണ്ട'));
    expect(find.text('Redmi Note 13 5G'), findsOneWidget);
    await _tap(t, _minus('k_ph2'));
    await _tap(t, find.widgetWithText(FilledButton, 'Remove (മാറ്റുക)'));
    expect(find.text('Redmi Note 13 5G'), findsNothing);
    // Item records are never touched by the bill screen.
    expect(Hive.box(boxItems).get('k_ph1')['stock'], 1);
    expect(Hive.box(boxItems).get('k_ph2')['stock'], 1);
    expect(t.takeException(), isNull);
  });

  testWidgets('Photostat-style item (code in IMEI box): qty goes to 10+',
      (t) async {
    await _open(t);
    await _scan(t, 'PS001');
    for (var i = 0; i < 9; i++) {
      await _tap(t, _plus('k_photo'));
    }
    expect(_qty(t, 'k_photo'), '10');
    expect(find.text('₹50'), findsWidgets); // 10 × ₹5
    await _scan(t, 'PS001'); // the same item again adds one more
    expect(_qty(t, 'k_photo'), '11');
    expect(find.textContaining('already in the bill'), findsNothing);
    expect(find.textContaining('IMEI ••••'), findsNothing); // not an IMEI
    expect(_enabled(t, _plus('k_photo')), isTrue);
    expect(t.takeException(), isNull);
  });

  // Writes to Hive: keep last.
  testWidgets('saved bill = screen; stock taken once; no double save',
      (t) async {
    await _open(t);
    final before = Hive.box(boxSales).length;
    await _scan(t, 'TF200601');
    await _tap(t, _plus('k_glass'));
    await _tap(t, _plus('k_glass')); // qty 3 = ₹450
    final complete = find.textContaining('COMPLETE PAYMENT');
    await t.tap(complete);
    await t.tap(complete, warnIfMissed: false); // a fast second tap
    for (var i = 0;
        i < 6 &&
            find.textContaining('ബില്ലിംഗ് പൂർത്തിയായി!').evaluate().isEmpty;
        i++) {
      await posSettleIO(t);
    }
    await posCloseDoneDialog(t);
    expect(Hive.box(boxSales).length, before + 1); // one bill only
    final b = posLastSale();
    final lines = (b['items'] as List).cast<Map>();
    expect(lines.length, 1);
    expect(lines.first['qty'], 3);
    expect(b['total'], 450.0);
    expect(Hive.box(boxItems).get('k_glass')['stock'], 7); // 10 - 3, once
    await posSettleIO(t);
  });
}
