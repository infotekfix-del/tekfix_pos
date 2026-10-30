import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/purchases/invoice_parser_service.dart';
import 'package:tekfix_erp_pos/purchases/purchase_models.dart';

void main() {
  group('PHASE 6: INVOICE INGESTION, EXTRACTION & POPULATION TEST SUITE', () {
    test('1. Structured Invoice Header Extraction (Invoice #, Date, GSTIN, Vendor)', () {
      const sampleInvoiceText = '''
      TAX INVOICE
      Sold By: SUPREME TELECOM DISTRIBUTORS PVT LTD
      GSTIN: 32AABCS1429B1Z8
      Invoice No: INV/2026/0998
      Date: 25-01-2026
      Bill To: TekFix Mobiles & Services
      Place of Supply: 32-Kerala

      Item Description              Qty   Rate       Tax%   Total
      1. iPhone 15 128GB Black      2     54999.00   18%    129797.64
      2. 20W USB-C Power Adapter    5     1299.00    18%    7664.10

      Subtotal: 116493.00
      IGST: 20968.74
      Grand Total: 137461.74
      ''';

      final parsed = InvoiceParserService.instance.parseInvoiceText(
        sampleInvoiceText,
        method: 'Stage C: AI / Heuristic Parser',
      );

      // Verify Header Fields
      expect(parsed.invoiceNumber, equals('INV/2026/0998'));
      expect(parsed.invoiceDate, equals(DateTime(2026, 1, 25)));
      expect(parsed.vendorGst, equals('32AABCS1429B1Z8'));
      expect(parsed.vendorName, contains('SUPREME TELECOM'));
      expect(parsed.invoiceTotal, equals(137461.74));

      // Verify Items
      expect(parsed.hasItems, isTrue);
      expect(parsed.itemCount, equals(2));

      final it1 = parsed.items[0];
      expect(it1.description, contains('iPhone 15 128GB Black'));
      expect(it1.quantity, equals(2));
      expect(it1.unitPrice, equals(54999.00));
      expect(it1.taxPercent, equals(18.0));

      final it2 = parsed.items[1];
      expect(it2.description, contains('20W USB-C Power Adapter'));
      expect(it2.quantity, equals(5));
      expect(it2.unitPrice, equals(1299.00));
      expect(it2.taxPercent, equals(18.0));
    });

    test('2. Multi-Format Date Parser (DD-MM-YYYY, DD/MM/YYYY, YYYY-MM-DD)', () {
      const docDmy = 'Invoice: PB-101\nDate: 14/02/2026\nGrand Total: 500.00\nItem: Case 1 500 500';
      final p1 = InvoiceParserService.instance.parseInvoiceText(docDmy);
      expect(p1.invoiceDate, equals(DateTime(2026, 2, 14)));

      const docYmd = 'Invoice: PB-102\nDate: 2026-11-05\nGrand Total: 800.00\nItem: Cable 2 400 800';
      final p2 = InvoiceParserService.instance.parseInvoiceText(docYmd);
      expect(p2.invoiceDate, equals(DateTime(2026, 11, 5)));
    });

    test('3. Line Items Extraction from Various Layout Formats', () {
      const invoiceTabular = '''
      M/s Apex Electronics
      Invoice No: APEX-8821
      Date: 10-02-2026
      
      Item Name                Qty    Rate      Amount
      OnePlus 12R 256GB        1      39999.00  39999.00
      Tempered Glass Premium   10     99.00     990.00
      
      Total: 40989.00
      ''';

      final parsed = InvoiceParserService.instance.parseInvoiceText(invoiceTabular);

      expect(parsed.itemCount, equals(2));
      expect(parsed.items[0].description, contains('OnePlus 12R 256GB'));
      expect(parsed.items[0].quantity, equals(1));
      expect(parsed.items[0].unitPrice, equals(39999.00));

      expect(parsed.items[1].description, contains('Tempered Glass Premium'));
      expect(parsed.items[1].quantity, equals(10));
      expect(parsed.items[1].unitPrice, equals(99.00));
    });

    test('4. ParsedItem to PurchaseBillItem Conversion & Staging States', () {
      const parsedItem = ParsedInvoiceItem(
        description: 'Samsung Galaxy A35 5G',
        skuOrHsn: '85171300',
        quantity: 3,
        unitPrice: 22499.0,
        discount: 500.0,
        taxPercent: 18.0,
        lineTotal: 79046.22,
      );

      // 1. Unmatched / New product conversion
      final newItem = parsedItem.toPurchaseBillItem(isNew: true);
      expect(newItem.name, equals('Samsung Galaxy A35 5G'));
      expect(newItem.isNewProduct, isTrue);
      expect(newItem.isStagedReady, isFalse);
      expect(newItem.quantity, equals(3));
      expect(newItem.purchaseRate, equals(22499.0));
      expect(newItem.discount, equals(500.0));
      expect(newItem.taxPercent, equals(18.0));

      // 2. Matched existing product conversion
      final matchedItem = parsedItem.toPurchaseBillItem(
        matchedProductId: 'PROD_SAMSUNG_A35',
        matchedProductName: 'Samsung A35 5G (8GB/128GB)',
        isNew: false,
      );
      expect(matchedItem.name, equals('Samsung A35 5G (8GB/128GB)'));
      expect(matchedItem.isNewProduct, isFalse);
      expect(matchedItem.isStagedReady, isTrue);
      expect(matchedItem.itemId, equals('PROD_SAMSUNG_A35'));
    });

    test('5. Non-Blocking Isolate & Stream Processing on File Parsing', () async {
      // Simulate raw invoice bytes (e.g., text or minimal PDF stream)
      final dummyPdfBytes = Uint8List.fromList('''
%PDF-1.4
stream
(Invoice No: INV-TEST-999) Tj
(Date: 12-03-2026) Tj
(Total: 1500.00) Tj
(Display Screen 1 1500 1500) Tj
endstream
%%EOF
'''.codeUnits);

      final parsed = await InvoiceParserService.instance.parseInvoiceFile(
        fileBytes: dummyPdfBytes,
        fileName: 'purchase_invoice.pdf',
      );

      expect(parsed, isNotNull);
      expect(parsed.invoiceNumber, equals('INV-TEST-999'));
      expect(parsed.invoiceDate, equals(DateTime(2026, 3, 12)));
      expect(parsed.invoiceTotal, equals(1500.00));
    });
  });
}
