// Real ECDSA P-256 device signatures (Windows path). The recharge-bridge edge
// function verifies with WebCrypto ECDSA P-256/SHA-256; these tests check the
// same maths, and the key vault stays in a temporary test folder.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:pointycastle/export.dart' show ECCurve_secp256r1;
import 'package:tekfix_erp_pos/main.dart' show boxSettings;
import 'package:tekfix_erp_pos/security/device_security_service.dart';
import 'package:tekfix_erp_pos/security/p256_ecdsa.dart';
import 'package:tekfix_erp_pos/security/platform_hardware_key_store.dart';

void main() {
  final n = ECCurve_secp256r1().n;

  group('P256Ecdsa', () {
    test('d = 1 gives the curve generator G as the public key', () {
      final pem = P256Ecdsa.publicKeyPem(BigInt.one);
      final der = base64Decode(pem.split('\n').where((l) => !l.startsWith('-----')).join());
      expect(der.length, 91);
      final x = der.sublist(27, 59).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(x, '6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296');
    });

    test('sign / verify round trip; tampered payload and other key fail', () {
      final d = P256Ecdsa.generateScalar();
      final pem = P256Ecdsa.publicKeyPem(d);
      const payload = 'ISSUE_STAGING_TOKEN:shop_staging_001:owner_staging_001:DEV_WIN_X:nonce123';
      final sig = P256Ecdsa.signDerHex(d, payload);
      expect(P256Ecdsa.verifyDerHex(pem, payload, sig), isTrue);
      expect(P256Ecdsa.verifyDerHex(pem, '${payload}x', sig), isFalse);
      final other = P256Ecdsa.publicKeyPem(P256Ecdsa.generateScalar());
      expect(P256Ecdsa.verifyDerHex(other, payload, sig), isFalse);
      // Deterministic k: same key + payload -> same signature.
      expect(P256Ecdsa.signDerHex(d, payload), sig);
    });

    test('private key vault format round trip; invalid keys rejected', () {
      final d = P256Ecdsa.generateScalar();
      expect(P256Ecdsa.scalarFromPrivateKeyPem(P256Ecdsa.privateKeyPem(d)), d);
      expect(P256Ecdsa.scalarFromPrivateKeyPem(null), isNull);
      expect(P256Ecdsa.scalarFromPrivateKeyPem(
          '-----BEGIN EC PRIVATE KEY-----\n0123456789abcdef\n-----END EC PRIVATE KEY-----'), isNull);
      expect(P256Ecdsa.scalarFromPrivateKeyPem(
          '-----BEGIN EC PRIVATE KEY-----\n${'0' * 64}\n-----END EC PRIVATE KEY-----'), isNull);
      expect(P256Ecdsa.scalarFromPrivateKeyPem(
          '-----BEGIN EC PRIVATE KEY-----\n${n.toRadixString(16).padLeft(64, '0')}\n-----END EC PRIVATE KEY-----'), isNull);
    });

    test('writes a sample for the Node WebCrypto cross-check', () {
      final out = Platform.environment['TEKFIX_P256_SAMPLE_OUT'];
      if (out == null || out.isEmpty) return;
      final samples = [
        for (var i = 0; i < 20; i++)
          () {
            final d = P256Ecdsa.generateScalar();
            final payload = 'ISSUE_STAGING_TOKEN:shop_staging_001:owner_staging_001:DEV_WIN_$i:n$i';
            return {
              'publicKeyPem': P256Ecdsa.publicKeyPem(d),
              'payload': payload,
              'signatureHex': P256Ecdsa.signDerHex(d, payload),
            };
          }(),
      ];
      File(out).writeAsStringSync(jsonEncode(samples));
    });
  });

  group('DeviceSecurityService (Windows path)', () {
    late Directory tmp;

    setUpAll(() async {
      tmp = await Directory.systemTemp.createTemp('tekfix_p256_svc_');
      Hive.init(tmp.path);
      await Hive.openBox(boxSettings);
      DeviceSecurityService.overridePlatformForTesting = DevicePlatformType.windows;
    });

    tearDownAll(() {
      DeviceSecurityService.overridePlatformForTesting = null;
    });

    test('key vault used by tests is a temporary folder, not %LOCALAPPDATA%', () async {
      await PlatformHardwareKeyStore.instance.init();
      final path = PlatformHardwareKeyStore.instance.vaultDirPath!;
      expect(path.startsWith(Directory.systemTemp.path), isTrue, reason: path);
      expect(path.contains('tekfix_test_vault'), isTrue, reason: path);
      final local = Platform.environment['LOCALAPPDATA'];
      if (local != null) {
        // Never the real vaults of the installed apps.
        expect(path.toLowerCase().startsWith('$local\\TekFixERP'.toLowerCase()), isFalse);
      }
    });

    test('new device keys produce signatures that verify against its public key', () async {
      final sec = DeviceSecurityService.instance;
      await sec.resetDeviceKeys();
      const payload = 'ISSUE_STAGING_TOKEN:shop_staging_001:owner_staging_001:DEV:nonce';
      final sig = await sec.signRawPayload(payload);
      expect(P256Ecdsa.verifyDerHex(sec.publicKeyPem, payload, sig), isTrue);
    });

    test('legacy simulated key is upgraded: same device id, real public key', () async {
      final d = P256Ecdsa.generateScalar();
      await PlatformHardwareKeyStore.instance.writePrivateKey(P256Ecdsa.privateKeyPem(d));
      final settings = Hive.box(boxSettings);
      await settings.put('trusted_device_id', 'DEV_WIN_LEGACY');
      await settings.put('trusted_device_public_key_pem',
          '-----BEGIN PUBLIC KEY-----\nFAKEHASHDERIVEDKEY\n-----END PUBLIC KEY-----');

      final sec = DeviceSecurityService.instance;
      await sec.init();
      expect(sec.deviceId, 'DEV_WIN_LEGACY');
      expect(sec.publicKeyPem, P256Ecdsa.publicKeyPem(d));
      expect(settings.get('trusted_device_public_key_pem'), P256Ecdsa.publicKeyPem(d));
      final sig = await sec.signRawPayload('x');
      expect(P256Ecdsa.verifyDerHex(sec.publicKeyPem, 'x', sig), isTrue);
    });

    test('unusable stored key gets a new pair but keeps the device id', () async {
      await PlatformHardwareKeyStore.instance.writePrivateKey(
          '-----BEGIN EC PRIVATE KEY-----\nnot-a-key\n-----END EC PRIVATE KEY-----');
      await Hive.box(boxSettings).put('trusted_device_id', 'DEV_WIN_KEEP');
      final sec = DeviceSecurityService.instance;
      await sec.init();
      expect(sec.deviceId, 'DEV_WIN_KEEP');
      final sig = await sec.signRawPayload('y');
      expect(P256Ecdsa.verifyDerHex(sec.publicKeyPem, 'y', sig), isTrue);
    });
  });
}
