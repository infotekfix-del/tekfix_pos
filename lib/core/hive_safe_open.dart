// Opening Hive boxes without ever losing shop data.
//
// Two very different failures used to be treated the same way ("corrupted:
// delete the file and start empty"):
//  * The file is LOCKED because TekFix is already running (a second window,
//    a copy hidden in the tray, a debug build next to the release build).
//    Nothing is wrong with the data. We must never delete it: we stop and
//    tell the user the app is already open.
//  * The file is really unreadable. We first keep a backup copy next to it
//    (<name>.corrupt-<time>.hive.bak), and only then start the box empty.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// Thrown when a data file is held by another running TekFix.
class TekFixAlreadyRunningException implements Exception {
  final String boxName;
  final Object cause;
  const TekFixAlreadyRunningException(this.boxName, this.cause);
  @override
  String toString() =>
      'TekFix is already open on this computer (data file "$boxName" is in use).';
}

/// Windows sharing / lock violations and Hive's own "lock failed".
bool isHiveLockError(Object e) {
  final text = e.toString().toLowerCase();
  if (text.contains('lock failed') ||
      text.contains('being used by another process') ||
      text.contains('locked a portion of the file') ||
      text.contains('resource temporarily unavailable')) {
    return true;
  }
  if (e is FileSystemException) {
    final code = e.osError?.errorCode;
    // Windows: 32 sharing violation, 33 lock violation. POSIX: 11 EAGAIN.
    if (code == 32 || code == 33 || code == 11) return true;
  }
  return false;
}

/// `<dir>/<name>.corrupt-20261127-110302.hive.bak`
String corruptBackupPath(String boxFilePath, DateTime now) {
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp =
      '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}';
  final base = boxFilePath.endsWith('.hive')
      ? boxFilePath.substring(0, boxFilePath.length - 5)
      : boxFilePath;
  return '$base.corrupt-$stamp.hive.bak';
}

/// Folder that holds the .hive files, learnt from the first box that opens.
String? _hiveDir;

@visibleForTesting
set hiveDirForTesting(String? d) => _hiveDir = d;

void _rememberDir(Box b) {
  final p = b.path;
  if (_hiveDir == null && p != null) _hiveDir = File(p).parent.path;
}

/// Opens [name]. A lock error throws [TekFixAlreadyRunningException] and
/// never touches the file. Any other error backs the file up, then starts the
/// box empty; if no backup can be made, the error is rethrown (data kept).
Future<Box> openBoxSafely(String name) async {
  if (Hive.isBoxOpen(name)) return Hive.box(name);
  try {
    final b = await Hive.openBox(name);
    _rememberDir(b);
    return b;
  } catch (e) {
    if (isHiveLockError(e)) {
      debugPrint('[TekFix Hive] "$name" is in use by another TekFix. Not touching it.');
      throw TekFixAlreadyRunningException(name, e);
    }
    debugPrint('[TekFix Hive] "$name" could not be opened ($e). Backing it up first...');
    final dir = _hiveDir;
    if (dir == null) {
      debugPrint('[TekFix Hive] Data folder unknown; keeping "$name" as it is.');
      rethrow;
    }
    final file = File('$dir${Platform.pathSeparator}${name.toLowerCase()}.hive');
    if (await file.exists()) {
      final backup = corruptBackupPath(file.path, DateTime.now());
      await file.copy(backup); // throws -> nothing is deleted
      debugPrint('[TekFix Hive] Backup saved: $backup');
    }
    await Hive.deleteBoxFromDisk(name);
    final b = await Hive.openBox(name);
    debugPrint('[TekFix Hive] "$name" started empty (backup kept).');
    return b;
  }
}
