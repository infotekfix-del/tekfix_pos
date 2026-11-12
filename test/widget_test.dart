import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/auth/auth_controller.dart';

void main() {
  setUpAll(() async {
    final tempDir = await Directory.systemTemp.createTemp();
    Hive.init(tempDir.path);

    for (final box in allBoxes) {
      await Hive.openBox(box);
    }
    await Db.settings.put('staff_logged_in', 'false');
    await AuthController.instance.init();
  });

  tearDownAll(() async {
    await Hive.close();
  });

  testWidgets('TekFix POS app starts', (WidgetTester tester) async {
    await tester.pumpWidget(const TekFixApp());
    await tester.pump();

    expect(find.byType(TekFixApp), findsOneWidget);
  });
}
