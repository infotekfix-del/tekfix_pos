import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Parties Receivables vs Payables Separation Tests', () {
    test('1. Strict separation of customer receivables and supplier payables', () {
      final sampleParties = [
        // Customers
        {'name': 'Customer A', 'type': 'Customer', 'balance': 500.0},
        {'name': 'Customer B', 'type': 'Customer', 'balance': 0.0},
        {'name': 'Customer C', 'type': null, 'balance': 1200.0}, // defaults to customer
        {'name': 'Customer D (Advance)', 'type': 'Customer', 'balance': -200.0}, // customer credit/advance

        // Suppliers
        {'name': 'GT MALAPPURAM', 'type': 'Supplier', 'balance': -10000.0}, // we owe them 10k
        {'name': 'U SPARE', 'type': 'Supplier', 'balance': -5000.0}, // we owe them 5k
        {'name': 'SUPPLIER C (Advance Paid)', 'type': 'Supplier', 'balance': 2000.0},
      ];

      double receivablesTotal = 0;
      double payablesTotal = 0;

      for (final p in sampleParties) {
        final isSupplier = p['type'] == 'Supplier';
        final bal = (p['balance'] as num).toDouble();

        if (!isSupplier) {
          // Customer receivables
          if (bal > 0.005) {
            receivablesTotal += bal;
          }
        } else {
          // Supplier payables
          if (bal < -0.005) {
            payablesTotal += (-bal);
          } else if (bal > 0.005) {
            payablesTotal += bal;
          }
        }
      }

      // Receivables must ONLY include Customer A (500) and Customer C (1200) = 1700.0
      // Under NO circumstance should supplier GT MALAPPURAM or U SPARE be included!
      expect(receivablesTotal, equals(1700.0));
      expect(payablesTotal, equals(17000.0)); // 10000 + 5000 + 2000
    });

    test('2. Filter due only correctly isolates customers and suppliers', () {
      final sampleParties = [
        {'id': '1', 'name': 'Cust Due', 'type': 'Customer', 'balance': 350.0},
        {'id': '2', 'name': 'Cust Settled', 'type': 'Customer', 'balance': 0.0},
        {'id': '3', 'name': 'Supp Due', 'type': 'Supplier', 'balance': -800.0},
        {'id': '4', 'name': 'Supp Settled', 'type': 'Supplier', 'balance': 0.0},
      ];

      // Customers Due Only
      final custDueOnly = sampleParties.where((p) {
        final isCust = p['type'] != 'Supplier';
        if (!isCust) return false;
        final bal = (p['balance'] as num).toDouble();
        return bal > 0.005;
      }).toList();

      expect(custDueOnly.length, equals(1));
      expect(custDueOnly.first['name'], equals('Cust Due'));

      // Suppliers Due Only
      final suppDueOnly = sampleParties.where((p) {
        final isSupp = p['type'] == 'Supplier';
        if (!isSupp) return false;
        final bal = (p['balance'] as num).toDouble();
        return bal.abs() > 0.005;
      }).toList();

      expect(suppDueOnly.length, equals(1));
      expect(suppDueOnly.first['name'], equals('Supp Due'));
    });
  });
}
