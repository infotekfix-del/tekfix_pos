import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/core/hive_safe_open.dart';

void main() {
  test('lock errors are recognised (never treated as corruption)', () {
    expect(
        isHiveLockError(const FileSystemException('lock failed', r'C:\x\tek_items.lock',
            OSError('The process cannot access the file because another process has '
                'locked a portion of the file', 33))),
        isTrue);
    expect(isHiveLockError(const FileSystemException('open', 'x', OSError('sharing', 32))), isTrue);
    expect(isHiveLockError(Exception('PathAccessException: lock failed, path = ...')), isTrue);
    expect(isHiveLockError(const FormatException('Wrong checksum in hive file')), isFalse);
  });

  test('backup name keeps the box name and a timestamp', () {
    expect(corruptBackupPath(r'C:\Docs\tek_items.hive', DateTime(2026, 11, 27, 11, 3, 2)),
        r'C:\Docs\tek_items.corrupt-20261127-110302.hive.bak');
  });

  test('a box held by another TekFix is never deleted', () async {
    final dir = await Directory.systemTemp.createTemp('tekfix_hive_lock_');
    Hive.init(dir.path);
    try {
      final box = await openBoxSafely('tek_items');
      await box.put('phone', 'Redmi 13');
      await box.close();
      final hiveFile = File('${dir.path}${Platform.pathSeparator}tek_items.hive');
      final sizeBefore = await hiveFile.length();
      expect(sizeBefore, greaterThan(0));

      // Another "TekFix" holds the lock file.
      final lockFile = File('${dir.path}${Platform.pathSeparator}tek_items.lock');
      final other = await lockFile.open(mode: FileMode.write);
      await other.lock(FileLock.exclusive);
      try {
        // Hive also leaks the lock error as an uncaught one (main.dart's zone
        // handler ignores it); collect it here the same way.
        Object? thrown;
        final leaked = <Object>[];
        await runZonedGuarded(() async {
          try {
            await openBoxSafely('tek_items');
          } catch (e) {
            thrown = e;
          }
        }, (e, _) => leaked.add(e));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(thrown, isA<TekFixAlreadyRunningException>());
        expect(leaked.every(isHiveLockError), isTrue);
      } finally {
        await other.unlock();
        await other.close();
      }

      expect(await hiveFile.exists(), isTrue);
      expect(await hiveFile.length(), sizeBefore);
      final again = await openBoxSafely('tek_items');
      expect(again.get('phone'), 'Redmi 13');
    } finally {
      await Hive.close();
      hiveDirForTesting = null;
      await dir.delete(recursive: true);
    }
  });
}
