// Vendor bill import: PDF text extraction, bill parsing, OCR clean-up,
// fuzzy item matching and the hand-off to the purchase entry.
//
// Money is asserted in integer paise throughout.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:tekfix_erp_pos/purchases/bill_import/bill_import_screen.dart';
import 'package:tekfix_erp_pos/purchases/bill_import/bill_import_service.dart';
import 'package:tekfix_erp_pos/purchases/bill_import/bill_item_matcher.dart';
import 'package:tekfix_erp_pos/purchases/bill_import/bill_ocr_service.dart';
import 'package:tekfix_erp_pos/purchases/bill_import/bill_text_layout.dart';
import 'package:tekfix_erp_pos/purchases/bill_import/pdf_text_extractor.dart';
import 'package:tekfix_erp_pos/purchases/bill_import/vendor_bill_parser.dart';
import 'package:tekfix_erp_pos/purchases/purchase_models.dart';

const _ownGstin = '32AAAAA0000A1Z5';
const _parser = VendorBillParser(ownGstin: _ownGstin, ownNames: ['TEKFIX']);

/// A Tally-style bill: rates before GST, Disc %, CGST/SGST lines, round off.
/// 5 × 12,711.86 = 63,559.30 ; 10 × 450 − 2% = 4,410.00 ; 20 × 35 = 700.00
/// taxable 68,669.30 ; CGST 9% 6,180.24 ; SGST 6,180.24 ; 81,029.78 → 81,030
Future<Uint8List> _tallyStylePdf({pw.Font? font}) {
  final doc = pw.Document();
  final st = pw.TextStyle(font: font, fontSize: 9);
  doc.addPage(pw.Page(
    pageFormat: PdfPageFormat.a4,
    build: (c) => pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Center(child: pw.Text('TAX INVOICE', style: st)),
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('SUPREME TELECOM DISTRIBUTORS PVT LTD', style: st),
            pw.Text('MG Road, Kozhikode, Kerala', style: st),
            pw.Text('GSTIN/UIN: 32AABCS1429B1Z8', style: st),
            pw.Text('Ph: 9847012345', style: st),
          ]),
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('Invoice No.: SUP/2026/0998', style: st),
            pw.Text('Dated: 12-Nov-26', style: st),
          ]),
        ]),
        pw.SizedBox(height: 10),
        pw.Text('Buyer (Bill to): TEKFIX DIGITAL', style: st),
        pw.Text('GSTIN: $_ownGstin', style: st),
        pw.SizedBox(height: 10),
        pw.TableHelper.fromTextArray(
          cellStyle: st,
          headerStyle: st,
          headers: [
            'Sl', 'Description of Goods', 'HSN/SAC', 'Quantity', 'Rate', 'per',
            'Disc. %', 'Amount'
          ],
          data: [
            ['1', 'Samsung Galaxy A15 (4/128) Blue', '85171300', '5 Nos', '12,711.86', 'Nos', '', '63,559.30'],
            ['2', 'Type-C Fast Charger 25W', '85044030', '10 Nos', '450.00', 'Nos', '2%', '4,410.00'],
            ['3', 'Tempered Glass 9H A15', '70071900', '20 Nos', '35.00', 'Nos', '', '700.00'],
          ],
        ),
        pw.Text('CGST @ 9%                         6,180.24', style: st),
        pw.Text('SGST @ 9%                         6,180.24', style: st),
        pw.Text('Round Off                              0.22', style: st),
        pw.Text('Total                     35 Nos   81,030.00', style: st),
        pw.Text('Amount Chargeable (in words): INR Eighty One Thousand Thirty Only', style: st),
      ],
    ),
  ));
  return doc.save();
}

