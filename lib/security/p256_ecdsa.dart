// ============================================================================
// TEKFIX ERP - Real ECDSA P-256 (secp256r1) for the Windows device key.
// ============================================================================
//
// Replaces the earlier simulated key/signature (hash-derived "public key" and
// HMAC "signature"), which a real verifier such as the recharge-bridge edge
// function (WebCrypto ECDSA P-256 / SHA-256) could never accept.
//
// * Public key  : X.509 SubjectPublicKeyInfo (SPKI) PEM, uncompressed point.
// * Signature   : ASN.1 DER SEQUENCE { INTEGER r, INTEGER s } as lower-case hex,
//                 ECDSA with SHA-256 over the UTF-8 payload, deterministic k
//                 (RFC 6979 style, HMAC-SHA256) and low-S normalised.
// * Private key : the 32-byte scalar, kept in the existing vault format
//                 "-----BEGIN EC PRIVATE KEY-----\n<64 hex>\n-----END EC PRIVATE KEY-----".
// ============================================================================

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

class P256Ecdsa {
  P256Ecdsa._();

  static final ECDomainParameters _curve = ECCurve_secp256r1();

  /// SPKI prefix for an id-ecPublicKey / prime256v1 uncompressed point.
  static const List<int> _spkiPrefix = [
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
    0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
  ];

  /// True when [d] is a valid private scalar (1 <= d < n).
  static bool isValidScalar(BigInt d) => d > BigInt.zero && d < _curve.n;

  /// A new random valid private scalar.
  static BigInt generateScalar([Random? rng]) {
    final r = rng ?? Random.secure();
    while (true) {
      final bytes = Uint8List.fromList(List<int>.generate(32, (_) => r.nextInt(256)));
      final d = bytesToBigInt(bytes);
      if (isValidScalar(d)) return d;
    }
  }

  static String privateKeyPem(BigInt d) =>
      '-----BEGIN EC PRIVATE KEY-----\n${bigIntToFixed(d, 32).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}\n-----END EC PRIVATE KEY-----';

  /// Reads the scalar from the vault format; null if missing or invalid.
  static BigInt? scalarFromPrivateKeyPem(String? pem) {
    if (pem == null) return null;
    final hex = pem
        .replaceAll(RegExp(r'-----BEGIN [A-Z ]+-----'), '')
        .replaceAll(RegExp(r'-----END [A-Z ]+-----'), '')
        .replaceAll(RegExp(r'\s+'), '');
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hex)) return null;
    final d = BigInt.parse(hex, radix: 16);
    return isValidScalar(d) ? d : null;
  }

  /// SPKI PEM public key for the scalar [d].
  static String publicKeyPem(BigInt d) {
    final q = (_curve.G * d)!;
    final point = q.getEncoded(false); // 0x04 || X || Y (65 bytes)
    final b64 = base64Encode([..._spkiPrefix, ...point]);
    final lines = <String>[];
    for (var i = 0; i < b64.length; i += 64) {
      lines.add(b64.substring(i, min(i + 64, b64.length)));
    }
    return '-----BEGIN PUBLIC KEY-----\n${lines.join('\n')}\n-----END PUBLIC KEY-----';
  }

  /// ECDSA-SHA256 signature of [payload] as DER hex.
  static String signDerHex(BigInt d, String payload) {
    final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
      ..init(true, PrivateKeyParameter<ECPrivateKey>(ECPrivateKey(d, _curve)));
    var sig = signer.generateSignature(Uint8List.fromList(utf8.encode(payload))) as ECSignature;
    sig = sig.normalize(_curve); // low-S
    return derEncode(sig.r, sig.s).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Verifies a DER-hex signature against an SPKI PEM (used by tests).
  static bool verifyDerHex(String publicKeyPem, String payload, String derHex) {
    try {
      final b64 = publicKeyPem
          .replaceAll(RegExp(r'-----BEGIN [A-Z ]+-----'), '')
          .replaceAll(RegExp(r'-----END [A-Z ]+-----'), '')
          .replaceAll(RegExp(r'\s+'), '');
      final spki = base64Decode(b64);
      if (spki.length != 91) return false;
      for (var i = 0; i < _spkiPrefix.length; i++) {
        if (spki[i] != _spkiPrefix[i]) return false;
      }
      final q = _curve.curve.decodePoint(spki.sublist(_spkiPrefix.length));
      final (r, s) = derDecode(_hexToBytes(derHex));
      final verifier = ECDSASigner(SHA256Digest())
        ..init(false, PublicKeyParameter<ECPublicKey>(ECPublicKey(q, _curve)));
      return verifier.verifySignature(
          Uint8List.fromList(utf8.encode(payload)), ECSignature(r, s));
    } catch (_) {
      return false;
    }
  }

  // --------------------------------------------------------------- helpers
  static BigInt bytesToBigInt(List<int> bytes) {
    var r = BigInt.zero;
    for (final b in bytes) {
      r = (r << 8) | BigInt.from(b);
    }
    return r;
  }

  static Uint8List bigIntToFixed(BigInt v, int length) {
    final out = Uint8List(length);
    var x = v;
    for (var i = length - 1; i >= 0; i--) {
      out[i] = (x & BigInt.from(0xff)).toInt();
      x = x >> 8;
    }
    return out;
  }

  static List<int> _derInt(BigInt v) {
    var bytes = bigIntToFixed(v, 33).toList();
    while (bytes.length > 1 && bytes[0] == 0 && (bytes[1] & 0x80) == 0) {
      bytes = bytes.sublist(1);
    }
    return [0x02, bytes.length, ...bytes];
  }

  static Uint8List derEncode(BigInt r, BigInt s) {
    final body = [..._derInt(r), ..._derInt(s)];
    return Uint8List.fromList([0x30, body.length, ...body]);
  }

  static (BigInt, BigInt) derDecode(Uint8List der) {
    if (der.isEmpty || der[0] != 0x30) throw const FormatException('not a SEQUENCE');
    var i = 2;
    BigInt readInt() {
      if (der[i] != 0x02) throw const FormatException('not an INTEGER');
      final len = der[i + 1];
      final v = bytesToBigInt(der.sublist(i + 2, i + 2 + len));
      i += 2 + len;
      return v;
    }

    final r = readInt();
    final s = readInt();
    return (r, s);
  }

  static Uint8List _hexToBytes(String hex) {
    final h = hex.trim();
    return Uint8List.fromList([
      for (var i = 0; i + 1 < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16),
    ]);
  }
}
