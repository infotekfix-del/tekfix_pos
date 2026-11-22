// =============================================================================
// TEKFIX ERP — Offline OCR for photographed / scanned bills
//
// Windows 10/11 ships an offline OCR engine (Windows.Media.Ocr). We call it
// through Windows PowerShell 5.1 (always installed), so no plugin, no API key
// and no internet is needed. Scanned PDFs are first rasterised with the
// `printing` package (already a dependency, uses pdfium).
//
// Android: there is no built-in OCR reachable without adding a plugin
// (google_mlkit_text_recognition, free & offline). Until that is added,
// image bills on Android report "OCR not available" and the user can type
// the bill or upload the vendor's PDF instead.
// =============================================================================

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:printing/printing.dart';

import 'bill_text_layout.dart';

class BillOcrUnavailable implements Exception {
  final String message;
  const BillOcrUnavailable(this.message);
  @override
  String toString() => message;
}

class BillOcrService {
  BillOcrService._();
  static final BillOcrService instance = BillOcrService._();

  bool get isSupported => !kIsWeb && Platform.isWindows;

  /// OCRs an image file (png/jpg/bmp/tiff). Returns positioned word runs.
  Future<List<TextRun>> ocrImageBytes(Uint8List bytes,
      {String extension = 'png', int page = 0}) async {
    if (!isSupported) {
      throw const BillOcrUnavailable(
          'Photo/scan reading works on the Windows app only. Please upload '
          'the PDF bill or enter items manually. '
          '(ഫോട്ടോ വായിക്കൽ Windows ആപ്പിൽ മാത്രം. PDF ബിൽ ഉപയോഗിക്കുക.)');
    }
    final dir = await Directory.systemTemp.createTemp('tekfix_ocr_');
    try {
      final img = File('${dir.path}${Platform.pathSeparator}bill.$extension');
      await img.writeAsBytes(bytes, flush: true);
      final script =
          File('${dir.path}${Platform.pathSeparator}ocr.ps1');
      await script.writeAsString(_script, flush: true);
      final res = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          script.path,
          '-Path',
          img.path,
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 90));
      if (res.exitCode != 0) {
        throw BillOcrUnavailable(
            'Windows OCR failed (${res.exitCode}): ${res.stderr}'.trim());
      }
      return parseOcrOutput(res.stdout.toString(), page: page);
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Rasterises each page of a scanned PDF and OCRs it.
  Future<List<TextRun>> ocrPdf(Uint8List pdfBytes, {int maxPages = 5}) async {
    if (!isSupported) {
      throw const BillOcrUnavailable(
          'This PDF is a scanned image. Scanned PDFs can be read on the '
          'Windows app only. (സ്കാൻ ചെയ്ത PDF Windows ആപ്പിൽ മാത്രം വായിക്കാം.)');
    }
    final out = <TextRun>[];
    var page = 0;
    await for (final raster in Printing.raster(pdfBytes, dpi: 220)) {
      final png = await raster.toPng();
      out.addAll(await ocrImageBytes(png, extension: 'png', page: page));
      page++;
      if (page >= maxPages) break;
    }
    return out;
  }

  /// Output format: one word per line: line# 	 x 	 y 	 w 	 h 	 text
  @visibleForTesting
  static List<TextRun> parseOcrOutput(String stdout, {int page = 0}) {
    final runs = <TextRun>[];
    String? prevLine;
    for (final line in const LineSplitter().convert(stdout)) {
      final parts = line.split('	');
      if (parts.length < 6) continue;
      final ln = parts[0];
      final x = double.tryParse(parts[1]);
      final y = double.tryParse(parts[2]);
      final w = double.tryParse(parts[3]);
      final h = double.tryParse(parts[4]);
      final text = fixOcrToken(parts.sublist(5).join('	').trim());
      if (x == null || y == null || w == null || h == null || text.isEmpty) {
        continue;
      }
      // Glue "1" + ",749.94" (OCR splits Indian digit groups).
      if (ln == prevLine && runs.isNotEmpty) {
        final p = runs.last;
        final gap = x - (p.x + p.w);
        if (gap < h * 0.6 &&
            RegExp(r'\d$').hasMatch(p.text) &&
            RegExp(r'^[,.]\d').hasMatch(text)) {
          runs[runs.length - 1] = TextRun(
              text: '${p.text}$text',
              x: p.x,
              y: p.y,
              w: x + w - p.x,
              h: p.h,
              page: page);
          continue;
        }
      }
      prevLine = ln;
      // Use the vertical centre as baseline proxy for line grouping.
      runs.add(TextRun(
          text: text, x: x, y: y + h / 2, w: w, h: h * 1.15, page: page));
    }
    return runs;
  }

  /// Fixes common OCR confusions inside numbers: "4,o46.0O" → "4,046.00",
  /// "1l5.00" → "115.00", leading "₹" read as "z"/"w"/"%".
  @visibleForTesting
  static String fixOcrToken(String t) {
    final m = RegExp(r'^([₹zZwW%])?([\doOlI|]{1,3}(?:,[\doOlI|]{2,3})*'
            r'|[\doOlI|]+)(\.[\doOlI|]{2})$')
        .firstMatch(t);
    if (m == null) return t;
    final core = '${m.group(2)}${m.group(3)}';
    final digits = RegExp(r'\d').allMatches(core).length;
    if (digits < 2) return t;
    return core
        .replaceAll(RegExp('[oO]'), '0')
        .replaceAll(RegExp('[lI|]'), '1');
  }

  static const String _script = r'''
param([string]$Path)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics, ContentType = WindowsRuntime]
$null = [Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime]
$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
  $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($op, [Type]$t) {
  $task = $asTask.MakeGenericMethod($t).Invoke($null, @($op))
  $null = $task.Wait(-1)
  $task.Result
}
$file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
$stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
$decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
$bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
$engine = $null
try { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage([Windows.Globalization.Language]::new('en-US')) } catch {}
if ($null -eq $engine) { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }
if ($null -eq $engine) { Write-Error 'No Windows OCR language installed (add English in Settings > Language).'; exit 3 }
$result = Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
$inv = [System.Globalization.CultureInfo]::InvariantCulture
$n = 0
foreach ($line in $result.Lines) {
  $n++
  foreach ($w in $line.Words) {
    $r = $w.BoundingRect
    [Console]::WriteLine([string]::Format($inv, "{0}`t{1:0.##}`t{2:0.##}`t{3:0.##}`t{4:0.##}`t{5}", $n, $r.X, $r.Y, $r.Width, $r.Height, $w.Text))
  }
}
''';
}
