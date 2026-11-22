// New POS (Step 3c): creating a customer from the POS (bad number blocked,
// valid number saved through the Customer CRM). Real CRM on a temporary
// Hive, no Firestore. Own file: CRM writes queued in one widget test never
// finish in the next one.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';

import 'new_pos_test_utils.dart';

Future<void> _open(WidgetTester t) async {
  await posSize(t, const Size(1366, 900));
  await t.pumpWidget(posApp());
  await posSettle(t);
}

void main() {
  setUpAll(posSeedCustomers);

  testWidgets('new customer: bad number blocked; valid number saved',
      (t) async {
    await _open(t);
    await t.tap(find.byTooltip('New customer (പുതിയ കസ്റ്റമർ)'));
    await posSettle(t);
    await posTypeKey(t, 'pos-new-customer-phone', '12345');
    await posTypeKey(t, 'pos-new-customer-name', 'Rahul');
    await t.tap(find.text('Save customer'));
    await posSettle(t);
    expect(find.textContaining('10'), findsWidgets); // validation message
    await posTypeKey(t, 'pos-new-customer-phone', '9746000222');
    await t.tap(find.text('Save customer'));
    // The save waits on real disk writes (still busy after the credit bill).
    for (var i = 0;
        i < 8 && find.text('No due (ബാക്കിയില്ല)').evaluate().isEmpty;
        i++) {
      await posSettleIO(t);
    }
    expect(find.text('Rahul'), findsOneWidget);
    expect(find.text('No due (ബാക്കിയില്ല)'), findsOneWidget);
    expect(Hive.box(boxParties).length, 3);
    final p = Hive.box(boxParties)
        .values
        .cast<Map>()
        .firstWhere((m) => m['phone'] == '9746000222');
    expect(p['name'], 'Rahul');
    expect(p['type'], 'Customer');
  });
}
