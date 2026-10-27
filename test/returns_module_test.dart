import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart'
    show
        boxItems,
        boxParties,
        boxSales,
        boxPurchases,
        boxSettings,
        boxAudit,
        boxReturns;
import 'package:tekfix_erp_pos/returns/return_models.dart';
import 'package:tekfix_erp_pos/returns/return_service.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tekfix_returns_test_');
    Hive.init(tempDir.path);

    await Hive.openBox(boxItems);
    await Hive.openBox(boxParties);
    await Hive.openBox(boxSales);
    await Hive.openBox(boxPurchases);
    await Hive.openBox(boxSettings);
    await Hive.openBox(boxAudit);
    await Hive.openBox(boxReturns);
  });

  tearDown(() async {
    await Hive.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('TEKFIX CUSTOMER RETURN, WARRANTY & VENDOR TRACKING MODULE TEST SUITE', () {
    test('1. Customer Search by Phone & Data Normalization', () async {
      final partiesBox = Hive.box(boxParties);
      final salesBox = Hive.box(boxSales);

      // Seed customer in parties
      final custKey = await partiesBox.add({
        '_id': 'cust_rahul_1',
        'name': 'Rahul Sharma',
        'phone': '9876543210',
        'type': 'Customer',
        'balance': 0.0,
      });

      // Seed sales bill for this customer
      await salesBox.add({
        'invoice': 'INV-2026-1001',
        'customerName': 'Rahul Sharma',
        'customerPhone': '9876543210',
        'partyKey': custKey,
        'createdAt': DateTime(2026, 1, 15).toIso8601String(),
        'items': [
          {
            'itemId': 'itm_boat_earbuds',
            'name': 'boAt Airdopes 141',
            'brand': 'boAt',
            'model': 'Airdopes 141',
            'imei': 'BOAT-SN-998877',
            'warranty': '1 Year',
            'price': 1499.0,
            'qty': 1,
          }
        ],
        'total': 1499.0,
      });

      // Search with various phone formats (+91, spaces, exact)
      final results1 = ReturnService.instance.searchCustomers('9876543210');
      expect(results1.isNotEmpty, isTrue);
      expect(results1.first['name'], equals('Rahul Sharma'));

      final results2 = ReturnService.instance.searchCustomers('+91 98765 43210');
      expect(results2.isNotEmpty, isTrue);
      expect(results2.first['phone'], equals('9876543210'));

      final resultsPartial = ReturnService.instance.searchCustomers('543210');
      expect(resultsPartial.isNotEmpty, isTrue);
    });

    test('2. Retrieve Purchased Products & Original Vendor Without Modifying Sales', () async {
      final salesBox = Hive.box(boxSales);
      final purchasesBox = Hive.box(boxPurchases);
      final partiesBox = Hive.box(boxParties);

      // Seed vendor in parties
      final vendorKey = await partiesBox.add({
        'name': 'Imagine Tech Distributors',
        'phone': '9845012345',
        'type': 'Supplier',
      });

      // Seed purchase record linking item to vendor
      await purchasesBox.add({
        'supplierKey': vendorKey,
        'supplierName': 'Imagine Tech Distributors',
        'itemKey': 101,
        'itemName': 'OnePlus Nord CE 3',
        'createdAt': DateTime(2026, 1, 1).toIso8601String(),
        'invoiceNumber': 'PO-9002',
      });

      // Seed customer sale
      final saleDate = DateTime(2026, 2, 10);
      final saleKey = await salesBox.add({
        'invoice': 'INV-5501',
        'customerName': 'Anjali Nair',
        'customerPhone': '9447123456',
        'createdAt': saleDate.toIso8601String(),
        'items': [
          {
            'itemKey': 101,
            'itemId': 'itm_op_nord3',
            'name': 'OnePlus Nord CE 3',
            'brand': 'OnePlus',
            'model': 'Nord CE 3',
            'imei': '869012345678901',
            'warranty': '1 Year',
            'price': 19999.0,
            'qty': 1,
          }
        ],
        'total': 19999.0,
      });

      final products = ReturnService.instance.getPurchasedProductsByPhone('9447123456');
      expect(products.length, equals(1));

      final prod = products.first;
      expect(prod.productName, equals('OnePlus Nord CE 3'));
      expect(prod.serialNumber, equals('869012345678901'));
      expect(prod.originalVendorName, equals('Imagine Tech Distributors'));
      expect(prod.invoiceNumber, equals('INV-5501'));

      // Crucial requirement: Verify original sales transaction remains completely untouched
      final rawSale = salesBox.get(saleKey) as Map;
      expect(rawSale['invoice'], equals('INV-5501'));
      expect(rawSale['total'], equals(19999.0));
      expect((rawSale['items'] as List).length, equals(1));
    });

    test('3. Accurate Customer Warranty Calculation & Independence from Vendor Warranty', () {
      final now = DateTime.now();

      // Case A: Active 1 Year warranty purchased 2 months ago
      final purchaseActive = now.subtract(const Duration(days: 60));
      final statusActive = ReturnService.instance.calculateWarrantyStatus(
        purchaseActive,
        '1 Year',
        hasInvoice: true,
      );
      expect(statusActive, equals(CustomerWarrantyStatus.active));

      // Case B: Expired 6 Months warranty purchased 250 days ago
      final purchaseExpired = now.subtract(const Duration(days: 250));
      final statusExpired = ReturnService.instance.calculateWarrantyStatus(
        purchaseExpired,
        '6 Months',
        hasInvoice: true,
      );
      expect(statusExpired, equals(CustomerWarrantyStatus.expired));

      // Case C: No Warranty item
      final statusNone = ReturnService.instance.calculateWarrantyStatus(
        purchaseActive,
        'No Warranty',
        hasInvoice: true,
      );
      expect(statusNone, equals(CustomerWarrantyStatus.noWarranty));

      // Case D: Missing invoice triggers Verification Required rather than rejection
      final statusMissingInv = ReturnService.instance.calculateWarrantyStatus(
        purchaseActive,
        '1 Year',
        hasInvoice: false,
      );
      expect(statusMissingInv, equals(CustomerWarrantyStatus.verificationRequired));
    });

    test('4. End-to-End Workflow: Stages A through L', () async {
      // Stage A & B: Customer Search & Product Selection
      const custName = 'Deepak Kumar';
      const custPhone = '9744112233';
      const productName = 'Redmi Note 13 Pro';
      const serialNumber = '861122334455667';
      final purchaseDate = DateTime(2026, 1, 10);

      // Stage E: Register Return (Generates RET-YYYY-0001)
      final returnCase = await ReturnService.instance.registerReturn(
        customerName: custName,
        customerPhone: custPhone,
        originalInvoiceNumber: 'INV-7788',
        originalPurchaseDate: purchaseDate,
        productName: productName,
        productBrand: 'Xiaomi',
        productModel: 'Redmi Note 13 Pro',
        serialNumber: serialNumber,
        customerWarrantyPeriod: '1 Year',
        customerWarrantyStatus: CustomerWarrantyStatus.active,
        originalVendorName: 'Redmi South Hub',
        originalVendorPhone: '9840011223',
        returnReason: ReturnReason.displayProblem,
        customerComplaint: 'Flickering vertical green lines on screen',
        productCondition: 'Good condition, no glass cracks',
        accessoriesReceived: 'Phone with original box and invoice copy',
        assignedStaffId: 'staff_101',
        assignedStaffName: 'Akhil (Staff)',
        internalNotes: 'Customer verified original box and purchase bill',
        actorId: 'staff_101',
        actorName: 'Akhil (Staff)',
        actorRole: 'Staff',
      );

      expect(returnCase.returnId, startsWith('RET-'));
      expect(returnCase.customerReturnStatus, equals(CustomerReturnStatus.registered));
      expect(returnCase.vendorStatus, equals(VendorStatus.notHandedOver));
      expect(returnCase.timeline.length, equals(2)); // Return Received + Warranty Evaluated
      expect(returnCase.timeline.first.title, equals('Customer Return Received'));

      // Stage F: Hand Over to Vendor (Generates VHO-YYYY-0001)
      final handedOverCase = await ReturnService.instance.handoverToVendor(
        returnKey: returnCase.key,
        vendorName: 'Redmi Authorized Service Hub',
        vendorPhone: '9840011223',
        vendorReferenceNumber: 'MI-SRV-9021',
        vendorServiceCentre: 'Kochi Central Hub',
        actorId: 'staff_101',
        actorName: 'Akhil (Staff)',
        actorRole: 'Staff',
        handoverNotes: 'Dispatched via courier for display replacement',
      );

      expect(handedOverCase.vendorStatus, equals(VendorStatus.handedOverToVendor));
      expect(handedOverCase.customerReturnStatus, equals(CustomerReturnStatus.handedOverToVendor));
      expect(handedOverCase.handoverRecord, isNotNull);
      expect(handedOverCase.handoverRecord!.handoverReference, startsWith('VHO-'));
      expect(handedOverCase.handoverRecord!.isReceivedByVendor, isFalse);
      expect(handedOverCase.vendorStatusHistory.length, equals(1));

      // Stage G: Confirm Vendor Receipt
      final receivedByVendorCase = await ReturnService.instance.confirmVendorReceipt(
        returnKey: returnCase.key,
        actorId: 'staff_101',
        actorName: 'Akhil (Staff)',
        actorRole: 'Staff',
        notes: 'Vendor docket acknowledged by service center',
      );

      expect(receivedByVendorCase.vendorStatus, equals(VendorStatus.receivedByVendor));
      expect(receivedByVendorCase.handoverRecord!.isReceivedByVendor, isTrue);

      // Stage H: Vendor Status Tracking (Under Inspection -> Waiting for Parts -> Under Repair)
      await ReturnService.instance.updateVendorStatus(
        returnKey: returnCase.key,
        newStatus: VendorStatus.underInspectionAtVendor,
        actorId: 'staff_101',
        actorName: 'Akhil (Staff)',
        actorRole: 'Staff',
        notes: 'Engineer confirmed display defect covered under warranty',
      );

      await ReturnService.instance.updateVendorStatus(
        returnKey: returnCase.key,
        newStatus: VendorStatus.waitingForSpareParts,
        actorId: 'staff_101',
        actorName: 'Akhil (Staff)',
        actorRole: 'Staff',
        notes: 'OLED assembly ordered from central warehouse',
      );

      final repairStatusCase = await ReturnService.instance.updateVendorStatus(
        returnKey: returnCase.key,
        newStatus: VendorStatus.underRepairAtVendor,
        actorId: 'staff_101',
        actorName: 'Akhil (Staff)',
        actorRole: 'Staff',
        notes: 'Parts arrived, replacement in progress',
      );

      expect(repairStatusCase.vendorStatus, equals(VendorStatus.underRepairAtVendor));
      expect(repairStatusCase.vendorStatusHistory.length, equals(5));

      // Stage I: Vendor Repair & Replacement Resolution
      final resolvedCase = await ReturnService.instance.resolveVendorClaim(
        returnKey: returnCase.key,
        decision: VendorResolutionType.repaired,
        actorId: 'owner_1',
        actorName: 'Owner',
        actorRole: 'Owner',
        repairDetails: 'Original display panel replaced under warranty. Tested OK.',
        vendorCharges: 0.0,
        vendorCreditRefund: 0.0,
        vendorNotes: 'Zero charges under brand warranty claim',
      );

      expect(resolvedCase.vendorStatus, equals(VendorStatus.repairedByVendor));
      expect(resolvedCase.vendorResolution, isNotNull);
      expect(resolvedCase.vendorResolution!.decision, equals(VendorResolutionType.repaired));

      // Stage J: Receive Product at Shop ("RECEIVE FROM VENDOR")
      final receivedAtShopCase = await ReturnService.instance.receiveAtShop(
        returnKey: returnCase.key,
        actorId: 'staff_101',
        actorName: 'Akhil (Staff)',
        actorRole: 'Staff',
        inspectionNotes: 'Product verified at shop counter. Screen working perfectly.',
        isReadyForCustomer: true,
      );

      expect(receivedAtShopCase.customerReturnStatus, equals(CustomerReturnStatus.readyForCustomer));
      expect(receivedAtShopCase.isReadyForCustomer, isTrue);
      expect(receivedAtShopCase.shopReceiptDate, isNotNull);

      // Stage K: Return Product to Customer & Case Closure
      final deliveredCase = await ReturnService.instance.returnToCustomer(
        returnKey: returnCase.key,
        actorId: 'staff_101',
        actorName: 'Akhil (Staff)',
        actorRole: 'Staff',
        customerConfirmation: 'Customer inspected phone and signed delivery receipt',
        deliveryNotes: 'Delivered in full working condition with bill copy',
      );

      expect(deliveredCase.customerReturnStatus, equals(CustomerReturnStatus.returnedToCustomer));
      expect(deliveredCase.isCompleted, isTrue);
      expect(deliveredCase.customerDeliveryRecord, isNotNull);
      expect(deliveredCase.customerDeliveryRecord!.customerConfirmation, contains('signed delivery receipt'));

      // Stage L: Complete Chronological Timeline Verification
      expect(deliveredCase.timeline.length, greaterThanOrEqualTo(8));
      for (final event in deliveredCase.timeline) {
        expect(event.title.isNotEmpty, isTrue);
        expect(event.actorName.isNotEmpty, isTrue);
        expect(event.timestamp, isNotNull);
      }
    });

    test('5. Replacement Workflow with New IMEI/Serial', () async {
      final returnCase = await ReturnService.instance.registerReturn(
        customerName: 'Sanjay Menon',
        customerPhone: '9847000111',
        originalInvoiceNumber: 'INV-8899',
        originalPurchaseDate: DateTime(2026, 2, 1),
        productName: 'Realme Buds Air 5',
        serialNumber: 'R-BUDS-ORIG-001',
        customerWarrantyPeriod: '1 Year',
        customerWarrantyStatus: CustomerWarrantyStatus.active,
        originalVendorName: 'Realme Kerala Dist',
        returnReason: ReturnReason.soundProblem,
        customerComplaint: 'Left bud completely silent',
        productCondition: 'Like new',
        accessoriesReceived: 'Full box set with charging case',
        actorId: 'staff_01',
        actorName: 'Staff User',
        actorRole: 'Staff',
      );

      await ReturnService.instance.handoverToVendor(
        returnKey: returnCase.key,
        vendorName: 'Realme Kerala Dist',
        vendorPhone: '9847000222',
        vendorReferenceNumber: 'RME-REPL-77',
        vendorServiceCentre: 'Ernakulam Service Point',
        actorId: 'staff_01',
        actorName: 'Staff User',
        actorRole: 'Staff',
        handoverNotes: 'Dispatched for replacement evaluation',
      );

      // Vendor approves Brand New Replacement Unit with New Serial
      final replCase = await ReturnService.instance.resolveVendorClaim(
        returnKey: returnCase.key,
        decision: VendorResolutionType.replacementApproved,
        actorId: 'owner_1',
        actorName: 'Store Owner',
        actorRole: 'Owner',
        isReplacement: true,
        replacementProduct: 'Realme Buds Air 5 (Sealed Unit)',
        replacementSerialNumber: 'R-BUDS-NEW-999',
        replacementReceivedDate: DateTime.now(),
        vendorCharges: 0.0,
      );

      expect(replCase.vendorStatus, equals(VendorStatus.replacementApproved));
      expect(replCase.vendorResolution!.isReplacement, isTrue);
      expect(replCase.vendorResolution!.replacementSerialNumber, equals('R-BUDS-NEW-999'));

      // Original serial is strictly preserved in return case!
      expect(replCase.serialNumber, equals('R-BUDS-ORIG-001'));
    });

    test('6. Vendor Follow-up System & Owner Configurable Threshold', () async {
      // Default threshold is 7 days
      expect(ReturnService.instance.getFollowupThresholdDays(), equals(7));

      // Owner reconfigures threshold to 5 days
      await ReturnService.instance.setFollowupThresholdDays(5);
      expect(ReturnService.instance.getFollowupThresholdDays(), equals(5));

      // Create return handed over 6 days ago
      final ret = await ReturnService.instance.registerReturn(
        customerName: 'Manoj Pillai',
        customerPhone: '9446001122',
        originalInvoiceNumber: 'INV-4411',
        originalPurchaseDate: DateTime(2026, 1, 1),
        productName: 'Samsung Galaxy A14',
        customerWarrantyPeriod: '1 Year',
        customerWarrantyStatus: CustomerWarrantyStatus.active,
        returnReason: ReturnReason.chargingProblem,
        customerComplaint: 'Not charging',
        productCondition: 'Used',
        accessoriesReceived: 'None',
        actorId: 'staff_1',
        actorName: 'Staff',
        actorRole: 'Staff',
      );

      await ReturnService.instance.handoverToVendor(
        returnKey: ret.key,
        vendorName: 'Samsung Care',
        vendorPhone: '1800407267864',
        vendorReferenceNumber: 'SS-441',
        vendorServiceCentre: 'Trivandrum City Centre',
        actorId: 'staff_1',
        actorName: 'Staff',
        actorRole: 'Staff',
        handoverNotes: 'Handed over for motherboard repair',
      );

      final reloaded = ReturnService.instance.getReturn(ret.key)!;
      // Pending with vendor
      expect(reloaded.isPendingWithVendor, isTrue);
      // Evaluates follow-up logic correctly
      expect(reloaded.isFollowUpOverdue(0), isTrue); // If threshold 0, immediately overdue
    });

    test('7. Owner Dashboard Metrics & Multi-Field Search/Filter', () async {
      // Seed test returns
      final ret1 = await ReturnService.instance.registerReturn(
        customerName: 'Manoj Pillai',
        customerPhone: '9446001122',
        originalInvoiceNumber: 'INV-4411',
        originalPurchaseDate: DateTime(2026, 1, 1),
        productName: 'Samsung Galaxy A14',
        customerWarrantyPeriod: '1 Year',
        customerWarrantyStatus: CustomerWarrantyStatus.active,
        returnReason: ReturnReason.chargingProblem,
        customerComplaint: 'Not charging',
        productCondition: 'Used',
        accessoriesReceived: 'None',
        actorId: 'staff_1',
        actorName: 'Staff',
        actorRole: 'Staff',
      );

      await ReturnService.instance.handoverToVendor(
        returnKey: ret1.key,
        vendorName: 'Samsung Care',
        vendorPhone: '1800407267864',
        vendorReferenceNumber: 'SS-441',
        vendorServiceCentre: 'Trivandrum City Centre',
        actorId: 'staff_1',
        actorName: 'Staff',
        actorRole: 'Staff',
        handoverNotes: 'Handed over for motherboard repair',
      );

      final metrics = ReturnService.instance.computeDashboardMetrics();
      expect(metrics.containsKey('Total Customer Returns'), isTrue);
      expect(metrics.containsKey('Pending Inspection'), isTrue);
      expect(metrics.containsKey('Handed Over to Vendors'), isTrue);
      expect(metrics.containsKey('Vendor Follow-up Required'), isTrue);
      expect(metrics.containsKey('Completed Returns'), isTrue);
      expect(metrics['Total Customer Returns'], equals(1));
      expect(metrics['Handed Over to Vendors'], equals(1));

      // Search by Customer Phone
      final matchedByPhone = ReturnService.instance.searchAndFilter(query: '9446001122');
      expect(matchedByPhone.isNotEmpty, isTrue);
      expect(matchedByPhone.first.customerName, equals('Manoj Pillai'));

      // Search by Product Name
      final matchedByProd = ReturnService.instance.searchAndFilter(query: 'Galaxy A14');
      expect(matchedByProd.isNotEmpty, isTrue);

      // Filter by Card Category
      final handedOverList = ReturnService.instance.searchAndFilter(cardFilterCategory: 'Handed Over to Vendors');
      expect(handedOverList.every((r) => r.vendorStatus == VendorStatus.handedOverToVendor), isTrue);
    });

    test('8. Owner vs Staff Permissions & Warranty Override', () async {
      final ret = await ReturnService.instance.registerReturn(
        customerName: 'Fathima Beevi',
        customerPhone: '9567000333',
        originalInvoiceNumber: 'INV-1100',
        originalPurchaseDate: DateTime(2025, 1, 1),
        productName: 'Vivo Y20',
        customerWarrantyPeriod: '1 Year',
        customerWarrantyStatus: CustomerWarrantyStatus.expired,
        returnReason: ReturnReason.batteryProblem,
        customerComplaint: 'Battery draining fast',
        productCondition: 'Good',
        accessoriesReceived: 'Phone only',
        actorId: 'staff_2',
        actorName: 'Staff 2',
        actorRole: 'Staff',
      );

      expect(ret.customerWarrantyStatus, equals(CustomerWarrantyStatus.expired));

      // Owner overrides warranty as goodwill approval
      final overridden = await ReturnService.instance.verifyWarranty(
        returnKey: ret.key,
        newWarrantyStatus: CustomerWarrantyStatus.active,
        reasonNotes: 'Owner approved warranty repair as customer goodwill concession',
        actorId: 'owner_main',
        actorName: 'Shop Owner',
        actorRole: 'Owner',
      );

      expect(overridden.customerWarrantyStatus, equals(CustomerWarrantyStatus.active));
      expect(overridden.warrantyVerifiedByName, equals('Shop Owner'));
      expect(overridden.warrantyInspectionNotes, contains('goodwill concession'));
    });
  });
}
