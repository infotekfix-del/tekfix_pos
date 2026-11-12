import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tekfix_erp_pos/security/device_security_service.dart';
import 'package:tekfix_erp_pos/security/platform_hardware_key_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'com.example.tekfix_pos/keystore';
  final List<MethodCall> channelCalls = [];
  bool strongBoxSupported = true;
  bool keyExistsInKeystore = false;

  setUp(() {
    channelCalls.clear();
    strongBoxSupported = true;
    keyExistsInKeystore = false;
    PlatformHardwareKeyStore.simulateDpapiFailureForTesting = false;
    DeviceSecurityService.overridePlatformForTesting = null;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), (MethodCall call) async {
      channelCalls.add(call);
      switch (call.method) {
        case 'getSecurityLevel':
          return strongBoxSupported ? 'hardware_strongbox' : 'hardware_tee';
        case 'generateKey':
          keyExistsInKeystore = true;
          return {
            'publicKeyPem': '-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEandroid_mock_public_key_point\n-----END PUBLIC KEY-----',
            'securityLevel': strongBoxSupported ? 'hardware_strongbox' : 'hardware_tee',
          };
        case 'signPayload':
          if (!keyExistsInKeystore) {
            throw PlatformException(code: 'KEY_NOT_FOUND', message: 'No key in keystore');
          }
          // Return valid Base64 DER sequence for ASN.1 ECDSA signature
          // 30 06 02 01 01 02 01 02
          final derBytes = Uint8List.fromList([0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02]);
          return base64Encode(derBytes);
        case 'hasKey':
          return keyExistsInKeystore;
        case 'deleteKey':
          keyExistsInKeystore = false;
          return true;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), null);
    PlatformHardwareKeyStore.simulateDpapiFailureForTesting = false;
    DeviceSecurityService.overridePlatformForTesting = null;
  });

  group('TEKFIX ERP - PHASE 14.3: HARDWARE KEYSTORE & DPAPI REMEDIATION TESTS', () {
    test('FIX C1 (TEST 1): Android Keystore generateKey is called natively and returns StrongBox/TEE level', () async {
      final keyStore = PlatformHardwareKeyStore.instance;
      final keyRes = await keyStore.generateAndroidHardwareKey(alias: 'test_owner_key');

      expect(keyRes['publicKeyPem'], contains('BEGIN PUBLIC KEY'));
      expect(keyRes['securityLevel'], equals('hardware_strongbox'));
      expect(channelCalls.any((c) => c.method == 'generateKey' && c.arguments['alias'] == 'test_owner_key'), isTrue);
      expect(await keyStore.hasAndroidHardwareKey(alias: 'test_owner_key'), isTrue);
    });

    test('FIX C1 (TEST 2): Android Keystore signPayload signs natively and returns DER hex signature', () async {
      final keyStore = PlatformHardwareKeyStore.instance;
      await keyStore.generateAndroidHardwareKey(alias: 'test_owner_key');

      final payload = Uint8List.fromList(utf8.encode('shop_1:owner_1:DEV_ANDR_01:nonce_12345'));
      final sigHex = await keyStore.signWithAndroidHardwareKey(alias: 'test_owner_key', payload: payload);

      expect(sigHex, equals('3006020101020102'));
      expect(channelCalls.any((c) => c.method == 'signPayload'), isTrue);
    });

    test('FIX C1 (TEST 3): Android DeviceSecurityService delegates keygen and signing to native Keystore with ZERO plaintext files', () async {
      DeviceSecurityService.overridePlatformForTesting = DevicePlatformType.android;

      final sec = DeviceSecurityService.instance;
      await sec.generateDeviceKeys();

      expect(sec.deviceType, equals('mobile'));
      expect(sec.publicKeyPem, contains('BEGIN PUBLIC KEY'));
      expect(channelCalls.any((c) => c.method == 'generateKey'), isTrue);

      // Sign challenge
      final sigHex = await sec.signChallenge(shopId: 'shop_1', ownerUid: 'owner_1', nonce: 'nonce_999');
      expect(sigHex, isNotEmpty);
      expect(channelCalls.any((c) => c.method == 'signPayload'), isTrue);

      // Assert that NO plaintext private key file exists in systemTemp or vault dir
      final tempVault = Directory(p.join(Directory.systemTemp.path, 'tekfix_secure_vault'));
      if (tempVault.existsSync()) {
        final keyFile = File(p.join(tempVault.path, 'device_private_p256.key'));
        expect(keyFile.existsSync(), isFalse, reason: 'Security Violation: Plaintext key file found on disk!');
      }
    });

    test('FIX B1 (TEST 4): Windows DPAPI fail-closed - CryptProtectData failure aborts and NEVER writes plaintext PEM', () async {
      if (!Platform.isWindows) return;

      final keyStore = PlatformHardwareKeyStore.instance;
      await keyStore.init();

      // Enable simulated DPAPI failure
      PlatformHardwareKeyStore.simulateDpapiFailureForTesting = true;

      const testPrivKey = '-----BEGIN EC PRIVATE KEY-----\nsecret_private_key_data\n-----END EC PRIVATE KEY-----';

      expect(
        () async => await keyStore.writePrivateKey(testPrivKey),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('CryptProtectData failed'),
        )),
      );

      // Verify that NO plaintext fallback file was written
      final localAppData = Platform.environment['LOCALAPPDATA'] ?? Directory.current.path;
      final plaintextFile = File(p.join(localAppData, 'TekFixERP', 'tekfix_secure_vault', 'device_private_p256.key'));
      expect(plaintextFile.existsSync(), isFalse, reason: 'Security Violation: Plaintext fallback file was written after DPAPI failure!');
    });

    test('FIX B1 (TEST 5): Windows DPAPI success round-trip encrypts and decrypts with DPAPI binary blob on disk', () async {
      if (!Platform.isWindows) return;

      final keyStore = PlatformHardwareKeyStore.instance;
      await keyStore.init();

      const testPrivKey = '-----BEGIN EC PRIVATE KEY-----\n0123456789abcdef_dpapi_test\n-----END EC PRIVATE KEY-----';
      await keyStore.writePrivateKey(testPrivKey);

      final readBack = await keyStore.readPrivateKey();
      expect(readBack, equals(testPrivKey));

      // Verify binary file exists and is NOT plaintext
      final localAppData = Platform.environment['LOCALAPPDATA'] ?? Directory.current.path;
      final dpapiFile = File(p.join(localAppData, 'TekFixERP', 'tekfix_secure_vault', 'device_private_p256.dpapi'));
      expect(dpapiFile.existsSync(), isTrue);

      final rawBytes = await dpapiFile.readAsBytes();
      final asString = String.fromCharCodes(rawBytes);
      expect(asString.contains('0123456789abcdef'), isFalse, reason: 'Security Violation: Private key is visible in DPAPI file!');

      await keyStore.deletePrivateKey();
      expect(await keyStore.readPrivateKey(), isNull);
    });
  });
}
