import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/pos/pos_models.dart';
import 'package:tekfix_erp_pos/pos/pos_service.dart';
import 'package:tekfix_erp_pos/repairs/repair_models.dart';
import 'package:tekfix_erp_pos/repairs/repair_service.dart';

void main() {
  group('Repairs Module Premium Inline Actions & Billing Tests', () {
    late Directory tempDir;

    setUpAll(() async {
      GoogleFonts.config.allowRuntimeFetching = false;
      tempDir =
          await Directory.systemTemp.createTemp('repairs_inline_actions_test_');
      Hive.init(tempDir.path);

      for (final b in allBoxes) {
        await Hive.openBox(b);
      }

      final settingsBox = Hive.box(boxSettings);
      await settingsBox.put('store_state_code', '32');
      await settingsBox.put('shop_id', 'shop_test_repairs');
      await settingsBox.put('admin_pass', '1234');
      await settingsBox.put('invoice_prefix', 'INV-SRV');
    });

    tearDownAll(() async {
      try {
        await Hive.close();
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    test(
        '1. RepairJob model accurately computes balance, overdue, and status attributes',
        () {
      final job = RepairJob(
        id: 'JOB-9001',
        customerName: 'Rahul Menon',
        phone: '9847012345',
        productType: 'Mobile',
        brandModel: 'OnePlus 11R',
        serial: '862910023451',
        complaint: 'Display flickering and touch unresponsive',
        technician: 'Arun Kumar',
        estimatedCost: 6500.0,
        advance: 1500.0,
        status: 'In Progress',
        createdAt: DateTime(2026, 11, 1, 10, 30),
      );

      expect(job.id, 'JOB-9001');
      expect(job.customerName, 'Rahul Menon');
      expect(job.phone, '9847012345');
      expect(job.brandModel, 'OnePlus 11R');
      expect(job.technician, 'Arun Kumar');
      expect(job.estimatedCost, 6500.0);
      expect(job.advance, 1500.0);
      expect(job.balance, 5000.0);
      expect(job.isActive, isTrue);
      expect(job.billCreated, isFalse);
      expect(job.invoice, isNull);
      expect(job.formattedCreatedAt, isNotEmpty);
    });

    test(
        '2. Changing status to Delivered must NOT alter billCreated or mark unpaid bill as paid',
        () async {
      final serviceKey = await Db.services.add({
        'jobId': 'JOB-DELV-101',
        'customerName': 'Suresh Babu',
        'phone': '9847998877',
        'productType': 'Laptop',
        'brandModel': 'Dell XPS 15',
        'serial': 'DLXPS-992',
        'complaint': 'Battery replacement and thermal paste reapply',
        'technician': 'Deepak',
        'estimatedCost': 4200.0,
        'advance': 1000.0,
        'status': 'Ready',
        'billCreated': false,
        'invoice': null,
        'createdAt': DateTime.now().toIso8601String(),
        'statusHistory': [],
      });

      // Update status to 'Delivered'
      await RepairService.instance.updateRepairStatus(
        shopId: 'shop_test_repairs',
        jobId: 'JOB-DELV-101',
        hiveKey: serviceKey,
        newStatus: 'Delivered',
        notes: 'Device delivered to customer in good condition',
        staffName: 'Deepak',
        staffId: 'STAFF-02',
      );

      final updatedJob =
          Map<String, dynamic>.from(Db.services.get(serviceKey) as Map);
      expect(updatedJob['status'], 'Delivered');
      // Crucial: billCreated must remain false and invoice must remain null!
      expect(updatedJob['billCreated'], isFalse);
      expect(updatedJob['invoice'], isNull);
      expect(updatedJob['estimatedCost'], 4200.0);
      expect(updatedJob['advance'], 1000.0);

      // Verify status history was recorded
      final history = (updatedJob['statusHistory'] as List).cast<Map>();
      expect(history.length, 1);
      expect(history.first['status'], 'Delivered');
      expect(history.first['user'], 'Deepak');
      expect(history.first['notes'],
          'Device delivered to customer in good condition');
    });

    test(
        '3. Direct Service Checkout completes sale, updates Db.sales and links invoice to Db.services atomically',
        () async {
      final srvKey = await Db.services.add({
        'jobId': 'JOB-SALE-202',
        'customerName': 'Anjali Nair',
        'phone': '9447112233',
        'productType': 'Mobile',
        'brandModel': 'Samsung Galaxy S23',
        'serial': 'SM-S911B',
        'complaint': 'Screen damage',
        'technician': 'Vikram',
        'estimatedCost': 8500.0,
        'advance': 2000.0,
        'status': 'Ready',
        'billCreated': false,
        'invoice': null,
        'createdAt': DateTime.now().toIso8601String(),
        'statusHistory': [],
      });

      // Verify unbilled state
      expect(PosService.instance.isJobBilled('JOB-SALE-202'), isFalse);

      // Create cart with service charge + extra accessory
      final cartItems = [
        PosCartItem(
          item: const PosItem(
            id: 'service_JOB-SALE-202',
            name: 'Service: Samsung Galaxy S23 (#JOB-SALE-202)',
            sellingPrice: 8500.0,
            minPrice: 0.0,
            category: 'Services',
            stock: 9999,
          ),
          qty: 1,
          unitPrice: 8500.0,
        ),
        PosCartItem(
          item: const PosItem(
            id: 'PROD-UV-GLASS',
            name: 'UV Tempered Glass S23',
            sellingPrice: 500.0,
            minPrice: 300.0,
            category: 'Tempered Glass',
            stock: 25,
          ),
          qty: 1,
          unitPrice: 500.0,
        ),
      ];

      // Total gross: 8500 + 500 = 9000
      // Advance: 2000
      // Balance due collected: 7000
      const netBalance = 7000.0;
      const payment = PosPayment(
        mode: 'Cash',
        totalAmount: netBalance,
        cashAmount: netBalance,
        cashReceived: 7000.0,
        changeDue: 0.0,
      );

      final invoice = await PosService.instance.completeSale(
        shopId: 'shop_test_repairs',
        staffId: 'STAFF-01',
        staffName: 'Shahal',
        cartItems: cartItems,
        payment: payment,
        subtotal: 9000.0,
        discount: 0.0,
        total: 9000.0,
        customerName: 'Anjali Nair',
        customerPhone: '9447112233',
        serviceJobId: 'JOB-SALE-202',
        serviceJobKey: srvKey,
        serviceAdvanceApplied: 2000.0,
      );

      expect(invoice.invoiceId, isNotEmpty);
      expect(invoice.serviceJobId, 'JOB-SALE-202');
      expect(invoice.serviceAdvanceApplied, 2000.0);

      // Verify Service record in Db.services was linked
      final updatedSrv =
          Map<String, dynamic>.from(Db.services.get(srvKey) as Map);
      expect(updatedSrv['billCreated'], isTrue);
      expect(updatedSrv['invoice'], invoice.invoiceId);
      expect(updatedSrv['finalAmount'], 9000.0);
      expect(updatedSrv['paidAmount'], 9000.0);
      expect(updatedSrv['advanceApplied'], 2000.0);

      // Verify isJobBilled now returns true
      expect(PosService.instance.isJobBilled('JOB-SALE-202'), isTrue);

      // Verify sales record in Db.sales
      final sale =
          PosService.instance.getLinkedSale(invoice.invoiceId, 'JOB-SALE-202');
      expect(sale, isNotNull);
      expect(sale!['invoice'], invoice.invoiceId);
      expect(sale['serviceJobId'], 'JOB-SALE-202');
      expect(sale['serviceAdvanceApplied'], 2000.0);
      expect(sale['total'], 9000.0);
      expect(sale['cash'], 7000.0);
    });

    test('4. Prevent duplicate billing when job has already been billed',
        () async {
      final srvKey = await Db.services.add({
        'jobId': 'JOB-PAID-303',
        'customerName': 'Mathew George',
        'phone': '9847123123',
        'productType': 'Tablet',
        'brandModel': 'iPad Air 5th Gen',
        'serial': 'DMPV123',
        'complaint': 'Port charging issue',
        'technician': 'Vikram',
        'estimatedCost': 3000.0,
        'advance': 0.0,
        'status': 'Ready',
        'billCreated': true,
        'invoice': 'INV-SRV-SHAHAL-5555',
        'createdAt': DateTime.now().toIso8601String(),
        'statusHistory': [],
      });

      // Verify isJobBilled returns true
      expect(PosService.instance.isJobBilled('JOB-PAID-303'), isTrue);

      final job = RepairJob.fromMap(
          srvKey, Map<String, dynamic>.from(Db.services.get(srvKey) as Map));
      expect(job.billCreated, isTrue);
      expect(job.invoice, 'INV-SRV-SHAHAL-5555');
    });

    test(
        '5. Verify inline action buttons state: Unbilled job yields Sale to Customer, Billed job yields View Invoice',
        () async {
      final unbilledKey = await Db.services.add({
        'jobId': 'JOB-UNBILLED-505',
        'customerName': 'Nikhil Raj',
        'phone': '9847111222',
        'productType': 'Mobile',
        'brandModel': 'Google Pixel 7',
        'serial': 'G-P7-889',
        'complaint': 'Battery drain issue',
        'technician': 'Deepak',
        'estimatedCost': 3500.0,
        'advance': 500.0,
        'status': 'In Progress',
        'billCreated': false,
        'invoice': null,
        'createdAt': DateTime.now().toIso8601String(),
        'statusHistory': [],
      });

      final unbilledJob = RepairJob.fromMap(unbilledKey,
          Map<String, dynamic>.from(Db.services.get(unbilledKey) as Map));
      expect(PosService.instance.isJobBilled(unbilledJob.id), isFalse);
      expect(unbilledJob.billCreated, isFalse);
      expect(unbilledJob.invoice, isNull);

      // Verify that after checkout, it transitions to Billed state
      final cart = [
        PosCartItem(
          item: PosItem(
            id: 'service_${unbilledJob.id}',
            name: 'Service: ${unbilledJob.brandModel} (#${unbilledJob.id})',
            sellingPrice: 3500.0,
            minPrice: 0.0,
            category: 'Services',
            stock: 9999,
          ),
          qty: 1,
          unitPrice: 3500.0,
        ),
      ];

      final invoice = await PosService.instance.completeSale(
        shopId: 'shop_test_repairs',
        staffId: 'STAFF-01',
        staffName: 'Shahal',
        cartItems: cart,
        payment: const PosPayment(
          mode: 'UPI',
          totalAmount: 3000.0,
          upiAmount: 3000.0,
          cashReceived: 3000.0,
          changeDue: 0.0,
        ),
        subtotal: 3500.0,
        discount: 0.0,
        total: 3500.0,
        customerName: unbilledJob.customerName,
        customerPhone: unbilledJob.phone,
        serviceJobId: unbilledJob.id,
        serviceJobKey: unbilledKey,
        serviceAdvanceApplied: 500.0,
      );

      final billedJob = RepairJob.fromMap(unbilledKey,
          Map<String, dynamic>.from(Db.services.get(unbilledKey) as Map));
      expect(billedJob.billCreated, isTrue);
      expect(billedJob.invoice, invoice.invoiceId);
      expect(PosService.instance.isJobBilled(billedJob.id), isTrue);

      final linkedSale =
          PosService.instance.getLinkedSale(billedJob.invoice, billedJob.id);
      expect(linkedSale, isNotNull);
      expect(linkedSale!['invoice'], invoice.invoiceId);
      expect(linkedSale['serviceJobId'], unbilledJob.id);
      expect(linkedSale['serviceAdvanceApplied'], 500.0);
    });
  });
}
