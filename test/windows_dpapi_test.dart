import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

final class DataBlob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef CryptProtectDataC = Int32 Function(
  Pointer<DataBlob> pDataIn,
  Pointer<Utf16> szDataDescr,
  Pointer<DataBlob> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  Uint32 dwFlags,
  Pointer<DataBlob> pDataOut,
);
typedef CryptProtectDataDart = int Function(
  Pointer<DataBlob> pDataIn,
  Pointer<Utf16> szDataDescr,
  Pointer<DataBlob> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  int dwFlags,
  Pointer<DataBlob> pDataOut,
);

typedef CryptUnprotectDataC = Int32 Function(
  Pointer<DataBlob> pDataIn,
  Pointer<Pointer<Utf16>> ppszDataDescr,
  Pointer<DataBlob> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  Uint32 dwFlags,
  Pointer<DataBlob> pDataOut,
);
typedef CryptUnprotectDataDart = int Function(
  Pointer<DataBlob> pDataIn,
  Pointer<Pointer<Utf16>> ppszDataDescr,
  Pointer<DataBlob> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  int dwFlags,
  Pointer<DataBlob> pDataOut,
);

void main() {
  test('Windows DPAPI CryptProtectData & CryptUnprotectData FFI test', () {
    if (!Platform.isWindows) return;

    final crypt32 = DynamicLibrary.open('crypt32.dll');
    final kernel32 = DynamicLibrary.open('kernel32.dll');

    final cryptProtectData = crypt32.lookupFunction<CryptProtectDataC, CryptProtectDataDart>('CryptProtectData');
    final cryptUnprotectData = crypt32.lookupFunction<CryptUnprotectDataC, CryptUnprotectDataDart>('CryptUnprotectData');
    final localFree = kernel32.lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>('LocalFree');

    const plainText = '-----BEGIN EC PRIVATE KEY-----\nTEST_P256_PRIVATE_KEY_BYTES\n-----END EC PRIVATE KEY-----';
    final plainBytes = Uint8List.fromList(plainText.codeUnits);

    // 1. Encrypt with CryptProtectData
    final pDataIn = calloc<DataBlob>();
    pDataIn.ref.cbData = plainBytes.length;
    pDataIn.ref.pbData = calloc<Uint8>(plainBytes.length);
    for (var i = 0; i < plainBytes.length; i++) {
      pDataIn.ref.pbData[i] = plainBytes[i];
    }

    final pDataOut = calloc<DataBlob>();
    // ignore: constant_identifier_names
    const CRYPTPROTECT_UI_FORBIDDEN = 0x1;

    final protectSuccess = cryptProtectData(
      pDataIn,
      nullptr,
      nullptr,
      nullptr,
      nullptr,
      CRYPTPROTECT_UI_FORBIDDEN,
      pDataOut,
    );

    expect(protectSuccess, equals(1), reason: 'CryptProtectData should return 1 (TRUE)');
    expect(pDataOut.ref.cbData, greaterThan(0));

    final cipherBytes = Uint8List(pDataOut.ref.cbData);
    for (var i = 0; i < pDataOut.ref.cbData; i++) {
      cipherBytes[i] = pDataOut.ref.pbData[i];
    }

    // Free inputs
    calloc.free(pDataIn.ref.pbData);
    calloc.free(pDataIn);
    localFree(pDataOut.ref.pbData.cast<Void>());
    calloc.free(pDataOut);

    expect(cipherBytes, isNot(equals(plainBytes)));

    // 2. Decrypt with CryptUnprotectData
    final pUnprotectIn = calloc<DataBlob>();
    pUnprotectIn.ref.cbData = cipherBytes.length;
    pUnprotectIn.ref.pbData = calloc<Uint8>(cipherBytes.length);
    for (var i = 0; i < cipherBytes.length; i++) {
      pUnprotectIn.ref.pbData[i] = cipherBytes[i];
    }

    final pUnprotectOut = calloc<DataBlob>();
    final unprotectSuccess = cryptUnprotectData(
      pUnprotectIn,
      nullptr,
      nullptr,
      nullptr,
      nullptr,
      CRYPTPROTECT_UI_FORBIDDEN,
      pUnprotectOut,
    );

    expect(unprotectSuccess, equals(1), reason: 'CryptUnprotectData should return 1 (TRUE)');
    final decryptedBytes = Uint8List(pUnprotectOut.ref.cbData);
    for (var i = 0; i < pUnprotectOut.ref.cbData; i++) {
      decryptedBytes[i] = pUnprotectOut.ref.pbData[i];
    }

    final decryptedText = String.fromCharCodes(decryptedBytes);
    expect(decryptedText, equals(plainText));

    calloc.free(pUnprotectIn.ref.pbData);
    calloc.free(pUnprotectIn);
    localFree(pUnprotectOut.ref.pbData.cast<Void>());
    calloc.free(pUnprotectOut);
  });
}
