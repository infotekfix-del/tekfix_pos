// =============================================================================
// TEKFIX ERP — Vendor bill import: positioned text model
//
// Both the PDF text extractor and the OCR engine produce positioned text runs.
// This file groups those runs into visual lines and "cells" (text separated by
// a wide horizontal gap, i.e. table columns) so the bill parser can work with
// the bill's real layout instead of a flat string.
// =============================================================================

/// A piece of text with its position on the page.
///
/// Coordinates are in a "y grows downwards" space (top of page = 0) so PDF and
/// OCR output can be handled identically. [h] is roughly the font size.
class TextRun {
  final String text;
  final double x;
  final double y;
  final double w;
  final double h;
  final int page;

  const TextRun({
    required this.text,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.page = 0,
  });

  @override
  String toString() => 'TextRun("$text" p$page @${x.toStringAsFixed(1)},'
      '${y.toStringAsFixed(1)} w${w.toStringAsFixed(1)} h${h.toStringAsFixed(1)})';
}

/// A single word inside a line, with its horizontal extent.
class LayoutWord {
  final String text;
  final double x0;
  final double x1;

  const LayoutWord(this.text, this.x0, this.x1);

  double get xc => (x0 + x1) / 2;

  @override
  String toString() => '$text[${x0.toStringAsFixed(0)}-${x1.toStringAsFixed(0)}]';
}

/// Words that sit close together on a line (one table cell).
class LayoutCell {
  final List<LayoutWord> words;

  LayoutCell(this.words);

  String get text => words.map((w) => w.text).join(' ');
  double get x0 => words.first.x0;
  double get x1 => words.last.x1;
}

/// One visual line of the document.
class LayoutLine {
  final int page;
  final double y;
  final double h;
  final List<LayoutCell> cells;

  LayoutLine({
    required this.page,
    required this.y,
    required this.h,
    required this.cells,
  });

  List<LayoutWord> get words => [for (final c in cells) ...c.words];

  /// Cells joined with three spaces so plain-text consumers still see columns.
  String get text => cells.map((c) => c.text).join('   ');

  @override
  String toString() => text;
}

class BillTextLayout {
  BillTextLayout._();

  /// Groups positioned runs into lines and cells.
  static List<LayoutLine> groupRuns(List<TextRun> runs) {
    final words = <_PosWord>[];
    for (final r in runs) {
      _splitRun(r, words);
    }
    if (words.isEmpty) return const [];

    words.sort((a, b) {
      final p = a.page.compareTo(b.page);
      if (p != 0) return p;
      final y = a.y.compareTo(b.y);
      if (y != 0) return y;
      return a.x0.compareTo(b.x0);
    });

    // --- 1. Cluster words into lines by vertical position ---
    final lines = <List<_PosWord>>[];
    var current = <_PosWord>[];
    double lineY = 0;
    double lineH = 0;
    int linePage = -1;
    for (final w in words) {
      final tol = (lineH > 0 ? lineH : w.h) * 0.45;
      if (current.isEmpty) {
        current.add(w);
        lineY = w.y;
        lineH = w.h;
        linePage = w.page;
        continue;
      }
      if (w.page == linePage && (w.y - lineY).abs() <= tol) {
        current.add(w);
        // Running average keeps slightly skewed OCR lines together.
        lineY = (lineY * (current.length - 1) + w.y) / current.length;
        if (w.h > lineH) lineH = w.h;
      } else {
        lines.add(current);
        current = [w];
        lineY = w.y;
        lineH = w.h;
        linePage = w.page;
      }
    }
    if (current.isNotEmpty) lines.add(current);

    // --- 2. Inside each line, sort by x and split into cells on wide gaps ---
    final out = <LayoutLine>[];
    for (final lw in lines) {
      lw.sort((a, b) => a.x0.compareTo(b.x0));
      final cells = <LayoutCell>[];
      var cellWords = <LayoutWord>[];
      _PosWord? prev;
      double maxH = 0;
      double sumY = 0;
      for (final w in lw) {
        if (w.h > maxH) maxH = w.h;
        sumY += w.y;
        if (prev != null) {
          final gap = w.x0 - prev.x1;
          final em = (w.h + prev.h) / 2;
          // Overlapping duplicate (fake-bold PDFs draw text twice).
          if (gap < -0.5 * em &&
              w.text == prev.text &&
              (w.x0 - prev.x0).abs() < em * 0.5) {
            continue;
          }
          final breakCell = w.forceBreak || gap > em * 0.85;
          if (breakCell && cellWords.isNotEmpty) {
            cells.add(LayoutCell(cellWords));
            cellWords = <LayoutWord>[];
          } else if (gap < em * 0.12 &&
              cellWords.isNotEmpty &&
              !w.startsWord) {
            // Same word split across runs (kerning) -> glue together.
            final last = cellWords.removeLast();
            cellWords.add(LayoutWord(last.text + w.text, last.x0, w.x1));
            prev = w;
            continue;
          }
        }
        cellWords.add(LayoutWord(w.text, w.x0, w.x1));
        prev = w;
      }
      if (cellWords.isNotEmpty) cells.add(LayoutCell(cellWords));
      if (cells.isEmpty) continue;
      out.add(LayoutLine(
        page: lw.first.page,
        y: sumY / lw.length,
        h: maxH,
        cells: cells,
      ));
    }
    return out;
  }

