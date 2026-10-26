import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/widgets.dart';
import '../auth/auth_controller.dart';

/// Writes "I am online" to shops/{shop}/presence/{uid} while the app is open.
/// Owner reads it live in StaffTrackingView.
class PresenceService with WidgetsBindingObserver {
  PresenceService._();
  static final PresenceService instance = PresenceService._();

  Timer? _timer;
  bool _running = false;

  DocumentReference<Map<String, dynamic>>? get _ref {
    final a = AuthController.instance;
    if (!a.signedIn) return null;
    return FirebaseFirestore.instance
        .doc('shops/${a.shopId}/presence/${a.uid}');
  }

  void start() {
    if (_running) return;
    _running = true;
    WidgetsBinding.instance.addObserver(this);
    _beat(true);
    _timer = Timer.periodic(const Duration(minutes: 2), (_) => _beat(true));
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    await _beat(false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_running) return;
    _beat(state == AppLifecycleState.resumed);
  }

  Future<void> _beat(bool online) async {
    final ref = _ref;
    if (ref == null) return;
    try {
      await ref.set({
        'name': AuthController.instance.name,
        'role': AuthController.instance.roleLabel,
        'online': online,
        'lastSeen': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {
      // offline: ignore, next beat will retry
    }
  }
}
