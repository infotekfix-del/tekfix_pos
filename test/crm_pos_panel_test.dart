// Widget test for the POS customer panel (Phase 2): typing a known number
// shows the customer card and locks the name; an unknown number shows the
// new-customer field; an empty number is a walk-in.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/crm/customer_crm.dart';
import 'package:tekfix_erp_pos/crm/pos_customer_panel.dart';

void main() {
  late Directory tmp;
  late CustomerCrm crm;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('tekfix_crm_panel_');
    Hive.init(tmp.path);
  });

  tearDownAll(() async {
    await Hive.close();
  });

  testWidgets('known number -> card + locked name; unknown -> new customer',
      (tester) async {
    await tester.runAsync(() async {
      final parties = await Hive.openBox('p_panel');
      final sales = await Hive.openBox('s_panel');
      crm = await CustomerCrm.open(parties: parties, sales: sales);
      final a = await crm.createCustomer(name: 'Anu', phone: '9847012345');
      await sales.add({
        '_id': CustomerCrm.newId(),
        'invoice': 'INV-1',
        'saleDate': '2026-11-10T10:00:00Z',
        'total': 1250.0,
        'customerId': a.id,
        'items': [
          {'name': 'Tempered Glass', 'qty': 1}
        ],
      });
      await crm.idle;
    });

    final name = TextEditingController();
    final phone = TextEditingController();
    final ctrl = PosCustomerController(name: name, phone: phone);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PosCustomerPanel(controller: ctrl, onFullHistory: (_) {}),
        ),
      ),
    ));

    await tester.enterText(find.byType(TextField).first, '+91 98470 12345');
    await tester.pump(const Duration(milliseconds: 300)); // debounce
    await tester.pump();
    expect(ctrl.found?.name, 'Anu');
    expect(name.text, 'Anu');
    expect(ctrl.nameLocked, isTrue);
    expect(find.text('Tempered Glass'), findsOneWidget);
    expect(find.textContaining('Full history'), findsOneWidget);

    await tester.tap(find.text('Edit'));
    await tester.pump();
    expect(ctrl.nameLocked, isFalse);

    await tester.enterText(find.byType(TextField).first, '9000000001');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(ctrl.found, isNull);
    expect(ctrl.isNewCustomer, isTrue);
    expect(name.text, isEmpty); // auto-filled name cleared
    expect(find.textContaining('New customer name'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '');
    await tester.pump(const Duration(milliseconds: 300));
    expect(ctrl.willHaveCustomer, isFalse); // walk-in
    ctrl.dispose();
  });
}
