import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:pdf/pdf.dart';
import 'package:tekfix_erp_pos/barcode/barcode_label_service.dart';
import 'package:tekfix_erp_pos/main.dart'
    show boxItems, boxStockMoves, Db;

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tekfix_phase5_barcode_test_');
    Hive.init(tempDir.path);
    await Hive.openBox(boxItems);
    await Hive.openBox(boxStockMoves);
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('PHASE 5: TVS LP 46 LITE (38 mm × 25 mm) BARCODE PRINTING TEST SUITE', () {
    test('1. Exact Physical Specification (38 mm × 25 mm)', () {
      final pageFormat = BarcodeLabelService.pageFormat;

      const expectedWidth = 38.0 * PdfPageFormat.mm;
      const expectedHeight = 25.0 * PdfPageFormat.mm;

      expect(pageFormat.width, closeTo(expectedWidth, 0.01));
      expect(pageFormat.height, closeTo(expectedHeight, 0.01));

      // Tight margins to prevent thermal edge clipping while maximizing printable area
      expect(pageFormat.marginTop, closeTo(1.0 * PdfPageFormat.mm, 0.01));
      expect(pageFormat.marginBottom, closeTo(1.0 * PdfPageFormat.mm, 0.01));
      expect(pageFormat.marginLeft, closeTo(1.2 * PdfPageFormat.mm, 0.01));
      expect(pageFormat.marginRight, closeTo(1.2 * PdfPageFormat.mm, 0.01));
    });

    test('2. Unique Code 128 Scannable Barcode Generation', () {
      final service = BarcodeLabelService.instance;
      final bc1 = service.generateUniqueBarcode();
      final bc2 = service.generateUniqueBarcode();

      expect(bc1, startsWith('TF'));
      expect(bc2, startsWith('TF'));
      expect(bc1.length, equals(8));
      expect(bc2.length, equals(8));
      expect(bc1 != bc2, isTrue);
    });

    test('3. Single Test Label Generation (1 Sticker)', () async {
      final service = BarcodeLabelService.instance;

      final testItem = BarcodeLabelItem(
        name: 'OLED Display Assembly',
        model: 'DA-OLED',
        brand: 'TekFix',
        barcode: 'TF901234',
        sellingPrice: 3499.0,
        quantity: 1, // Single test label
      );

      final pdfBytes = await service.generateLabelsPdf(
        items: [testItem],
        showPrice: true,
        shopName: 'TEKFIX DIGITAL',
      );

      expect(pdfBytes, isNotNull);
      expect(pdfBytes.isNotEmpty, isTrue);

      // Verify TSPL command for single test label
      final tspl = service.generateTsplCommands(
        items: [testItem],
        showPrice: true,
      );

      expect(tspl, contains('PRINT 1,1'));
      expect(tspl, contains('SIZE 38 mm, 25 mm'));
      expect(tspl, contains('TF901234'));
      expect(tspl, contains('MRP: Rs. 3499.00'));
    });

    test('4. Batch Generation & Quantity Defaulting', () async {
      final service = BarcodeLabelService.instance;

      final itemA = BarcodeLabelItem(
        name: 'Tempered Glass 9D',
        barcode: 'TF112233',
        sellingPrice: 199.0,
        quantity: 5,
      );
      final itemB = BarcodeLabelItem(
        name: 'Silicone Case Matte',
        barcode: 'TF445566',
        sellingPrice: 299.0,
        quantity: 10,
      );

      final pdfBytes = await service.generateLabelsPdf(
        items: [itemA, itemB],
        showPrice: true,
      );

      expect(pdfBytes.isNotEmpty, isTrue);

      final tspl = service.generateTsplCommands(items: [itemA, itemB]);
      expect(tspl, contains('PRINT 5,1'));
      expect(tspl, contains('PRINT 10,1'));
    });

    test('5. Reprint Without Modifying Stock or Creating Stock Moves', () async {
      final service = BarcodeLabelService.instance;

      // 1. Setup item in Db.items with stock = 20
      final itemKey = await Db.items.add({
        'name': 'Original USB-C Cable 65W',
        'barcode': 'TF778899',
        'stock': 20,
        'costPrice': 150.0,
        'sellingPrice': 399.0,
      });

      final initialStockMoveCount = Db.stockMoves.length;
      final initialItemStock = (Db.items.get(itemKey) as Map)['stock'];

      // 2. Perform a reprint action of 5 labels
      final reprintItem = BarcodeLabelItem(
        itemKey: itemKey,
        name: 'Original USB-C Cable 65W',
        barcode: 'TF778899',
        sellingPrice: 399.0,
        quantity: 5,
      );

      final pdfBytes = await service.generateLabelsPdf(
        items: [reprintItem],
        showPrice: true,
      );

      expect(pdfBytes.isNotEmpty, isTrue);

      // 3. Confirm that stock in Db.items remained untouched at 20
      final currentItemStock = (Db.items.get(itemKey) as Map)['stock'];
      expect(currentItemStock, equals(initialItemStock));
      expect(currentItemStock, equals(20));

      // 4. Confirm that NO stock movements were added
      expect(Db.stockMoves.length, equals(initialStockMoveCount));
    });

    test('6. Permanent DB Barcode Sync & Scanner Retrieval', () async {
      final service = BarcodeLabelService.instance;

      final itemKey = await Db.items.add({
        'name': 'Stereo Earphones 3.5mm',
        'price': 249.0,
      });

      // Ensure item has barcode assigned
      final barcode = await service.ensureItemHasBarcode(
        itemKey,
        sellingPrice: 249.0,
      );

      expect(barcode, startsWith('TF'));

      final updated = Db.items.get(itemKey) as Map;
      expect(updated['barcode'], equals(barcode));
      expect(updated['code'], equals(barcode));
    });
  });
}