  /// Builds a layout from plain text (tests, pasted text, legacy callers).
  /// Columns are detected from 2+ spaces, tabs or pipes; x = character index.
  static List<LayoutLine> fromPlainText(String text) {
    final out = <LayoutLine>[];
    final rawLines = text.split(RegExp(r'\r?\n'));
    for (var li = 0; li < rawLines.length; li++) {
      final raw = rawLines[li].replaceAll('\t', '    ').replaceAll('|', '   ');
      if (raw.trim().isEmpty) continue;
      final cells = <LayoutCell>[];
      final cellRe = RegExp(r'\S+(?: \S+)*');
      for (final m in cellRe.allMatches(raw)) {
        final words = <LayoutWord>[];
        final wordRe = RegExp(r'\S+');
        for (final wm in wordRe.allMatches(m.group(0)!)) {
          final x0 = (m.start + wm.start).toDouble();
          words.add(LayoutWord(wm.group(0)!, x0, x0 + wm.group(0)!.length));
        }
        cells.add(LayoutCell(words));
      }
      out.add(LayoutLine(page: 0, y: li.toDouble(), h: 1, cells: cells));
    }
    return out;
  }

  static String toText(List<LayoutLine> lines) {
    final sb = StringBuffer();
    int page = -1;
    for (final l in lines) {
      if (page != -1 && l.page != page) sb.writeln();
      page = l.page;
      sb.writeln(l.text);
    }
    return sb.toString();
  }

  static void _splitRun(TextRun r, List<_PosWord> out) {
    final text = r.text.replaceAll(' ', ' ');
    if (text.trim().isEmpty) return;
    final n = text.length;
    final charW = n > 0 ? r.w / n : 0.0;
    final re = RegExp(r'\S+');
    int prevEnd = -1;
    for (final m in re.allMatches(text)) {
      final x0 = r.x + m.start * charW;
      final x1 = r.x + m.end * charW;
      // Two or more spaces inside a single run = deliberate column padding.
      final force = prevEnd >= 0 && (m.start - prevEnd) >= 2;
      out.add(_PosWord(
        text: m.group(0)!,
        x0: x0,
        x1: x1 > x0 ? x1 : x0 + r.h * 0.5,
        y: r.y,
        h: r.h,
        page: r.page,
        forceBreak: force,
        startsWord: m.start > 0 || text.startsWith(' '),
      ));
      prevEnd = m.end;
    }
  }
}

class _PosWord {
  final String text;
  final double x0;
  final double x1;
  final double y;
  final double h;
  final int page;
  final bool forceBreak;

  /// True when the run had whitespace before this word, so it must never be
  /// glued to the previous word even when the gap is tiny.
  final bool startsWord;

  _PosWord({
    required this.text,
    required this.x0,
    required this.x1,
    required this.y,
    required this.h,
    required this.page,
    required this.forceBreak,
    required this.startsWord,
  });
}
