import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import '../main.dart' show Db;
import 'p256_ecdsa.dart';
import 'platform_hardware_key_store.dart';

/// ============================================================================
/// TEKFIX ERP - PHASE 13.3.5: OWNER TRUSTED DEVICE SECURITY SERVICE
/// REMEDIATION HIGH-13-02 & MED-13-04: TRUE ASYMMETRIC ECDSA P-256 SIGNING
/// ============================================================================
///
/// Core Enhancements:
/// 1. Asymmetric ECDSA P-256 (secp256r1) signing implementation.
///    - Produces ASN.1 DER compliant ECDSA signatures verifiable by Node.js crypto.verify.
///    - Generates valid SPKI X.509 SubjectPublicKeyInfo formatted PEM public keys.
/// 2. Private Key Isolation:
///    - Private keys are completely removed from plaintext Hive.
///    - Delegated to PlatformHardwareKeyStore (DPAPI-aligned / app-private secure vault).
/// 3. Replay Protection:
///    - Nonce challenges are signed with the device private key.
/// ============================================================================

enum DevicePlatformType {
  android('mobile'),
  windows('laptop'),
  unsupported('unknown');

  final String category;
  const DevicePlatformType(this.category);
}

class DeviceChallenge {
  final String nonce;
  final String shopId;
  final DateTime expiresAt;

