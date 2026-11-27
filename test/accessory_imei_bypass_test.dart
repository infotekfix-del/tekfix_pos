import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/purchases/imei_validator.dart';

void main() {
  group('ImeiValidator.isAccessoryOrSpare', () {
    test('correctly identifies all accessories from bill 111713', () {
      final billItems = [
        'IPHONE 20W ADAPTER TAIWAN',
        'KSA IPHONE 20W ADAPTER',
        'SMACC WIFI+BLUETOOTH DONGLE (OT-WUA950NM)',
        'MEIBO 300CC BORDERLESS GLASS',
        'ASKME ESD ANTI-STATIC 5D GLASS',
        'OGOG SUPER X ESD GLASS',
        'STEREO SOUND G10 IPHONE HF(6M WRNTY)',
      ];

      for (final item in billItems) {
        expect(
          ImeiValidator.isAccessoryOrSpare(item),
          isTrue,
          reason: 'Expected "$item" to be detected as an accessory/spare',
        );
      }
    });

    test('preserves IMEI tracking for actual phones and tablets', () {
      final phones = [
        'Apple iPhone 14 Pro 128GB',
        'iPhone 13 128GB Midnight',
        'Samsung Galaxy S23 Ultra',
        'Redmi Note 12 5G',
        'Realme 11 Pro',
        'Vivo V29 5G',
        'OnePlus Nord CE 3 Lite',
        'iPad 9th Gen 64GB',
      ];

      for (final phone in phones) {
        expect(
          ImeiValidator.isAccessoryOrSpare(phone),
          isFalse,
          reason: 'Expected "$phone" to NOT be considered an accessory',
        );
      }
    });

    test('detects accessories by category as well', () {
      expect(
        ImeiValidator.isAccessoryOrSpare('Unknown Item X', 'Mobile Accessories'),
        isTrue,
      );
      expect(
        ImeiValidator.isAccessoryOrSpare('Unknown Item Y', 'Spare Parts'),
        isTrue,
      );
      expect(
        ImeiValidator.isAccessoryOrSpare('Unknown Item Z', 'Smartphones'),
        isFalse,
      );
    });
  });
}
