// New POS (Step 3e): payment modes, change, UPI QR + confirmation, credit
// rule, split. Temporary Hive, no Firestore. Each saved bill is checked
// against what the existing checkout stores (cash / upi / due).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/pos/new_pos/pos_payment_logic.dart';

import 'new_pos_test_utils.dart';

Future<void> _openWithGlass(WidgetTester t) async {
  await posSize(t, const Size(1366, 900));
  await t.pumpWidget(const SizedBox());
  await t.pumpWidget(posApp());
  await posSettle(t);
  await t.enterText(find.byType(TextField).first, 'TF200601');
  await t.testTextInput.receiveAction(TextInputAction.search);
  await posSettle(t);
}

int _sales() => Hive.box(boxSales).length;

Future<void> _done(WidgetTester t) async {
  for (var i = 0;
      i < 6 && find.textContaining('ബില്ലിംഗ് പൂർത്തിയായി!').evaluate().isEmpty;
      i++) {
    await posSettleIO(t);
  }
}

void main() {
  group('rules', () {
    test('mode -> stored amounts (existing cash / upi fields)', () {
      expect(posPaymentFor(PosPayMode.cash, 150), (cash: 150.0, upi: 0.0));
      expect(posPaymentFor(PosPayMode.upi, 150), (cash: 0.0, upi: 150.0));
      expect(posPaymentFor(PosPayMode.credit, 150), (cash: 0.0, upi: 0.0));
      expect(posPaymentFor(PosPayMode.split, 150), isNull);
    });
    test('cash received and change', () {
      expect(posTender(150, ''), (change: 0.0, error: null)); // exact
      expect(posTender(150, '500').change, 350);
      expect(posTender(150, '150').change, 0);
      expect(posTender(149.5, '200').change, 50.5);
      expect(posTender(150, '100').error, contains('₹50 less'));
      expect(posTender(150, 'abc').error, isNotNull);
    });
    test('UPI link and UPI ID check', () {
      expect(
          posUpiUri(
              vpa: '7034093101@okbizaxis',
              payee: 'TEKFIX DIGITAL',
              amount: 1299,
              note: 'TEKFIX DIGITAL bill'),
          'upi://pay?pa=7034093101@okbizaxis&pn=TEKFIX%20DIGITAL'
          '&am=1299.00&cu=INR&tn=TEKFIX%20DIGITAL%20bill');
      expect(posValidVpa('shop@okaxis'), isTrue);
      expect(posValidVpa('7034093101@okbizaxis'), isTrue);
      expect(posValidVpa('Q085585286@ybl'), isTrue); // shop UPI
      expect(posValidVpa('shop'), isFalse);
      expect(posValidVpa('a b@ok'), isFalse);
    });
  });

  setUpAll(() async {
    await posInitHive();
    await posSeed();
    await Hive.box(boxSettings).put('pos_new_ui', 'true');
  });

  testWidgets('cash received less than the bill is refused', (t) async {
    await _openWithGlass(t);
    expect(find.text('CASH'), findsOneWidget); // default mode
    await posType(t, 'Received ₹ (ലഭിച്ചത്)', '100');
    expect(find.textContaining('₹50 less than the bill'), findsOneWidget);
    await t.tap(find.textContaining('COMPLETE PAYMENT'));
    await posSettle(t);
    expect(_sales(), 0);
  });

  testWidgets('credit without a customer is refused', (t) async {
    await _openWithGlass(t);
    await t.tap(find.text('CREDIT'));
    await posSettle(t);
    expect(find.text('Credit needs a customer (ക്രെഡിറ്റിന് കസ്റ്റമർ വേണം)'),
        findsOneWidget);
    await t.tap(find.textContaining('COMPLETE PAYMENT'));
    await posSettle(t);
    expect(_sales(), 0);
  });

  testWidgets('UPI QR shows the amount; "Not yet" saves nothing', (t) async {
    await _openWithGlass(t);
    await t.tap(find.text('UPI / CARD'));
    await posSettle(t);
    expect(
        find.textContaining('Not confirmed (ഉറപ്പാക്കിയില്ല)'), findsOneWidget);
    await t.tap(find.text('Show UPI QR (QR കാണിക്കുക)'));
    await posSettle(t);
    expect(
        find.byWidgetPredicate((w) => w.runtimeType.toString() == 'QrImageView',
            description: 'UPI QR'),
        findsOneWidget);
    expect(find.textContaining('Q085585286@ybl'), findsOneWidget);
    await t.tap(find.text('Not yet (ഇല്ല)'));
    await posSettle(t);
    expect(_sales(), 0);
    // Complete without the QR still asks the cashier first.
    await t.tap(find.textContaining('COMPLETE PAYMENT'));
    await posSettle(t);
    expect(find.textContaining('Received ₹150 by UPI / Card?'), findsOneWidget);
    await t.tap(find.text('വേണ്ട')); // confirm(): No
    await posSettle(t);
    expect(_sales(), 0);
  });

  // Saving tests run as ONE test: a Hive write started inside one widget
  // test can stay pending into the next test (test-only effect).
  testWidgets('saved bills: cash with change, UPI via QR, split', (t) async {
    // 1) Cash: ₹500 for ₹150 -> change ₹350; the bill stores cash 150.

    await _openWithGlass(t);
    await t.tap(find.widgetWithText(OutlinedButton, '₹500'));
    await posSettle(t);
    expect(find.text('Give change (ബാക്കി കൊടുക്കുക)'), findsOneWidget);
    expect(find.text('₹350'), findsOneWidget);
    await t.tap(find.textContaining('COMPLETE PAYMENT'));
    await _done(t);
    expect(find.textContaining('Give change (ബാക്കി കൊടുക്കുക): ₹350'),
        findsOneWidget);
    await posCloseDoneDialog(t);
    final b = posLastSale();
    expect(
        [b['cash'], b['upi'], b['due'], b['total']], [150.0, 0.0, 0.0, 150.0]);

    // 2) UPI via QR + "UPI Received" -> upi 150.

    await _openWithGlass(t);
    await t.tap(find.text('UPI / CARD'));
    await posSettle(t);
    await t.tap(find.text('Show UPI QR (QR കാണിക്കുക)'));
    await posSettle(t);
    await t.tap(find.text('UPI Received (ലഭിച്ചു)'));
    await _done(t);
    await posCloseDoneDialog(t);
    final b2 = posLastSale();
    expect([b2['cash'], b2['upi'], b2['due']], [0.0, 150.0, 0.0]);
    expect(find.text('CASH'), findsOneWidget); // next bill starts on Cash

    // 3) Split: cash 100 + UPI 50 = fully paid.

    await _openWithGlass(t);
    await t.tap(find.text('SPLIT'));
    await posSettle(t);
    await posType(t, 'Cash ₹', '100');
    await posType(t, 'UPI / Card ₹', '50');
    expect(find.text('Fully paid (മുഴുവൻ അടച്ചു)'), findsOneWidget);
    await t.tap(find.textContaining('COMPLETE PAYMENT'));
    await _done(t);
    await posCloseDoneDialog(t);
    final b3 = posLastSale();
    expect([b3['cash'], b3['upi'], b3['due']], [100.0, 50.0, 0.0]);
    await posSettleIO(t);
  });
}
