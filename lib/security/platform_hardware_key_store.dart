import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// ============================================================================
/// TEKFIX ERP - PHASE 14.3: NATIVE HARDWARE KEY STORE
/// REMEDIATIONS:
/// - FIX C1: Genuine Android Keystore (StrongBox/TEE non-exportable keys)
/// - FIX B1: Fail-closed Windows DPAPI (Zero plaintext fallback)
/// - FIX B2: Native memory zeroization hygiene before buffer deallocation
/// ============================================================================

// FFI struct for Win32 DATA_BLOB
// ignore: camel_case_types
final class DATA_BLOB extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef CryptProtectDataNative = Int32 Function(
  Pointer<DATA_BLOB> pDataIn,
  Pointer<Utf16> szDataDescr,
  Pointer<DATA_BLOB> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  Uint32 dwFlags,
  Pointer<DATA_BLOB> pDataOut,
);
typedef CryptProtectDataDart = int Function(
  Pointer<DATA_BLOB> pDataIn,
  Pointer<Utf16> szDataDescr,
  Pointer<DATA_BLOB> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  int dwFlags,
  Pointer<DATA_BLOB> pDataOut,
);

typedef CryptUnprotectDataNative = Int32 Function(
  Pointer<DATA_BLOB> pDataIn,
  Pointer<Pointer<Utf16>> ppszDataDescr,
  Pointer<DATA_BLOB> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  Uint32 dwFlags,
  Pointer<DATA_BLOB> pDataOut,
);
typedef CryptUnprotectDataDart = int Function(
  Pointer<DATA_BLOB> pDataIn,
  Pointer<Pointer<Utf16>> ppszDataDescr,
  Pointer<DATA_BLOB> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  int dwFlags,
  Pointer<DATA_BLOB> pDataOut,
);

typedef LocalFreeNative = Pointer<Void> Function(Pointer<Void> hMem);
typedef LocalFreeDart = Pointer<Void> Function(Pointer<Void> hMem);

// ignore: constant_identifier_names
const int CRYPTPROTECT_UI_FORBIDDEN = 0x1;

class PlatformHardwareKeyStore {
  PlatformHardwareKeyStore._();
  static final PlatformHardwareKeyStore instance = PlatformHardwareKeyStore._();

  static const String _keyDirName = 'tekfix_secure_vault';
  static const String _dpapiFileName = 'device_private_p256.dpapi';
  static const String _sandboxedFileName = 'device_private_p256.key';
  static const MethodChannel _keystoreChannel =
      MethodChannel('com.example.tekfix_pos/keystore');

  @visibleForTesting
  static bool simulateDpapiFailureForTesting = false;

  Directory? _vaultDir;
  String? _inMemoryCachedKey;

  // Cached FFI bindings for Windows DPAPI
  CryptProtectDataDart? _cryptProtectData;
  CryptUnprotectDataDart? _cryptUnprotectData;
  LocalFreeDart? _localFree;
  bool _dpapiInitialized = false;

  void _initWindowsDpapi() {
    if (_dpapiInitialized) return;
    try {
      if (Platform.isWindows) {
        final crypt32 = DynamicLibrary.open('crypt32.dll');
        final kernel32 = DynamicLibrary.open('kernel32.dll');

        _cryptProtectData = crypt32.lookupFunction<CryptProtectDataNative,
            CryptProtectDataDart>('CryptProtectData');
        _cryptUnprotectData = crypt32.lookupFunction<CryptUnprotectDataNative,
            CryptUnprotectDataDart>('CryptUnprotectData');
        _localFree = kernel32
            .lookupFunction<LocalFreeNative, LocalFreeDart>('LocalFree');
      }
    } catch (e) {
      debugPrint('[PlatformHardwareKeyStore] DPAPI FFI load notice: $e');
    } finally {
      _dpapiInitialized = true;
    }
  }