void _expectTallyBill(ExtractedBill b) {
  expect(b.vendorName, 'SUPREME TELECOM DISTRIBUTORS PVT LTD');
  expect(b.vendorGstin, '32AABCS1429B1Z8'); // not our own GSTIN
  expect(b.vendorPhone, '9847012345');
  expect(b.billNumber, 'SUP/2026/0998');
  expect(b.billDate, DateTime(2026, 11, 12));
  expect(b.lines.length, 3);

  final a15 = b.lines[0];
  expect(a15.description, 'Samsung Galaxy A15 (4/128) Blue');
  expect(a15.hsn, '85171300');
  expect(a15.qtyCenti, 500);
  expect(a15.unit, 'Piece');
  expect(a15.ratePaise, 1271186);
  expect(a15.gstBp, 1800); // inferred from CGST+SGST totals

  final chg = b.lines[1];
  expect(chg.ratePaise, 45000);
  expect(chg.discountPaise, 9000); // 2 % of 4,500
  expect(chg.taxablePaise, 441000);

  expect(b.lines[2].qtyCenti, 2000);
  expect(b.cgstPaise, 618024);
  expect(b.sgstPaise, 618024);
  expect(b.roundOffPaise, 22);
  expect(b.grandTotalPaise, 8103000);
  expect(b.ratesIncludedGst, isFalse);
  expect(b.totalDifferencePaise!.abs(), lessThanOrEqualTo(2));
  expect(b.lines.every((l) => l.consistent), isTrue);
}

