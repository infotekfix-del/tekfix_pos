// App auto-lock for owner screens (2026-11-22, hardened 2026-11-23).
// - OFF until the owner sets a lock PIN and switches it on in Settings.
// - The PIN is stored only as a salted SHA-256 hash; there is no default or
//   master password.
// - Never locks while a POS sale is in progress.
// - 5 wrong PINs -> 30 s wait. Forgotten PIN: sign out and sign in again.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

import '../main.dart' show Db;

class AutoLockService extends ChangeNotifier {
  AutoLockService._();
  static final AutoLockService instance = AutoLockService._();

  static const String kEnabledKey = 'auto_lock_enabled';
  static const String kTimeoutKey = 'auto_lock_timeout_minutes';
  static const String kPinHashKey = 'auto_lock_pin_hash';
  static const String kPinSaltKey = 'auto_lock_pin_salt';
  static const int kMaxAttempts = 5;
  static const Duration kCooldown = Duration(seconds: 30);

  Timer? _timer;
  DateTime _lastActivity = DateTime.now();
  bool _isLocked = false;
  bool _posSaleInProgress = false;
  int _failedAttempts = 0;
  DateTime? _cooldownUntil;

  /// For tests: replaces the clock.
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  bool get isLocked => _isLocked;
  bool get isPosSaleInProgress => _posSaleInProgress;

  String _setting(String key, String def) =>
      Db.settings.isOpen ? Db.setting(key, def) : def;

  bool get hasPin => _setting(kPinHashKey, '').isNotEmpty && _setting(kPinSaltKey, '').isNotEmpty;

  /// On only when the owner switched it on AND a PIN exists.
  bool get isEnabled => hasPin && _setting(kEnabledKey, 'false') == 'true';

  int get timeoutMinutes {
    final val = int.tryParse(_setting(kTimeoutKey, '10'));
    return (val != null && val > 0) ? val : 10;
  }

  /// Seconds left before another PIN try is allowed (0 = allowed now).
  int get cooldownSecondsLeft {
    final until = _cooldownUntil;
    if (until == null) return 0;
    final left = until.difference(clock()).inSeconds;
    return left > 0 ? left : 0;
  }

  static bool isValidPin(String pin) => RegExp(r'^[0-9]{4,8}$').hasMatch(pin);

  static String _hash(String salt, String pin) =>
      sha256.convert(utf8.encode('tekfix-autolock|$salt|$pin')).toString();

  /// Sets (or replaces) the owner's lock PIN. Returns false for a bad PIN.
  Future<bool> setPin(String pin) async {
    if (!isValidPin(pin) || !Db.settings.isOpen) return false;
    final rnd = Random.secure();
    final salt = base64Url.encode(List<int>.generate(16, (_) => rnd.nextInt(256)));
    await Db.settings.put(kPinSaltKey, salt);
    await Db.settings.put(kPinHashKey, _hash(salt, pin));
    notifyListeners();
    return true;
  }

  bool _matches(String pin) {
    final salt = _setting(kPinSaltKey, '');
    final stored = _setting(kPinHashKey, '');
    if (salt.isEmpty || stored.isEmpty) return false;
    final h = _hash(salt, pin);
    // Constant-time compare.
    if (h.length != stored.length) return false;
    var diff = 0;
    for (var i = 0; i < h.length; i++) {
      diff |= h.codeUnitAt(i) ^ stored.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Tries to unlock with [pin]. Null on success, else a bilingual message.
  String? tryUnlock(String pin) {
    final wait = cooldownSecondsLeft;
    if (wait > 0) {
      return 'കുറച്ച് കാത്തിരിക്കുക ($wait s) (Too many wrong PINs, wait $wait s)';
    }
    if (_matches(pin.trim())) {
      _failedAttempts = 0;
      _cooldownUntil = null;
      unlock();
      return null;
    }
    _failedAttempts++;
    if (_failedAttempts >= kMaxAttempts) {
      _failedAttempts = 0;
      _cooldownUntil = clock().add(kCooldown);
      return 'തെറ്റായ PIN, 30 സെക്കൻഡ് കാത്തിരിക്കുക (Wrong PIN, wait 30 s)';
    }
    return 'തെറ്റായ PIN (Wrong PIN)';
  }

  /// Switching on needs a PIN first; switching off always works.
  Future<bool> setEnabled(bool enabled) async {
    if (enabled && !hasPin) return false;
    if (Db.settings.isOpen) {
      await Db.settings.put(kEnabledKey, enabled ? 'true' : 'false');
    }
    if (!enabled) _isLocked = false;
    recordActivity();
    notifyListeners();
    return true;
  }

  void setTimeoutMinutes(int minutes) {
    if (Db.settings.isOpen && minutes > 0) {
      Db.settings.put(kTimeoutKey, '$minutes');
    }
    recordActivity();
    notifyListeners();
  }

  void setPosSaleInProgress(bool inProgress) {
    _posSaleInProgress = inProgress;
    if (inProgress) recordActivity();
  }

  void recordActivity() {
    if (!_isLocked) _lastActivity = clock();
  }

  void startMonitoring() {
    _timer?.cancel();
    _lastActivity = clock();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => checkIdle());
  }

  void stopMonitoring() {
    _timer?.cancel();
    _timer = null;
  }

  @visibleForTesting
  void checkIdle() {
    if (!isEnabled || _isLocked || _posSaleInProgress) return;
    final idleSeconds = clock().difference(_lastActivity).inSeconds;
    if (idleSeconds >= timeoutMinutes * 60) {
      _isLocked = true;
      notifyListeners();
    }
  }

  void unlock() {
    _isLocked = false;
    _lastActivity = clock();
    notifyListeners();
  }

  /// Clears the lock after the owner signs out (forgotten PIN path).
  void resetForSignOut() {
    _isLocked = false;
    _failedAttempts = 0;
    _cooldownUntil = null;
    notifyListeners();
  }

  @visibleForTesting
  void resetForTesting() {
    _timer?.cancel();
    _timer = null;
    _isLocked = false;
    _posSaleInProgress = false;
    _failedAttempts = 0;
    _cooldownUntil = null;
    clock = DateTime.now;
    _lastActivity = clock();
  }

  /// Asks the owner for a new 4-8 digit PIN (twice). Returns true if saved.
  static Future<bool> showSetPinDialog(BuildContext context) async {
    final a = TextEditingController();
    final b = TextEditingController();
    String? err;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Lock PIN (ലോക്ക് PIN)'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('4-8 അക്കങ്ങൾ. ഇത് ആരോടും പറയരുത്. (4-8 digits; keep it private.)',
                  style: TextStyle(fontSize: 12)),
              TextField(
                key: const ValueKey('autolock-pin-1'),
                controller: a,
                obscureText: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'New PIN (പുതിയ PIN)'),
              ),
              TextField(
                key: const ValueKey('autolock-pin-2'),
                controller: b,
                obscureText: true,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: 'Repeat PIN (വീണ്ടും)', errorText: err),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                if (!isValidPin(a.text.trim())) {
                  setD(() => err = '4-8 അക്കങ്ങൾ മാത്രം (Digits only, 4-8)');
                  return;
                }
                if (a.text.trim() != b.text.trim()) {
                  setD(() => err = 'PIN ഒന്നല്ല (PINs do not match)');
                  return;
                }
                final saved = await instance.setPin(a.text.trim());
                if (ctx.mounted) Navigator.pop(ctx, saved);
              },
              child: const Text('Save (സേവ്)'),
            ),
          ],
        ),
      ),
    );
    return ok == true;
  }
}
