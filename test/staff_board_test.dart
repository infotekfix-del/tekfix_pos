// Staff board: one-tap today marks, forgotten-days list, phone / desktop
// layout. Temporary Hive only.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/staff/staff_board.dart';
import 'package:tekfix_erp_pos/staff/staff_payroll.dart';

String day(int back) => payrollDayKey(DateTime.now().subtract(Duration(days: back)));

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 20; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    final dir = await Directory.systemTemp.createTemp('tekfix_staff_board_');
    Hive.init(dir.path);
    for (final b in allBoxes) {
      if (!Hive.isBoxOpen(b)) await Hive.openBox(b);
    }
  });

  Future<void> seed(WidgetTester t) => t.runAsync(() async {
    await Db.staff.clear();
    await Db.staff.put('s1', {
      'name': 'SHAHAL',
      'role': 'SERVICE',
      'phone': '9946268502',
      'dailyRate': 350.0,
      // marked 3 days ago, so yesterday and 2 days ago are "forgotten"
      'attendance': {day(3): 'Present'},
      'payments': <dynamic>[],
    });
  });

  Future<void> open(WidgetTester t, Size size) async {
    await seed(t);
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StaffBoard(onPay: (_, __) {}, onEdit: (_, __) {}, onDelete: (_, __) {}),
      ),
    ));
    await t.pump();
  }

  // One test on purpose: Hive writes inside a widget test can block the next
  // test's I/O in this project.
  testWidgets('forgotten days list, one-tap today, desktop and phone layout', (t) async {
    await open(t, const Size(1366, 900));
    expect(t.takeException(), isNull);
    expect(find.byKey(const ValueKey('staff-missing-panel')), findsOneWidget);
    final key = ValueKey('missing-s1-${day(1)}-Present');
    expect(find.byKey(key), findsOneWidget);
    await t.tap(find.byKey(key));
    await settle(t);
    expect((Db.staff.get('s1') as Map)['attendance'][day(1)], 'Present');
    expect(find.byKey(key), findsNothing);

    await t.tap(find.byKey(const ValueKey('today-s1-Half Day')));
    await settle(t);
    expect((Db.staff.get('s1') as Map)['attendance'][day(0)], 'Half Day');
    await t.tap(find.byKey(const ValueKey('today-s1-Half Day')));
    await settle(t);
    expect((Db.staff.get('s1') as Map)['attendance'][day(0)], isNull);

    for (final size in const [Size(1000, 900), Size(390, 900)]) {
      t.view.physicalSize = size;
      await t.pump();
      expect(find.byKey(const ValueKey('staff-card-s1')), findsOneWidget);
      expect(t.takeException(), isNull, reason: '$size');
    }
  });
}
