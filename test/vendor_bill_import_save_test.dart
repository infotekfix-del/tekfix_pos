// End-to-end: an imported vendor bill is saved through the same
// PurchaseBillService.confirmPurchaseBill path as a manual bill, so stock,
// new items and the vendor ledger update exactly the same way.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';
import 'package:tekfix_erp_pos/auth/auth_controller.dart';
import 'package:tekfix_erp_pos/main.dart'
    show
        Db,
        boxAudit,
        boxBank,
        boxItems,
        boxParties,
        boxPurchaseBills,
        boxPurchases,
        boxReturns,
        boxSales,
        boxSettings,
        boxStockMoves,
        boxVendorPayments;
import 'package:tekfix_erp_pos/purchases/bill_import/bill_import_screen.dart';
import 'package:tekfix_erp_pos/purchases/bill_import/bill_import_service.dart';
import 'package:tekfix_erp_pos/purchases/bill_import/bill_item_matcher.dart';
import 'package:tekfix_erp_pos/purchases/bill_import/vendor_bill_parser.dart';
import 'package:tekfix_erp_pos/purchases/manual_purchase_entry_screen.dart';
import 'package:tekfix_erp_pos/purchases/purchase_bill_service.dart';
import 'package:tekfix_erp_pos/purchases/purchase_models.dart';

