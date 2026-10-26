import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../main.dart' show Db;

/// Identifies this installation (Windows / Mobile) for audit + sync.
class DeviceInfo {
  static const _uuid = Uuid();

  static String get platform {
    if (kIsWeb) return 'Web';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isAndroid || Platform.isIOS) return 'Mobile';
    return Platform.operatingSystem;
  }

  /// Stable random id, created once per install.
  static String get id {
    var v = Db.setting('device_id');
    if (v.isEmpty) {
      v = _uuid.v4();
      Db.settings.put('device_id', v);
    }
    return v;
  }

  /// Short code used inside invoice / job numbers so two devices never
  /// generate the same number (e.g. INV-W0001, INV-M0001).
  static String get counterCode {
    var v = Db.setting('counter_code');
    if (v.isEmpty) {
      v = platform == 'Windows' ? 'W' : 'M';
      Db.settings.put('counter_code', v);
    }
    return v;
  }

  /// Human name of the billing counter ("Counter-Windows").
  static String get counterName {
    final v = Db.setting('counter_name');
    return v.isEmpty ? 'Counter-$platform' : v;
  }
}
