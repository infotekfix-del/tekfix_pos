import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart';
import 'package:tekfix_erp_pos/security/auto_lock_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;
  final lockSvc = AutoLockService.instance;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('tekfix_autolock_test_');
    Hive.init(tempDir.path);
    for (final b in allBoxes) {
      await Hive.openBox(b);
    }
  });

  tearDownAll(() async {
    lockSvc.stopMonitoring();
    try {
      await Hive.close();
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('AutoLockService Inactivity and POS Exemption Tests', () {
    test('Default configuration is enabled with 10 min timeout', () {
      expect(lockSvc.isEnabled, isTrue);
      expect(lockSvc.timeoutMinutes, 10);
      expect(lockSvc.isLocked, isFalse);
    });

    test('Configuration changes persist to settings box', () {
      lockSvc.setTimeoutMinutes(15);
      expect(lockSvc.timeoutMinutes, 15);
      expect(Db.setting('auto_lock_timeout_minutes'), '15');

      lockSvc.setEnabled(false);
      expect(lockSvc.isEnabled, isFalse);
      expect(Db.setting('auto_lock_enabled'), 'false');

      // Re-enable for subsequent tests
      lockSvc.setEnabled(true);
      lockSvc.setTimeoutMinutes(10);
      expect(lockSvc.isEnabled, isTrue);
      expect(lockSvc.timeoutMinutes, 10);
    });

    test('Idle timeout triggers locked state', () {
      expect(lockSvc.isLocked, isFalse);
      // Simulate last activity 11 minutes ago
      lockSvc.setLastActivityForTesting(
          DateTime.now().subtract(const Duration(minutes: 11)));
      lockSvc.checkIdleForTesting();

      expect(lockSvc.isLocked, isTrue,
          reason: 'App should be locked after exceeding idle timeout');

      // Unlock restores normal state
      lockSvc.unlock();
      expect(lockSvc.isLocked, isFalse);
    });

    test('Active POS checkout session NEVER triggers auto-lock', () {
      lockSvc.unlock();
      expect(lockSvc.isLocked, isFalse);

      // Flag POS sale in progress
      lockSvc.setPosSaleInProgress(true);
      expect(lockSvc.isPosSaleInProgress, isTrue);

      // Simulate last activity 20 minutes ago
      lockSvc.setLastActivityForTesting(
          DateTime.now().subtract(const Duration(minutes: 20)));
      lockSvc.checkIdleForTesting();

      expect(lockSvc.isLocked, isFalse,
          reason: 'Active POS sale must be exempted from auto-lock');

      // Once sale ends, idle check can lock if idle
      lockSvc.setPosSaleInProgress(false);
      lockSvc.setLastActivityForTesting(
          DateTime.now().subtract(const Duration(minutes: 11)));
      lockSvc.checkIdleForTesting();
      expect(lockSvc.isLocked, isTrue);

      lockSvc.unlock();
    });
  });
}