const _billText = '''
SUPREME TELECOM DISTRIBUTORS PVT LTD
GSTIN: 32AABCS1429B1Z8      Invoice No: SUP-5521      Date: 14-11-2026
Bill To: TEKFIX DIGITAL
Description              HSN        Qty    Rate        GST%   Amount
SAM GAL A15 4/128 BLU    85171300   5      12,711.86   18%    74,999.97
Tempered Glass 9H A15    70071900   20     35.00       18%    826.00
Grand Total                                                   75,825.97
''';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    tempDir = await Directory.systemTemp.createTemp('tekfix_bill_import_');
    Hive.init(tempDir.path);
    for (final b in [
      boxItems, boxParties, boxSales, boxPurchases, boxBank, boxSettings,
      boxAudit, boxStockMoves, boxReturns, boxPurchaseBills, boxVendorPayments,
    ]) {
      await Hive.openBox(b);
    }
    await Hive.box(boxSettings).put('store_state_code', '32');
    await Hive.box(boxSettings).put('shop_id', 'test_shop');
  });

  // Hive boxes are left open (like the other purchase widget tests): the
  // inventory search engine keeps a listener, and Hive.close() would wait.
  tearDownAll(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('parse → match → save updates stock, creates new item, vendor ledger',
      () async {
    final a15Key = await Db.items.add({
      'name': 'Samsung Galaxy A15 4GB/128GB Blue',
      'sku': 'A15-4-128-BLU',
      'barcode': 'A15-4-128-BLU',
      'stock': 2,
      'costPrice': 12500.0,
      'sellingPrice': 14999.0,
      'mrp': 16999.0,
      'imeiRequired': false,
    });
    final vendorKey = await Db.parties.add({
      'name': 'Supreme Telecom Distributors',
      'phone': '9847012345',
      'gst': '32AABCS1429B1Z8',
      'type': 'Supplier',
      'balance': 0.0,
    });

    final bill = const VendorBillParser(ownNames: ['TEKFIX'])
        .parseText(_billText);
    expect(bill.lines.length, 2);
    expect(bill.grandTotalPaise, 7582597);

    // Vendor and items are matched against the real (Hive) data.
    final vendor = BillImportService.instance.matchVendor(bill);
    expect(vendor?['key'], vendorKey);
    final matcher = BillImportService.instance.buildMatcher();
    final m0 = matcher.match(bill.lines[0].description, hsn: bill.lines[0].hsn);
    final m1 = matcher.match(bill.lines[1].description);
    expect(m0.best?.item.key, a15Key);
    expect(m1.level, MatchLevel.none);

    final items = [
      for (var i = 0; i < bill.lines.length; i++)
        buildPurchaseItemFromLine(
          rowId: 'r$i',
          description: bill.lines[i].description,
          hsn: bill.lines[i].hsn,
          qty: bill.lines[i].quantity,
          ratePaise: bill.lines[i].ratePaise,
          discountPaise: bill.lines[i].discountPaise,
          gstPercent: bill.lines[i].gstPercent,
          mrpPaise: bill.lines[i].mrpPaise,
          serials: bill.lines[i].serials,
          linked: i == 0 ? m0.best!.item : null,
        ),
    ];

    final saved = await PurchaseBillService.instance.confirmPurchaseBill(
      billNumber: 'PB/IMP/001',
      vendorInvoiceNumber: bill.billNumber!,
      vendorKey: vendorKey,
      vendorName: vendor!['name'],
      vendorPhone: vendor['phone'],
      vendorGst: vendor['gst'],
      purchaseDate: bill.billDate!,
      items: items,
      initialPaidAmount: 25000.0,
      initialPaymentMethod: 'Cash',
      staffId: 'T1',
      staffName: 'Owner',
      invoiceExtractedTotal: bill.grandTotalPaise! / 100,
      entrySource: EntrySource.billUpload,
    );

    // Same totals as the bill (paise)
    expect(saved.grandTotalPaise, 7582597);
    expect(saved.entrySource, EntrySource.billUpload);
    expect(saved.vendorInvoiceNumber, 'SUP-5521');

    // Linked item: stock 2 + 5
    final a15 = Db.items.get(a15Key) as Map;
    expect(a15['stock'], 7);
    expect(a15['costPrice'], 12711.86);

    // New item created with the bill's name and qty
    final glass = Db.items.values
        .whereType<Map>()
        .firstWhere((m) => m['name'] == 'Tempered Glass 9H A15');
    expect(glass['stock'], 20);
    expect(glass['barcode'], isNot('70071900')); // HSN never becomes barcode

    // Vendor ledger: grand total − paid
    final bal = await PurchaseBillService.instance
        .fetchVendorBalancePaise(vendorKey);
    expect(bal, 7582597 - 2500000);
  });

  test('remembered wording is stored in settings and reused', () async {
    final key = await Db.items.add({'name': 'boAt Airdopes 141', 'stock': 0});
    await BillImportService.instance.rememberAliases({
      BillItemMatcher.normalize('BOAT AD 141 TWS BLK'): key,
    });
    final r = BillImportService.instance
        .buildMatcher()
        .match('Boat AD 141 TWS Blk');
    expect(r.level, MatchLevel.matched);
    expect(r.best!.item.key, key);
  });

  for (final size in const [Size(1400, 900), Size(390, 844)]) {
    testWidgets('Review screen renders the PDF bill at ${size.width.toInt()}px',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final prevOnError = FlutterError.onError;
      FlutterError.onError = (d) {
        debugPrint('FLUTTER_ERR ${d.toString()}');
        prevOnError?.call(d);
      };
      addTearDown(() => FlutterError.onError = prevOnError);
      final bytes =
          File('test/fixtures/bill_import/browser_style_bill.pdf')
              .readAsBytesSync();
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: BillImportScreen(
            initialBytes: bytes, initialFileName: 'browser_style_bill.pdf'),
      ));
      await tester.pump();
      // PDF parsing runs in an isolate (compute) → needs real time.
      for (var i = 0; i < 20 && find.text('Continue (തുടരുക)').evaluate().isEmpty; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 250)));
        await tester.pump();
      }
      expect(find.text('Continue (തുടരുക)'), findsOneWidget);
      expect(find.text('Malabar Mobile Accessories LLP'), findsOneWidget);
      expect(find.textContaining('NEW (പുതിയത്)'), findsWidgets);
      expect(
          find.textContaining('Add as new item (പുതിയ ഐറ്റം ചേർക്കുക)'),
          findsWidgets);
      final ex = tester.takeException();
      if (ex != null) debugPrint('EXC: ${(ex as FlutterError).toStringDeep()}');
      expect(ex, isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('Purchase Entry opens pre-filled from an imported bill',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final imported = ImportedPurchaseBill(
      vendorName: 'Malabar Mobile Accessories LLP',
      vendorGst: '32ABCFM4321K1ZQ',
      invoiceNumber: 'MMA-2425-1187',
      invoiceDate: DateTime(2026, 11, 8),
      printedTotalPaise: 4104600,
      items: [
        buildPurchaseItemFromLine(
          rowId: 'w1',
          description: 'USB Type-C Cable 1m',
          hsn: '85444299',
          qty: 25,
          ratePaise: 5932,
          discountPaise: 0,
          gstPercent: 18,
          mrpPaise: 0,
          serials: const [],
        ),
      ],
      gstEnabled: true,
      sourceNote: 'Imported from test.pdf',
    );
    await tester.pumpWidget(MultiProvider(
      providers: [ChangeNotifierProvider.value(value: AuthController.instance)],
      child: MaterialApp(
        theme: ThemeData.dark(),
        home: ManualPurchaseEntryScreen(importedBill: imported),
      ),
    ));
    // _init reads Hive (bill number, vendors): give it real async time.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    bool hasText(String t) =>
        find.textContaining(t).evaluate().isNotEmpty ||
        find
            .byWidgetPredicate(
                (w) => w is EditableText && w.controller.text.contains(t))
            .evaluate()
            .isNotEmpty;
    expect(hasText('USB Type-C Cable 1m'), isTrue);
    expect(hasText('Imported from test.pdf'), isTrue);
    expect(hasText('MMA-2425-1187'), isTrue);
    // Dispose the screen so its timers/listeners stop before Hive closes.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
