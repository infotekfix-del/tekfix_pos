// =============================================================================
// TEKFIX ERP — Pure-Dart PDF text extractor (offline, no plugins)
//
// Reads the text layer of a "digital" PDF (bills exported from Tally, Busy,
// Marg, Zoho, Vyapar, myBillBook, browsers, …) together with each text run's
// position, so the bill parser can rebuild the table rows and columns.
//
// Supported: classic + compressed object streams (PDF 1.5+), FlateDecode /
// ASCIIHex / ASCII85 filters, page tree with inherited resources, Form
// XObjects, simple fonts (WinAnsi/Standard + /Differences), Type0/CID fonts
// with ToUnicode CMaps, text/graphics matrices.
//
// Not supported (falls back to OCR on Windows): scanned/photo PDFs that have no
// text layer, encrypted PDFs, CID fonts without a ToUnicode map.
// =============================================================================

import 'dart:convert';
import 'dart:io' show zlib, ZLibDecoder;
import 'dart:math' as math;
import 'dart:typed_data';

import 'bill_text_layout.dart';

/// Result of extracting text from a PDF.
class PdfTextResult {
  final List<TextRun> runs;
  final int pageCount;

  /// Glyphs that could not be mapped to Unicode (fonts without ToUnicode).
  final int unreadableGlyphs;
  final int totalGlyphs;
  final bool encrypted;

  const PdfTextResult({
    required this.runs,
    required this.pageCount,
    this.unreadableGlyphs = 0,
    this.totalGlyphs = 0,
    this.encrypted = false,
  });

  /// Number of letters/digits that were successfully read.
  int get readableChars {
    var n = 0;
    for (final r in runs) {
      for (final c in r.text.codeUnits) {
        if ((c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)) {
          n++;
        }
      }
    }
    return n;
  }

  /// True when the text layer is good enough to parse (otherwise try OCR).
  bool get hasUsableText =>
      readableChars >= 40 &&
      (totalGlyphs == 0 || unreadableGlyphs / totalGlyphs < 0.3);
}

class PdfTextExtractor {
  PdfTextExtractor._();

  /// Synchronous so it can run inside `compute()` (a worker isolate).
  static PdfTextResult extract(Uint8List bytes) {
    final doc = _PdfDoc(bytes);
    doc.index();
    final pages = doc.pages();
    final runs = <TextRun>[];
    var pageNo = 0;
    for (final page in pages) {
      final interp = _ContentInterpreter(doc, pageNo, page.top);
      try {
        interp.run(page.contents, page.resources, _Matrix.identity);
      } catch (_) {
        // A broken page must not kill the whole extraction.
      }
      runs.addAll(interp.runs);
      doc.unreadable += interp.unreadable;
      doc.glyphs += interp.glyphs;
      pageNo++;
    }
    return PdfTextResult(
      runs: runs,
      pageCount: pages.length,
      unreadableGlyphs: doc.unreadable,
      totalGlyphs: doc.glyphs,
      encrypted: doc.encrypted,
    );
  }

  /// Convenience for `compute()`: returns grouped plain text.
  static String extractPlainText(Uint8List bytes) =>
      BillTextLayout.toText(BillTextLayout.groupRuns(extract(bytes).runs));
}

// ---------------------------------------------------------------------------
// PDF object model
// ---------------------------------------------------------------------------

class _Name {
  final String v;
  const _Name(this.v);
  @override
  bool operator ==(Object other) => other is _Name && other.v == v;
  @override
  int get hashCode => v.hashCode;
  @override
  String toString() => '/$v';
}

class _Ref {
  final int num;
  final int gen;
  const _Ref(this.num, this.gen);
}

class _Op {
  final String v;
  const _Op(this.v);
  @override
  String toString() => v;
}

class _PdfString {
  final Uint8List bytes;
  const _PdfString(this.bytes);
}

class _Stream {
  final Map<String, dynamic> dict;
  final Uint8List raw;
  const _Stream(this.dict, this.raw);
}

// ---------------------------------------------------------------------------
// Lexer / parser
// ---------------------------------------------------------------------------

class _Lexer {
  final Uint8List d;
  int p;
  _Lexer(this.d, [this.p = 0]);

  bool get eof => p >= d.length;

  static bool isWs(int c) =>
      c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32;
  static bool isDelim(int c) =>
      c == 40 || c == 41 || c == 60 || c == 62 || c == 91 || c == 93 ||
      c == 123 || c == 125 || c == 47 || c == 37;

  void skipWs() {
    while (p < d.length) {
      final c = d[p];
      if (isWs(c)) {
        p++;
      } else if (c == 37) {
        // % comment
        while (p < d.length && d[p] != 10 && d[p] != 13) {
          p++;
        }
      } else {
        break;
      }
    }
  }

