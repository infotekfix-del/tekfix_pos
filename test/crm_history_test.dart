// Phase 3: customer history logic + screen smoke test.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/crm/customer_crm.dart';
import 'package:tekfix_erp_pos/crm/customer_history.dart';
import 'package:tekfix_erp_pos/crm/customer_history_screen.dart';

MapEntry<dynamic, Map<String, dynamic>> bill(int k, String inv, String when,
        double total,
        {List<Map<String, dynamic>> items = const [],
        double? cash,
        double? upi,
        double due = 0,
        bool returned = false}) =>
    MapEntry(k, {
      'invoice': inv,
      'saleDate': when,
      'total': total,
      if (cash != null) 'cash': cash,
      if (upi != null) 'upi': upi,
      'due': due,
      'items': items,
      if (returned) 'status': 'RETURNED',
    });

void main() {
  final sales = [
    bill(1, 'INV-1', '2026-11-01T04:30:00Z', 500,
        items: [
          {'name': 'Tempered Glass', 'qty': 2, 'warranty': 'No Warranty'}
        ],
        cash: 500),
    bill(2, 'INV-2', '2026-11-01T09:30:00Z', 15000,
        items: [
          {'name': 'Redmi Note 13', 'qty': 1, 'imei': '86', 'warranty': '1 Year'}
        ],
        cash: 5000,
        upi: 10000),
    bill(3, 'INV-3', '2026-11-10T06:00:00Z', 300,
        items: [
          {'name': 'ചാർജർ Type-C', 'qty': 1, 'warranty': '6 Months'}
        ],
        cash: 0,
        due: 300),
    bill(4, 'INV-4', '2026-11-12T06:00:00Z', 200,
        items: [
          {'name': 'Back Cover', 'qty': 1, 'warranty': '3 Months'}
        ],
        cash: 200,
        returned: true),
  ];

  group('groupHistory', () {
    test('newest day first, newest bill first, grouped by day', () {
      final days = groupHistory(sales);
      expect(days.map((d) => d.day), [
        DateTime(2026, 11, 12),
        DateTime(2026, 11, 10),
        DateTime(2026, 11, 1),
      ]);
      expect(days.last.sales.map((e) => e.value['invoice']), ['INV-2', 'INV-1']);
      expect(days.last.totalPaise, 1550000);
      expect(days.first.totalPaise, 0); // returned bill not counted
    });

    test('item search is case-insensitive and Malayalam-safe', () {
      expect(groupHistory(sales, itemQuery: 'redmi').single.sales.single.key, 2);
      expect(groupHistory(sales, itemQuery: 'ചാർജർ').single.sales.single.key, 3);
      expect(groupHistory(sales, itemQuery: 'TYPE-c').single.sales.single.key, 3);
      expect(groupHistory(sales, itemQuery: 'iphone'), isEmpty);
    });

    test('date range is inclusive of both days', () {
      final r = groupHistory(sales,
          from: DateTime(2026, 11, 1), to: DateTime(2026, 11, 10));
      expect(r.expand((d) => d.sales).map((e) => e.key), [3, 2, 1]);
      final none = groupHistory(sales,
          from: DateTime(2026, 11, 2), to: DateTime(2026, 11, 9));
      expect(none, isEmpty);
    });
  });

  test('paymentMode', () {
    expect(paymentMode(sales[0].value), 'Cash');
    expect(paymentMode(sales[1].value), 'Cash + UPI');
    expect(paymentMode(sales[2].value), 'Credit');
    expect(paymentMode({'total': 100}), 'Cash'); // legacy bill without split
  });

  test('parseWarranty + warrantyLines', () {
    expect(parseWarranty('No Warranty'), isNull);
    expect(parseWarranty('1 Year'), const Duration(days: 365));
    expect(parseWarranty('90 Days'), const Duration(days: 90));
    final w = warrantyLines(sales);
    expect(w.map((e) => e.item), ['ചാർജർ Type-C', 'Redmi Note 13']);
    expect(w.last.imei, '86');
    expect(w.last.activeOn(DateTime(2027, 10, 1)), isTrue);
    expect(w.last.activeOn(DateTime(2028, 1, 1)), isFalse);
  });

  test('servicesForPhone matches normalised phone or customerId', () {
    final jobs = [
      const MapEntry(1, {'jobId': 'A', 'phone': '+91 98470 12345', 'createdAt': '2026-11-01'}),
      const MapEntry(2, {'jobId': 'B', 'phone': '9000000001', 'createdAt': '2026-11-02'}),
      const MapEntry(3, {'jobId': 'C', 'customerId': 'cid', 'createdAt': '2026-11-03'}),
    ];
    final r = servicesForPhone(jobs, '9847012345', customerId: 'cid');
    expect(r.map((e) => e.value['jobId']), ['C', 'A']);
    expect(servicesForPhone(jobs, ''), isEmpty);
  });

  testWidgets('history screen shows header, timeline, search and services',
      (tester) async {
    late String id;
    await tester.runAsync(() async {
      final tmp = Directory.systemTemp.createTempSync('tekfix_crm_hist_');
      Hive.init(tmp.path);
      final parties = await Hive.openBox('tek_parties');
      final salesBox = await Hive.openBox('tek_sales');
      final services = await Hive.openBox('tek_service_jobs');
      await Hive.openBox('tek_settings');
      final crm = await CustomerCrm.open(parties: parties, sales: salesBox);
      final c = await crm.createCustomer(name: 'Anu', phone: '9847012345');
      id = c.id;
      for (final s in sales) {
        await salesBox.add({...s.value, 'customerId': id});
      }
      await services.add({
        'jobId': 'SRV-1',
        'phone': '98470 12345',
        'status': 'Received',
        'brandModel': 'Vivo Y20',
        'createdAt': '2026-11-05T10:00:00Z',
      });
      await crm.idle;
    });

    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
        MaterialApp(home: CustomerHistoryScreen(customerId: id)));
    await tester.pump();

    expect(find.text('Anu'), findsWidgets);
    expect(find.text('9847012345'), findsOneWidget);
    expect(find.text('3'), findsOneWidget); // bill count (returned excluded)
    expect(find.text('INV-3'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'redmi');
    await tester.pump();
    expect(find.text('INV-2'), findsOneWidget);
    expect(find.text('INV-3'), findsNothing);

    await tester.tap(find.textContaining('സർവീസ് / വാറന്റി'));
    await tester.pumpAndSettle();
    expect(find.text('SRV-1'), findsOneWidget);
    expect(find.text('Redmi Note 13'), findsOneWidget);
  });
}
