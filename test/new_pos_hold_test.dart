// New POS (Step 3h): hold / resume, recent bills, shortcuts help.
// Temporary Hive, no Firestore. Holding must never touch stock or sales.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/pos/new_pos/pos_hold_logic.dart';

import 'new_pos_test_utils.dart';

Map<String, dynamic> _held(List<Map<String, dynamic>> lines,
        {String discount = ''}) =>
    {
      'id': 'H1',
      'heldAt': '2026-11-19T10:00:00Z',
      'discount': discount,
      'lines': lines,
    };

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

void main() {
  group('rules', () {
    test('draft keeps ids, qty, price, IMEI, customer, discount – no cost', () {
      final d = posHeldDraft(
        cart: [
          {
            'key': 'k1',
            'itemId': 'i1',
            'name': 'Glass',
            'qty': 2,
            'price': 150.0,
            'cost': 40.0,
            'imei': ''
          }
        ],
        customerPhone: ' 9847012321 ',
        customerName: 'Unais',
        partyId: 'c1',
        discount: '20',
        by: 'Staff',
        now: DateTime.utc(2026, 11, 19, 10),
      );
      expect(d.toString(), isNot(contains('cost')));
      expect(d['customerPhone'], '9847012321');
      expect((d['lines'] as List).single, {
        'itemId': 'i1',
        'key': 'k1',
        'name': 'Glass',
        'qty': 2,
        'price': 150.0,
        'imei': ''
      });
      expect(posHeldTotal(d), 280);
      expect(posHeldCount(d), 2);
    });

    test('age', () {
      final now = DateTime.utc(2026, 11, 19, 12);
      expect(posHeldAge('2026-11-19T11:59:40Z', now), 'just now');
      expect(posHeldAge('2026-11-19T11:48:00Z', now), '12 min');
      expect(posHeldAge('2026-11-19T09:00:00Z', now), '3 h');
      expect(posHeldAge('2026-11-17T12:00:00Z', now), '2 days');
    });

    test('resume re-checks stock, IMEI and price', () {
      final items = {
        'ok': {'stock': 10, 'sellingPrice': 150.0},
        'few': {'stock': 1, 'sellingPrice': 100.0},
        'none': {'stock': 0, 'sellingPrice': 50.0},
        'phone': {'stock': 0, 'sellingPrice': 9999.0},
        'pricey': {'stock': 5, 'sellingPrice': 120.0},
      };
      final plan = posPlanResume(
        _held([
          {'itemId': 'ok', 'name': 'Glass', 'qty': 2, 'price': 150.0},
          {'itemId': 'few', 'name': 'Cable', 'qty': 3, 'price': 100.0},
          {'itemId': 'none', 'name': 'OTG', 'qty': 1, 'price': 50.0},
          {
            'itemId': 'phone',
            'name': 'Redmi',
            'qty': 1,
            'price': 9999.0,
            'imei': '356789012345678'
          },
          {'itemId': 'gone', 'name': 'Old', 'qty': 1, 'price': 10.0},
          {'itemId': 'pricey', 'name': 'Case', 'qty': 1, 'price': 100.0},
        ]),
        find: (l) {
          final it = items[l['itemId']];
          return it == null ? null : (key: l['itemId'], item: it);
        },
      );
      expect([
        for (final l in plan.lines) (l.key, l.qty, l.price)
      ], [
        ('ok', 2, 150.0),
        ('few', 1, 100.0), // capped at stock
        ('pricey', 1, 100.0), // held price kept
      ]);
      final w = plan.warnings.join('\n');
      expect(w, contains('Cable: only 1 in stock now (was 3)'));
      expect(w, contains('OTG: out of stock now'));
      expect(w, contains('Redmi: this IMEI is already sold'));
      expect(w, contains('Old: no longer in the item list'));
      expect(w, contains('Case: price is now ₹120 (held ₹100)'));
      expect(plan.warnings.length, 5);
    });
  });

  setUpAll(() async {
    await posInitHive();
    await posSeed();
    await Hive.box(boxSettings).put('pos_new_ui', 'true');
    await Hive.box(boxSettings).delete(kPosHeldSetting);
    await Hive.box(boxSales).add({
      'invoice': 'INV-77',
      'saleDate': DateTime.now().toUtc().toIso8601String(),
      'customerName': 'Walk-in Customer',
      'customerPhone': '',
      'items': [
        {'name': 'weva screen gurd', 'qty': 1, 'price': 150.0}
      ],
      'total': 150.0,
      'cash': 150.0,
      'upi': 0.0,
      'due': 0.0,
      'status': 'SOLD',
    });
  });

  testWidgets('F6 on an empty bill only explains', (t) async {
    await _open(t);
    await t.sendKeyEvent(LogicalKeyboardKey.f6);
    await posSettle(t);
    expect(find.textContaining('Nothing to hold'), findsOneWidget);
  });

  testWidgets('Ctrl+R recent bills (read-only) and F1 help', (t) async {
    await _open(t);
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyR);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await posSettle(t);
    expect(find.text('Recent bills (സമീപകാല ബില്ലുകൾ)'), findsOneWidget);
    expect(find.text('INV-77'), findsOneWidget);
    expect(find.textContaining('PAID'), findsOneWidget);
    expect(find.text('Thermal (തെർമൽ)'), findsOneWidget);
    expect(find.byType(TextField), findsWidgets); // POS fields behind only
    await t.tap(find.byTooltip('Close (അടയ്ക്കുക)'));
    await posSettle(t);

    await t.sendKeyEvent(LogicalKeyboardKey.f1);
    await posSettle(t);
    expect(find.text('Keyboard shortcuts (കീബോർഡ്)'), findsOneWidget);
    expect(find.text('Hold bill (ഹോൾഡ്)'), findsOneWidget);
    await t.tap(find.text('OK'));
    await posSettle(t);
  });

  // Saving tests run as ONE test (a Hive write inside one widget test can
  // stay pending into the next one – test-only effect).
  testWidgets('hold -> resume; stock changed -> warning; max 10', (t) async {
    await _open(t);
    await _scan(t, 'TF200601');
    await _scan(t, 'TF200601');
    await posType(t, 'Discount ₹ (കിഴിവ്)', '20');
    await t.sendKeyEvent(LogicalKeyboardKey.f6);
    await posSettleIO(t);

    // The counter is empty; nothing was sold, stock untouched.
    expect(find.text('₹150 each'), findsNothing);
    expect(Hive.box(boxSales).length, 1); // only the seeded bill
    expect((Hive.box(boxItems).get('k_glass') as Map)['stock'], 10);
    final held = posHeldFrom(Hive.box(boxSettings).get(kPosHeldSetting));
    expect(held.length, 1);
    expect((held.single['lines'] as List).single['qty'], 2);
    expect(held.single['discount'], '20');

    // F7 -> Resume: same lines, qty and discount come back.
    await t.sendKeyEvent(LogicalKeyboardKey.f7);
    await posSettle(t);
    expect(find.text('Walk-in (വാക്ക്-ഇൻ)'), findsOneWidget);
    expect(find.textContaining('2 items'), findsOneWidget);
    await t.tap(find.text('Resume (തുടരുക)'));
    await posSettleIO(t);
    expect(find.text('₹150 each'), findsOneWidget);
    expect(find.text('₹280'), findsWidgets); // 2 x 150 - 20
    expect(posHeldFrom(Hive.box(boxSettings).get(kPosHeldSetting)), isEmpty);

    // Hold again, then stock drops to 1 before resuming.
    await t.sendKeyEvent(LogicalKeyboardKey.f6);
    await posSettleIO(t);
    await t.runAsync(() async {
      final it =
          Map<String, dynamic>.from(Hive.box(boxItems).get('k_glass') as Map);
      it['stock'] = 1;
      await Hive.box(boxItems).put('k_glass', it);
    });
    await t.sendKeyEvent(LogicalKeyboardKey.f7);
    await posSettle(t);
    await t.tap(find.text('Resume (തുടരുക)'));
    await posSettle(t);
    expect(find.textContaining('only 1 in stock now (was 2)'), findsOneWidget);
    await t.tap(find.text('Resume anyway (തുടരുക)'));
    await posSettleIO(t);
    expect(find.text('₹150 each'), findsOneWidget);
    expect(find.text('₹130'), findsWidgets); // 1 x 150 - 20

    // Max 10 held bills.
    await t.runAsync(() => Hive.box(boxSettings).put(kPosHeldSetting, [
          for (var i = 0; i < kPosMaxHeld; i++)
            _held([
              {'itemId': 'item_glass', 'name': 'x', 'qty': 1, 'price': 1.0}
            ])
              ..['id'] = 'H$i'
        ]));
    await t.sendKeyEvent(LogicalKeyboardKey.f6);
    await posSettle(t);
    expect(find.textContaining('Max 10 held bills'), findsOneWidget);
    await posSettleIO(t);
  });
}
