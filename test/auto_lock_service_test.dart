// App auto-lock: off until the owner sets a PIN; salted-hash PIN only; no
// master password; never during a POS sale; cooldown after 5 wrong PINs.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/main.dart' show Db, boxSettings;
import 'package:tekfix_erp_pos/security/auto_lock_service.dart';

void main() {
  late Directory dir;
  final svc = AutoLockService.instance;
  var now = DateTime(2026, 11, 23, 9);

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('tekfix_autolock_');
    Hive.init(dir.path);
    await Hive.openBox(boxSettings);
  });

  tearDownAll(() async {
    await Hive.close();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  setUp(() async {
    await Db.settings.clear();
    svc.resetForTesting();
    now = DateTime(2026, 11, 23, 9);
    svc.clock = () => now;
    svc.recordActivity();
  });

  void idle(Duration d) {
    now = now.add(d);
    svc.checkIdle();
  }

  test('off by default: never locks, even after hours idle', () {
    expect(svc.isEnabled, isFalse);
    idle(const Duration(hours: 5));
    expect(svc.isLocked, isFalse);
  });

  test('cannot be switched on without a PIN', () async {
    expect(await svc.setEnabled(true), isFalse);
    expect(svc.isEnabled, isFalse);
  });

  test('PIN is stored only as a salted hash', () async {
    expect(await svc.setPin('12'), isFalse, reason: 'too short');
    expect(await svc.setPin('48291'), isTrue);
    final stored = Db.setting(AutoLockService.kPinHashKey, '');
    expect(stored, isNot(contains('48291')));
    expect(stored.length, 64);
    expect(Db.setting(AutoLockService.kPinSaltKey, ''), isNotEmpty);
  });

  test('locks after the timeout and unlocks only with the right PIN', () async {
    await svc.setPin('48291');
    expect(await svc.setEnabled(true), isTrue);
    svc.setTimeoutMinutes(10);
    idle(const Duration(minutes: 9));
    expect(svc.isLocked, isFalse);
    idle(const Duration(minutes: 2));
    expect(svc.isLocked, isTrue);

    for (final backdoor in ['admin123', '0000', '1234', '']) {
      expect(svc.tryUnlock(backdoor), isNotNull, reason: 'no master password: $backdoor');
      expect(svc.isLocked, isTrue);
    }
    expect(svc.tryUnlock('48291'), isNull);
    expect(svc.isLocked, isFalse);
  });

  test('never locks during a POS sale', () async {
    await svc.setPin('48291');
    await svc.setEnabled(true);
    svc.setPosSaleInProgress(true);
    idle(const Duration(hours: 1));
    expect(svc.isLocked, isFalse);
    svc.setPosSaleInProgress(false);
    idle(const Duration(minutes: 11));
    expect(svc.isLocked, isTrue);
  });

  test('5 wrong PINs -> 30 s wait, even the right PIN waits', () async {
    await svc.setPin('48291');
    await svc.setEnabled(true);
    idle(const Duration(minutes: 11));
    for (var i = 0; i < 5; i++) {
      svc.tryUnlock('11111');
    }
    expect(svc.cooldownSecondsLeft, greaterThan(0));
    expect(svc.tryUnlock('48291'), isNotNull);
    expect(svc.isLocked, isTrue);
    now = now.add(const Duration(seconds: 31));
    expect(svc.tryUnlock('48291'), isNull);
    expect(svc.isLocked, isFalse);
  });

  test('switching off unlocks; sign-out reset clears the lock', () async {
    await svc.setPin('48291');
    await svc.setEnabled(true);
    idle(const Duration(minutes: 11));
    expect(svc.isLocked, isTrue);
    svc.resetForSignOut();
    expect(svc.isLocked, isFalse);
    idle(const Duration(minutes: 11));
    await svc.setEnabled(false);
    expect(svc.isLocked, isFalse);
  });
}