  /// Reads one object. Keywords (operators) come back as [_Op].
  /// [allowRefs] is false inside content streams (no indirect refs there).
  dynamic read({bool allowRefs = true}) {
    skipWs();
    if (p >= d.length) return null;
    final c = d[p];
    if (c == 47) return _readName();
    if (c == 40) return _readLiteral();
    if (c == 60) {
      if (p + 1 < d.length && d[p + 1] == 60) return _readDict(allowRefs);
      return _readHex();
    }
    if (c == 91) {
      p++;
      final arr = <dynamic>[];
      while (true) {
        skipWs();
        if (p >= d.length) break;
        if (d[p] == 93) {
          p++;
          break;
        }
        final v = read(allowRefs: allowRefs);
        if (v == null && p >= d.length) break;
        arr.add(v);
      }
      return arr;
    }
    if (c == 93 || c == 62 || c == 41 || c == 123 || c == 125) {
      p++;
      return _Op(String.fromCharCode(c));
    }
    if ((c >= 48 && c <= 57) || c == 43 || c == 45 || c == 46) {
      final n = _readNumber();
      if (allowRefs && n is int && n >= 0) {
        final save = p;
        skipWs();
        final g = _peekInt();
        if (g != null) {
          final afterGen = p;
          skipWs();
          if (p < d.length &&
              d[p] == 82 &&
              (p + 1 >= d.length || isWs(d[p + 1]) || isDelim(d[p + 1]))) {
            p++;
            return _Ref(n, g);
          }
          p = afterGen;
        }
        p = save;
      }
      return n;
    }
    // keyword
    final start = p;
    while (p < d.length && !isWs(d[p]) && !isDelim(d[p])) {
      p++;
    }
    if (p == start) {
      p++;
      return _Op(String.fromCharCode(c));
    }
    final kw = latin1.decode(d.sublist(start, p));
    if (kw == 'true') return true;
    if (kw == 'false') return false;
    if (kw == 'null') return null;
    return _Op(kw);
  }

  int? _peekInt() {
    final start = p;
    while (p < d.length && d[p] >= 48 && d[p] <= 57) {
      p++;
    }
    if (p == start) return null;
    if (p < d.length && !isWs(d[p]) && !isDelim(d[p])) {
      p = start;
      return null;
    }
    return int.tryParse(latin1.decode(d.sublist(start, p)));
  }

  num _readNumber() {
    final start = p;
    p++;
    while (p < d.length) {
      final c = d[p];
      if ((c >= 48 && c <= 57) || c == 46) {
        p++;
      } else {
        break;
      }
    }
    final s = latin1.decode(d.sublist(start, p));
    if (!s.contains('.')) {
      final i = int.tryParse(s);
      if (i != null) return i;
    }
    return double.tryParse(s) ?? 0;
  }

  _Name _readName() {
    p++; // '/'
    final sb = StringBuffer();
    while (p < d.length && !isWs(d[p]) && !isDelim(d[p])) {
      if (d[p] == 35 && p + 2 < d.length) {
        final h = int.tryParse(latin1.decode(d.sublist(p + 1, p + 3)), radix: 16);
        if (h != null) {
          sb.writeCharCode(h);
          p += 3;
          continue;
        }
      }
      sb.writeCharCode(d[p]);
      p++;
    }
    return _Name(sb.toString());
  }

  _PdfString _readLiteral() {
    p++; // '('
    final out = BytesBuilder(copy: false);
    var depth = 1;
    while (p < d.length) {
      final c = d[p];
      if (c == 92) {
        // backslash escape
        p++;
        if (p >= d.length) break;
        final e = d[p];
        switch (e) {
          case 110:
            out.addByte(10);
            p++;
            break;
          case 114:
            out.addByte(13);
            p++;
            break;
          case 116:
            out.addByte(9);
            p++;
            break;
          case 98:
            out.addByte(8);
            p++;
            break;
          case 102:
            out.addByte(12);
            p++;
            break;
          case 13:
            p++;
            if (p < d.length && d[p] == 10) p++;
            break;
          case 10:
            p++;
            break;
          default:
            if (e >= 48 && e <= 55) {
              var v = 0;
              var k = 0;
              while (k < 3 && p < d.length && d[p] >= 48 && d[p] <= 55) {
                v = v * 8 + (d[p] - 48);
                p++;
                k++;
              }
              out.addByte(v & 0xFF);
            } else {
              out.addByte(e);
              p++;
            }
        }
        continue;
      }
      if (c == 40) depth++;
      if (c == 41) {
        depth--;
        if (depth == 0) {
          p++;
          break;
        }
      }
      out.addByte(c);
      p++;
    }
    return _PdfString(out.toBytes());
  }

  _PdfString _readHex() {
    p++; // '<'
    final out = BytesBuilder(copy: false);
    int? hi;
    while (p < d.length && d[p] != 62) {
      final v = _hexVal(d[p]);
      p++;
      if (v < 0) continue;
      if (hi == null) {
        hi = v;
      } else {
        out.addByte(hi * 16 + v);
        hi = null;
      }
    }
    if (hi != null) out.addByte(hi * 16);
    p++; // '>'
    return _PdfString(out.toBytes());
  }

  static int _hexVal(int c) {
    if (c >= 48 && c <= 57) return c - 48;
    if (c >= 65 && c <= 70) return c - 55;
    if (c >= 97 && c <= 102) return c - 87;
    return -1;
  }

  Map<String, dynamic> _readDict(bool allowRefs) {
    p += 2;
    final m = <String, dynamic>{};
    while (true) {
      skipWs();
      if (p >= d.length) break;
      if (d[p] == 62 && p + 1 < d.length && d[p + 1] == 62) {
        p += 2;
        break;
      }
      final k = read(allowRefs: allowRefs);
      if (k is! _Name) {
        if (p >= d.length) break;
        continue;
      }
      final v = read(allowRefs: allowRefs);
      m[k.v] = v;
    }
    return m;
  }
}

// ---------------------------------------------------------------------------
// Document: object index, resolution, streams, page tree
// ---------------------------------------------------------------------------

