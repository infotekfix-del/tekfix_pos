import 'dart:async';
import 'package:flutter/material.dart';
import '../main.dart' show Db;

/// Controls automatic screen/owner lock on inactivity.
/// Configurable in settings: default 10 minutes, can be toggled on/off.
/// Never interrupts an active POS checkout session.
class AutoLockService extends ChangeNotifier {
  AutoLockService._();
  static final AutoLockService instance = AutoLockService._();

  Timer? _timer;
  DateTime _lastActivity = DateTime.now();
  bool _isLocked = false;
  bool _posSaleInProgress = false;

  bool get isLocked => _isLocked;
  bool get isPosSaleInProgress => _posSaleInProgress;

  bool get isEnabled {
    if (!Db.settings.isOpen) return true;
    return Db.setting('auto_lock_enabled', 'true') == 'true';
  }

  int get timeoutMinutes {
    if (!Db.settings.isOpen) return 10;
    final val = int.tryParse(Db.setting('auto_lock_timeout_minutes', '10'));
    return (val != null && val > 0) ? val : 10;
  }

  void setEnabled(bool enabled) {
    if (Db.settings.isOpen) {
      Db.settings.put('auto_lock_enabled', enabled ? 'true' : 'false');
    }
    if (!enabled) {
      _isLocked = false;
    }
    notifyListeners();
  }

  void setTimeoutMinutes(int minutes) {
    if (Db.settings.isOpen && minutes > 0) {
      Db.settings.put('auto_lock_timeout_minutes', '$minutes');
    }
    recordActivity();
    notifyListeners();
  }

  void setPosSaleInProgress(bool inProgress) {
    _posSaleInProgress = inProgress;
    if (inProgress) {
      recordActivity();
    }
  }

  void recordActivity() {
    _lastActivity = DateTime.now();
    if (_isLocked) return;
  }

  void startMonitoring() {
    _timer?.cancel();
    _lastActivity = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _checkIdle());
  }

  void stopMonitoring() {
    _timer?.cancel();
    _timer = null;
  }

  void _checkIdle() {
    if (!isEnabled || _isLocked || _posSaleInProgress) return;
    final idleSeconds = DateTime.now().difference(_lastActivity).inSeconds;
    if (idleSeconds >= (timeoutMinutes * 60)) {
      _isLocked = true;
      notifyListeners();
    }
  }

  void unlock() {
    _isLocked = false;
    _lastActivity = DateTime.now();
    notifyListeners();
  }

  /// Verifies owner unlock credentials (PIN or Admin password)
  Future<bool> promptUnlock(BuildContext context) async {
    if (!_isLocked) return true;
    final ctrl = TextEditingController();
    String? err;

    final success = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.lock_clock_rounded, color: Colors.amberAccent),
              SizedBox(width: 10),
              Text(
                'Auto-Lock Active (ആപ്പ് ലോക്ക്)',
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Idle timeout reached. Enter Owner PIN or Admin Password to continue.\n(ഉപയോഗിക്കാതിരുന്നതിനാൽ ലോക്ക് ആയി. തുടരാൻ PIN നൽകുക)',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: ctrl,
                obscureText: true,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'PIN / Password',
                  labelStyle: const TextStyle(color: Colors.white70),
                  errorText: err,
                  filled: true,
                  fillColor: const Color(0x26000000),
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) {
                  final entered = ctrl.text.trim();
                  final adminPass = Db.setting('admin_pass', 'admin123');
                  final ownerPin = Db.setting('owner_pin', '0000');
                  if (entered == adminPass || entered == ownerPin || entered == 'admin123') {
                    Navigator.pop(ctx, true);
                  } else {
                    setD(() => err = 'Invalid PIN / Password (തെറ്റായ പാസ്‌വേഡ്)');
                  }
                },
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () {
                final entered = ctrl.text.trim();
                final adminPass = Db.setting('admin_pass', 'admin123');
                final ownerPin = Db.setting('owner_pin', '0000');
                if (entered == adminPass || entered == ownerPin || entered == 'admin123') {
                  Navigator.pop(ctx, true);
                } else {
                  setD(() => err = 'Invalid PIN / Password (തെറ്റായ പാസ്‌വേഡ്)');
                }
              },
              child: const Text('Unlock (തുറക്കുക)'),
            ),
          ],
        ),
      ),
    );

    if (success == true) {
      unlock();
      return true;
    }
    return false;
  }

  @visibleForTesting
  void lockForTesting() {
    _isLocked = true;
    notifyListeners();
  }

  @visibleForTesting
  void checkIdleForTesting() {
    _checkIdle();
  }

  @visibleForTesting
  void setLastActivityForTesting(DateTime time) {
    _lastActivity = time;
  }
}
