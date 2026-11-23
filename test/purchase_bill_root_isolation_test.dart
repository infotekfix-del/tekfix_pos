import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/purchases/purchase_bill_service.dart';
import 'package:tekfix_erp_pos/purchases/purchase_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;
  final svc = PurchaseBillService.instance;

  setUpAll(() async {
    PurchaseBillService.ownerCheckForTesting = true;
    tempDir = await Directory.systemTemp.createTemp('tekfix_root_isolation_test_');
    Hive.init(tempDir.path);
    for (final b in allBoxes) {
      await Hive.openBox(b);
    }
    await Hive.box(boxSettings).put('shop_id', 'test_shop_root_iso');
  });

  tearDownAll(() async {
    PurchaseBillService.ownerCheckForTesting = null;
    try {
      await Hive.close();
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('PurchaseBillService Root Isolation & Dual-Write Elimination', () {
    test('source has no root-level Firestore writes left', () {
      final src = File('lib/purchases/purchase_bill_service.dart').readAsStringSync();
      final col = RegExp(r"\.collection\('(purchase_bills|vendor_ledger|accounting_cash_bank|audit_logs|products|stock_units)'\)");
      final underShop = RegExp(r"\.doc\([^)]*\)\s*$");
      final rootUses = <String>[];
      for (final m in col.allMatches(src)) {
        final before = src.substring(m.start - 120 < 0 ? 0 : m.start - 120, m.start);
        if (underShop.hasMatch(before)) continue; // shops/{shopId}/...
        rootUses.add('${m.group(1)}: ${before.trim().split('\n').last.trim()}');
      }
      // Only the read-only legacy barcode lookup may touch a root collection.
      expect(rootUses, ['products: final rootSnap = await fs'],
          reason: 'every Firestore write must live under shops/{shopId}/');
    });

    test('confirmPurchaseBill saves locally without root dual writes', () async {
      final vendorKey = await Db.parties.add({
        'name': 'Direct Supplier',
        'phone': '9876543210',
        'type': 'Supplier',
        'balance': 0.0,
      });

      final bill = await svc.confirmPurchaseBill(
        billNumber: 'PB-ROOT-ISO-001',
        vendorInvoiceNumber: 'INV-ROOT-001',
        vendorKey: vendorKey,
        vendorName: 'Direct Supplier',
        vendorPhone: '9876543210',
        purchaseDate: DateTime(2026, 11, 22),
        items: [
          PurchaseBillItem(
            id: 'item_iso_1',
            name: 'Isolated Item',
            quantity: 2,
            purchaseRate: 250.0,
          ),
        ],
        staffId: 'S1',
        staffName: 'Owner',
      );

      expect(bill.isDraft, isFalse);
      expect(bill.grandTotalPaise, 50000);
      expect(bill.balanceDuePaise, 50000);

      // Verify bill saved in local Hive purchase bills box
      final savedBill = svc.getPurchaseBill(bill.key);
      expect(savedBill, isNotNull);
      expect(savedBill!.billNumber, 'PB-ROOT-ISO-001');
    });

    test('recordBillPayment records payment without writing to root', () async {
      final vendorKey = await Db.parties.add({
        'name': 'Payment Supplier',
        'phone': '9876543211',
        'type': 'Supplier',
        'balance': 0.0,
      });

      final bill = await svc.confirmPurchaseBill(
        billNumber: 'PB-ROOT-ISO-002',
        vendorInvoiceNumber: 'INV-ROOT-002',
        vendorKey: vendorKey,
        vendorName: 'Payment Supplier',
        vendorPhone: '9876543211',
        purchaseDate: DateTime(2026, 11, 22),
        items: [
          PurchaseBillItem(
            id: 'item_iso_2',
            name: 'Payment Item',
            quantity: 1,
            purchaseRate: 1000.0,
          ),
        ],
        staffId: 'S1',
        staffName: 'Owner',
      );

      final updated = await svc.recordBillPayment(
        billKey: bill.key,
        amount: 400.0,
        paymentDate: DateTime(2026, 11, 22),
        paymentMethod: 'Cash',
        transactionReference: 'CASH-ISO-002',
        staffId: 'S1',
        staffName: 'Owner',
      );

      expect(updated.paidAmountPaise, 40000);
      expect(updated.balanceDuePaise, 60000);
      expect(updated.paymentStatus.toLowerCase(), 'partial');
    });

    test('deletePurchaseBill marks void without root dependencies', () async {
      final vendorKey = await Db.parties.add({
        'name': 'Void Supplier',
        'phone': '9876543212',
        'type': 'Supplier',
        'balance': 0.0,
      });

      final bill = await svc.confirmPurchaseBill(
        billNumber: 'PB-ROOT-ISO-003',
        vendorInvoiceNumber: 'INV-ROOT-003',
        vendorKey: vendorKey,
        vendorName: 'Void Supplier',
        vendorPhone: '9876543212',
        purchaseDate: DateTime(2026, 11, 22),
        items: [
          PurchaseBillItem(
            id: 'item_iso_3',
            name: 'Void Item',
            quantity: 1,
            purchaseRate: 300.0,
          ),
        ],
        staffId: 'S1',
        staffName: 'Owner',
      );

      await svc.deletePurchaseBill(bill.key, reason: 'Test void isolation');
      final voided = svc.getPurchaseBill(bill.key);
      expect(voided!.isVoided, isTrue);
      expect(voided.paymentStatus, 'voided');
    });
  });
}

