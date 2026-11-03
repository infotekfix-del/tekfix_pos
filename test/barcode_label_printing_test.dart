import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/barcode/barcode_label_models.dart';
import 'package:tekfix_erp_pos/barcode/tspl_generator.dart';
import 'package:tekfix_erp_pos/barcode/barcode_label_service.dart';
import 'package:tekfix_erp_pos/barcode/barcode_print_dialog.dart';
import 'package:tekfix_erp_pos/barcode/windows_raw_printer.dart';

void main() {
  group('TVS LP 46 Lite / LP 44 Lite - 50x25mm Label Printing Specifications', () {
    test('PrinterConfig calculates correct 203 DPI dot geometry for 50x25mm with 3mm gap', () {
      const config = PrinterConfig(
        widthMm: 50.0,
        heightMm: 25.0,
        gapMm: 3.0,
        offsetMm: 0.0,
        dpi: 203,
        safetyMarginMm: 1.5,
        storeName: 'TEKFIX DIGITAL',
      );

      expect(config.widthDots, equals(400), reason: '50mm at 8 dots/mm = 400 dots');
      expect(config.heightDots, equals(200), reason: '25mm at 8 dots/mm = 200 dots');
      expect(config.gapDots, equals(24), reason: '3mm gap at 8 dots/mm = 24 dots');
      expect(config.safetyMarginDots, equals(12), reason: '1.5mm margin at 8 dots/mm = 12 dots');
    });

    test('PrinterDevice correctly identifies TVS LP 46 and TT065-50 thermal printers', () {
      const tvsPrinter = PrinterDevice(
        name: 'TVS LP 46 Lite',
        driver: 'TVS LP 46 Lite',
        port: 'USB001',
      );
      expect(tvsPrinter.isTargetTvs, isTrue);

      const tt065Printer = PrinterDevice(
        name: 'Bar Code Printer TT065-50',
        driver: 'Bar Code Printer TT065-50',
        port: 'USB002',
      );
      expect(tt065Printer.isTargetTvs, isTrue);

      const pdfPrinter = PrinterDevice(
        name: 'Microsoft Print to PDF',
        driver: 'Microsoft Print To PDF',
        port: 'PORTPROMPT:',
      );
      expect(pdfPrinter.isTargetTvs, isFalse);
    });

    test('TSPL command generator creates accurate 50x25mm initialization headers', () {
      final item = BarcodeLabelItem(
        name: 'iPhone 13 Screen Protector',
        barcode: 'TF100001',
        itemCode: 'SCR-IP13',
        sellingPrice: 499.0,
        quantity: 1,
      );

      final tspl = TsplGenerator.generateSingleItem(
        item: item,
        config: const PrinterConfig(),
        showPrice: true,
      );

      // Verify strict TVS LP 46 Lite / LP 44 Lite initialization commands
      expect(tspl, contains('SIZE 50 mm,25 mm'));
      expect(tspl, contains('GAP 3 mm,0 mm'));
      expect(tspl, contains('DIRECTION 1'));
      expect(tspl, contains('REFERENCE 0,0'));
      expect(tspl, contains('OFFSET 0 mm'));
      expect(tspl, contains('CLS'));
    });

    test('Single-label print generates exact PRINT 1,1 with zero trailing feeds', () {
      final item = BarcodeLabelItem(
        name: 'Type-C Fast Cable 65W',
        barcode: 'TF200002',
        itemCode: 'CAB-TC65',
        sellingPrice: 299.0,
        quantity: 1,
      );

      final tspl = TsplGenerator.generateSingleItem(
        item: item,
        quantity: 1,
      );

      // Requirement 1 & Critical criteria: No trailing FEED or form feeds
      expect(tspl, contains('PRINT 1,1'));
      expect(tspl, isNot(contains('FEED')));
      expect(tspl, isNot(contains('FORMFEED')));
      expect(tspl, isNot(contains('\x0C'))); // No ASCII Form Feed (FF) character
    });

    test('Multi-quantity print generates exact count (e.g. PRINT 5,1)', () {
      final item = BarcodeLabelItem(
        name: 'Wireless Earbuds Pro',
        barcode: 'TF300003',
        itemCode: 'EAR-WPRO',
        sellingPrice: 1499.0,
        quantity: 5,
      );

      final tspl = TsplGenerator.generateSingleItem(
        item: item,
        quantity: 5,
      );

      expect(tspl, contains('PRINT 5,1'));
    });

    test('TSPL contains store name, Code 128 barcode, and item code/MRP', () {
      final item = BarcodeLabelItem(
        name: 'Samsung 25W Adapter',
        barcode: 'TF400004',
        itemCode: 'SAM-ADP25',
        sellingPrice: 1299.0,
        quantity: 1,
      );

      final tspl = TsplGenerator.generateSingleItem(
        item: item,
        showPrice: true,
      );

      expect(tspl, contains('TEKFIX DIGITAL'));
      expect(tspl, contains('Samsung 25W Adapter'));
      expect(tspl, contains('BARCODE '));
      expect(tspl, contains('"128",50,0,0,2,2,"TF400004"'));
      expect(tspl, contains('TF400004'));
      expect(tspl, contains('SAM-ADP25 • MRP: Rs.1299'));
    });

    test('TSPL text wrapping handles long product names cleanly across two lines', () {
      final item = BarcodeLabelItem(
        name: 'Super High Speed Ultra Durable Braided USB Type-C to Lightning Cable 2M',
        barcode: 'TF500005',
        itemCode: 'CAB-LT2M',
        sellingPrice: 850.0,
        quantity: 1,
      );

      final tspl = TsplGenerator.generateSingleItem(
        item: item,
        showPrice: true,
      );

      // Verify wrapped into Font "1" lines
      expect(tspl, contains('"1",0,1,1,'));
      expect(tspl, contains('PRINT 1,1'));
    });

    test('Gap sensor calibration command produces exact GAPDETECT', () {
      final cmd = TsplGenerator.generateCalibrationCommand();
      expect(cmd, equals('GAPDETECT\r\n'));
    });

    test('BarcodeLabelService and BarcodePrintDialog initialize cleanly', () {
      final service = BarcodeLabelService.instance;
      expect(service.config.widthMm, equals(50.0));
      expect(service.config.heightMm, equals(25.0));
      expect(service.config.gapMm, equals(3.0));

      final rawPrinter = WindowsRawPrinter.instance;
      expect(rawPrinter, isNotNull);

      final dialog = BarcodePrintDialog(
        initialItems: [
          BarcodeLabelItem(
            name: 'Test Item',
            barcode: 'TF999001',
            itemCode: 'TEST-01',
            sellingPrice: 199.0,
            quantity: 1,
          )
        ],
      );
      expect(dialog, isNotNull);
    });
  });
}