class _Page {
  final List<Uint8List> contents;
  final Map<String, dynamic> resources;
  final double top;
  _Page(this.contents, this.resources, this.top);
}

class _PdfDoc {
  final Uint8List data;
  final Map<int, int> offsets = {};
  final Map<int, dynamic> cache = {};
  final Map<int, _FontInfo> fontCache = {};
  bool encrypted = false;
  int unreadable = 0;
  int glyphs = 0;

  _PdfDoc(this.data);

  void index() {
    final s = latin1.decode(data, allowInvalid: true);
    final re = RegExp(r'(?<![0-9])(\d{1,7})\s+(\d{1,5})\s+obj\b');
    for (final m in re.allMatches(s)) {
      offsets[int.parse(m.group(1)!)] = m.end;
    }
    encrypted = s.contains('/Encrypt');

    // Objects inside compressed object streams (PDF 1.5+).
    final stmNums = <int>[];
    for (final e in offsets.entries) {
      final end = math.min(e.value + 400, s.length);
      final head = s.substring(e.value, end);
      if (head.contains('/ObjStm')) stmNums.add(e.key);
    }
    for (final n in stmNums) {
      final obj = getObject(n);
      if (obj is! _Stream) continue;
      final dec = decodeStream(obj);
      if (dec == null) continue;
      final count = resolve(obj.dict['N']);
      final first = resolve(obj.dict['First']);
      if (count is! int || first is! int) continue;
      final lx = _Lexer(dec);
      final pairs = <List<int>>[];
      for (var i = 0; i < count; i++) {
        final on = lx.read(allowRefs: false);
        final off = lx.read(allowRefs: false);
        if (on is int && off is int) pairs.add([on, off]);
      }
      for (final pr in pairs) {
        if (offsets.containsKey(pr[0]) || cache.containsKey(pr[0])) continue;
        try {
          final l2 = _Lexer(dec, first + pr[1]);
          cache[pr[0]] = l2.read();
        } catch (_) {}
      }
    }
  }

  dynamic resolve(dynamic v, [int depth = 0]) {
    if (v is _Ref && depth < 16) return resolve(getObject(v.num), depth + 1);
    return v;
  }

  dynamic getObject(int num) {
    if (cache.containsKey(num)) return cache[num];
    final off = offsets[num];
    if (off == null) return null;
    cache[num] = null; // cycle guard
    dynamic result;
    try {
      final lx = _Lexer(data, off);
      final v = lx.read();
      result = v;
      if (v is Map<String, dynamic>) {
        lx.skipWs();
        if (_startsWith(lx.p, 'stream')) {
          var start = lx.p + 6;
          if (start < data.length && data[start] == 13) start++;
          if (start < data.length && data[start] == 10) start++;
          final lenObj = resolve(v['Length']);
          int end = -1;
          if (lenObj is int && lenObj >= 0 && start + lenObj <= data.length) {
            final probe = _Lexer(data, start + lenObj)..skipWs();
            if (_startsWith(probe.p, 'endstream')) end = start + lenObj;
          }
          if (end < 0) end = _findEndstream(start);
          result = _Stream(v, Uint8List.sublistView(data, start, end));
        }
      }
    } catch (_) {
      result = null;
    }
    cache[num] = result;
    return result;
  }

  bool _startsWith(int p, String kw) {
    if (p + kw.length > data.length) return false;
    for (var i = 0; i < kw.length; i++) {
      if (data[p + i] != kw.codeUnitAt(i)) return false;
    }
    return true;
  }

  int _findEndstream(int from) {
    for (var i = from; i < data.length - 9; i++) {
      if (data[i] == 101 && _startsWith(i, 'endstream')) {
        var e = i;
        if (e > from && data[e - 1] == 10) e--;
        if (e > from && data[e - 1] == 13) e--;
        return e;
      }
    }
    return data.length;
  }

  Uint8List? decodeStream(_Stream s) {
    var bytes = s.raw;
    final f = resolve(s.dict['Filter']);
    final filters = <String>[];
    if (f is _Name) filters.add(f.v);
    if (f is List) {
      for (final x in f) {
        final r = resolve(x);
        if (r is _Name) filters.add(r.v);
      }
    }
    for (final name in filters) {
      switch (name) {
        case 'FlateDecode':
        case 'Fl':
          final out = _inflate(bytes);
          if (out == null) return null;
          bytes = out;
          break;
        case 'ASCIIHexDecode':
        case 'AHx':
          bytes = _asciiHex(bytes);
          break;
        case 'ASCII85Decode':
        case 'A85':
          bytes = _ascii85(bytes);
          break;
        default:
          return null; // images (DCT, JBIG2, CCITT) or unsupported (LZW)
      }
    }
    return bytes;
  }

  static Uint8List? _inflate(Uint8List b) {
    try {
      return Uint8List.fromList(zlib.decode(b));
    } catch (_) {}
    try {
      return Uint8List.fromList(ZLibDecoder(raw: true).convert(b));
    } catch (_) {}
    // Some producers write a valid zlib stream followed by junk bytes.
    if (b.length > 2) {
      try {
        return Uint8List.fromList(
            ZLibDecoder(raw: true).convert(Uint8List.sublistView(b, 2)));
      } catch (_) {}
    }
    return null;
  }

