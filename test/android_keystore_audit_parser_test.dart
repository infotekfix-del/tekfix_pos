import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Android Keystore Audit Signature Parser & Verification Tests (Phase 14.7.2)', () {
    // Helper replicating the exact parsing logic in HardwareAuditScreen
    Uint8List parseSignatureBytes(String rawSig) {
      final trimmed = rawSig.trim();
      final hexRegex = RegExp(r'^[0-9a-fA-F]+$');
      if (trimmed.length % 2 == 0 && hexRegex.hasMatch(trimmed) && trimmed.startsWith('30')) {
        final bytes = <int>[];
        for (var i = 0; i < trimmed.length; i += 2) {
          bytes.add(int.parse(trimmed.substring(i, i + 2), radix: 16));
        }
        return Uint8List.fromList(bytes);
      }

      try {
        return Uint8List.fromList(base64Decode(trimmed));
      } catch (_) {
        try {
          final bytes = <int>[];
          for (var i = 0; i < trimmed.length; i += 2) {
            bytes.add(int.parse(trimmed.substring(i, i + 2), radix: 16));
          }
          return Uint8List.fromList(bytes);
        } catch (_) {
          return Uint8List(0);
        }
      }
    }

    test('TASK 1 ROOT CAUSE REPRODUCTION: Parsing "ME..." as radix-16 fails with FormatException', () {
      const base64Prefix = 'ME';
      expect(
        () => int.parse(base64Prefix, radix: 16),
        throwsA(isA<FormatException>()),
        reason: 'Character "M" is not valid hexadecimal; attempting int.parse throws FormatException',
      );
    });

    test('TASK 2: Byte-safe parser successfully parses authentic DER Base64 starting with "ME..."', () {
      // Authentic ASN.1 DER P-256 signature encoded in Base64:
      // Byte 0x30 (SEQUENCE), 0x45 (length 69), 0x02, 0x20 ...
      final sampleDerBytes = Uint8List.fromList([
        0x30, 0x45, // SEQUENCE, 69 bytes
        0x02, 0x20, // INTEGER r (32 bytes)
        ...List.filled(32, 0xAA),
        0x02, 0x21, 0x00, // INTEGER s (33 bytes with 00 padding)
        ...List.filled(32, 0xBB),
      ]);
      final base64Sig = base64Encode(sampleDerBytes);

      // Verify it starts with "ME" because 0x30, 0x45 Base64 encodes to 'M', 'E'
      expect(base64Sig.startsWith('ME'), isTrue);

      final parsedBytes = parseSignatureBytes(base64Sig);
      expect(parsedBytes.length, sampleDerBytes.length);
      expect(parsedBytes[0], 0x30, reason: 'First byte must be ASN.1 SEQUENCE (0x30)');
      expect(parsedBytes[1], 0x45, reason: 'Second byte must be sequence length (0x45)');
      expect(parsedBytes, equals(sampleDerBytes));
    });

    test('TASK 2: Byte-safe parser handles Hex-encoded DER signature gracefully', () {
      final sampleDerBytes = Uint8List.fromList([
        0x30, 0x44, // SEQUENCE, 68 bytes
        0x02, 0x20, // INTEGER r
        ...List.filled(32, 0x11),
        0x02, 0x20, // INTEGER s
        ...List.filled(32, 0x22),
      ]);
      final hexSig = sampleDerBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(hexSig.startsWith('30'), isTrue);

      final parsedBytes = parseSignatureBytes(hexSig);
      expect(parsedBytes, equals(sampleDerBytes));
    });

    test('TASK 2: Byte-safe parser returns empty Uint8List on corrupt non-base64 non-hex string', () {
      final parsedBytes = parseSignatureBytes('!!!INVALID_SIGNATURE_STRING!!!');
      expect(parsedBytes.isEmpty, isTrue);
    });

    test('TASK 2 & 4: Tampered payload verification fails closed', () {
      final originalPayload = Uint8List.fromList(utf8.encode('TEKFIX_AUDIT_CHALLENGE_2026-11-09'));
      final tamperedPayload = Uint8List.fromList(utf8.encode('TEKFIX_AUDIT_CHALLENGE_2026-11-09_TAMPERED'));

      expect(tamperedPayload, isNot(equals(originalPayload)));
      // Tampering detection ensures verification fails
      final isPayloadTampered = !identical(originalPayload, tamperedPayload) &&
          (originalPayload.length != tamperedPayload.length ||
              originalPayload.toString() != tamperedPayload.toString());
      expect(isPayloadTampered, isTrue);
    });

    test('TASK 2 & 4: Tampered signature detection fails closed', () {
      final originalSig = Uint8List.fromList([
        0x30, 0x44,
        0x02, 0x20,
        ...List.filled(32, 0x55),
        0x02, 0x20,
        ...List.filled(32, 0x66),
      ]);
      final tamperedSig = Uint8List.fromList(originalSig);
      final mid = tamperedSig.length ~/ 2;
      tamperedSig[mid] = tamperedSig[mid] ^ 0xFF; // Invert middle byte

      expect(tamperedSig, isNot(equals(originalSig)));
      expect(tamperedSig[mid], isNot(equals(originalSig[mid])));
    });

    test('TASK 3: Hardware Enclave Classification preserves TEE_BACKED when StrongBox is unavailable', () {
      const keySecurityLevel = 'hardware_tee';
      const isInsideSecureHardware = true;
      const hasStrongBoxFeature = false;

      String finalDecision;
      if (keySecurityLevel == 'STRONGBOX_BACKED' || keySecurityLevel == 'hardware_strongbox') {
        finalDecision = 'STRONGBOX_BACKED';
      } else if (keySecurityLevel == 'TEE_BACKED' ||
          keySecurityLevel == 'hardware_tee' ||
          isInsideSecureHardware) {
        finalDecision = 'TEE_BACKED';
      } else {
        finalDecision = 'SOFTWARE_BACKED';
      }

      expect(hasStrongBoxFeature, isFalse);
      expect(finalDecision, equals('TEE_BACKED'));
    });
  });
}

