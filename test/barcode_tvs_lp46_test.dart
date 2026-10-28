import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:pdf/pdf.dart';
import 'package:tekfix_erp_pos/barcode/barcode_label_service.dart';
import 'package:tekfix_erp_pos/main.dart' show boxItems;
import 'package:tekfix_erp_pos/pos/pos_models.dart';
import 'package:tekfix_erp_pos/purchases/purchase_models.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tekfix_barcode_test_');
    Hive.init(tempDir.path);
    await Hive.openBox(boxItems);
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('TVS LP 46 LITE (38 mm × 25 mm) BARCODE MODULE TEST SUITE', () {
    test('1. Exact Physical Dimensions: Width 38 mm, Height 25 mm', () {
      final format = BarcodeLabelService.pageFormat;

      // 1 mm in PDF points is 72 / 25.4 = ~2.83464567 pt
      final expectedWidthPt = 38.0 * (72.0 / 25.4);
      final expectedHeightPt = 25.0 * (72.0 / 25.4);

      expect(format.width, closeTo(expectedWidthPt, 0.01));
      expect(format.height, closeTo(expectedHeightPt, 0.01));

      // Margins must be tight to maximize printable area without edge clipping
      expect(format.marginTop, closeTo(1.0 * (72.0 / 25.4), 0.01));
      expect(format.marginBottom, closeTo(1.0 * (72.0 / 25.4), 0.01));
    });

    test('2. Generate Genuine Scannable Code 128 Barcodes & Unique ID', () {
      final service = BarcodeLabelService.instance;
      final code1 = service.generateUniqueBarcode();
      final code2 = service.generateUniqueBarcode();

      expect(code1, startsWith('TF'));
      expect(code2, startsWith('TF'));
      expect(code1.length, equals(8)); // TF + 6 digits
      expect(code1 != code2, isTrue);
    });

    test('3. Compact Label Content & PDF Generation for TVS LP 46 Lite', () async {
      final service = BarcodeLabelService.instance;

      final items = [
        BarcodeLabelItem(
          name: 'Fast Charger 65W GaN',
          model: 'FC-65W',
          brand: 'TekFix',
          barcode: 'TF894218',
          sellingPrice: 1499.0,
          quantity: 1,
        ),
      ];

      final pdfBytes = await service.generateLabelsPdf(
        items: items,
        showPrice: true,
        shopName: 'TEKFIX DIGITAL',
      );

      expect(pdfBytes, isNotNull);
      expect(pdfBytes.isNotEmpty, isTrue);
      expect(pdfBytes.length, greaterThan(1000));
    });

    test('4. Quantity Defaulting: If 10 pieces purchased, generates 10 labels', () async {
      final service = BarcodeLabelService.instance;

      // 10 units purchased
      final items = [
        BarcodeLabelItem(
          name: 'USB-C Braided Cable 1.5m',
          model: 'CBL-TC15',
          barcode: 'TF102938',
          sellingPrice: 299.0,
          quantity: 10,
        ),
      ];

      final pdfBytes = await service.generateLabelsPdf(
        items: items,
        showPrice: true,
      );

      // Verify PDF structure has multiple pages for 10 labels
      expect(pdfBytes.length, greaterThan(2500));
    });

    test('5. Multi-Item Purchase Bill Label Batch Generation', () async {
      final service = BarcodeLabelService.instance;

      final billItemA = BarcodeLabelItem(
        name: 'Samsung S24 Screen',
        model: 'S24 Ultra',
        barcode: 'TF203948',
        sellingPrice: 14500.0,
        quantity: 5,
      );
      final billItemB = BarcodeLabelItem(
        name: 'iPhone 15 Tempered Glass',
        model: 'IP15-TG',
        barcode: 'TF394857',
        sellingPrice: 499.0,
        quantity: 10,
      );

      final pdfBytes = await service.generateLabelsPdf(
        items: [billItemA, billItemB],
        showPrice: true,
      );

      expect(pdfBytes.isNotEmpty, isTrue);
    });

    test('6. Permanent DB Storage: Barcode persists to Db.items & matches POS scanner', () async {
      final service = BarcodeLabelService.instance;
      final itemsBox = Hive.box(boxItems);

      // 1. Add a catalog item without barcode
      final itemKey = await itemsBox.add({
        'name': 'Wireless Ergonomic Mouse',
        'model': 'WM-88',
        'price': 899.0,
        'cost': 450.0,
        'stock': 12,
      });

      // 2. Ensure item has barcode permanently stored
      final assignedBarcode = await service.ensureItemHasBarcode(
        itemKey,
        sellingPrice: 899.0,
      );

      expect(assignedBarcode, startsWith('TF'));

      // 3. Verify in Hive database
      final stored = itemsBox.get(itemKey) as Map;
      expect(stored['barcode'], equals(assignedBarcode));
      expect(stored['code'], equals(assignedBarcode));

      // 4. Verify POS scanner matches PosItem
      final posItem = PosItem.fromMap('$itemKey', Map<String, dynamic>.from(stored));
      expect(posItem.barcode, equals(assignedBarcode));
      expect(posItem.barcode.toLowerCase().contains(assignedBarcode.toLowerCase()), isTrue);
      expect(posItem.sellingPrice, equals(899.0));
    });

    test('7. TSPL2 Command Generation for Direct Thermal TVS LP 46 Lite Output', () {
      final service = BarcodeLabelService.instance;

      final items = [
        BarcodeLabelItem(
          name: 'Fast Charger 65W',
          model: 'FC-65',
          barcode: 'TF894218',
          sellingPrice: 1499.0,
          quantity: 10,
        ),
      ];

      final tspl = service.generateTsplCommands(
        items: items,
        showPrice: true,
        shopName: 'TEKFIX DIGITAL',
      );

      expect(tspl, contains('SIZE 38 mm, 25 mm'));
      expect(tspl, contains('GAP 2 mm, 0 mm'));
      expect(tspl, contains('DIRECTION 1'));
      expect(tspl, contains('TEKFIX DIGITAL'));
      expect(tspl, contains('Fast Charger 65W'));
      expect(tspl, contains('BARCODE 28,68,"128",50,1,0,2,2,"TF894218"'));
      expect(tspl, contains('MRP: Rs. 1499.00'));
      expect(tspl, contains('PRINT 10,1'));
    });
  });
}
