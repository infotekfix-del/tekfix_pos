import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';
import 'barcode_label_models.dart';
import 'tspl_generator.dart';

/// Direct Windows Print Spooler communicator using native Win32 API.
/// Sends raw TSPL commands directly to TVS LP 46 Lite / LP 44 Lite via USB/Spooler.
class WindowsRawPrinter {
  WindowsRawPrinter._();
  static final WindowsRawPrinter instance = WindowsRawPrinter._();

  /// Lists all printers installed on the Windows system.
  Future<List<PrinterDevice>> listPrinters() async {
    if (!Platform.isWindows) return [];

    final list = <PrinterDevice>[];

    try {
      final res = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-Command',
          'Get-CimInstance Win32_Printer | Select-Object Name, DriverName, PortName, Default | ConvertTo-Json',
        ],
      );

      if (res.exitCode == 0 && res.stdout.toString().trim().isNotEmpty) {
        final decoded = json.decode(res.stdout.toString().trim());
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              list.add(PrinterDevice(
                name: (item['Name'] ?? '').toString().trim(),
                driver: (item['DriverName'] ?? '').toString().trim(),
                port: (item['PortName'] ?? '').toString().trim(),
                isDefault: item['Default'] == true,
              ));
            }
          }
        } else if (decoded is Map) {
          list.add(PrinterDevice(
            name: (decoded['Name'] ?? '').toString().trim(),
            driver: (decoded['DriverName'] ?? '').toString().trim(),
            port: (decoded['PortName'] ?? '').toString().trim(),
            isDefault: decoded['Default'] == true,
          ));
        }
      }
    } catch (e) {
      debugPrint('WindowsRawPrinter: Error listing printers: $e');
    }

    return list;
  }

  /// Finds the preferred TVS LP 46 Lite / LP 44 Lite / TT065 printer if available.
  Future<PrinterDevice?> findTargetPrinter() async {
    final printers = await listPrinters();
    for (final p in printers) {
      if (p.isTargetTvs) return p;
    }
    for (final p in printers) {
      if (p.isDefault) return p;
    }
    return printers.isNotEmpty ? printers.first : null;
  }

  /// Sends raw TSPL command bytes directly to the specified Windows printer.
  /// Bypasses the GDI printer driver completely, preventing blank label skips.
  Future<PrintJobResult> sendRawTspl({
    required String printerName,
    required String tsplCommand,
    String docName = 'TekFix Barcode Print',
    int labelsCount = 1,
  }) async {
    if (!Platform.isWindows) {
      return const PrintJobResult(
        success: false,
        message: 'Direct RAW spooler is only supported on Windows Desktop.',
        error: 'Unsupported platform',
      );
    }

    if (printerName.trim().isEmpty) {
      return const PrintJobResult(
        success: false,
        message: 'Printer not specified.',
        error: 'Empty printer name',
      );
    }

    final pPrinterName = printerName.toNativeUtf16();
    final phPrinter = calloc<HANDLE>();
    final pDocName = docName.toNativeUtf16();
    final pDataType = 'RAW'.toNativeUtf16();

    try {
      // 1. Open Printer Handle
      final openRes = OpenPrinter(pPrinterName, phPrinter, nullptr);
      if (openRes == 0) {
        final err = GetLastError();
        return PrintJobResult(
          success: false,
          message: 'Failed to connect to printer "$printerName". (Error code $err)',
          error: 'OpenPrinter error $err',
        );
      }

      final hPrinter = phPrinter.value;

      // 2. Setup DOC_INFO_1 with RAW datatype
      final pDocInfo = calloc<DOC_INFO_1>();
      pDocInfo.ref.pDocName = pDocName;
      pDocInfo.ref.pOutputFile = nullptr;
      pDocInfo.ref.pDatatype = pDataType;

      // 3. Start Document
      final docJobId = StartDocPrinter(hPrinter, 1, pDocInfo);
      if (docJobId == 0) {
        final err = GetLastError();
        ClosePrinter(hPrinter);
        free(pDocInfo);
        return PrintJobResult(
          success: false,
          message: 'Failed to start print job on "$printerName". (Error $err)',
          error: 'StartDocPrinter error $err',
        );
      }

      try {
        // 4. Start Page
        final pageRes = StartPagePrinter(hPrinter);
        if (pageRes == 0) {
          final err = GetLastError();
          EndDocPrinter(hPrinter);
          ClosePrinter(hPrinter);
          free(pDocInfo);
          return PrintJobResult(
            success: false,
            message: 'Failed to initialize label page. (Error $err)',
            error: 'StartPagePrinter error $err',
          );
        }

        try {
          // 5. Write RAW TSPL Bytes
          final rawBytes = utf8.encode(tsplCommand);
          final pBytes = calloc<Uint8>(rawBytes.length);
          final bytesList = pBytes.asTypedList(rawBytes.length);
          bytesList.setAll(0, rawBytes);

          final pBytesWritten = calloc<DWORD>();

          try {
            final writeRes = WritePrinter(
              hPrinter,
              pBytes.cast<Void>(),
              rawBytes.length,
              pBytesWritten,
            );

            if (writeRes == 0) {
              final err = GetLastError();
              return PrintJobResult(
                success: false,
                message: 'Failed to write data to printer. (Error $err)',
                error: 'WritePrinter error $err',
              );
            }

            final written = pBytesWritten.value;
            debugPrint('WindowsRawPrinter: Wrote $written bytes to "$printerName"');
          } finally {
            free(pBytes);
            free(pBytesWritten);
          }
        } finally {
          EndPagePrinter(hPrinter);
        }
      } finally {
        EndDocPrinter(hPrinter);
        ClosePrinter(hPrinter);
        free(pDocInfo);
      }

      return PrintJobResult(
        success: true,
        message: 'Printed $labelsCount label(s) successfully to $printerName.',
        labelsPrinted: labelsCount,
      );
    } catch (e) {
      return PrintJobResult(
        success: false,
        message: 'Printing error: $e',
        error: e.toString(),
      );
    } finally {
      free(pPrinterName);
      free(phPrinter);
      free(pDocName);
      free(pDataType);
    }
  }

  /// Sends a Gap Sensor Calibration command (`GAPDETECT\r\n`) to TVS LP 46 Lite.
  Future<PrintJobResult> calibrate(String printerName) async {
    final cmd = TsplGenerator.generateCalibrationCommand();
    return sendRawTspl(
      printerName: printerName,
      tsplCommand: cmd,
      docName: 'TekFix Gap Sensor Calibration',
      labelsCount: 0,
    );
  }

  /// Sends a single test label (38x25mm or 50x25mm) to verify alignment.
  Future<PrintJobResult> testPrint(String printerName, {PrinterConfig config = const PrinterConfig()}) async {
    final testItem = BarcodeLabelItem(
      name: 'TEST PRODUCT ${config.widthMm.toStringAsFixed(0)}X${config.heightMm.toStringAsFixed(0)}MM',
      barcode: 'TF999888',
      itemCode: 'TEST-001',
      sellingPrice: 499.0,
      quantity: 1,
    );

    final tspl = TsplGenerator.generateSingleItem(
      item: testItem,
      config: config,
      showPrice: true,
      quantity: 1,
    );

    return sendRawTspl(
      printerName: printerName,
      tsplCommand: tspl,
      docName: 'TekFix Test Label ${config.profile.shortName}',
      labelsCount: 1,
    );
  }
}

