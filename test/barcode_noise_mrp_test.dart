import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/barcode/barcode_label_models.dart';
import 'package:tekfix_erp_pos/barcode/barcode_label_service.dart';
import 'package:tekfix_erp_pos/barcode/tspl_generator.dart';

void main() {
  group('Phase 2 - Barcode Label MRP Noise Air Clips Pro Test', () {
    test('effectivePrice should fallback to sellingPrice when mrp is lower than sellingPrice or invalid', () {
      final itemCorruptedMrp = BarcodeLabelItem(
        barcode: 'NOISE-001',
        name: 'NOISE AIR CLIPS PRO',
        mrp: 493.75, // corrupted reverse markup (395 * 1.25)
        sellingPrice: 680.0,
      );

      // MRP cannot be less than selling price; must reject 493.75 and use selling price 680.0
      expect(itemCorruptedMrp.effectivePrice, 680.0);
    });

    test('TSPL generator formats MRP with Rs. prefix and exactly 2 decimal places', () {
      final item = BarcodeLabelItem(
        barcode: 'NOISE-001',
        name: 'NOISE AIR CLIPS PRO',
        mrp: 493.75,
        sellingPrice: 680.0,
      );

      final tspl = TsplGenerator.generateJob(
        items: [item],
        config: const PrinterConfig(),
        showPrice: true,
      );

      // TSPL text must include Rs.680.00 and must NOT include 493.75
      expect(tspl.contains('Rs.680.00'), isTrue);
      expect(tspl.contains('493.75'), isFalse);
    });

    test('Barcode preview currency constant is Indian Rupee symbol', () {
      expect(BarcodeLabelService.previewCurrencySymbol, '₹');
      expect(BarcodeLabelService.tsplCurrencyPrefix, 'Rs.');

      const price = 680.0;
      final previewText = 'MRP: ${BarcodeLabelService.previewCurrencySymbol}${price.toStringAsFixed(2)}';
      expect(previewText, 'MRP: ₹680.00');
    });
  });
}
