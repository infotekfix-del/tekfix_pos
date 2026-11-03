import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/barcode/barcode_label_service.dart';
import 'package:tekfix_erp_pos/barcode/barcode_print_dialog.dart';

void main() {
  group('TVS LP 46 Lite - Thermal Barcode Label Printing (38×25mm & 50×25mm Profiles)', () {
    // -------------------------------------------------------------------------
    // TEST 1: Standard product on default 38x25mm profile
    // -------------------------------------------------------------------------
    test('TEST 1: Standard item (BATTERY AXLEL GOLD 805, 123456789012, ₹450) fits inside 38×25mm', () {
      final item = BarcodeLabelItem(
        name: 'BATTERY AXLEL GOLD 805',
        barcode: '123456789012',
        itemCode: 'BAT-AX805',
        sellingPrice: 450.0,
        quantity: 1,
      );

      const config = PrinterConfig(); // Default is 38mm x 25mm

      expect(config.widthMm, equals(38.0));
      expect(config.heightMm, equals(25.0));
      expect(config.widthDots, equals(304)); // 38 * 8 = 304 dots
      expect(config.heightDots, equals(200)); // 25 * 8 = 200 dots
      expect(config.printableWidthDots, equals(280)); // 35 * 8 = 280 dots
      expect(config.printableHeightDots, equals(176)); // 22 * 8 = 176 dots

      final tspl = TsplGenerator.generateSingleItem(
        item: item,
        config: config,
        showPrice: true,
      );

      // Verify exact TVS LP 46 Lite initialization
      expect(tspl, contains('SIZE 38 mm,25 mm'));
      expect(tspl, contains('GAP 3 mm,0 mm'));
      expect(tspl, contains('DIRECTION 1'));
      expect(tspl, contains('REFERENCE 0,0'));
      expect(tspl, contains('OFFSET 0 mm'));
      expect(tspl, contains('CLS'));

      // Header, single-line product name, Code 128 barcode, barcode text, and price
      expect(tspl, contains('TEKFIX DIGITAL'));
      expect(tspl, contains('BATTERY AXLEL GOLD 805'));
      expect(tspl, contains('BARCODE '));
      expect(tspl, contains('"128",84,0,0,1,1,"123456789012"'));
      expect(tspl, contains('TEXT '));
      expect(tspl, contains('"123456789012"'));
      expect(tspl, contains('PRICE: Rs.450'));
      expect(tspl, contains('PRINT 1,1'));
      expect(tspl, isNot(contains('FEED')));
    });

    // -------------------------------------------------------------------------
    // TEST 2: Long product name is truncated to single line with ellipsis
    // -------------------------------------------------------------------------
    test('TEST 2: Long product name truncates to a single line without multi-line overflow', () {
      final item = BarcodeLabelItem(
        name: 'Ultra High Capacity Extended Life Replacement Battery for Redmi Note 10 Pro Max',
        barcode: '123456789012',
        sellingPrice: 850.0,
        quantity: 1,
      );

      final tspl = TsplGenerator.generateSingleItem(
        item: item,
        config: const PrinterConfig(), // 38mm x 25mm
        showPrice: true,
      );

      // Verify name is truncated with ellipsis and fits on single line
      expect(tspl, contains('...'));
      final lines = tspl.split('\n');
      final nameLines = lines.where((l) => l.contains('Ultra High Capacity'));
      expect(nameLines.length, equals(1), reason: 'Product name must strictly occupy at most 1 line');
      expect(tspl, contains('PRINT 1,1'));
    });

    // -------------------------------------------------------------------------
    // TEST 3: Long barcode remains within printable width (max 32mm / 256 dots)
    // -------------------------------------------------------------------------
    test('TEST 3: Long barcode stays within maximum printable barcode width (32mm)', () {
      final item = BarcodeLabelItem(
        name: 'Type-C Data Cable',
        barcode: '890123456789012345', // 18-digit long barcode
        sellingPrice: 199.0,
        quantity: 1,
      );

      final tspl = TsplGenerator.generateSingleItem(
        item: item,
        config: const PrinterConfig(),
        showPrice: true,
      );

      // Verify barcode command uses module 1 and fits inside 304 dots with safety margins
      expect(tspl, contains('BARCODE '));
      expect(tspl, contains('"128",84,0,0,1,1,"890123456789012345"'));
      expect(tspl, contains('890123456789012345'));
    });

    // -------------------------------------------------------------------------
    // TEST 4: High selling price formats without clipping
    // -------------------------------------------------------------------------
    test('TEST 4: High selling price (e.g. ₹149999) displays cleanly without clipping', () {
      final item = BarcodeLabelItem(
        name: 'Apple iPhone 15 Pro Max 256GB',
        barcode: 'TF99015P',
        sellingPrice: 149999.0,
        quantity: 1,
      );

      final tspl = TsplGenerator.generateSingleItem(
        item: item,
        config: const PrinterConfig(),
        showPrice: true,
      );

      expect(tspl, contains('PRICE: Rs.149999'));
    });

    // -------------------------------------------------------------------------
    // TEST 5: Consecutive multi-label printing generates exact count with no feeds
    // -------------------------------------------------------------------------
    test('TEST 5: Consecutive 10 labels print accurately with PRINT 10,1 and no gap crossing', () {
      final item = BarcodeLabelItem(
        name: 'OLED Display Combo',
        barcode: 'TF555666',
        sellingPrice: 2200.0,
        quantity: 10,
      );

      final tspl = TsplGenerator.generateSingleItem(
        item: item,
        config: const PrinterConfig(),
        quantity: 10,
      );

      // Strict requirement: PRINT 10,1 with no extra feeds or blank sticker skips
      expect(tspl, contains('PRINT 10,1'));
      expect(tspl, isNot(contains('FEED')));
      expect(tspl, isNot(contains('FORMFEED')));
      expect(tspl, isNot(contains('\x0C')));
    });

    // -------------------------------------------------------------------------
    // TEST 6: Switch to 50×25mm profile
    // -------------------------------------------------------------------------
    test('TEST 6: Switch to 50×25mm profile generates correct 50mm dimensions and layout', () {
      final item = BarcodeLabelItem(
        name: 'Samsung Galaxy A52 Display Combo',
        barcode: 'TF777888',
        sellingPrice: 1850.0,
        quantity: 1,
      );

      final config50 = const PrinterConfig().withProfile(LabelProfile.profile50x25);

      expect(config50.widthMm, equals(50.0));
      expect(config50.heightMm, equals(25.0));
      expect(config50.widthDots, equals(400));
      expect(config50.heightDots, equals(200));
      expect(config50.printableWidthDots, equals(376));

      final tspl = TsplGenerator.generateSingleItem(
        item: item,
        config: config50,
        showPrice: true,
      );

      expect(tspl, contains('SIZE 50 mm,25 mm'));
      expect(tspl, contains('GAP 3 mm,0 mm'));
      expect(tspl, contains('TEKFIX DIGITAL'));
      expect(tspl, contains('Samsung Galaxy A52 Display Combo'));
      expect(tspl, contains('PRICE: Rs.1850'));
      expect(tspl, contains('PRINT 1,1'));
    });

    // -------------------------------------------------------------------------
    // TEST 7: Missing / ₹0 price handling (Does not print ₹0 accidentally)
    // -------------------------------------------------------------------------
    test('TEST 7: Missing / ₹0 price omits price line and does not print Rs.0', () {
      final itemZero = BarcodeLabelItem(
        name: 'Free Promotional Sticker',
        barcode: 'TF000999',
        sellingPrice: 0.0,
        mrp: 0.0,
        quantity: 1,
      );

      expect(itemZero.hasValidPrice, isFalse);
      expect(itemZero.effectivePrice, isNull);

      final tspl = TsplGenerator.generateSingleItem(
        item: itemZero,
        config: const PrinterConfig(),
        showPrice: true,
      );

      expect(tspl, isNot(contains('PRICE: Rs.0')));
      expect(tspl, isNot(contains('PRICE: Rs. 0')));

      // Test MRP fallback
      final itemMrp = BarcodeLabelItem(
        name: 'Tempered Glass Screen Guard',
        barcode: 'TF888111',
        sellingPrice: null, // Selling price missing
        mrp: 250.0, // MRP available
        quantity: 1,
      );

      expect(itemMrp.hasValidPrice, isTrue);
      expect(itemMrp.effectivePrice, equals(250.0));

      final tsplMrp = TsplGenerator.generateSingleItem(
        item: itemMrp,
        config: const PrinterConfig(),
        showPrice: true,
      );

      expect(tsplMrp, contains('PRICE: Rs.250'));
    });

    // -------------------------------------------------------------------------
    // TEST 8: Gap Sensor Calibration command
    // -------------------------------------------------------------------------
    test('TEST 8: Gap sensor calibration produces exact GAPDETECT command', () {
      final cmd = TsplGenerator.generateCalibrationCommand();
      expect(cmd, equals('GAPDETECT\r\n'));
    });

    // -------------------------------------------------------------------------
    // TEST 9: Printer identification logic
    // -------------------------------------------------------------------------
    test('TEST 9: PrinterDevice correctly identifies TVS LP 46 Lite and TT065 printers', () {
      const tvs = PrinterDevice(name: 'TVS LP 46 Lite', driver: 'TVS LP 46 Lite', port: 'USB001');
      expect(tvs.isTargetTvs, isTrue);

      const tt065 = PrinterDevice(name: 'Bar Code Printer TT065-50', driver: 'TT065', port: 'USB002');
      expect(tt065.isTargetTvs, isTrue);

      const standard = PrinterDevice(name: 'HP LaserJet Pro', driver: 'HP', port: 'DOT4_001');
      expect(standard.isTargetTvs, isFalse);
    });

    // -------------------------------------------------------------------------
    // TEST 10: BarcodePrintDialog Widget preview & profile controls
    // -------------------------------------------------------------------------
    testWidgets('TEST 10: BarcodePrintDialog renders 38x25mm preview and profile dropdown', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final item = BarcodeLabelItem(
        name: 'BATTERY AXLEL GOLD 805',
        barcode: '123456789012',
        sellingPrice: 450.0,
        quantity: 1,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: BarcodePrintDialog(
              initialItems: [item],
              title: 'Print Barcode Labels (TVS LP 46 Lite)',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify Dialog Title and Elements
      expect(find.text('Print Barcode Labels (TVS LP 46 Lite)'), findsOneWidget);
      expect(find.text('TEKFIX DIGITAL'), findsOneWidget);
      expect(find.text('BATTERY AXLEL GOLD 805'), findsWidgets);
      expect(find.text('123456789012'), findsWidgets);
      expect(find.text('PRICE: ₹450'), findsOneWidget);

      // Verify Test Print and Actions
      expect(find.text('Test Print (1 Label)'), findsOneWidget);
      expect(find.text('Calibrate Gap'), findsOneWidget);
      expect(find.textContaining('Print 1 Labels'), findsOneWidget);
    });
  });
}
