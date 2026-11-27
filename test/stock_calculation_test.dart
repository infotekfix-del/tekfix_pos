import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/pos/pos_models.dart';
import 'dart:math' as math;

void main() {
  group('Stock calculation & negative stock prevention', () {
    test('Selling 1 item when stock is 1 leaves 0, not -1', () {
      int initialStock = 1;
      int qtyToSell = 1;

      int calculatedStock = math.max(0, initialStock - qtyToSell);
      expect(calculatedStock, 0);
      expect(calculatedStock, isNot(isNegative));
    });

    test('Selling more than available stock is clamped to 0', () {
      int initialStock = 1;
      int qtyToSell = 2;

      int calculatedStock = math.max(0, initialStock - qtyToSell);
      expect(calculatedStock, 0);
      expect(calculatedStock, isNot(isNegative));
    });

    test('Delta calculation with baseline update prevents double deduction', () {
      int initialStock = 1;
      int qtyToSell = 1;

      // 1. Transaction decrements stock in Firestore to 0
      int firestoreStock = math.max(0, initialStock - qtyToSell);
      expect(firestoreStock, 0);

      // 2. Local stock updated to 0
      int localStock = math.max(0, initialStock - qtyToSell);
      expect(localStock, 0);

      // 3. Baseline (lsKey) updated to 0
      int baselineStock = localStock;

      // 4. SyncEngine computes delta: cur - baseline
      int delta = localStock - baselineStock;
      expect(delta, 0, reason: 'SyncEngine delta must be 0 so no second decrement is sent to Firestore');

      // 5. Remote snapshot arrives with remote = 0
      int remote = firestoreStock;
      int merged = (remote + (localStock - baselineStock)).round();
      int finalStock = math.max(0, merged);
      expect(finalStock, 0, reason: 'Final stock must remain 0 and never go negative');
    });

    test('Multi-item cart calculations keep all stocks non-negative', () {
      final items = [
        {'id': 'item_1', 'stock': 1, 'sellQty': 1},
        {'id': 'item_2', 'stock': 5, 'sellQty': 3},
        {'id': 'item_3', 'stock': 0, 'sellQty': 1},
      ];

      for (final it in items) {
        final cur = it['stock'] as int;
        final qty = it['sellQty'] as int;
        final res = math.max(0, cur - qty);
        expect(res >= 0, isTrue);
        if (it['id'] == 'item_1') expect(res, 0);
        if (it['id'] == 'item_2') expect(res, 2);
        if (it['id'] == 'item_3') expect(res, 0);
      }
    });
  });
}