void main() {
  group('Money parsing (paise)', () {
    test('Indian grouping, symbols, negatives', () {
      expect(VendorBillParser.parsePaise('1,23,456.50'), 12345650);
      expect(VendorBillParser.parsePaise('₹ 500'), 50000);
      expect(VendorBillParser.parsePaise('Rs.99.9'), 9990);
      expect(VendorBillParser.parsePaise('(-)0.40'), -40);
      expect(VendorBillParser.parsePaise('-0.52'), -52);
      expect(VendorBillParser.parsePaise('12.345'), 1235); // rounded
      expect(VendorBillParser.parsePaise('abc'), isNull);
      expect(VendorBillParser.parsePaise('12-11-2026'), isNull);
    });
  });

  group('PDF text extraction', () {
    test('standard-font PDF → full bill', () async {
      final bytes = await _tallyStylePdf();
      final res = PdfTextExtractor.extract(bytes);
      expect(res.pageCount, 1);
      expect(res.hasUsableText, isTrue);
      _expectTallyBill(_parser.parseLines(BillTextLayout.groupRuns(res.runs)));
    });

    test('embedded TrueType (CID + ToUnicode) PDF → same result', () async {
      final ttf = File(r'C:\Windows\Fonts\arial.ttf');
      if (!ttf.existsSync()) {
        markTestSkipped('arial.ttf not available on this machine');
        return;
      }
      final font = pw.Font.ttf(ttf.readAsBytesSync().buffer.asByteData());
      final bytes = await _tallyStylePdf(font: font);
      final res = PdfTextExtractor.extract(bytes);
      expect(res.unreadableGlyphs, 0);
      _expectTallyBill(_parser.parseLines(BillTextLayout.groupRuns(res.runs)));
    });

    test('browser-generated bill with wrapped, vertically-centred cells',
        () {
      final f = File('test/fixtures/bill_import/browser_style_bill.pdf');
      final res = PdfTextExtractor.extract(f.readAsBytesSync());
      expect(res.hasUsableText, isTrue);
      final b = _parser.parseLines(BillTextLayout.groupRuns(res.runs));
      expect(b.vendorName, 'Malabar Mobile Accessories LLP');
      expect(b.vendorGstin, '32ABCFM4321K1ZQ');
      expect(b.billNumber, 'MMA-2425-1187');
      expect(b.billDate, DateTime(2026, 11, 8)); // not the due date
      expect(b.lines.length, 3);
      final redmi = b.lines[0];
      expect(redmi.description, 'Redmi 13C 5G (4GB/128GB) Starry Black');
      expect(redmi.qtyCenti, 300);
      expect(redmi.ratePaise, 974576);
      expect(redmi.gstBp, 1800);
      expect(redmi.serials, ['861234567890123']); // IMEI under the name
      expect(b.lines[1].description, 'boAt Airdopes 141 TWS');
      expect(b.lines[2].qtyCenti, 2500);
      expect(b.lines[2].ratePaise, 5932);
      expect(b.roundOffPaise, 8);
      expect(b.grandTotalPaise, 4104600);
      expect(b.totalDifferencePaise!.abs(), lessThanOrEqualTo(2));
    });

    test('non-PDF bytes do not crash and give no text', () {
      final res = PdfTextExtractor.extract(
          Uint8List.fromList(List<int>.generate(2000, (i) => i % 251)));
      expect(res.hasUsableText, isFalse);
    });
  });

  group('Bill parsing from text', () {
    test('GST-inclusive rates are converted to rates before GST', () {
      const text = '''
Sri Balaji Mobile Traders
GSTIN: 33ABCDE1234F1Z9
Bill No: 4471                      Date: 05/11/2026
Bill To: TEKFIX DIGITAL   GSTIN: 32AAAAA0000A1Z5
Item Name                     Qty     Rate      Amount
Realme Buds T110              4       1,180.00  4,720.00
Grand Total                                     4,720.00
IGST included 720.00
''';
      final b = _parser.parseText(text);
      expect(b.vendorGstin, '33ABCDE1234F1Z9');
      expect(b.billNumber, '4471');
      expect(b.billDate, DateTime(2026, 11, 5));
      expect(b.lines.single.qtyCenti, 400);
      expect(b.igstPaise, 72000);
      expect(b.ratesIncludedGst, isTrue);
      expect(b.lines.single.gstBp, 1800);
      expect(b.lines.single.ratePaise, 100000); // 1,180 / 1.18
      expect(b.lines.single.totalPaise, 472000);
    });

    test('row maths: 5% discount is not mistaken for 5% GST', () {
      const text = '''
Item Description     Qty   Rate      Disc   Amount
Neckband BT-200      10    500.00    5%     4,750.00
Total                                       4,750.00
''';
      final b = _parser.parseText(text);
      final l = b.lines.single;
      expect(l.qtyCenti, 1000);
      expect(l.ratePaise, 50000);
      expect(l.discountPaise, 25000);
      expect(l.consistent, isTrue);
    });

    test('a 4-digit quantity is not taken as HSN when the maths says qty',
        () {
      const text = '''
Particulars            Qty     Rate     Amount
Screen Guard Matte     1000    10.00    10,000.00
''';
      final l = _parser.parseText(text).lines.single;
      expect(l.qtyCenti, 100000);
      expect(l.ratePaise, 1000);
      expect(l.hsn, '');
    });

    test('bill number in the cell below its label (Tally boxes)', () {
      final lines = BillTextLayout.fromPlainText('''
ABC Distributors      Invoice No.        Dated
Calicut               ABC/778            3-Nov-2026
''');
      final b = _parser.parseLines(lines);
      expect(b.billNumber, 'ABC/778');
      expect(b.billDate, DateTime(2026, 11, 3));
    });

    test('accessory distributor "Sales Estimate" layout (no GST, wrapped names)',
        () {
      // Same layout as a real local distributor's estimate PDF.
      final lines = BillTextLayout.fromPlainText('''
                         Sales Estimate Invoice
ESTIMATE No.                  : 120045.0
ESTIMATE Date                 : 19 Nov 26
NAME OF CONSIGNEE             : TEKFIX MOBILES
No  Description of Goods          Qty      Rate     Discount    Total
1   SILICON POUCH CLEAR           1.00     26.90    0.00        26.90
    WIFI BLUETOOTH DONGLE
2                                 1.00     239.00   0.00        239.00
    (OT-W950)
3   ESD 5D GLASS                  10.00    18.50    0.00        185.00
    Total                         12.00             0.00        450.90
GRAND TOTAL (IN WORDS)            Total Amount      0           450.90
four hundred fifty Only.          Grand Total       0           450.90
                                  Old Balance       0           31607.30
''');
      final b = _parser.parseLines(lines);
      expect(b.billNumber, '120045');
      expect(b.billDate, DateTime(2026, 11, 19));
      expect(b.lines.length, 3);
      expect(b.lines[1].description, 'WIFI BLUETOOTH DONGLE (OT-W950)');
      expect(b.lines[2].qtyCenti, 1000);
      expect(b.lines[2].ratePaise, 1850);
      expect(b.grandTotalPaise, 45090); // not the old balance
      expect(b.totalDifferencePaise, 0);
    });

    test('freight on the bill becomes other charges', () {
      const text = '''
Item          Qty   Rate     Amount
USB Cable     10    50.00    500.00
Freight Charges              120.00
Total                        620.00
''';
      final b = _parser.parseText(text);
      expect(b.otherChargesPaise, 12000);
      expect(b.computedTotalPaise, 62000);
    });

    test('warns when nothing could be read', () {
      final b = _parser.parseText('Thank you for your business');
      expect(b.lines, isEmpty);
      expect(b.warnings.first, contains('No item rows'));
    });
  });

  group('OCR output', () {
    test('word list → runs, digit groups glued, O/I fixed in numbers', () {
      const out = '1\t10\t100\t60\t12\tRedmi\n'
          '1\t75\t100\t30\t12\t13C\n'
          '1\t400\t100\t8\t12\t1\n'
          '1\t409\t100\t40\t12\t,749.94\n'
          '2\t10\t130\t60\t12\t4,O46.0O\n';
      final runs = BillOcrService.parseOcrOutput(out);
      expect(runs.map((r) => r.text).toList(),
          ['Redmi', '13C', '1,749.94', '4,046.00']);
      expect(BillOcrService.fixOcrToken('1l5.00'), '115.00');
      expect(BillOcrService.fixOcrToken('Black'), 'Black');
    });
  });

  group('Item matching', () {
    final catalog = [
      const CatalogItem(key: 1, id: '1', name: 'Samsung Galaxy A15 4GB/128GB Blue', hsn: '85171300'),
      const CatalogItem(key: 2, id: '2', name: 'Samsung Galaxy A25 8GB/128GB Blue'),
      const CatalogItem(key: 3, id: '3', name: 'Type C Fast Charger 25W', barcode: '8906012345678'),
      const CatalogItem(key: 4, id: '4', name: 'Tempered Glass 9H Samsung A15'),
      const CatalogItem(key: 5, id: '5', name: 'boAt Airdopes 141'),
    ];
    final m = BillItemMatcher(catalog);

    test('vendor abbreviations still match the right variant', () {
      final r = m.match('SAM GAL A15 4/128 BLU');
      expect(r.best!.item.key, 1);
      expect(r.level, isNot(MatchLevel.none));
    });

    test('different model number is never auto-linked', () {
      final r = m.match('Samsung Galaxy A35 8GB/128GB Blue');
      expect(r.level, isNot(MatchLevel.matched));
    });

    test('exact name and barcode printed on the bill', () {
      expect(m.match('boAt Airdopes 141').level, MatchLevel.matched);
      final r = m.match('FAST CHARGER 8906012345678');
      expect(r.level, MatchLevel.matched);
      expect(r.best!.item.key, 3);
    });

    test('longer vendor wording containing our item name links', () {
      final r = m.match('boAt Airdopes 141 TWS Bluetooth Earbuds Black');
      expect(r.best!.item.key, 5);
      expect(r.level, isNot(MatchLevel.none));
    });

    test('unknown item is NEW', () {
      expect(m.match('Lenovo Tab M10 Plus 3rd Gen').level, MatchLevel.none);
    });

    test('remembered wording links instantly', () {
      final withAlias = BillItemMatcher(catalog, aliases: {
        BillItemMatcher.normalize('TG 9H A15 FULL GLUE'): 4,
      });
      final r = withAlias.match('TG 9H A15 Full Glue');
      expect(r.level, MatchLevel.matched);
      expect(r.best!.item.key, 4);
    });

    test('IMEI only for handsets, not phone accessories', () {
      expect(isHandsetCategory('Mobile Phones'), isTrue);
      expect(isHandsetCategory('Smartphones'), isTrue);
      expect(isHandsetCategory('Mobile Phone Accessories'), isFalse);
      expect(isHandsetCategory('Phone Cases'), isFalse);
      expect(
          CatalogItem.fromMap(1, {'name': 'X', 'category': 'Mobile Accessories'})
              .imeiRequired,
          isFalse);
      expect(looksLikeAccessoryName('IPHONE 20W ADAPTER TAIWAN'), isTrue);
      expect(looksLikeAccessoryName('MEIBO 300CC BORDELESS GLASS'), isTrue);
      expect(looksLikeAccessoryName('STEREO SOUND G10 IPHONE HF(6M WRNDY)'),
          isTrue);
      expect(looksLikeAccessoryName('iPhone 15 128GB Black'), isFalse);
    });

    test('normalize splits letters and numbers', () {
      expect(BillItemMatcher.normalize('128GB Type-C'), '128 gb typec');
    });
  });

  group('Vendor matching', () {
    final vendors = [
      {'key': 10, 'name': 'Supreme Telecom Distributors', 'phone': '9847012345', 'gst': '32AABCS1429B1Z8'},
      {'key': 11, 'name': 'Malabar Mobile Accessories LLP', 'phone': '', 'gst': ''},
    ];

    test('by GSTIN, phone, then name', () {
      expect(
          BillImportService.matchVendorIn(
              vendors, ExtractedBill(vendorGstin: '32AABCS1429B1Z8'))?['key'],
          10);
      expect(
          BillImportService.matchVendorIn(
              vendors, ExtractedBill(vendorPhone: '+919847012345'))?['key'],
          10);
      expect(
          BillImportService.matchVendorIn(vendors,
              ExtractedBill(vendorName: 'MALABAR MOBILE ACCESSORIES LLP'))?['key'],
          11);
      expect(
          BillImportService.matchVendorIn(
              vendors, ExtractedBill(vendorName: 'Unknown Traders')),
          isNull);
    });
  });

  group('Hand-off to purchase entry', () {
    test('linked line keeps stock key and catalog name; maths in paise', () {
      const linked = CatalogItem(
          key: 7,
          id: 'p7',
          name: 'Samsung Galaxy A15 4GB/128GB Blue',
          sellingPricePaise: 1499900,
          imeiRequired: true);
      final it = buildPurchaseItemFromLine(
        rowId: 'r1',
        description: 'SAM GAL A15 4/128 BLU',
        hsn: '85171300',
        qty: 5,
        ratePaise: 1271186,
        discountPaise: 0,
        gstPercent: 18,
        mrpPaise: 0,
        serials: const [],
        linked: linked,
      );
      expect(it.itemKey, 7);
      expect(it.name, linked.name);
      expect(it.isNewProduct, isFalse);
      expect(it.imeiRequired, isTrue);
      expect(it.purchaseRatePaise, 1271186);
      expect(it.sellingPricePaise, 1499900);
      expect(it.taxAmountPaise, 1144067); // 63,559.30 × 18 %
      expect(it.lineTotalPaise, 7499997);
      expect(it.matchStatusOverride, ProductMatchStatus.matched);
    });

    test('unlinked line is a staged new product with the bill name', () {
      final it = buildPurchaseItemFromLine(
        rowId: 'r2',
        description: 'Tempered Glass 9H A15',
        hsn: '70071900',
        qty: 20,
        ratePaise: 3500,
        discountPaise: 0,
        gstPercent: 18,
        mrpPaise: 9900,
        serials: const [],
      );
      expect(it.itemKey, isNull);
      expect(it.isNewProduct, isTrue);
      expect(it.isStagedReady, isTrue);
      expect(it.sku, ''); // HSN is never used as SKU/barcode
      expect(it.hsnCode, '70071900');
      expect(it.mrpPaise, 9900);
      expect(it.lineTotalPaise, 82600);
    });
  });
}
