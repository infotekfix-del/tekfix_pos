import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/crm/crm_messaging.dart';
import 'package:tekfix_erp_pos/sync/sync_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (MethodCall methodCall) async {
        if (methodCall.method == 'check') {
          return ['wifi'];
        }
        return null;
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
      MockStreamHandler.inline(
        onListen: (args, sink) {
          sink.success(['wifi']);
        },
      ),
    );

    tempDir = await Directory.systemTemp.createTemp('tek_sync_staff_push_test_');
    Hive.init(tempDir.path);
    for (final b in allBoxes) {
      await Hive.openBox(b);
    }
    await Hive.openBox(kBoxCrmTemplates);
    await Hive.openBox(kBoxCrmSettings);
    await Hive.openBox(kBoxCrmCampaigns);
    await Hive.openBox(kBoxMessageLog);
  });

  tearDownAll(() async {
    await Hive.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('SyncEngine Staff Push Restriction Tests', () {
    test('Staff device ignores local changes to owner-only collections', () async {
      final engine = SyncEngine.instance;
      await engine.initForTesting(isOwner: false);
      final outbox = Hive.box('tek_sync_outbox');
      await outbox.clear();

      // Write to items (allowed for staff)
      await Db.items.add({'_id': 'item_1', 'name': 'USB Cable', 'stock': 10});
      await Future.delayed(const Duration(milliseconds: 100));
      expect(outbox.containsKey('$boxItems|item_1'), isTrue,
          reason: 'Items should be queued on staff device');

      // Clear outbox
      await outbox.clear();

      // Write to staff box (owner-only push)
      await Db.staff.add({'_id': 'staff_2', 'name': 'Technician', 'role': 'Staff'});
      // Write to CRM templates box (owner-only push)
      await Hive.box(kBoxCrmTemplates).add({'_id': 'tmpl_1', 'title': 'Promo'});
      // Write to CRM settings box (owner-only push)
      await Hive.box(kBoxCrmSettings).add({'_id': 'crm_set_1', 'autoSend': true});
      // Write to campaigns box (owner-only push)
      await Hive.box(kBoxCrmCampaigns).add({'_id': 'camp_1', 'name': 'New Year'});

      await Future.delayed(const Duration(milliseconds: 100));

      expect(outbox.containsKey('$boxStaff|staff_2'), isFalse,
          reason: 'Staff box must NOT be queued on staff device');
      expect(outbox.containsKey('$kBoxCrmTemplates|tmpl_1'), isFalse,
          reason: 'CRM templates must NOT be queued on staff device');
      expect(outbox.containsKey('$kBoxCrmSettings|crm_set_1'), isFalse,
          reason: 'CRM settings must NOT be queued on staff device');
      expect(outbox.containsKey('$kBoxCrmCampaigns|camp_1'), isFalse,
          reason: 'CRM campaigns must NOT be queued on staff device');

      await engine.stop();
    });

    test('Owner device DOES queue changes to owner-only collections', () async {
      final engine = SyncEngine.instance;
      await engine.initForTesting(isOwner: true);
      final outbox = Hive.box('tek_sync_outbox');
      await outbox.clear();

      // Write to staff box as owner
      await Db.staff.add({'_id': 'staff_owner_created', 'name': 'New Staff'});
      await Future.delayed(const Duration(milliseconds: 100));

      expect(outbox.containsKey('$boxStaff|staff_owner_created'), isTrue,
          reason: 'Staff box should be queued on owner device');

      await engine.stop();
    });
  });
}