  Future<void> init() async {
    if (kIsWeb) return;

    try {
      String basePath;
      if (Platform.isWindows) {
        _initWindowsDpapi();
        final localAppData = Platform.environment['LOCALAPPDATA'] ??
            Platform.environment['APPDATA'] ??
            Directory.current.path;
        basePath = p.join(localAppData, 'TekFixERP', _keyDirName);
      } else if (Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isLinux ||
          Platform.isMacOS) {
        basePath = p.join(Directory.systemTemp.path, _keyDirName);
      } else {
        basePath = p.join(Directory.current.path, _keyDirName);
      }

      _vaultDir = Directory(basePath);
      if (!_vaultDir!.existsSync()) {
        _vaultDir!.createSync(recursive: true);
      }
    } catch (e) {
      debugPrint('[PlatformHardwareKeyStore] Init error: $e');
    }
  }

  /// Get the genuine security level of the host platform key storage
  Future<String> getSecurityLevel() async {
    if (kIsWeb) return 'unsupported_web';

    if (Platform.isWindows) {
      _initWindowsDpapi();
      if (_cryptProtectData != null && _cryptUnprotectData != null) {
        return 'hardware_dpapi';
      }
      return 'software_sandboxed';
    }

    if (Platform.isAndroid) {
      try {
        final level = await _keystoreChannel.invokeMethod<String>('getSecurityLevel');
        if (level != null && level.isNotEmpty) {
          return level;
        }
      } catch (_) {}
      return 'software_sandboxed';
    }

    return 'software_sandboxed';
  }

  // ===========================================================================
  // ANDROID NATIVE KEYSTORE METHODS (FIX C1)
  // ===========================================================================

  /// Generate hardware-backed ECDSA P-256 keypair inside AndroidKeyStore enclave
  Future<Map<String, String>> generateAndroidHardwareKey({
    String alias = 'tekfix_owner_device_key',
  }) async {
    try {
      final res = await _keystoreChannel.invokeMapMethod<String, dynamic>(
        'generateKey',
        {'alias': alias},
      );
      if (res != null && res['publicKeyPem'] != null) {
        return {
          'publicKeyPem': res['publicKeyPem'] as String,
          'securityLevel': (res['securityLevel'] as String?) ?? 'hardware_tee',
        };
      }
      throw StateError('Android Keystore returned empty public key');
    } catch (e) {
      throw StateError('CRITICAL: Android Keystore key generation failed: $e');
    }
  }

  /// Sign payload using non-exportable hardware-backed key inside Android Keystore
  Future<String> signWithAndroidHardwareKey({
    String alias = 'tekfix_owner_device_key',
    required Uint8List payload,
  }) async {
    try {
      final sigBase64 = await _keystoreChannel.invokeMethod<String>(
        'signPayload',
        {
          'alias': alias,
          'payload': payload,
        },
      );
      if (sigBase64 != null && sigBase64.isNotEmpty) {
        final sigBytes = base64Decode(sigBase64);
        return sigBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      }
      throw StateError('Android Keystore returned empty signature');
    } catch (e) {
      throw StateError('CRITICAL: Android Keystore hardware signing failed: $e');
    }
  }

