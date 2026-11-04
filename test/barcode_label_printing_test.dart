import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/barcode/barcode_label_service.dart';
import 'package:tekfix_erp_pos/barcode/barcode_print_dialog.dart';

void main() {
  group('FINAL LABEL SPEC - TVS LP 46 Lite Thermal Barcode Label Printing', () {
    // -------------------------------------------------------------------------
    // TEST 1: Default label size 38x25 mm with 16-dot safe margins & DENSITY 8
    // -------------------------------------------------------------------------
    test(
        'TEST 1: Default label size 38x25 mm, 304x200 dots, 16-dot safe margins, DENSITY 8',
        () {
      const config = PrinterConfig();

      expect(config.widthMm, equals(38.0));
      expect(config.heightMm, equals(25.0));
      expect(config.widthDots, equals(304)); // 38 * 8 = 304 dots
      expect(config.heightDots, equals(200)); // 25 * 8 = 200 dots
      expect(config.safeMarginDots, equals(16)); // 16-dot safe margins
      expect(config.printableWidthDots, equals(272)); // 304 - 32 = 272 dots
      expect(config.printableHeightDots, equals(168)); // 200 - 32 = 168 dots
      expect(config.darkness, equals(8)); // DENSITY 8
      expect(config.speed, equals(3)); // SPEED 3
      expect(config.preset, equals(LabelPreset.preset38x25));
    });

    // -------------------------------------------------------------------------
    // TEST 2: Exact TSPL Header and PRINT 1,1 per label
    // -------------------------------------------------------------------------
    test('TEST 2: Exact TSPL Header matches spec and ends with PRINT 1,1', () {
      final item = BarcodeLabelItem(
        name: 'BATTERY AXLEL GOLD 805',
        barcode: 'TKF894218',
        mrp: 450.0,
        quantity: 1,
      );

      final tspl = TsplGenerator.generateSingleLabel(
        item: item,
        config: const PrinterConfig(),
        showPrice: true,
      );

      // Verify exact TSPL header
      expect(tspl, contains('SIZE 38 mm,25 mm'));
      expect(tspl, contains('GAP 3 mm,0 mm'));
      expect(tspl, contains('DIRECTION 1'));
      expect(tspl, contains('REFERENCE 0,0'));
      expect(tspl, contains('DENSITY 8'));
      expect(tspl, contains('SPEED 3'));
      expect(tspl, contains('CLS'));

      // Layout elements
      expect(tspl, contains('TEXT '));
      expect(tspl, contains('"TEKFIX DIGITAL"'));
      expect(tspl, contains('"BATTERY AXLEL GOLD 805"'));
      expect(tspl, contains('BARCODE '));
      expect(tspl, contains('"128",60,0,0,')); // height ~60 dots
      expect(tspl, contains('"TKF894218"'));
      expect(tspl, contains('MRP: Rs.450'));
      expect(tspl, contains('PRINT 1,1'));
      expect(tspl, isNot(contains('FEED')));
    });

    // -------------------------------------------------------------------------
    // TEST 3: Print only primary code (TKF... / IMEI) - Remove ITEM_... line
    // -------------------------------------------------------------------------
    test('TEST 3: Print only primary code (TKF... / IMEI) and no ITEM_... line',
        () {
      final item = BarcodeLabelItem(
        itemId: 'ITEM_INTERNAL_9999',
        itemCode: 'ITEM_CODE_8888',
        name: 'Display Combo iPhone X',
        barcode: 'TKF100200',
        mrp: 2500.0,
        quantity: 1,
      );

      final tspl = TsplGenerator.generateSingleLabel(
        item: item,
        config: const PrinterConfig(),
        showPrice: true,
      );

      // Primary barcode code must appear
      expect(tspl, contains('TKF100200'));
      // Internal item document IDs must NOT appear
      expect(tspl, isNot(contains('ITEM_INTERNAL_9999')));
      expect(tspl, isNot(contains('ITEM_CODE_8888')));
    });

    // -------------------------------------------------------------------------
    // TEST 4: Item name wraps to at most 2 lines without overflowing
    // -------------------------------------------------------------------------
    test('TEST 4: Item name wraps to max 2 lines inside 272-dot safe width',
        () {
      final item = BarcodeLabelItem(
        name:
            'Super AMOLED Display Combo With Touch Screen Digitizer Assembly Replacement',
        barcode: 'TKF777888',
        mrp: 3200.0,
        quantity: 1,
      );

      final tspl = TsplGenerator.generateSingleLabel(
        item: item,
        config: const PrinterConfig(),
        showPrice: true,
      );

      final lines = tspl.split('\n');
      final textLines = lines.where((l) => l.startsWith('TEXT ')).toList();
      // Total text lines: Shop name (1), Item name (max 2), Barcode text (1), MRP (1) = 5
      expect(textLines.length, lessThanOrEqualTo(5));
      expect(tspl, contains('BARCODE '));
      expect(tspl, contains('PRINT 1,1'));
    });

    // -------------------------------------------------------------------------
    // TEST 5: Auto-reduce bar width if barcode is too wide
    // -------------------------------------------------------------------------
    test(
        'TEST 5: Code 128 auto-reduces narrow module width to 1 for long barcodes',
        () {
      final longItem = BarcodeLabelItem(
        name: 'Motherboard',
        barcode: '890123456789012345', // 18-digit barcode
        mrp: 4500.0,
        quantity: 1,
      );

      final tspl = TsplGenerator.generateSingleLabel(
        item: longItem,
        config: const PrinterConfig(),
        showPrice: true,
      );

      // (18 * 11) + 35 = 233 modules. Module 2 would be 466 > 272. Must auto-reduce to module 1.
      expect(tspl, contains('"128",60,0,0,1,1,"890123456789012345"'));
    });

    // -------------------------------------------------------------------------
    // TEST 6: Print 3 labels produces 3 separate labels each with PRINT 1,1
    // -------------------------------------------------------------------------
    test(
        'TEST 6: Print 3 labels generates 3 separate labels each with PRINT 1,1 and no drift',
        () {
      final item = BarcodeLabelItem(
        name: 'Screen Protector Guard',
        barcode: 'TKF555444',
        mrp: 150.0,
        quantity: 3,
      );

      final tspl = TsplGenerator.generateJob(
        items: [item],
        config: const PrinterConfig(),
        showPrice: true,
      );

      // Verify exactly 3 CLS and 3 PRINT 1,1 commands
      final clsMatches = RegExp(r'\bCLS\b').allMatches(tspl);
      final printMatches = RegExp(r'PRINT 1,1').allMatches(tspl);

      expect(clsMatches.length, equals(3),
          reason: 'Each label must reset buffer with CLS');
      expect(printMatches.length, equals(3),
          reason: 'Each label must end with PRINT 1,1');
    });

    // -------------------------------------------------------------------------
    // TEST 7: MRP toggle and Missing / ₹0 price handling
    // -------------------------------------------------------------------------
    test(
        'TEST 7: MRP printed when toggle ON & price > 0; omitted when 0 or toggle OFF',
        () {
      final itemWithPrice = BarcodeLabelItem(
        name: 'USB-C Cable',
        barcode: 'TKF123',
        mrp: 299.0,
        quantity: 1,
      );

      final itemZeroPrice = BarcodeLabelItem(
        name: 'Free Promo Sticker',
        barcode: 'TKF000',
        mrp: 0.0,
        sellingPrice: 0.0,
        quantity: 1,
      );

      // Case A: Toggle ON with valid price -> Prints MRP: Rs.299
      final tsplA = TsplGenerator.generateSingleLabel(
          item: itemWithPrice, showPrice: true);
      expect(tsplA, contains('MRP: Rs.299'));

      // Case B: Toggle OFF with valid price -> Does not print MRP
      final tsplB = TsplGenerator.generateSingleLabel(
          item: itemWithPrice, showPrice: false);
      expect(tsplB, isNot(contains('MRP:')));

      // Case C: Toggle ON but price is 0 -> Does NOT print Rs.0
      final tsplC = TsplGenerator.generateSingleLabel(
          item: itemZeroPrice, showPrice: true);
      expect(tsplC, isNot(contains('MRP:')));
      expect(tsplC, isNot(contains('Rs.0')));
      expect(itemZeroPrice.hasValidPrice, isFalse);
    });

    // -------------------------------------------------------------------------
    // TEST 8: Border Test Command generates rectangular box at 16-dot margin edge
    // -------------------------------------------------------------------------
    test(
        'TEST 8: Print Border Test generates BOX rectangle at 16-dot safe margins',
        () {
      const config = PrinterConfig();
      final borderTspl =
          TsplGenerator.generateBorderTestCommand(config: config);

      expect(borderTspl, contains('SIZE 38 mm,25 mm'));
      expect(borderTspl, contains('GAP 3 mm,0 mm'));
      expect(borderTspl, contains('CLS'));
      // BOX x_start, y_start, x_end, y_end, thickness
      // (304 - 16 = 288, 200 - 16 = 184)
      expect(borderTspl, contains('BOX 16,16,288,184,2'));
      expect(borderTspl, contains('BORDER TEST'));
      expect(borderTspl, contains('PRINT 1,1'));
    });

    // -------------------------------------------------------------------------
    // TEST 9: DENSITY (1-15) and X/Y Offset settings
    // -------------------------------------------------------------------------
    test(
        'TEST 9: DENSITY and X/Y Offset settings dynamically alter TSPL header',
        () {
      final config = const PrinterConfig().copyWith(
        darkness: 12,
        xOffsetMm: 1.5,
        yOffsetMm: -0.5,
      );

      expect(config.darkness, equals(12));
      expect(config.referenceXDots, equals(12)); // 1.5 * 8 = 12 dots
      expect(config.referenceYDots, equals(-4)); // -0.5 * 8 = -4 dots

      final item = BarcodeLabelItem(
        name: 'Charger',
        barcode: 'TKF999',
        mrp: 650.0,
        quantity: 1,
      );

      final tspl =
          TsplGenerator.generateSingleLabel(item: item, config: config);
      expect(tspl, contains('DENSITY 12'));
      expect(tspl, contains('REFERENCE 12,-4'));
    });

    // -------------------------------------------------------------------------
    // TEST 10: Presets 38x25 / 50x25 / Custom
    // -------------------------------------------------------------------------
    test(
        'TEST 10: Presets 38x25, 50x25, and Custom configure dimensions correctly',
        () {
      const def = PrinterConfig();
      expect(def.preset, equals(LabelPreset.preset38x25));
      expect(def.widthMm, equals(38.0));

      final p50 = def.withPreset(LabelPreset.preset50x25);
      expect(p50.preset, equals(LabelPreset.preset50x25));
      expect(p50.widthMm, equals(50.0));
      expect(p50.heightMm, equals(25.0));

      final custom = def.withPreset(LabelPreset.custom,
          customWidth: 60.0, customHeight: 30.0);
      expect(custom.preset, equals(LabelPreset.custom));
      expect(custom.widthMm, equals(60.0));
      expect(custom.heightMm, equals(30.0));
    });

    // -------------------------------------------------------------------------
    // TEST 11: Calibrate Gap sends GAPDETECT
    // -------------------------------------------------------------------------
    test('TEST 11: Calibrate Gap command sends GAPDETECT', () {
      final calCmd = TsplGenerator.generateCalibrationCommand();
      expect(calCmd, equals('GAPDETECT\r\n'));
    });

    // -------------------------------------------------------------------------
    // TEST 12: BarcodePrintDialog Widget Test (1-up preview, actions & MRP display)
    // -------------------------------------------------------------------------
    testWidgets(
        'TEST 12: BarcodePrintDialog renders preview, Border Test, and MRP',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final item = BarcodeLabelItem(
        name: 'BATTERY AXLEL GOLD 805',
        barcode: 'TKF123456',
        mrp: 450.0,
        quantity: 1,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BarcodePrintDialog(
              initialItems: [item],
              title: 'Print Labels',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify Store Name, Product Name, Barcode and MRP are displayed
      expect(find.text('TEKFIX DIGITAL'), findsOneWidget);
      expect(find.text('BATTERY AXLEL GOLD 805'), findsNWidgets(2));
      expect(find.text('TKF123456'), findsNWidgets(2));
      expect(find.text('MRP: ₹450'), findsOneWidget);

      // Verify Action Buttons
      expect(find.text('Print Border Test'), findsOneWidget);
      expect(find.text('Test Print (1 Label)'), findsOneWidget);
      expect(find.text('Calibrate Gap'), findsOneWidget);
      expect(find.text('View TSPL Commands (Direct Thermal)'), findsOneWidget);
    });
  });
}
