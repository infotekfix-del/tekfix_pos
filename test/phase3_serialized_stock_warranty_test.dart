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
import 'package:tekfix_erp_pos/purchases/imei_validator.dart';
import 'package:tekfix_erp_pos/purchases/purchase_bill_service.dart';
import 'package:tekfix_erp_pos/purchases/purchase_models.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tekfix_phase3_test_');
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

  group('PHASE 3: SERIALIZED STOCK, DUAL-IMEI & SUPPLIER WARRANTY TEST SUITE', () {
    test('1. 3GPP Luhn Checksum Algorithm & Check Digit Generation', () {
      // 14-digit prefix
      const prefix14 = '86450104712345';
      final checkDigit = ImeiValidator.calculateCheckDigit(prefix14);
      expect(checkDigit, isNotNull);
      expect(checkDigit! >= 0 && checkDigit <= 9, isTrue);

      // Construct valid 15-digit IMEI
      final validImei = '$prefix14$checkDigit';
      expect(ImeiValidator.isValidLuhn(validImei), isTrue);
      expect(ImeiValidator.categorizeIdentifier(validImei), equals('VALID_IMEI'));

      // Tampered / typo IMEI (corrupted check digit)
      final badCheckDigit = (checkDigit + 1) % 10;
      final invalidImei = '$prefix14$badCheckDigit';
      expect(ImeiValidator.isValidLuhn(invalidImei), isFalse);
      expect(ImeiValidator.categorizeIdentifier(invalidImei), equals('INVALID_LUHN_IMEI'));

      // Non-15 digit alphanumeric device serial (e.g. Apple serial number)
      const appleSerial = 'F17X89KLMD6R';
      expect(ImeiValidator.isValidLuhn(appleSerial), isFalse);
      expect(ImeiValidator.categorizeIdentifier(appleSerial), equals('DEVICE_SERIAL'));

      // Empty string
      expect(ImeiValidator.categorizeIdentifier(''), equals('EMPTY'));
    });

    test('2. Dual-IMEI Handling: Pairing, Formatting & Extraction', () {
      const imei1 = '864501047123456';
      const imei2 = '864501047123457';

      // Formatting dual IMEI
      final formatted = ImeiValidator.formatDualImei(imei1, imei2);
      expect(formatted, equals('$imei1 / $imei2'));

      // Formatting single IMEI
      final single = ImeiValidator.formatDualImei(imei1, null);
      expect(single, equals(imei1));

      // Formatting identical secondary ignored
      final duplicateSecondary = ImeiValidator.formatDualImei(imei1, imei1);
      expect(duplicateSecondary, equals(imei1));

      // Extraction of dual IMEI
      final extracted = ImeiValidator.extractImeisFromUnit(formatted);
      expect(extracted.length, equals(2));
      expect(extracted[0], equals(imei1));
      expect(extracted[1], equals(imei2));

      // Extraction of comma-separated dual IMEI
      final commaExtracted = ImeiValidator.extractImeisFromUnit('$imei1, $imei2');
      expect(commaExtracted.length, equals(2));
      expect(commaExtracted[0], equals(imei1));
      expect(commaExtracted[1], equals(imei2));

      // Extraction of single unit
      final singleExtracted = ImeiValidator.extractImeisFromUnit(imei1);
      expect(singleExtracted.length, equals(1));
      expect(singleExtracted.first, equals(imei1));
    });

    test('3. Duplicate IMEI Detection: Intra-Bill and Inter-Item Checks', () {
      final items = [
        PurchaseBillItem(
          name: 'iPhone 15 Pro 128GB',
          quantity: 2,
          purchaseRate: 95000.0,
          imeiRequired: true,
          serialNumbers: ['864501047123450 / 864501047123451', '864501047123452 / 864501047123453'],
        ),
        PurchaseBillItem(
          name: 'iPhone 15 Pro 256GB',
          quantity: 1,
          purchaseRate: 105000.0,
          imeiRequired: true,
          serialNumbers: ['864501047123454 / 864501047123455'],
        ),
      ];

      // Collect all individual IMEIs across all items
      final allBillImeis = <String>{};
      bool duplicateFound = false;

      for (final item in items) {
        for (final unit in item.serialNumbers) {
          final imeis = ImeiValidator.extractImeisFromUnit(unit);
          for (final imei in imeis) {
            if (allBillImeis.contains(imei)) {
              duplicateFound = true;
            }
            allBillImeis.add(imei);
          }
        }
      }

      expect(duplicateFound, isFalse);
      expect(allBillImeis.length, equals(6)); // 3 units * 2 IMEIs each = 6 IMEIs

      // Now introduce duplicate in item 2
      const duplicateImei = '864501047123450'; // already in item 1
      expect(allBillImeis.contains(duplicateImei), isTrue);
    });

    test('4. Supplier Warranty Duration Presets & Expiry Date Auto-Calculation', () {
      final service = PurchaseBillService.instance;
      final purchaseDate = DateTime(2026, 10, 29);

      // 0 Months (No Warranty)
      final expNoWarranty = service.calculateItemWarrantyExpiry(
        purchaseDate,
        ItemWarrantyDuration.noWarranty,
      );
      expect(expNoWarranty, isNull);

      // 3 Months
      final exp3M = service.calculateItemWarrantyExpiry(
        purchaseDate,
        ItemWarrantyDuration.threeMonths,
      );
      expect(exp3M, isNotNull);
      expect(exp3M!.difference(purchaseDate).inDays, inInclusiveRange(89, 93));

      // 6 Months
      final exp6M = service.calculateItemWarrantyExpiry(
        purchaseDate,
        ItemWarrantyDuration.sixMonths,
      );
      expect(exp6M, isNotNull);
      expect(exp6M!.difference(purchaseDate).inDays, inInclusiveRange(180, 184));

      // 12 Months
      final exp12M = service.calculateItemWarrantyExpiry(
        purchaseDate,
        ItemWarrantyDuration.twelveMonths,
      );
      expect(exp12M, isNotNull);
      expect(exp12M!.difference(purchaseDate).inDays, inInclusiveRange(365, 366));

      // 24 Months
      final exp24M = service.calculateItemWarrantyExpiry(
        purchaseDate,
        ItemWarrantyDuration.twentyFourMonths,
      );
      expect(exp24M, isNotNull);
      expect(exp24M!.difference(purchaseDate).inDays, inInclusiveRange(730, 731));

      // Custom Days (e.g. 45 Days)
      final expCustom = service.calculateItemWarrantyExpiry(
        purchaseDate,
        ItemWarrantyDuration.custom,
        customDays: 45,
      );
      expect(expCustom, isNotNull);
      expect(expCustom!.difference(purchaseDate).inDays, equals(45));
    });

    test('5. Item Staging Model with Dual-IMEI & Warranty Attributes', () {
      final item = PurchaseBillItem(
        name: 'Samsung Galaxy S24 Ultra',
        quantity: 2,
        purchaseRate: 85000.0,
        sellingPrice: 115000.0,
        mrp: 129999.0,
        hsnCode: '85171300',
        imeiRequired: true,
        serialNumbers: [
          '352938112345670 / 352938112345671',
          '352938112345672 / 352938112345673',
        ],
        warrantyAvailable: true,
        warrantyDuration: ItemWarrantyDuration.twelveMonths,
        warrantyExpiryDate: DateTime(2027, 10, 29),
        isNewProduct: false,
        isStagedReady: true,
        matchedProductId: 's24_ultra_01',
      );

      expect(item.serialNumbers.length, equals(item.quantity));
      expect(item.hasWarranty, isTrue);
      expect(item.warrantyExpiryDate, isNotNull);
      expect(item.matchStatus, equals(ProductMatchStatus.matched));

      // Verify toMap and fromMap serialization preservation
      final map = item.toMap();
      final revived = PurchaseBillItem.fromMap(map);

      expect(revived.name, equals(item.name));
      expect(revived.serialNumbers.length, equals(2));
      expect(revived.serialNumbers.first, contains(' / '));
      expect(revived.warrantyDuration, equals(ItemWarrantyDuration.twelveMonths));
      expect(revived.warrantyExpiryDate, equals(item.warrantyExpiryDate));
      expect(revived.hsnCode, equals('85171300'));
      expect(revived.mrp, equals(129999.0));
    });
  });
}

