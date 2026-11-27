// New POS (Step 3b): Top Selling, Favorites, category chips, View All.
// Temporary Hive only, sync engine not started (no Firestore).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';

import 'new_pos_test_utils.dart';

Future<void> _seedCatalog() async {
  await posSeed();
  await Hive.box(boxSettings).put('pos_new_ui', 'true');
  await Hive.box(boxSettings).delete('pos_favorites');
  await Hive.box(boxItems).put('k_tws', {
    '_id': 'item_tws',
    'name': 'Boat TWS Airdopes',
    'barcode': 'TF300100',
    'stock': 5,
    'minStock': 2,
    'costPrice': 700.0,
    'sellingPrice': 1299.0,
    'category': 'TWS',
  });
  final recent = DateTime.now()
      .toUtc()
      .subtract(const Duration(days: 2))
      .toIso8601String();
  final old = DateTime.now()
      .toUtc()
      .subtract(const Duration(days: 60))
      .toIso8601String();
  await Hive.box(boxSales).add({
    'invoice': 'T-1',
    'saleDate': recent,
    'status': 'SOLD',
    'items': [
      {'key': 'k_tws', 'itemId': 'item_tws', 'name': 'Boat TWS', 'qty': 3}
    ],
  });
  await Hive.box(boxSales).add({
    'invoice': 'T-0',
    'saleDate': old, // outside the 30-day window
    'status': 'SOLD',
    'items': [
      {'key': 'k_glass', 'itemId': 'item_glass', 'qty': 40}
    ],
  });
}

Future<void> _open(WidgetTester t, Size size) async {
  await posSize(t, size);
  await t.pumpWidget(posApp());
  await posSettle(t);
  await t.pump(const Duration(milliseconds: 400)); // Top Selling (debounced)
  await posSettle(t);
}

void main() {
  setUpAll(posInitHive);
  setUp(_seedCatalog);

  testWidgets('landing: Top Selling from the last 30 days only', (t) async {
    await _open(t, const Size(1366, 768));
    expect(find.text('Top Selling'), findsOneWidget);
    expect(find.text('കൂടുതൽ വിറ്റത്'), findsOneWidget); // stacked
    expect(find.text('Boat TWS Airdopes'), findsOneWidget);
    // Sold 60 days ago / never sold: not on the landing view.
    expect(find.text('weva screen gurd'), findsNothing);
    expect(find.text('Old charger'), findsNothing);
    expect(find.text('Bluetooth Devices'), findsOneWidget); // chip
    expect(find.text('ബ്ലൂടൂത്ത്'), findsOneWidget);
    // Cost is never shown to staff (and only with Alt for the owner).
    expect(find.textContaining('Cost'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('tapping a card adds it to the bill', (t) async {
    await _open(t, const Size(1366, 768));
    await t.tap(find.text('Boat TWS Airdopes'));
    await posSettle(t);
    expect(find.text('In bill 1'), findsOneWidget);
    expect(find.text('₹1,299 each'), findsOneWidget); // the bill line
  });

  testWidgets('category chip shows that category', (t) async {
    await _open(t, const Size(1366, 768));
    await t.tap(find.text('Accessories'));
    await posSettle(t);
    expect(find.text('weva screen gurd'), findsOneWidget);
    expect(find.text('Boat TWS Airdopes'), findsNothing);
    await t.tap(find.text('Other Products'));
    await posSettle(t);
    expect(find.text('Old charger'), findsOneWidget);
    expect(find.text('Out'), findsOneWidget); // stock as a word, not a number
  });

  testWidgets('View All: exact stock, in-stock filter, add', (t) async {
    await _open(t, const Size(1366, 768));
    await t.tap(find.textContaining('View All Items'));
    await posSettle(t);
    expect(find.text('All Items'), findsOneWidget);
    expect(find.text('ITEM'), findsOneWidget); // table header
    expect(find.text('STOCK'), findsOneWidget);
    expect(find.text('3 items'), findsOneWidget);
    expect(find.text('10'), findsOneWidget); // exact stock column
    expect(find.text('Old charger'), findsOneWidget);

    await t.tap(find.text('In stock only (സ്റ്റോക്ക് ഉള്ളത്)'));
    await posSettle(t);
    expect(find.text('Old charger'), findsNothing);
    expect(find.text('2 items'), findsOneWidget);

    await t.tap(find.widgetWithText(FilledButton, 'Add').first);
    await posSettle(t);
    expect(find.textContaining('Bill: 1 items'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('narrow window (1000 px) and phone: no overflow', (t) async {
    await _open(t, const Size(1000, 700));
    expect(find.text('Boat TWS Airdopes'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await _open(t, const Size(390, 800));
    expect(find.text('Boat TWS Airdopes'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('light app: POS, View All and side panels are all dark',
      (t) async {
    await posSize(t, const Size(1366, 768));
    await t.pumpWidget(posApp());
    await posSettle(t);
    Brightness b(Finder f) => Theme.of(t.element(f)).brightness;
    expect(b(find.text('Top Selling')), Brightness.dark);

    await t.tap(find.textContaining('View All Items'));
    await posSettle(t);
    expect(b(find.text('All Items')), Brightness.dark);
    expect(b(find.text('ITEM')), Brightness.dark);
    await t.pageBack();
    await posSettle(t);

    await t.tap(find.byTooltip('Held bills (ഹോൾഡ് ബില്ലുകൾ)  F7'));
    await posSettle(t);
    expect(b(find.text('Held bills (ഹോൾഡ് ബില്ലുകൾ)')), Brightness.dark);
    expect(t.takeException(), isNull);
  });

  // Keep last: a Hive write made from inside a widget test can leave the
  // box busy for the next test's setUp.
  testWidgets('star adds the item to Favorites (local setting)', (t) async {
    await _open(t, const Size(1366, 900));
    await t.tap(find.byTooltip('Add to favorites (പ്രിയപ്പെട്ടത്)').first);
    await posSettleIO(t);
    expect(find.text('Boat TWS Airdopes'), findsNWidgets(2)); // top + fav
    expect(Hive.box(boxSettings).get('pos_favorites'), ['item_tws']);
  });
}
