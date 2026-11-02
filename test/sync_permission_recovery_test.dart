import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:tekfix_pos/sync/sync_engine.dart';
import 'dart:io';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('tek_sync_test_');
    Hive.init(tempDir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('SyncEngine Queue Recovery and Outbox Tests', () {
    test('openBoxes initializes sync metadata and outbox boxes', () async {
      final engine = SyncEngine.instance;
      await engine.openBoxes();
      expect(Hive.isBoxOpen('tek_sync_meta'), isTrue);
      expect(Hive.isBoxOpen('tek_sync_outbox'), isTrue);
    });

    test('clearOutbox safely purges pending outbox items without touching other data', () async {
      final engine = SyncEngine.instance;
      await engine.openBoxes();
      final outbox = Hive.box('tek_sync_outbox');

      // Populate dummy blocked items simulating 262 pending uploads
      for (var i = 0; i < 262; i++) {
        await outbox.put('staff|staff_$i', {'op': 'put', 't': 123456789});
      }
      expect(engine.pending, 262);

      // Perform clearOutbox recovery
      await engine.clearOutbox();

      expect(engine.pending, 0);
      expect(outbox.isEmpty, isTrue);
      expect(engine.lastError, isNull);
    });
  });
}