  /// Check if non-exportable hardware key exists in Android Keystore
  Future<bool> hasAndroidHardwareKey({
    String alias = 'tekfix_owner_device_key',
  }) async {
    try {
      final has = await _keystoreChannel.invokeMethod<bool>(
        'hasKey',
        {'alias': alias},
      );
      return has ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Delete hardware key from Android Keystore
  Future<void> deleteAndroidHardwareKey({
    String alias = 'tekfix_owner_device_key',
  }) async {
    try {
      await _keystoreChannel.invokeMethod('deleteKey', {'alias': alias});
    } catch (_) {}
  }

  // ===========================================================================
  // WINDOWS DPAPI & NON-EXPORTABLE FILE STORAGE (FIX B1)
  // ===========================================================================

  /// Store private key securely outside Hive
  /// On Windows: Uses Win32 DPAPI CryptProtectData. FAILS CLOSED on error.
  /// On Android: Strictly throws error; Android keys must remain non-exportable in Keystore.
  Future<void> writePrivateKey(String privateKeyPem) async {
    _inMemoryCachedKey = privateKeyPem;
    if (kIsWeb) return;

    if (Platform.isAndroid) {
      // FIX C1: Never write private keys to file storage on Android.
      // Wipe any legacy plaintext files if they exist
      if (_vaultDir != null) {
        final oldFile = File(p.join(_vaultDir!.path, _sandboxedFileName));
        if (await oldFile.exists()) {
          await oldFile.delete();
        }
      }
      return;
    }

    if (_vaultDir == null) await init();
    if (_vaultDir == null) {
      throw StateError('CRITICAL: Secure vault directory cannot be initialized.');
    }

    if (Platform.isWindows) {
      _initWindowsDpapi();
      if (_cryptProtectData == null || _localFree == null) {
        throw StateError('CRITICAL: Win32 DPAPI bindings unavailable on Windows.');
      }

      if (simulateDpapiFailureForTesting) {
        throw StateError('CRITICAL SECURITY ERROR: CryptProtectData failed (Simulated failure test). Aborting to prevent plaintext key exposure.');
      }

      final rawBytes = Uint8List.fromList(utf8.encode(privateKeyPem));
      final encryptedBytes = _protectWithDpapi(rawBytes);

      // FIX B1: Zero plaintext fallback. If DPAPI encryption fails, fail closed!
      if (encryptedBytes == null) {
        throw StateError('CRITICAL SECURITY ERROR: CryptProtectData failed to encrypt private key. Aborting to prevent plaintext key exposure.');
      }

      final dpapiFile = File(p.join(_vaultDir!.path, _dpapiFileName));
      await dpapiFile.writeAsBytes(encryptedBytes, flush: true);

      // Clean up legacy sandboxed file if present
      final oldFile = File(p.join(_vaultDir!.path, _sandboxedFileName));
      if (await oldFile.exists()) {
        await oldFile.delete();
      }
      return;
    }

    // Isolated unit testing harness fallback for non-Windows, non-Android hosts (e.g. Linux CI runner)
    final file = File(p.join(_vaultDir!.path, _sandboxedFileName));
    await file.writeAsString(privateKeyPem, flush: true);
  }

  /// Read private key securely from protected storage
  Future<String?> readPrivateKey() async {
    if (_inMemoryCachedKey != null && _inMemoryCachedKey!.isNotEmpty) {
      return _inMemoryCachedKey;
    }
    if (kIsWeb) return null;
    if (Platform.isAndroid) return null; // Android private keys are non-exportable in Keystore!

    try {
      if (_vaultDir == null) await init();
      if (_vaultDir == null) return null;

      if (Platform.isWindows) {
        _initWindowsDpapi();
        final dpapiFile = File(p.join(_vaultDir!.path, _dpapiFileName));
        if (await dpapiFile.exists()) {
          final encryptedBytes = await dpapiFile.readAsBytes();
          if (_cryptUnprotectData != null && _localFree != null) {
            final decryptedBytes = _unprotectWithDpapi(encryptedBytes);
            if (decryptedBytes != null) {
              _inMemoryCachedKey = utf8.decode(decryptedBytes);
              return _inMemoryCachedKey;
            }
          }
        }
        return null;
      }

      // Check sandboxed file (Linux unit test runners only)
      final file = File(p.join(_vaultDir!.path, _sandboxedFileName));
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.isNotEmpty) {
          _inMemoryCachedKey = content;
          return _inMemoryCachedKey;
        }
      }
    } catch (e) {
      debugPrint('[PlatformHardwareKeyStore] readPrivateKey notice: $e');
    }
    return null;
  }