  DeviceChallenge({
    required this.nonce,
    required this.shopId,
    required this.expiresAt,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

class DeviceSecurityService {
  DeviceSecurityService._();
  static final DeviceSecurityService instance = DeviceSecurityService._();

  static const String _keyDeviceId = 'trusted_device_id';
  static const String _keyPublicKey = 'trusted_device_public_key_pem';
  static const String _keyDeviceType = 'trusted_device_type';
  static const String _keyEnrolled = 'trusted_device_enrolled';

  String? _cachedDeviceId;
  String? _cachedPrivateKeyPem;
  String? _cachedPublicKeyPem;
  String? _cachedDeviceType;

  @visibleForTesting
  static DevicePlatformType? overridePlatformForTesting;

  /// Detect platform category
  DevicePlatformType get platformType {
    if (overridePlatformForTesting != null) {
      return overridePlatformForTesting!;
    }
    if (kIsWeb) {
      return DevicePlatformType.unsupported; // Web is not an authorized trusted platform
    }
    if (Platform.isAndroid) {
      return DevicePlatformType.android;
    }
    if (Platform.isWindows) {
      return DevicePlatformType.windows;
    }
    return DevicePlatformType.unsupported;
  }

  static String _getSetting(String key, [String def = '']) {
    try {
      if (Hive.isBoxOpen('tek_settings')) {
        return Db.setting(key, def);
      }
    } catch (_) {}
    return def;
  }

  static Future<void> _putSetting(String key, String value) async {
    try {
      if (Hive.isBoxOpen('tek_settings')) {
        await Db.settings.put(key, value);
      }
    } catch (_) {}
  }

  /// Initialize device security state
  Future<void> init() async {
    await PlatformHardwareKeyStore.instance.init();

    _cachedDeviceId = _getSetting(_keyDeviceId, '');
    _cachedPublicKeyPem = _getSetting(_keyPublicKey, '');
    _cachedDeviceType = _getSetting(_keyDeviceType, '');

    if (platformType == DevicePlatformType.android) {
      final hasKey = await PlatformHardwareKeyStore.instance.hasAndroidHardwareKey();
      if (!hasKey ||
          _cachedDeviceId == null ||
          _cachedDeviceId!.isEmpty ||
          _cachedPublicKeyPem == null ||
          _cachedPublicKeyPem!.isEmpty) {
        await generateDeviceKeys();
      }
      return;
    }

    // Windows / Desktop Fallback: Read private key from secure hardware-backed DPAPI vault (NOT Hive!)
    _cachedPrivateKeyPem = await PlatformHardwareKeyStore.instance.readPrivateKey();

    if (_cachedDeviceId == null || _cachedDeviceId!.isEmpty || _cachedPrivateKeyPem == null) {
      await generateDeviceKeys();
      return;
    }
    await _ensureRealP256PublicKey();
  }

  /// Older builds stored a simulated public key (hash-derived) that no real
  /// ECDSA verifier accepts. Keep the same device id and private scalar, and
  /// store the genuine P-256 public key for it. An unusable private key gets
  /// a fresh key pair.
  Future<void> _ensureRealP256PublicKey() async {
    final d = P256Ecdsa.scalarFromPrivateKeyPem(_cachedPrivateKeyPem);
    if (d == null) {
      // Keep the same device id (audit trail); only the key pair is replaced.
      debugPrint('[DeviceSecurity] Stored private key unusable; new P-256 key pair for $_cachedDeviceId.');
      final nd = P256Ecdsa.generateScalar();
      _cachedPrivateKeyPem = P256Ecdsa.privateKeyPem(nd);
      _cachedPublicKeyPem = P256Ecdsa.publicKeyPem(nd);
      await PlatformHardwareKeyStore.instance.writePrivateKey(_cachedPrivateKeyPem!);
      await _putSetting(_keyPublicKey, _cachedPublicKeyPem!);
      return;
    }
    final realPem = P256Ecdsa.publicKeyPem(d);
    String norm(String? x) => (x ?? '').replaceAll(RegExp(r'\s+'), '');
    if (norm(_cachedPublicKeyPem) != norm(realPem)) {
      debugPrint('[DeviceSecurity] Upgraded device $_cachedDeviceId to a real P-256 public key '
          '(re-register this device on servers that enforce device signatures).');
      _cachedPublicKeyPem = realPem;
      await _putSetting(_keyPublicKey, realPem);
    }
  }

  String get deviceId {
    if (_cachedDeviceId == null || _cachedDeviceId!.isEmpty) {
      _cachedDeviceId = _getSetting(_keyDeviceId, '');
      if (_cachedDeviceId == null || _cachedDeviceId!.isEmpty) {
        _generateDeviceId();
      }
    }
    return _cachedDeviceId!;
  }

  String get publicKeyPem {
    if (_cachedPublicKeyPem == null || _cachedPublicKeyPem!.isEmpty) {
      _cachedPublicKeyPem = _getSetting(_keyPublicKey, '');
    }
    return _cachedPublicKeyPem ?? '';
  }

  String get deviceType {
    if (_cachedDeviceType == null || _cachedDeviceType!.isEmpty) {
      _cachedDeviceType = _getSetting(_keyDeviceType, platformType.category);
    }
    return _cachedDeviceType!;
  }

  bool get isEnrolledLocally => _getSetting(_keyEnrolled, 'false') == 'true';

  Future<void> setEnrolledLocally(bool enrolled) async {
    await _putSetting(_keyEnrolled, enrolled ? 'true' : 'false');
  }

  /// Generate a genuine ECDSA P-256 compliant keypair
  Future<Map<String, String>> generateDeviceKeys() async {
    _generateDeviceId();

    // FIX C1: Genuine Hardware-Backed AndroidKeyStore Keypair Generation
    if (platformType == DevicePlatformType.android) {
      final keyResult = await PlatformHardwareKeyStore.instance.generateAndroidHardwareKey();
      _cachedPublicKeyPem = keyResult['publicKeyPem'];
      _cachedPrivateKeyPem = null; // NON-EXPORTABLE: private key never enters Dart memory on Android!
      _cachedDeviceType = platformType.category;

      await _putSetting(_keyPublicKey, _cachedPublicKeyPem!);
      await _putSetting(_keyDeviceType, platformType.category);

      return {
        'deviceId': _cachedDeviceId!,
        'publicKeyPem': _cachedPublicKeyPem!,
        'deviceType': platformType.category,
      };
    }

    // Windows Desktop / Fallback: genuine ECDSA P-256 key pair
    final d = P256Ecdsa.generateScalar();
    final publicKeyPem = P256Ecdsa.publicKeyPem(d);
    final privateKeyPem = P256Ecdsa.privateKeyPem(d);

    _cachedPrivateKeyPem = privateKeyPem;
    _cachedPublicKeyPem = publicKeyPem;

    // Securely persist private key to PlatformHardwareKeyStore via Windows DPAPI
    await PlatformHardwareKeyStore.instance.writePrivateKey(privateKeyPem);

    // Only non-sensitive public metadata is stored in settings
    await _putSetting(_keyPublicKey, publicKeyPem);
    await _putSetting(_keyDeviceType, platformType.category);

    return {
      'deviceId': _cachedDeviceId!,
      'publicKeyPem': publicKeyPem,
      'deviceType': platformType.category,
    };
  }

  void _generateDeviceId() {
    final prefix = platformType == DevicePlatformType.android ? 'DEV_ANDR' : 'DEV_WIN';
    final randomSuffix = Random.secure().nextInt(0xFFFFFF).toRadixString(16).toUpperCase().padLeft(6, '0');
    _cachedDeviceId = '${prefix}_$randomSuffix';
    _putSetting(_keyDeviceId, _cachedDeviceId!);
  }

  /// Sign an authorization challenge nonce using ECDSA P-256 ASN.1 DER encoding
  /// Sign an arbitrary canonical payload with device ECDSA P-256 key
  Future<String> signRawPayload(String canonicalPayload) async {
    // Hardware-Backed Android Keystore Signing
    if (platformType == DevicePlatformType.android) {
      final payloadBytes = Uint8List.fromList(utf8.encode(canonicalPayload));
      return await PlatformHardwareKeyStore.instance.signWithAndroidHardwareKey(
        payload: payloadBytes,
      );
    }

    // Windows Desktop / Fallback Environment
    if (_cachedPrivateKeyPem == null || _cachedPrivateKeyPem!.isEmpty) {
      _cachedPrivateKeyPem = await PlatformHardwareKeyStore.instance.readPrivateKey();
      if (_cachedPrivateKeyPem == null || _cachedPrivateKeyPem!.isEmpty) {
        await generateDeviceKeys();
      }
    }

    // Genuine ECDSA P-256 / SHA-256 signature (DER, hex) — verifiable by the
    // recharge-bridge edge function (WebCrypto) and Node crypto.verify.
    var d = P256Ecdsa.scalarFromPrivateKeyPem(_cachedPrivateKeyPem);
    if (d == null) {
      await generateDeviceKeys();
      d = P256Ecdsa.scalarFromPrivateKeyPem(_cachedPrivateKeyPem)!;
    }
    return P256Ecdsa.signDerHex(d, canonicalPayload);
  }

  /// Sign a 4-part challenge nonce: shopId:ownerUid:deviceId:nonce
  Future<String> signChallenge({
    required String shopId,
    required String ownerUid,
    required String nonce,
  }) async {
    return signRawPayload('$shopId:$ownerUid:$deviceId:$nonce');
  }

  /// Reset or rotate device security identity (for device revocation / wipe)
  Future<void> resetDeviceKeys() async {
    _cachedDeviceId = null;
    _cachedPrivateKeyPem = null;
    _cachedPublicKeyPem = null;
    _cachedDeviceType = null;

    await PlatformHardwareKeyStore.instance.deletePrivateKey();
    await _putSetting(_keyDeviceId, '');
    await _putSetting(_keyPublicKey, '');
    await _putSetting(_keyDeviceType, '');
    await _putSetting(_keyEnrolled, 'false');
    await init();
  }
}
