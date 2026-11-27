import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/pos/invoice_pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('InvoiceData calculations and Indian currency words', () {
    final data = InvoiceData(
      invoiceNo: 'INV-W0130',
      date: DateTime(2026, 11, 20),
      customerName: 'Nihal P',
      customerPhone: '+91 73065 18977',
      paymentMode: 'Cash',
      lines: [
        InvoiceLine(
          name: 'Sault 65W USB-C to C Cable',
          qty: 2,
          rate: 350.0,
          serialNo: 'SL65W20261120',
          warrantyMonths: 6,
        ),
      ],
      discount: 50.0,
      paid: 650.0,
    );

    expect(data.subtotal, 700.0);
    expect(data.total, 650.0);
    expect(data.balance, 0.0);
    expect(data.isPaid, isTrue);

    final words = amountInWords(data.total);
    expect(words, contains('Six Hundred Fifty'));
  });

  test('InvoiceData.fromMap correctly parses POS bill structure', () {
    final map = {
      'invoice': 'INV-TEST-001',
      'createdAt': '2026-11-23T10:00:00.000Z',
      'customerName': 'Rahul',
      'customerPhone': '9876543210',
      'total': 1200.0,
      'cash': 1000.0,
      'upi': 200.0,
      'discount': 100.0,
      'items': [
        {
          'name': 'Tempered Glass',
          'qty': 1,
          'price': 200.0,
          'warranty': 'No Warranty',
        },
        {
          'name': 'Fast Charger 33W',
          'qty': 1,
          'price': 1100.0,
          'imei': 'CHG-33W-8899',
          'warranty': '6 Months',
        }
      ]
    };

    final inv = InvoiceData.fromMap(map);
    expect(inv.invoiceNo, 'INV-TEST-001');
    expect(inv.customerName, 'Rahul');
    expect(inv.lines.length, 2);
    expect(inv.lines[0].hasWarranty, isFalse);
    expect(inv.lines[1].hasWarranty, isTrue);
    expect(inv.lines[1].warrantyMonths, 6);
    expect(inv.lines[1].serialNo, 'CHG-33W-8899');
    expect(inv.paymentMode, 'Split (Cash+UPI)');
    expect(inv.isPaid, isTrue);
  });

  test('buildInvoicePdf generates PDF bytes cleanly without hanging', () async {
    final map = {
      'invoice': 'INV-TEST-999',
      'createdAt': '2026-11-23T10:00:00.000Z',
      'customerName': 'Test User',
      'customerPhone': '9876543210',
      'total': 500.0,
      'cash': 500.0,
      'items': [
        {
          'name': 'Test Cable',
          'qty': 1,
          'price': 500.0,
          'warranty': '6 Months',
        }
      ]
    };
    final inv = InvoiceData.fromMap(map);
    final bytes = await buildInvoicePdf(inv);
    expect(bytes, isNotEmpty);
    expect(bytes.length, greaterThan(100));
  });
}
