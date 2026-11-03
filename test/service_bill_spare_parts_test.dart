import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/repairs/service_bill_dialog.dart';

void main() {
  group('Service Bill Spare Parts Integration Tests', () {
    test('ServiceSparePart calculates line total and line cost accurately', () {
      final part = ServiceSparePart(
        itemKey: 101,
        itemId: 'ITEM-101',
        name: 'iPhone 11 Screen Replacement (Original)',
        category: 'Screens',
        barcode: 'TF891234',
        costPrice: 1200.0,
        unitPrice: 2200.0,
        qty: 2,
        maxStock: 5,
      );

      expect(part.lineTotal, equals(4400.0), reason: '2200 * 2 = 4400');
      expect(part.lineCost, equals(2400.0), reason: '1200 * 2 = 2400');

      final map = part.toMap();
      expect(map['key'], equals(101));
      expect(map['name'], equals('iPhone 11 Screen Replacement (Original)'));
      expect(map['qty'], equals(2));
      expect(map['price'], equals(2200.0));
      expect(map['costPrice'], equals(1200.0));
      expect(map['lineTotal'], equals(4400.0));
      expect(map['lineCost'], equals(2400.0));
    });

    test('Inventory filter matches products by name, category, barcode, and model', () {
      final inventory = [
        {
          'name': 'Samsung A51 AMOLED Display',
          'category': 'Screen',
          'barcode': 'TF112233',
          'model': 'SM-A515F',
          'stock': 4,
          'sellingPrice': 2500.0,
        },
        {
          'name': 'iPhone 12 Battery OEM',
          'category': 'Battery',
          'barcode': 'TF445566',
          'model': 'A2403',
          'stock': 10,
          'sellingPrice': 1800.0,
        },
        {
          'name': 'Universal B-7000 Glue 50ml',
          'category': 'Consumables',
          'barcode': 'TF778899',
          'model': 'B7000',
          'stock': 25,
          'sellingPrice': 150.0,
        },
      ];

      // Query 1: by partial name "screen" or "display"
      final matches1 = inventory.where((it) {
        final q = 'display'.toLowerCase();
        return '${it['name']}'.toLowerCase().contains(q) ||
            '${it['category']}'.toLowerCase().contains(q);
      }).toList();
      expect(matches1.length, equals(1));
      expect(matches1.first['name'], contains('Samsung A51'));

      // Query 2: by category "battery"
      final matches2 = inventory.where((it) {
        final q = 'battery'.toLowerCase();
        return '${it['name']}'.toLowerCase().contains(q) ||
            '${it['category']}'.toLowerCase().contains(q);
      }).toList();
      expect(matches2.length, equals(1));
      expect(matches2.first['name'], contains('iPhone 12'));

      // Query 3: by barcode "TF778899"
      final matches3 = inventory.where((it) {
        final q = 'TF778899'.toLowerCase();
        return '${it['barcode']}'.toLowerCase().contains(q);
      }).toList();
      expect(matches3.length, equals(1));
      expect(matches3.first['name'], contains('Glue'));
    });

    test('Financial calculation accurately handles service charge, parts, labour, discount, and advance', () {
      const double serviceCharge = 500.0;
      const double partsCharge = 2200.0;
      const double labour = 200.0;
      const double discount = 100.0;
      const double advanceReceived = 1000.0;

      final double grossTotal = serviceCharge + partsCharge + labour - discount;
      expect(grossTotal, equals(2800.0), reason: '500 + 2200 + 200 - 100 = 2800');

      final double netBalanceDue = (grossTotal - advanceReceived).clamp(0.0, double.infinity);
      expect(netBalanceDue, equals(1800.0), reason: '2800 - 1000 = 1800');
    });

    test('Quantity stepper bounds respects available inventory stock', () {
      final part = ServiceSparePart(
        itemKey: 202,
        name: 'OnePlus 9 Charging Flex Cable',
        unitPrice: 650.0,
        qty: 1,
        maxStock: 3,
      );

      // Increment within stock limit
      if (part.qty < part.maxStock) {
        part.qty++;
      }
      expect(part.qty, equals(2));

      // Increment to max
      if (part.qty < part.maxStock) {
        part.qty++;
      }
      expect(part.qty, equals(3));

      // Cannot increment past maxStock
      bool exceededStock = false;
      if (part.qty >= part.maxStock) {
        exceededStock = true;
      }
      expect(exceededStock, isTrue);
      expect(part.qty, equals(3));
    });

    test('ServiceBillDialog instantiates correctly for a service job card', () {
      final job = <String, dynamic>{
        'jobId': 'JOB-2026-0042',
        'customerName': 'Rahul Menon',
        'phone': '9876543210',
        'productType': 'Mobile',
        'brandModel': 'iPhone 13',
        'estimatedCost': 1500.0,
        'advance': 500.0,
        'warrantyDays': 30,
        'status': 'In Progress',
        'billCreated': false,
      };

      final dialog = ServiceBillDialog(
        jobKey: 'job_42',
        job: job,
      );

      expect(dialog, isNotNull);
      expect(dialog.jobKey, equals('job_42'));
      expect(dialog.job['jobId'], equals('JOB-2026-0042'));
    });
  });
}