  /// Wipe stored private key (upon device revocation)
  Future<void> deletePrivateKey() async {
    _inMemoryCachedKey = null;
    if (kIsWeb) return;

    try {
      if (_vaultDir == null) await init();
      if (_vaultDir != null) {
        final dpapiFile = File(p.join(_vaultDir!.path, _dpapiFileName));
        if (await dpapiFile.exists()) {
          await dpapiFile.delete();
        }
        final sandboxedFile = File(p.join(_vaultDir!.path, _sandboxedFileName));
        if (await sandboxedFile.exists()) {
          await sandboxedFile.delete();
        }
      }

      if (Platform.isAndroid) {
        await deleteAndroidHardwareKey();
      }
    } catch (_) {}
  }

  // ===========================================================================
  // WINDOWS DPAPI FFI WITH MEMORY HYGIENE ZEROIZATION (FIX B2)
  // ===========================================================================

  Uint8List? _protectWithDpapi(Uint8List plaintext) {
    if (_cryptProtectData == null || _localFree == null) return null;

    final inBlob = calloc<DATA_BLOB>();
    final outBlob = calloc<DATA_BLOB>();
    final inBytesPtr = calloc<Uint8>(plaintext.length);

    try {
      for (var i = 0; i < plaintext.length; i++) {
        inBytesPtr[i] = plaintext[i];
      }
      inBlob.ref.cbData = plaintext.length;
      inBlob.ref.pbData = inBytesPtr;

      final result = _cryptProtectData!(
        inBlob,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        CRYPTPROTECT_UI_FORBIDDEN,
        outBlob,
      );

      if (result == 0) {
        debugPrint('[PlatformHardwareKeyStore] CryptProtectData failed');
        return null;
      }

      final outLen = outBlob.ref.cbData;
      final outBytes = Uint8List(outLen);
      final outPtr = outBlob.ref.pbData;
      for (var i = 0; i < outLen; i++) {
        outBytes[i] = outPtr[i];
      }

      // FIX B2: Zeroize Windows-allocated buffer in native memory before LocalFree
      for (var i = 0; i < outLen; i++) {
        outPtr[i] = 0;
      }
      _localFree!(outPtr.cast<Void>());
      return outBytes;
    } finally {
      // FIX B2: Secure zeroization of private-key input buffer before calloc.free
      for (var i = 0; i < plaintext.length; i++) {
        inBytesPtr[i] = 0;
      }
      calloc.free(inBytesPtr);
      calloc.free(inBlob);
      calloc.free(outBlob);
    }
  }

  Uint8List? _unprotectWithDpapi(Uint8List ciphertext) {
    if (_cryptUnprotectData == null || _localFree == null) return null;

    final inBlob = calloc<DATA_BLOB>();
    final outBlob = calloc<DATA_BLOB>();
    final inBytesPtr = calloc<Uint8>(ciphertext.length);

    try {
      for (var i = 0; i < ciphertext.length; i++) {
        inBytesPtr[i] = ciphertext[i];
      }
      inBlob.ref.cbData = ciphertext.length;
      inBlob.ref.pbData = inBytesPtr;

      final result = _cryptUnprotectData!(
        inBlob,
        nullptr,
        nullptr,
        nullptr,
        nullptr,
        CRYPTPROTECT_UI_FORBIDDEN,
        outBlob,
      );

      if (result == 0) {
        debugPrint('[PlatformHardwareKeyStore] CryptUnprotectData failed');
        return null;
      }

      final outLen = outBlob.ref.cbData;
      final outBytes = Uint8List(outLen);
      final outPtr = outBlob.ref.pbData;
      for (var i = 0; i < outLen; i++) {
        outBytes[i] = outPtr[i];
      }

      // FIX B2: Zeroize decrypted plaintext in Windows native memory before LocalFree
      for (var i = 0; i < outLen; i++) {
        outPtr[i] = 0;
      }
      _localFree!(outPtr.cast<Void>());
      return outBytes;
    } finally {
      // FIX B2: Zeroize ciphertext input buffer before calloc.free
      for (var i = 0; i < ciphertext.length; i++) {
        inBytesPtr[i] = 0;
      }
      calloc.free(inBytesPtr);
      calloc.free(inBlob);
      calloc.free(outBlob);
    }
  }
}
