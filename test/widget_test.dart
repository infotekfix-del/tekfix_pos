
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:tekfix_erp_pos/main.dart';

void main() {
  setUpAll(() async {
    Hive.init('./test_hive_data');

    for (final box in allBoxes) {
      await Hive.openBox(box);
    }
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
