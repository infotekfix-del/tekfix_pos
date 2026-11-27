import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('tekfix_hive_enc_proto_');
    Hive.init(tempDir.path);
  });

  tearDownAll(() async {
    try {
      await Hive.close();
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('Hive Encryption & Migration Prototype (Plan Verification)', () {
    test('Plaintext box can be migrated to HiveAesCipher encrypted box seamlessly', () async {
      const plainBoxName = 'test_unencrypted_parties';
      const encBoxName = 'test_encrypted_parties';

      // 1. Create and populate plaintext box
      final plainBox = await Hive.openBox(plainBoxName);
      await plainBox.put('p1', {'name': 'Wholesale Vendor', 'balance': -5000.0});
      await plainBox.put('p2', {'name': 'Retail Customer', 'balance': 250.0});
      expect(plainBox.length, 2);
      await plainBox.close();

      // 2. Generate 256-bit encryption key (simulating key stored in DPAPI / SecureStorage)
      final List<int> encryptionKey = Hive.generateSecureKey();
      expect(encryptionKey.length, 32); // 256 bits

      // 3. Migration step: Open plaintext box, copy to temporary/encrypted box
      final sourceBox = await Hive.openBox(plainBoxName);
      final cipher = HiveAesCipher(encryptionKey);
      final targetBox = await Hive.openBox(encBoxName, encryptionCipher: cipher);

      for (final key in sourceBox.keys) {
        await targetBox.put(key, sourceBox.get(key));
      }
      expect(targetBox.length, 2);

      await sourceBox.close();
      await targetBox.close();

      // 4. Re-open encrypted box with cipher - data must decrypt properly
      final reopenedEncBox =
          await Hive.openBox(encBoxName, encryptionCipher: cipher);
      final p1 = reopenedEncBox.get('p1') as Map;
      expect(p1['name'], 'Wholesale Vendor');
      expect(p1['balance'], -5000.0);
      expect(reopenedEncBox.length, 2);
      await reopenedEncBox.close();
    });

    test('Rollback safety: original plaintext box remains intact until migration verified', () async {
      const boxName = 'test_rollback_items';
      final box = await Hive.openBox(boxName);
      await box.put('it1', {'name': 'Screen Protector', 'stock': 50});
      await box.close();

      // Backup simulated
      final boxFile = File('${tempDir.path}/$boxName.hive');
      final backupFile = File('${tempDir.path}/${boxName}_backup.hive');
      await boxFile.copy(backupFile.path);
      expect(backupFile.existsSync(), isTrue);

      // Verify restore from backup works
      final restoredBox = await Hive.openBox('${boxName}_backup');
      expect(restoredBox.get('it1')['stock'], 50);
      await restoredBox.close();
    });
  });
}
