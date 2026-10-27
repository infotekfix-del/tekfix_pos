import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart'
    show
        boxItems,
        boxParties,
        boxSales,
        boxPurchases,
        boxBank,
        boxSettings,
        boxAudit,
        boxReturns,
        boxStockMoves,
        boxPurchaseBills,
        boxVendorPayments;
import 'package:tekfix_erp_pos/purchases/purchase_bill_service.dart';
import 'package:tekfix_erp_pos/purchases/purchase_models.dart';
import 'package:tekfix_erp_pos/returns/return_service.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir =
        await Directory.systemTemp.createTemp('tekfix_purchase_bills_test_');
    Hive.init(tempDir.path);

    await Hive.openBox(boxItems);
    await Hive.openBox(boxParties);
    await Hive.openBox(boxSales);
    await Hive.openBox(boxPurchases);
    await Hive.openBox(boxBank);
    await Hive.openBox(boxSettings);
    await Hive.openBox(boxAudit);
    await Hive.openBox(boxStockMoves);
    await Hive.openBox(boxReturns);
    await Hive.openBox(boxPurchaseBills);
    await Hive.openBox(boxVendorPayments);
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('TEKFIX PURCHASE BILL UPLOAD & VENDOR PAYMENT MODULE TEST SUITE', () {
    test('1. Vendor Management: Creation, Auto-Select & Duplicate Prevention',
        () async {
      final service = PurchaseBillService.instance;

      // Create first vendor
      final vendor1 = await service.addNewVendor(
        name: 'ABC Mobile Distributors',
        phone: '9876543210',
        address: '123 Market Road, Kochi',
        gst: '32AAAAA0000A1Z5',
        notes: '30-day payment term',
      );

      expect(vendor1['name'], equals('ABC Mobile Distributors'));
      expect(vendor1['phone'], equals('9876543210'));
      expect(vendor1['key'], isNotNull);

      // Verify vendor retrieved
      final vendors = service.getVendors();
      expect(vendors.length, equals(1));
      expect(vendors.first['name'], equals('ABC Mobile Distributors'));

      // Duplicate prevention by name
      expect(
        () => service.addNewVendor(
          name: 'ABC Mobile Distributors',
          phone: '9123456789',
        ),
        throwsA(isA<Exception>()),
      );

      // Duplicate prevention by phone
      expect(
        () => service.addNewVendor(
          name: 'XYZ Cellular',
          phone: '9876543210',
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('2. Sequential ID Generation for Bills and Payments', () async {
      final service = PurchaseBillService.instance;

      final billId1 = await service.generateBillNumber();
      final billId2 = await service.generateBillNumber();
      expect(billId1, startsWith('PB-${DateTime.now().year}-'));
      expect(billId2, startsWith('PB-${DateTime.now().year}-'));
      expect(billId1 != billId2, isTrue);

      final payId1 = await service.generatePaymentId();
      final payId2 = await service.generatePaymentId();
      expect(payId1, startsWith('PAY-${DateTime.now().year}-'));
      expect(payId2, startsWith('PAY-${DateTime.now().year}-'));
      expect(payId1 != payId2, isTrue);
    });

    test('3. Warranty Expiry Date Calculations per Duration Option', () {
      final service = PurchaseBillService.instance;
      final purchaseDate = DateTime(2026, 1, 15);

      // 3 Months
      final exp3m = service.calculateItemWarrantyExpiry(
          purchaseDate, ItemWarrantyDuration.threeMonths);
      expect(exp3m, equals(DateTime(2026, 4, 15)));

      // 6 Months
      final exp6m = service.calculateItemWarrantyExpiry(
          purchaseDate, ItemWarrantyDuration.sixMonths);
      expect(exp6m, equals(DateTime(2026, 7, 15)));

      // 12 Months
      final exp12m = service.calculateItemWarrantyExpiry(
          purchaseDate, ItemWarrantyDuration.twelveMonths);
      expect(exp12m, equals(DateTime(2027, 1, 15)));

      // 24 Months
      final exp24m = service.calculateItemWarrantyExpiry(
          purchaseDate, ItemWarrantyDuration.twentyFourMonths);
      expect(exp24m, equals(DateTime(2028, 1, 15)));

      // Custom Days (e.g. 45 days)
      final expCustom = service.calculateItemWarrantyExpiry(
        purchaseDate,
        ItemWarrantyDuration.custom,
        customDays: 45,
      );
      expect(expCustom, equals(purchaseDate.add(const Duration(days: 45))));

      // No Warranty
      final expNone = service.calculateItemWarrantyExpiry(
          purchaseDate, ItemWarrantyDuration.noWarranty);
      expect(expNone, isNull);
    });

    test('4. Bill Attachment Support: Images & PDFs with Metadata', () {
      final imgAttachment = BillAttachment(
        fileName: 'vendor_invoice_1001.jpg',
        fileType: 'image/jpeg',
        fileSizeBytes: 2048576, // 2MB
        fileBytesBase64: 'base64testimagebytes==',
        filePath: '/tmp/vendor_invoice_1001.jpg',
        uploadedAt: DateTime(2026, 1, 15, 10, 30),
      );

      expect(imgAttachment.isPdf, isFalse);
      expect(imgAttachment.formattedSize, equals('2.0 MB'));

      final pdfAttachment = BillAttachment(
        fileName: 'tax_invoice_2026.pdf',
        fileType: 'application/pdf',
        fileSizeBytes: 512000, // 500KB
        fileBytesBase64: 'base64testpdfbytes==',
        uploadedAt: DateTime(2026, 1, 15, 11, 00),
      );

      expect(pdfAttachment.isPdf, isTrue);
      expect(pdfAttachment.formattedSize, equals('500 KB'));

      final map = pdfAttachment.toMap();
      final revived = BillAttachment.fromMap(map);
      expect(revived.fileName, equals('tax_invoice_2026.pdf'));
      expect(revived.isPdf, isTrue);
    });

    test(
        '5. Accurate Decimal Purchase Calculations (Subtotal, Tax, Discount, Charges, Grand Total)',
        () {
      // Product A: 10 units @ ₹1,500 = ₹15,000, Discount = ₹500, Tax = 18%
      // Taxable = 14,500, Tax = 2,610, Line Total = 17,110
      final itemA = PurchaseBillItem(
        itemName: 'Fast Charger 65W',
        quantity: 10,
        purchaseRate: 1500.0,
        discount: 500.0,
        taxPercent: 18.0,
      );
      expect(itemA.taxAmount, equals(2610.0));
      expect(itemA.lineTotal, equals(17110.0));

      // Product B: 5 units @ ₹1,000 = ₹5,000, Discount = ₹0, Tax = 0%
      final itemB = PurchaseBillItem(
        itemName: 'Tempered Glass Pack',
        quantity: 5,
        purchaseRate: 1000.0,
        discount: 0.0,
        taxPercent: 0.0,
      );
      expect(itemB.taxAmount, equals(0.0));
      expect(itemB.lineTotal, equals(5000.0));

      // Combined calculation
      final subtotal = (10 * 1500.0) + (5 * 1000.0); // 20,000
      final totalDiscount = 500.0;
      final totalTax = 2610.0;
      final otherCharges = 200.0;
      final grandTotal = subtotal - totalDiscount + totalTax + otherCharges; // 22,310.0

      expect(grandTotal, equals(22310.0));
    });

    test(
        '6. Complete Purchase Bill Save: Inventory Increments, Stock Movement, Ledger Update & Legacy Mirror',
        () async {
      final service = PurchaseBillService.instance;
      final itemsBox = Hive.box(boxItems);

      // 1. Seed existing product in catalog
      final prodKey = await itemsBox.add({
        'name': 'Samsung Galaxy S24 Ultra Screen',
        'brand': 'Samsung',
        'model': 'S24 Ultra',
        'category': 'Spare Parts',
        'code': 'SP-SAM-S24U',
        'cost': 12000.0,
        'price': 16000.0,
        'stock': 3,
      });

      // 2. Seed vendor
      final vendor = await service.addNewVendor(
        name: 'Prime Electronics Hub',
        phone: '9845012345',
        address: 'MG Road, Ernakulam',
      );

      // 3. Create purchase bill items (with per-item warranty!)
      final purchaseDate = DateTime(2026, 2, 10, 14, 0);
      final items = [
        PurchaseBillItem(
          itemKey: prodKey,
          itemName: 'Samsung Galaxy S24 Ultra Screen',
          brand: 'Samsung',
          model: 'S24 Ultra',
          productCode: 'SP-SAM-S24U',
          imeiOrSerial: 'SCR-9988221',
          quantity: 5,
          purchaseRate: 12000.0,
          discount: 1000.0,
          taxPercent: 18.0,
          hasWarranty: true,
          warrantyDuration: ItemWarrantyDuration.sixMonths,
          warrantyExpiryDate: service.calculateItemWarrantyExpiry(
              purchaseDate, ItemWarrantyDuration.sixMonths),
        ),
      ];

      // 4. Save purchase bill with initial partial payment of ₹25,000
      final bill = await service.savePurchaseBill(
        vendorInvoiceNumber: 'INV-PRIME-889',
        vendorKey: vendor['key'],
        vendorName: vendor['name'],
        vendorPhone: vendor['phone'],
        purchaseDate: purchaseDate,
        items: items,
        otherCharges: 500.0,
        initialPaidAmount: 25000.0,
        initialPaymentMethod: 'UPI',
        initialPaymentReference: 'UPI-TXN-778899',
        staffId: 'staff_1',
        staffName: 'Arun Kumar',
      );

      expect(bill.billNumber, startsWith('PB-2026-'));
      expect(bill.grandTotal, equals(70120.0)); // (60000 - 1000) * 1.18 + 500
      expect(bill.paidAmount, equals(25000.0));
      expect(bill.balanceDue, equals(45120.0));
      expect(bill.paymentStatus, equals(BillPaymentStatus.partiallyPaid));

      // Verify Inventory Updated in Db.items
      final updatedProd = itemsBox.get(prodKey) as Map;
      expect(updatedProd['stock'], equals(8)); // 3 + 5 = 8
      expect(updatedProd['costPrice'], equals(12000.0));

      // Verify Stock Movement Logged in Db.stockMoves
      final movesBox = Hive.box(boxStockMoves);
      expect(movesBox.isNotEmpty, isTrue);

      // Verify Vendor Balance in Db.parties:
      // Unpaid balance = ₹45,120. Supplier balance is negative: -45,120
      final outstanding = service.getVendorOutstandingBalance(vendor['key']);
      expect(outstanding, equals(45120.0));

      // Verify Legacy purchases box mirrored
      final legacyBox = Hive.box(boxPurchases);
      expect(legacyBox.isNotEmpty, isTrue);
      final legacyEntry = legacyBox.values.first as Map;
      expect(legacyEntry['purchaseBillNumber'], equals(bill.billNumber));
      expect(legacyEntry['warranty'], equals(ItemWarrantyDuration.sixMonths));
    });

    test('7. Duplicate Vendor Invoice Warning Detection', () async {
      final service = PurchaseBillService.instance;
      final vendor = await service.addNewVendor(
        name: 'Super Display Distributors',
        phone: '9789012345',
      );

      // Save first bill with invoice 'BILL-100'
      await service.savePurchaseBill(
        vendorInvoiceNumber: 'BILL-100',
        vendorKey: vendor['key'],
        vendorName: vendor['name'],
        vendorPhone: vendor['phone'],
        purchaseDate: DateTime.now(),
        items: [
          PurchaseBillItem(
            itemName: 'AMOLED Screen',
            quantity: 2,
            purchaseRate: 3000.0,
          )
        ],
        staffId: 'staff_1',
        staffName: 'Staff User',
      );

      // Check duplicate
      final dup = service.checkDuplicateInvoice('BILL-100', vendor['key']);
      expect(dup, isNotNull);
      expect(dup!.vendorInvoiceNumber, equals('BILL-100'));

      // Different invoice should not trigger duplicate
      final noDup = service.checkDuplicateInvoice('BILL-101', vendor['key']);
      expect(noDup, isNull);
    });

    test('8. Draft Purchase Bill Does Not Increase Stock or Vendor Debt',
        () async {
      final service = PurchaseBillService.instance;
      final itemsBox = Hive.box(boxItems);

      final pKey = await itemsBox.add({
        'name': 'Tempered Glass',
        'cost': 50.0,
        'stock': 10,
      });

      final vendor = await service.addNewVendor(
        name: 'Draft Vendor Traders',
        phone: '9900112233',
      );

      // Save as draft
      final draftBill = await service.savePurchaseBill(
        vendorInvoiceNumber: 'DRAFT-001',
        vendorKey: vendor['key'],
        vendorName: vendor['name'],
        vendorPhone: vendor['phone'],
        purchaseDate: DateTime.now(),
        items: [
          PurchaseBillItem(
            itemKey: pKey,
            itemName: 'Tempered Glass',
            quantity: 20,
            purchaseRate: 50.0,
          )
        ],
        staffId: 'staff_1',
        staffName: 'Staff User',
        isDraft: true,
      );

      expect(draftBill.isDraft, isTrue);
      expect(draftBill.paymentStatus, equals(BillPaymentStatus.draft));

      // Inventory must NOT change
      final prod = itemsBox.get(pKey) as Map;
      expect(prod['stock'], equals(10));

      // Vendor balance must remain 0
      final bal = service.getVendorOutstandingBalance(vendor['key']);
      expect(bal, equals(0.0));
    });

    test(
        '9. Subsequent Payments Lifecycle: Unpaid -> Partially Paid -> Fully Paid',
        () async {
      final service = PurchaseBillService.instance;

      final vendor = await service.addNewVendor(
        name: 'Metro Spares Co',
        phone: '9888877777',
      );

      // 1. Create completely unpaid bill of ₹20,000
      final bill = await service.savePurchaseBill(
        vendorInvoiceNumber: 'METRO-550',
        vendorKey: vendor['key'],
        vendorName: vendor['name'],
        vendorPhone: vendor['phone'],
        purchaseDate: DateTime(2026, 2, 1),
        items: [
          PurchaseBillItem(
            itemName: 'Laptop Battery',
            quantity: 10,
            purchaseRate: 2000.0,
          )
        ],
        initialPaidAmount: 0.0,
        staffId: 'staff_1',
        staffName: 'Staff User',
      );

      expect(bill.grandTotal, equals(20000.0));
      expect(bill.paidAmount, equals(0.0));
      expect(bill.balanceDue, equals(20000.0));
      expect(bill.paymentStatus, equals(BillPaymentStatus.unpaid));
      expect(service.getVendorOutstandingBalance(vendor['key']), equals(20000.0));

      // 2. Record First Payment: ₹5,000 (Becomes Partially Paid)
      final afterPay1 = await service.recordBillPayment(
        billKey: bill.key,
        amount: 5000.0,
        paymentDate: DateTime(2026, 2, 5),
        paymentMethod: 'Bank Transfer',
        transactionReference: 'NEFT998811',
        staffId: 'staff_1',
        staffName: 'Staff User',
      );

      expect(afterPay1.paidAmount, equals(5000.0));
      expect(afterPay1.balanceDue, equals(15000.0));
      expect(afterPay1.paymentStatus, equals(BillPaymentStatus.partiallyPaid));
      expect(service.getVendorOutstandingBalance(vendor['key']), equals(15000.0));

      // 3. Record Second Payment: ₹5,000 (Remaining ₹10,000)
      final afterPay2 = await service.recordBillPayment(
        billKey: bill.key,
        amount: 5000.0,
        paymentDate: DateTime(2026, 2, 10),
        paymentMethod: 'UPI',
        transactionReference: 'UPI-METRO-2',
        staffId: 'staff_1',
        staffName: 'Staff User',
      );

      expect(afterPay2.paidAmount, equals(10000.0));
      expect(afterPay2.balanceDue, equals(10000.0));
      expect(service.getVendorOutstandingBalance(vendor['key']), equals(10000.0));

      // 4. Record Final Payment: ₹10,000 (Becomes Fully Paid)
      final afterPay3 = await service.recordBillPayment(
        billKey: bill.key,
        amount: 10000.0,
        paymentDate: DateTime(2026, 2, 15),
        paymentMethod: 'Cash',
        transactionReference: 'CASH-REC-3',
        staffId: 'staff_1',
        staffName: 'Staff User',
      );

      expect(afterPay3.paidAmount, equals(20000.0));
      expect(afterPay3.balanceDue, equals(0.0));
      expect(afterPay3.paymentStatus, equals(BillPaymentStatus.paid));
      expect(service.getVendorOutstandingBalance(vendor['key']), equals(0.0));

      // 5. Overpayment should throw error
      expect(
        () => service.recordBillPayment(
          billKey: bill.key,
          amount: 500.0,
          paymentDate: DateTime.now(),
          paymentMethod: 'Cash',
          transactionReference: 'FAIL',
          staffId: 'staff_1',
          staffName: 'Staff User',
        ),
        throwsA(isA<Exception>()),
      );
    });

    test(
        '10. Vendor Account Ledger: Running Chronological Statement & Advance Payments',
        () async {
      final service = PurchaseBillService.instance;
      final vendor = await service.addNewVendor(
        name: 'National Chip Distributors',
        phone: '9800001111',
      );

      // Bill 1: ₹20,700 on Feb 1, paid ₹15,000, balance ₹5,700
      await service.savePurchaseBill(
        vendorInvoiceNumber: 'INV-NAT-001',
        vendorKey: vendor['key'],
        vendorName: vendor['name'],
        vendorPhone: vendor['phone'],
        purchaseDate: DateTime(2026, 2, 1),
        items: [
          PurchaseBillItem(
            itemName: 'CPU Chips',
            quantity: 1,
            purchaseRate: 20700.0,
          )
        ],
        initialPaidAmount: 15000.0,
        initialPaymentMethod: 'Bank Transfer',
        staffId: 'staff_1',
        staffName: 'Staff User',
      );

      // Bill 2: ₹10,000 on Feb 5, paid ₹4,000, balance ₹6,000
      await service.savePurchaseBill(
        vendorInvoiceNumber: 'INV-NAT-002',
        vendorKey: vendor['key'],
        vendorName: vendor['name'],
        vendorPhone: vendor['phone'],
        purchaseDate: DateTime(2026, 2, 5),
        items: [
          PurchaseBillItem(
            itemName: 'Power ICs',
            quantity: 1,
            purchaseRate: 10000.0,
          )
        ],
        initialPaidAmount: 4000.0,
        initialPaymentMethod: 'Cash',
        staffId: 'staff_1',
        staffName: 'Staff User',
      );

      // Total Outstanding must be ₹11,700 (5,700 + 6,000)
      expect(service.getVendorOutstandingBalance(vendor['key']), equals(11700.0));

      // Record Advance Payment of ₹2,000 on Feb 8
      await service.recordAdvancePayment(
        vendorKey: vendor['key'],
        vendorName: vendor['name'],
        amount: 2000.0,
        paymentDate: DateTime(2026, 2, 8),
        paymentMethod: 'UPI',
        transactionReference: 'ADV-UPI-2000',
        staffId: 'staff_1',
        staffName: 'Staff User',
      );

      // Outstanding balance is reduced to ₹9,700 (11,700 - 2,000)
      expect(service.getVendorOutstandingBalance(vendor['key']), equals(9700.0));

      // Fetch Vendor Ledger
      final ledger = service.getVendorLedger(vendor['key']);
      expect(ledger.length, equals(5)); // Bill 1, Pay 1, Bill 2, Pay 2, Advance Pay

      // Verify running balance at end of ledger is ₹9,700
      expect(ledger.first.runningBalance, equals(9700.0));
    });

    test(
        '11. Cross-Module Integration: Warranty Returns Tracing to Purchase Bill & Original Vendor',
        () async {
      final purchaseService = PurchaseBillService.instance;
      final returnService = ReturnService.instance;
      final itemsBox = Hive.box(boxItems);

      // 1. Seed Product
      final itemKey = await itemsBox.add({
        'name': 'Sony WH-1000XM5 Headphones',
        'cost': 24000.0,
        'stock': 1,
      });

      // 2. Vendor
      final vendor = await purchaseService.addNewVendor(
        name: 'Sony Official Distribution Kerala',
        phone: '9847098470',
      );

      // 3. Purchase Bill with 12-Month Warranty
      final purchaseDate = DateTime(2026, 1, 10);
      final pBill = await purchaseService.savePurchaseBill(
        vendorInvoiceNumber: 'SONY-INV-9921',
        vendorKey: vendor['key'],
        vendorName: vendor['name'],
        vendorPhone: vendor['phone'],
        purchaseDate: purchaseDate,
        items: [
          PurchaseBillItem(
            itemKey: itemKey,
            itemName: 'Sony WH-1000XM5 Headphones',
            quantity: 1,
            purchaseRate: 24000.0,
            hasWarranty: true,
            warrantyDuration: ItemWarrantyDuration.twelveMonths,
            warrantyExpiryDate: purchaseService.calculateItemWarrantyExpiry(
                purchaseDate, ItemWarrantyDuration.twelveMonths),
          ),
        ],
        staffId: 'owner_1',
        staffName: 'Store Owner',
      );

      expect(pBill.billNumber, isNotNull);

      // 4. Now Customer returns product:
      // ReturnService searches original vendor and purchase bill:
      final vendorInfo = returnService.findOriginalVendor(
        itemKey,
        'Sony WH-1000XM5 Headphones',
      );

      expect(vendorInfo, isNotNull);
      expect(vendorInfo!['vendorName'],
          equals('Sony Official Distribution Kerala'));
      expect(vendorInfo['vendorPhone'], equals('9847098470'));
      expect(vendorInfo['vendorInvoice'], equals('SONY-INV-9921'));
      expect(vendorInfo['purchaseBillNumber'], equals(pBill.billNumber));
      expect(vendorInfo['warrantyDuration'],
          equals(ItemWarrantyDuration.twelveMonths));
      expect(vendorInfo['warrantyExpiryDate'],
          equals(DateTime(2027, 1, 10)));
    });

    test('12. Dashboard Metrics KPI Calculations and Multi-Criteria Search',
        () async {
      final service = PurchaseBillService.instance;

      final vA = await service.addNewVendor(name: 'Vendor Alpha', phone: '1111');
      final vB = await service.addNewVendor(name: 'Vendor Beta', phone: '2222');

      // Bill 1: ₹10,000 paid ₹10,000 (Paid)
      await service.savePurchaseBill(
        vendorInvoiceNumber: 'VA-1',
        vendorKey: vA['key'],
        vendorName: vA['name'],
        vendorPhone: vA['phone'],
        purchaseDate: DateTime.now(),
        items: [PurchaseBillItem(itemName: 'Item A1', quantity: 1, purchaseRate: 10000.0)],
        initialPaidAmount: 10000.0,
        staffId: 's1',
        staffName: 'Staff One',
      );

      // Bill 2: ₹20,000 paid ₹5,000 (Partially Paid)
      await service.savePurchaseBill(
        vendorInvoiceNumber: 'VB-1',
        vendorKey: vB['key'],
        vendorName: vB['name'],
        vendorPhone: vB['phone'],
        purchaseDate: DateTime.now(),
        items: [PurchaseBillItem(itemName: 'Item B1', quantity: 2, purchaseRate: 10000.0)],
        initialPaidAmount: 5000.0,
        staffId: 's2',
        staffName: 'Staff Two',
      );

      // Bill 3: ₹5,000 paid ₹0 (Unpaid)
      await service.savePurchaseBill(
        vendorInvoiceNumber: 'VB-2',
        vendorKey: vB['key'],
        vendorName: vB['name'],
        vendorPhone: vB['phone'],
        purchaseDate: DateTime.now(),
        items: [PurchaseBillItem(itemName: 'Item B2', quantity: 1, purchaseRate: 5000.0)],
        initialPaidAmount: 0.0,
        staffId: 's2',
        staffName: 'Staff Two',
      );

      // Dashboard Metrics
      final metrics = service.getDashboardMetrics();
      expect(metrics['totalBills'], equals(3));
      expect(metrics['totalPurchaseValue'], equals(35000.0));
      expect(metrics['totalPaid'], equals(15000.0));
      expect(metrics['totalOutstanding'], equals(20000.0));
      expect(metrics['fullyPaidBills'], equals(1));
      expect(metrics['partiallyPaidBills'], equals(1));
      expect(metrics['unpaidBills'], equals(1));

      // Search by vendor
      final betaBills = service.searchPurchaseBills(vendorKey: vB['key']);
      expect(betaBills.length, equals(2));

      // Search by status
      final paidBills =
          service.searchPurchaseBills(status: BillPaymentStatus.paid);
      expect(paidBills.length, equals(1));
      expect(paidBills.first.vendorInvoiceNumber, equals('VA-1'));

      // Search by query text
      final queryResults = service.searchPurchaseBills(query: 'Item B2');
      expect(queryResults.length, equals(1));
      expect(queryResults.first.vendorInvoiceNumber, equals('VB-2'));
    });
  });
}