  static Uint8List _asciiHex(Uint8List b) {
    final out = BytesBuilder(copy: false);
    int? hi;
    for (final c in b) {
      if (c == 62) break;
      final v = _Lexer._hexVal(c);
      if (v < 0) continue;
      if (hi == null) {
        hi = v;
      } else {
        out.addByte(hi * 16 + v);
        hi = null;
      }
    }
    if (hi != null) out.addByte(hi * 16);
    return out.toBytes();
  }

  static Uint8List _ascii85(Uint8List b) {
    final out = BytesBuilder(copy: false);
    final group = <int>[];
    for (var i = 0; i < b.length; i++) {
      final c = b[i];
      if (c == 126) break; // '~>'
      if (_Lexer.isWs(c)) continue;
      if (c == 122 && group.isEmpty) {
        out.add([0, 0, 0, 0]);
        continue;
      }
      if (c < 33 || c > 117) continue;
      group.add(c - 33);
      if (group.length == 5) {
        var v = 0;
        for (final g in group) {
          v = v * 85 + g;
        }
        out.add([(v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255]);
        group.clear();
      }
    }
    if (group.isNotEmpty) {
      final n = group.length;
      while (group.length < 5) {
        group.add(84);
      }
      var v = 0;
      for (final g in group) {
        v = v * 85 + g;
      }
      final all = [(v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255];
      out.add(all.sublist(0, n - 1));
    }
    return out.toBytes();
  }

  Map<String, dynamic>? dictOf(dynamic v) {
    final r = resolve(v);
    if (r is Map<String, dynamic>) return r;
    if (r is _Stream) return r.dict;
    return null;
  }

  // ---- Page tree ----

  List<_Page> pages() {
    Map<String, dynamic>? root;
    for (final n in offsets.keys.toList()..sort()) {
      final d = dictOf(_Ref(n, 0));
      if (d != null && d['Type'] == const _Name('Catalog')) root = d;
    }
    if (root == null) {
      for (final e in cache.entries) {
        final v = e.value;
        if (v is Map<String, dynamic> && v['Type'] == const _Name('Catalog')) {
          root = v;
        }
      }
    }
    final out = <_Page>[];
    final seen = <Object>{};
    if (root != null) {
      _walk(root['Pages'], null, null, out, seen, 0);
    }
    if (out.isEmpty) {
      // Fallback: every /Type /Page object in number order.
      final nums = {...offsets.keys, ...cache.keys}.toList()..sort();
      for (final n in nums) {
        final d = dictOf(_Ref(n, 0));
        if (d != null && d['Type'] == const _Name('Page')) {
          _addPage(d, null, null, out);
        }
      }
    }
    return out;
  }

  void _walk(dynamic node, Map<String, dynamic>? inhRes, List? inhBox,
      List<_Page> out, Set<Object> seen, int depth) {
    if (depth > 32) return;
    if (node is _Ref) {
      if (!seen.add(node.num)) return;
    }
    final d = dictOf(node);
    if (d == null) return;
    final res = dictOf(d['Resources']) ?? inhRes;
    final boxR = resolve(d['MediaBox']);
    final box = boxR is List ? boxR : inhBox;
    final kids = resolve(d['Kids']);
    if (kids is List) {
      for (final k in kids) {
        _walk(k, res, box, out, seen, depth + 1);
      }
    } else {
      _addPage(d, res, box, out);
    }
  }

  void _addPage(Map<String, dynamic> d, Map<String, dynamic>? inhRes,
      List? inhBox, List<_Page> out) {
    final res = dictOf(d['Resources']) ?? inhRes ?? <String, dynamic>{};
    final boxR = resolve(d['MediaBox']);
    final box = boxR is List ? boxR : inhBox;
    double top = 842;
    if (box != null && box.length == 4) {
      final t = resolve(box[3]);
      if (t is num) top = t.toDouble();
    }
    final contents = <Uint8List>[];
    final c = resolve(d['Contents']);
    final list = c is List ? c : [d['Contents']];
    for (final item in list) {
      final s = resolve(item);
      if (s is _Stream) {
        final dec = decodeStream(s);
        if (dec != null) contents.add(dec);
      }
    }
    out.add(_Page(contents, res, top));
  }

  _FontInfo? font(dynamic ref) {
    if (ref is _Ref && fontCache.containsKey(ref.num)) {
      return fontCache[ref.num];
    }
    final d = dictOf(ref);
    if (d == null) return null;
    final f = _FontInfo.build(this, d);
    if (ref is _Ref) fontCache[ref.num] = f;
    return f;
  }
}

// ---------------------------------------------------------------------------
// Fonts
// ---------------------------------------------------------------------------

class _Glyph {
  final int code;
  final String text;
  final double width; // in 1/1000 em
  final bool singleByte;
  final bool unknown;
  const _Glyph(this.code, this.text, this.width, this.singleByte, this.unknown);
}

class _FontInfo {
  bool composite = false;
  final Map<int, String> toUnicode = {};
  // codespace byte lengths available, longest first not needed: we try 1..4.
  final Set<int> codeLengths = {};
  List<String?>? simpleEncoding;
  final Map<int, double> widths = {};
  double defaultWidth = 500;
  bool identityUnicode = false;

  static _FontInfo build(_PdfDoc doc, Map<String, dynamic> d) {
    final f = _FontInfo();
    final subtype = doc.resolve(d['Subtype']);
    f.composite = subtype == const _Name('Type0');

    // ToUnicode CMap
    final tu = doc.resolve(d['ToUnicode']);
    if (tu is _Stream) {
      final dec = doc.decodeStream(tu);
      if (dec != null) _parseCMap(dec, f);
    }

    if (f.composite) {
      f.defaultWidth = 1000;
      final desc = doc.resolve(d['DescendantFonts']);
      final df = desc is List && desc.isNotEmpty ? doc.dictOf(desc.first) : null;
      if (df != null) {
        final dw = doc.resolve(df['DW']);
        if (dw is num) f.defaultWidth = dw.toDouble();
        final w = doc.resolve(df['W']);
        if (w is List) _parseCidWidths(doc, w, f);
      }
      if (f.codeLengths.isEmpty) f.codeLengths.add(2);
      final enc = doc.resolve(d['Encoding']);
      if (f.toUnicode.isEmpty && enc is _Name && enc.v.startsWith('Uni')) {
        // e.g. UniGB-UCS2-H: codes are already UCS-2.
        f.identityUnicode = enc.v.contains('UCS2') || enc.v.contains('UTF16');
      }
    } else {
      final fc = doc.resolve(d['FirstChar']);
      final ws = doc.resolve(d['Widths']);
      if (fc is int && ws is List) {
        for (var i = 0; i < ws.length; i++) {
          final w = doc.resolve(ws[i]);
          if (w is num) f.widths[fc + i] = w.toDouble();
        }
      }
      final fd = doc.dictOf(d['FontDescriptor']);
      final mw = fd == null ? null : doc.resolve(fd['MissingWidth']);
      if (mw is num && mw > 0) f.defaultWidth = mw.toDouble();
      if (f.widths.isEmpty) {
        final base = doc.resolve(d['BaseFont']);
        if (base is _Name && base.v.toLowerCase().contains('courier')) {
          f.defaultWidth = 600;
        }
      }
      f.simpleEncoding = _buildSimpleEncoding(doc, d);
      if (f.codeLengths.isEmpty) f.codeLengths.add(1);
    }
    return f;
  }

  static List<String?> _buildSimpleEncoding(
      _PdfDoc doc, Map<String, dynamic> d) {
    final table = List<String?>.from(_winAnsi);
    final enc = doc.resolve(d['Encoding']);
    Map<String, dynamic>? encDict;
    if (enc is _Name) {
      if (enc.v == 'MacRomanEncoding') {
        // Close enough for invoice text (ASCII range is identical).
      }
    } else if (enc is Map<String, dynamic>) {
      encDict = enc;
    }
    if (encDict != null) {
      final diffs = doc.resolve(encDict['Differences']);
      if (diffs is List) {
        var code = 0;
        for (final item in diffs) {
          final v = doc.resolve(item);
          if (v is int) {
            code = v;
          } else if (v is _Name) {
            if (code >= 0 && code < 256) table[code] = _glyphName(v.v);
            code++;
          }
        }
      }
    }
    return table;
  }

  static void _parseCidWidths(_PdfDoc doc, List w, _FontInfo f) {
    var i = 0;
    while (i < w.length) {
      final first = doc.resolve(w[i]);
      if (first is! int) {
        i++;
        continue;
      }
      if (i + 1 >= w.length) break;
      final next = doc.resolve(w[i + 1]);
      if (next is List) {
        for (var k = 0; k < next.length; k++) {
          final v = doc.resolve(next[k]);
          if (v is num) f.widths[first + k] = v.toDouble();
        }
        i += 2;
      } else if (next is int && i + 2 < w.length) {
        final v = doc.resolve(w[i + 2]);
        if (v is num && next - first < 65536) {
          for (var c = first; c <= next; c++) {
            f.widths[c] = v.toDouble();
          }
        }
        i += 3;
      } else {
        i++;
      }
    }
  }

  static void _parseCMap(Uint8List data, _FontInfo f) {
    final lx = _Lexer(data);
    final stack = <dynamic>[];
    while (!lx.eof) {
      final t = lx.read(allowRefs: false);
      if (t == null && lx.eof) break;
      if (t is _Op) {
        switch (t.v) {
          case 'begincodespacerange':
            while (!lx.eof) {
              final a = lx.read(allowRefs: false);
              if (a is _Op) break;
              final b = lx.read(allowRefs: false);
              if (a is _PdfString && b is _PdfString) {
                f.codeLengths.add(a.bytes.length);
              }
            }
            break;
          case 'beginbfchar':
            while (!lx.eof) {
              final a = lx.read(allowRefs: false);
              if (a is _Op) break;
              final b = lx.read(allowRefs: false);
              if (a is _PdfString) {
                final s = _utf16(b);
                if (s != null) f.toUnicode[_bytesToInt(a.bytes)] = s;
              }
            }
            break;
          case 'beginbfrange':
            while (!lx.eof) {
              final a = lx.read(allowRefs: false);
              if (a is _Op) break;
              final b = lx.read(allowRefs: false);
              final c = lx.read(allowRefs: false);
              if (a is! _PdfString || b is! _PdfString) continue;
              final lo = _bytesToInt(a.bytes);
              final hi = _bytesToInt(b.bytes);
              if (hi < lo || hi - lo > 65535) continue;
              if (c is _PdfString) {
                final base = c.bytes;
                for (var code = lo; code <= hi; code++) {
                  final bytes = Uint8List.fromList(base);
                  // increment last byte(s)
                  var add = code - lo;
                  for (var k = bytes.length - 1; k >= 0 && add > 0; k--) {
                    final v = bytes[k] + add;
                    bytes[k] = v & 0xFF;
                    add = v >> 8;
                  }
                  final s = _utf16(_PdfString(bytes));
                  if (s != null) f.toUnicode[code] = s;
                }
              } else if (c is List) {
                for (var k = 0; k < c.length && lo + k <= hi; k++) {
                  final s = _utf16(c[k]);
                  if (s != null) f.toUnicode[lo + k] = s;
                }
              }
            }
            break;
        }
        stack.clear();
      } else {
        stack.add(t);
      }
    }
  }

  static int _bytesToInt(Uint8List b) {
    var v = 0;
    for (final x in b) {
      v = (v << 8) | x;
    }
    return v;
  }

  static String? _utf16(dynamic v) {
    if (v is! _PdfString) return null;
    final b = v.bytes;
    if (b.isEmpty) return '';
    if (b.length == 1) return String.fromCharCode(b[0]);
    final units = <int>[];
    for (var i = 0; i + 1 < b.length; i += 2) {
      units.add((b[i] << 8) | b[i + 1]);
    }
    return String.fromCharCodes(units);
  }

  List<_Glyph> decode(Uint8List bytes) {
    final out = <_Glyph>[];
    if (!composite) {
      for (final b in bytes) {
        final mapped = toUnicode[b];
        String? text = mapped ?? simpleEncoding?[b];
        final unknown = text == null;
        text ??= String.fromCharCode(b);
        out.add(_Glyph(b, text, widths[b] ?? defaultWidth, true, unknown));
      }
      return out;
    }
    final lens = codeLengths.toList()..sort();
    var i = 0;
    while (i < bytes.length) {
      int? code;
      int used = 0;
      // Prefer a length whose code exists in ToUnicode.
      for (final l in lens) {
        if (i + l > bytes.length) continue;
        var c = 0;
        for (var k = 0; k < l; k++) {
          c = (c << 8) | bytes[i + k];
        }
        if (toUnicode.containsKey(c) || l == lens.last) {
          code = c;
          used = l;
          break;
        }
      }
      if (code == null) {
        code = bytes[i];
        used = 1;
      }
      i += used;
      final mapped = toUnicode[code];
      String text;
      bool unknown = false;
      if (mapped != null) {
        text = mapped;
      } else if (identityUnicode) {
        text = String.fromCharCode(code);
      } else {
        text = '�';
        unknown = true;
      }
      out.add(_Glyph(code, text, widths[code] ?? defaultWidth, false, unknown));
    }
    return out;
  }
}

// ---------------------------------------------------------------------------
// Matrices
// ---------------------------------------------------------------------------

class _Matrix {
  final double a, b, c, d, e, f;
  const _Matrix(this.a, this.b, this.c, this.d, this.e, this.f);
  static const identity = _Matrix(1, 0, 0, 1, 0, 0);

  /// this × other
  _Matrix mul(_Matrix o) => _Matrix(
        a * o.a + b * o.c,
        a * o.b + b * o.d,
        c * o.a + d * o.c,
        c * o.b + d * o.d,
        e * o.a + f * o.c + o.e,
        e * o.b + f * o.d + o.f,
      );

  double tx(double x, double y) => a * x + c * y + e;
  double ty(double x, double y) => b * x + d * y + f;

  static _Matrix translate(double x, double y) => _Matrix(1, 0, 0, 1, x, y);

  static _Matrix? fromList(List v) {
    if (v.length != 6) return null;
    final n = <double>[];
    for (final x in v) {
      if (x is! num) return null;
      n.add(x.toDouble());
    }
    return _Matrix(n[0], n[1], n[2], n[3], n[4], n[5]);
  }
}

class _GState {
  _Matrix ctm;
  _FontInfo? font;
  double fontSize = 0;
  double tc = 0, tw = 0, th = 1, tl = 0, rise = 0;
  _GState(this.ctm);
  _GState copy() => _GState(ctm)
    ..font = font
    ..fontSize = fontSize
    ..tc = tc
    ..tw = tw
    ..th = th
    ..tl = tl
    ..rise = rise;
}

// ---------------------------------------------------------------------------
// Content stream interpreter
// ---------------------------------------------------------------------------

class _ContentInterpreter {
  final _PdfDoc doc;
  final int page;
  final double top;
  final List<TextRun> runs = [];
  int unreadable = 0;
  int glyphs = 0;
  int _depth = 0;

  _ContentInterpreter(this.doc, this.page, this.top);

  late _GState gs;
  final List<_GState> _stack = [];
  _Matrix tm = _Matrix.identity;
  _Matrix tlm = _Matrix.identity;

  // Current run being accumulated.
  final StringBuffer _buf = StringBuffer();
  double _runX = 0, _runY = 0, _runH = 0, _runEndX = 0;

  void run(List<Uint8List> contents, Map<String, dynamic> resources,
      _Matrix ctm) {
    gs = _GState(ctm);
    for (final c in contents) {
      _exec(c, resources);
    }
    _flush();
  }

  void _exec(Uint8List data, Map<String, dynamic> resources) {
    final lx = _Lexer(data);
    final ops = <dynamic>[];
    final fonts = doc.dictOf(resources['Font']) ?? const <String, dynamic>{};
    final xobjs = doc.dictOf(resources['XObject']) ?? const <String, dynamic>{};
    var guard = 0;
    while (!lx.eof && guard++ < 2000000) {
      final t = lx.read(allowRefs: false);
      if (t == null && lx.eof) break;
      if (t is! _Op) {
        ops.add(t);
        continue;
      }
      try {
        switch (t.v) {
          case 'q':
            _stack.add(gs.copy());
            break;
          case 'Q':
            if (_stack.isNotEmpty) gs = _stack.removeLast();
            break;
          case 'cm':
            final m = _Matrix.fromList(_nums(ops, 6));
            if (m != null) gs.ctm = m.mul(gs.ctm);
            break;
          case 'BT':
            tm = _Matrix.identity;
            tlm = _Matrix.identity;
            break;
          case 'ET':
            _flush();
            break;
          case 'Tf':
            if (ops.length >= 2) {
              final name = ops[ops.length - 2];
              final size = ops.last;
              if (name is _Name) gs.font = doc.font(fonts[name.v]);
              if (size is num) gs.fontSize = size.toDouble();
            }
            break;
          case 'Tc':
            gs.tc = _num(ops);
            break;
          case 'Tw':
            gs.tw = _num(ops);
            break;
          case 'Tz':
            gs.th = _num(ops) / 100;
            break;
          case 'TL':
            gs.tl = _num(ops);
            break;
          case 'Ts':
            gs.rise = _num(ops);
            break;
          case 'Td':
            final v = _nums(ops, 2);
            if (v.length == 2) _td(v[0].toDouble(), v[1].toDouble());
            break;
          case 'TD':
            final v = _nums(ops, 2);
            if (v.length == 2) {
              gs.tl = -v[1].toDouble();
              _td(v[0].toDouble(), v[1].toDouble());
            }
            break;
          case 'Tm':
            final m = _Matrix.fromList(_nums(ops, 6));
            if (m != null) {
              _flush();
              tm = m;
              tlm = m;
            }
            break;
          case 'T*':
            _td(0, -gs.tl);
            break;
          case 'Tj':
            if (ops.isNotEmpty && ops.last is _PdfString) {
              _show((ops.last as _PdfString).bytes);
            }
            break;
          case "'":
            _td(0, -gs.tl);
            if (ops.isNotEmpty && ops.last is _PdfString) {
              _show((ops.last as _PdfString).bytes);
            }
            break;
          case '"':
            if (ops.length >= 3) {
              final aw = ops[ops.length - 3];
              final ac = ops[ops.length - 2];
              if (aw is num) gs.tw = aw.toDouble();
              if (ac is num) gs.tc = ac.toDouble();
            }
            _td(0, -gs.tl);
            if (ops.isNotEmpty && ops.last is _PdfString) {
              _show((ops.last as _PdfString).bytes);
            }
            break;
          case 'TJ':
            if (ops.isNotEmpty && ops.last is List) {
              for (final el in ops.last as List) {
                if (el is _PdfString) {
                  _show(el.bytes);
                } else if (el is num) {
                  final adj = -el.toDouble() / 1000 * gs.fontSize * gs.th;
                  if (el.abs() > 180) {
                    // Visible gap: end this run; the layout step will decide
                    // between a space and a column break.
                    _advance(adj);
                    _flush();
                  } else {
                    _advance(adj);
                  }
                }
              }
            }
            break;
          case 'Do':
            if (ops.isNotEmpty && ops.last is _Name && _depth < 6) {
              final xo = doc.resolve(xobjs[(ops.last as _Name).v]);
              if (xo is _Stream &&
                  doc.resolve(xo.dict['Subtype']) == const _Name('Form')) {
                final dec = doc.decodeStream(xo);
                if (dec != null) {
                  _flush();
                  final saved = gs.copy();
                  final savedTm = tm, savedTlm = tlm;
                  final mList = doc.resolve(xo.dict['Matrix']);
                  final m = mList is List ? _Matrix.fromList(mList) : null;
                  if (m != null) gs.ctm = m.mul(gs.ctm);
                  final res = doc.dictOf(xo.dict['Resources']) ?? resources;
                  _depth++;
                  _exec(dec, res);
                  _depth--;
                  _flush();
                  gs = saved;
                  tm = savedTm;
                  tlm = savedTlm;
                }
              }
            }
            break;
          case 'BI':
            _skipInlineImage(lx);
            break;
        }
      } catch (_) {
        // ignore malformed operator
      }
      ops.clear();
    }
  }

  void _skipInlineImage(_Lexer lx) {
    // Skip "... ID <binary> EI"
    final d = lx.d;
    while (lx.p < d.length - 1) {
      if (d[lx.p] == 73 && d[lx.p + 1] == 68 &&
          (lx.p + 2 >= d.length || _Lexer.isWs(d[lx.p + 2]))) {
        lx.p += 3;
        break;
      }
      lx.p++;
    }
    while (lx.p < d.length - 2) {
      if (_Lexer.isWs(d[lx.p]) &&
          d[lx.p + 1] == 69 &&
          d[lx.p + 2] == 73 &&
          (lx.p + 3 >= d.length ||
              _Lexer.isWs(d[lx.p + 3]) ||
              _Lexer.isDelim(d[lx.p + 3]))) {
        lx.p += 3;
        return;
      }
      lx.p++;
    }
    lx.p = d.length;
  }

  double _num(List ops) =>
      ops.isNotEmpty && ops.last is num ? (ops.last as num).toDouble() : 0;

  List<num> _nums(List ops, int n) {
    if (ops.length < n) return const [];
    final out = <num>[];
    for (var i = ops.length - n; i < ops.length; i++) {
      final v = ops[i];
      if (v is! num) return const [];
      out.add(v);
    }
    return out;
  }

  void _td(double x, double y) {
    tlm = _Matrix.translate(x, y).mul(tlm);
    tm = tlm;
    _flush();
  }

  void _advance(double tx) {
    tm = _Matrix.translate(tx, 0).mul(tm);
  }

  void _show(Uint8List bytes) {
    final font = gs.font;
    if (font == null) return;
    final fs = gs.fontSize;
    for (final g in font.decode(bytes)) {
      glyphs++;
      if (g.unknown && !font.composite) {
        // simple fonts always map through the base encoding; only count CID
      }
      if (g.unknown && font.composite) unreadable++;
      // Device position of the glyph origin.
      final trm = _Matrix(fs * gs.th, 0, 0, fs, 0, gs.rise).mul(tm).mul(gs.ctm);
      final x = trm.tx(0, 0);
      final y = trm.ty(0, 0);
      final scaleY = math.sqrt(trm.c * trm.c + trm.d * trm.d);
      final scaleX = math.sqrt(trm.a * trm.a + trm.b * trm.b);
      var adv = g.width / 1000 * fs + gs.tc;
      if (g.singleByte && g.code == 32) adv += gs.tw;
      adv *= gs.th;
      final glyphW = (g.width / 1000) * scaleX;

      if (_buf.isEmpty) {
        _runX = x;
        _runY = y;
        _runH = scaleY;
      } else {
        // Same run only if the glyph continues on the same baseline.
        if ((y - _runY).abs() > _runH * 0.3 ||
            x < _runEndX - _runH * 0.6 ||
            x > _runEndX + _runH * 0.6) {
          _flush();
          _runX = x;
          _runY = y;
          _runH = scaleY;
        }
      }
      final t = g.text;
      if (t.isNotEmpty && t != '\u0000') _buf.write(t);
      _runEndX = x + glyphW;
      _advance(adv);
      // keep run end aligned with the advance (includes char spacing)
      final after = _Matrix(fs * gs.th, 0, 0, fs, 0, gs.rise).mul(tm).mul(gs.ctm);
      _runEndX = math.max(_runEndX, after.tx(0, 0));
    }
  }

  void _flush() {
    if (_buf.isEmpty) return;
    final text = _buf.toString();
    _buf.clear();
    if (text.trim().isEmpty) return;
    final h = _runH <= 0.5 ? 8.0 : _runH;
    runs.add(TextRun(
      text: text,
      x: _runX,
      y: top - _runY,
      w: math.max(_runEndX - _runX, h * 0.3),
      h: h,
      page: page,
    ));
  }
}

// ---------------------------------------------------------------------------
// Encodings
// ---------------------------------------------------------------------------

final List<String?> _winAnsi = () {
  final t = List<String?>.filled(256, null);
  for (var i = 32; i < 127; i++) {
    t[i] = String.fromCharCode(i);
  }
  for (var i = 160; i < 256; i++) {
    t[i] = String.fromCharCode(i);
  }
  const hi = {
    128: '€', 130: '‚', 131: 'ƒ', 132: '„', 133: '…', 134: '†', 135: '‡',
    136: 'ˆ', 137: '‰', 138: 'Š', 139: '‹', 140: 'Œ', 142: 'Ž', 145: '‘',
    146: '’', 147: '“', 148: '”', 149: '•', 150: '–', 151: '—', 152: '˜',
    153: '™', 154: 'š', 155: '›', 156: 'œ', 158: 'ž', 159: 'Ÿ',
  };
  hi.forEach((k, v) => t[k] = v);
  t[9] = ' ';
  t[10] = ' ';
  t[13] = ' ';
  return t;
}();

const Map<String, String> _glyphNames = {
  'space': ' ', 'exclam': '!', 'quotedbl': '"', 'numbersign': '#',
  'dollar': r'$', 'percent': '%', 'ampersand': '&', 'quotesingle': "'",
  'quoteright': '’', 'parenleft': '(', 'parenright': ')', 'asterisk': '*',
  'plus': '+', 'comma': ',', 'hyphen': '-', 'minus': '-', 'period': '.',
  'slash': '/', 'zero': '0', 'one': '1', 'two': '2', 'three': '3',
  'four': '4', 'five': '5', 'six': '6', 'seven': '7', 'eight': '8',
  'nine': '9', 'colon': ':', 'semicolon': ';', 'less': '<', 'equal': '=',
  'greater': '>', 'question': '?', 'at': '@', 'bracketleft': '[',
  'backslash': r'\', 'bracketright': ']', 'underscore': '_',
  'braceleft': '{', 'bar': '|', 'braceright': '}', 'endash': '–',
  'emdash': '—', 'bullet': '•', 'rupee': '₹', 'uni20B9': '₹',
  'nbspace': ' ', 'quoteleft': '‘', 'degree': '°', 'multiply': '×',
};

String? _glyphName(String n) {
  if (n.length == 1) return n;
  final known = _glyphNames[n];
  if (known != null) return known;
  final uni = RegExp(r'^uni([0-9A-Fa-f]{4})').firstMatch(n);
  if (uni != null) return String.fromCharCode(int.parse(uni.group(1)!, radix: 16));
  final u = RegExp(r'^u([0-9A-Fa-f]{4,6})$').firstMatch(n);
  if (u != null) return String.fromCharCode(int.parse(u.group(1)!, radix: 16));
  // "a.sc", "one.oldstyle" etc.
  final dot = n.indexOf('.');
  if (dot > 0) return _glyphName(n.substring(0, dot));
  return null;
}
