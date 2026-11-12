import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import '../firebase_options.dart';
import '../recharge/recharge_backend_bridge.dart';
import '../security/device_security_service.dart';

/// ============================================================================
/// TEKFIX ERP - PHASE 13.3.3: TRUSTED DEVICE CONTROLLER
/// ============================================================================
///
/// Coordinates trusted device lifecycle between:
/// 1. Local hardware-backed DeviceSecurityService
/// 2. Regional Cloud Functions (registerTrustedDevice, requestDeviceChallenge, revokeTrustedDevice)
/// 3. Firestore `shops/{shopId}/trusted_devices`
/// ============================================================================

class TrustedDeviceModel {
  final String deviceId;
  final String ownerUid;
  final String deviceType; // 'mobile' | 'laptop'
  final String platform; // 'android' | 'windows'
  final String deviceModel;
  final bool isActive;
  final bool isRevoked;
  final DateTime? enrolledAt;
  final DateTime? lastVerifiedAt;

  TrustedDeviceModel({
    required this.deviceId,
    required this.ownerUid,
    required this.deviceType,
    required this.platform,
    required this.deviceModel,
    required this.isActive,
    required this.isRevoked,
    this.enrolledAt,
    this.lastVerifiedAt,
  });

  factory TrustedDeviceModel.fromFirestore(Map<String, dynamic> data, String id) {
    DateTime? parseDate(dynamic val) {
      if (val is Timestamp) return val.toDate();
      if (val is String) return DateTime.tryParse(val);
      return null;
    }

    return TrustedDeviceModel(
      deviceId: id,
      ownerUid: data['ownerUid']?.toString() ?? '',
      deviceType: data['deviceType']?.toString() ?? 'mobile',
      platform: data['platform']?.toString() ?? 'unknown',
      deviceModel: data['deviceModel']?.toString() ?? 'Unknown Device',
      isActive: data['isActive'] == true,
      isRevoked: data['isRevoked'] == true,
      enrolledAt: parseDate(data['createdAt'] ?? data['enrolledAt']),
      lastVerifiedAt: parseDate(data['lastVerifiedAt']),
    );
  }
}

class TrustedDeviceController extends ChangeNotifier {
  TrustedDeviceController._();
  static final TrustedDeviceController instance = TrustedDeviceController._();

  bool _loading = false;
  String? _error;
  List<TrustedDeviceModel> _devices = [];

  bool get loading => _loading;
  String? get error => _error;
  List<TrustedDeviceModel> get devices => _devices;

  TrustedDeviceModel? get registeredMobile =>
      _devices.cast<TrustedDeviceModel?>().firstWhere(
            (d) => d?.deviceType == 'mobile' && d?.isActive == true && d?.isRevoked != true,
            orElse: () => null,
          );

  TrustedDeviceModel? get registeredLaptop =>
      _devices.cast<TrustedDeviceModel?>().firstWhere(
            (d) => d?.deviceType == 'laptop' && d?.isActive == true && d?.isRevoked != true,
            orElse: () => null,
          );

  bool get isCurrentDeviceRegistered {
    final currentId = DeviceSecurityService.instance.deviceId;
    return _devices.any((d) => d.deviceId == currentId && d.isActive && !d.isRevoked);
  }

  /// Load devices from Supabase PostgreSQL (or legacy Firestore)
  Future<void> loadDevices(String shopId) async {
    if (shopId.isEmpty) return;
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      if (RechargeBackendBridge.isSupabaseMode && RechargeBackendBridge.supabaseClient != null) {
        final list = await RechargeBackendBridge.supabaseClient!.getDevices(shopId: shopId);
        _devices = list
            .map((d) => TrustedDeviceModel.fromFirestore(d, d['deviceId']?.toString() ?? ''))
            .toList();
      } else if (!DefaultFirebaseOptions.isUatMode && Firebase.apps.isNotEmpty) {
        final snap = await FirebaseFirestore.instance
            .collection('shops')
            .doc(shopId)
            .collection('trusted_devices')
            .get();

        _devices = snap.docs
            .map((doc) => TrustedDeviceModel.fromFirestore(doc.data(), doc.id))
            .toList();
      }

      final currentId = DeviceSecurityService.instance.deviceId;
      final isReg = _devices.any((d) => d.deviceId == currentId && d.isActive && !d.isRevoked);
      await DeviceSecurityService.instance.setEnrolledLocally(isReg);
    } catch (e) {
      _error = e.toString();
      debugPrint('[TrustedDeviceController] loadDevices notice: $e');
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Register current device via Cloud Function
  Future<bool> registerCurrentDevice({
    required String shopId,
    required String deviceModelName,
  }) async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final sec = DeviceSecurityService.instance;
      final devId = sec.deviceId;
      final pubKey = sec.publicKeyPem;
      final devType = sec.deviceType;
      final platform = sec.platformType.name;

      // Phase 13.6: Zero-Cost Backend Support via Supabase Recharge Bridge
      if (RechargeBackendBridge.isSupabaseMode && RechargeBackendBridge.supabaseClient != null) {
        await RechargeBackendBridge.supabaseClient!.registerDevice(
          shopId: shopId,
          deviceId: devId,
          deviceType: devType,
          platform: platform,
          deviceModel: deviceModelName,
          publicKeyPem: pubKey,
        );
      } else {
        final callable = DefaultFirebaseOptions.functionsInstance.httpsCallable('registerTrustedDevice');
        await callable.call<Map<String, dynamic>>({
          'shopId': shopId,
          'deviceId': devId,
          'deviceType': devType,
          'platform': platform,
          'deviceModel': deviceModelName,
          'publicKeyPem': pubKey,
        });
      }

      await sec.setEnrolledLocally(true);
      await loadDevices(shopId);
      return true;
    } catch (e) {
      _error = e.toString();
      debugPrint('[TrustedDeviceController] register error: $e');
      return false;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Revoke a device via Cloud Function
  Future<bool> revokeDevice({
    required String shopId,
    required String targetDeviceId,
    String reason = 'Revoked by owner',
  }) async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      // Phase 13.6: Zero-Cost Backend Support via Supabase Recharge Bridge
      if (RechargeBackendBridge.isSupabaseMode && RechargeBackendBridge.supabaseClient != null) {
        await RechargeBackendBridge.supabaseClient!.revokeDevice(
          shopId: shopId,
          deviceId: targetDeviceId,
          reason: reason,
        );
      } else {
        final callable = DefaultFirebaseOptions.functionsInstance.httpsCallable('revokeTrustedDevice');
        await callable.call<Map<String, dynamic>>({
          'shopId': shopId,
          'deviceId': targetDeviceId,
          'reason': reason,
        });
      }

      final currentId = DeviceSecurityService.instance.deviceId;
      if (currentId == targetDeviceId) {
        await DeviceSecurityService.instance.setEnrolledLocally(false);
      }

      await loadDevices(shopId);
      return true;
    } catch (e) {
      _error = e.toString();
      debugPrint('[TrustedDeviceController] revoke error: $e');
      return false;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }
}

