// invoice_pdf.dart — Premium A4 invoice for TekFix POS (v2)
//
// Inter is used because it has the ₹ glyph (default Helvetica does not).
//
// Usage:
//   final bytes = await buildInvoicePdf(data);
//   await Printing.layoutPdf(onLayout: (_) async => bytes);                    // print
//   await Printing.sharePdf(bytes: bytes, filename: '${data.invoiceNo}.pdf');  // WhatsApp / share

import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

// ───────────────────────── Data model ─────────────────────────

class ShopInfo {
  final String name, tagline, address, phone, email;
  final String whatsapp; // digits only, with country code, for the QR link
  final String? gstin;
  const ShopInfo({
    this.name = 'TEKFIX DIGITAL',
    this.tagline = 'SALES · SERVICE · ACCESSORIES',
    this.address = 'Trumbuzhi, Kerala 676509',
    this.phone = '+91 70340 93101',
    this.email = 'info@tekfixdigital.com',
    this.whatsapp = '917034093101',
    this.gstin,
  });
}

class InvoiceLine {
  final String name;
  final int qty;
  final double rate;
  final String? serialNo;
  final int? warrantyMonths;
  const InvoiceLine({
    required this.name,
    required this.qty,
    required this.rate,
    this.serialNo,
    this.warrantyMonths,
  });
  double get amount => qty * rate;
  bool get hasWarranty => (warrantyMonths ?? 0) > 0;
}

class InvoiceData {
  final String invoiceNo;
  final DateTime date;
  final String customerName;
  final String? customerPhone;
  final String paymentMode; // Cash / UPI / Card / Credit
  final List<InvoiceLine> lines;
  final double discount; // flat ₹
  final double paid;
  final List<String> terms;

  const InvoiceData({
    required this.invoiceNo,
    required this.date,
    required this.customerName,
    this.customerPhone,
    required this.paymentMode,
    required this.lines,
    this.discount = 0,
    required this.paid,
    this.terms = defaultTerms,
  });

  double get subtotal => lines.fold(0, (s, l) => s + l.amount);
  double get total => subtotal - discount;
  double get balance => (total - paid).clamp(0, double.infinity).toDouble();
  bool get isPaid => balance <= 0.009;

  static const defaultTerms = [
    'Original invoice is required for all warranty claims.',
    'Covers manufacturing defects only. Physical, liquid or burn damage voids the warranty.',
    "Original box/packaging is required as per the brand's replacement policy.",
  ];

  /// Factory helper to build InvoiceData from a POS / Firestore sale map
  factory InvoiceData.fromMap(Map<dynamic, dynamic> map) {
    final invNo = map['invoice']?.toString() ??
        map['invoiceNo']?.toString() ??
        'INV-${DateTime.now().millisecondsSinceEpoch}';

    DateTime dt;
    final rawDt = map['createdAt'] ?? map['date'];
    if (rawDt is DateTime) {
      dt = rawDt;
    } else if (rawDt != null) {
      dt = DateTime.tryParse(rawDt.toString()) ?? DateTime.now();
    } else {
      dt = DateTime.now();
    }

    final custName = map['customerName']?.toString().trim();
    final name = (custName != null && custName.isNotEmpty) ? custName : 'Counter Customer';
    final phone = map['customerPhone']?.toString().trim();

    // Payment mode & amounts
    final cash = (map['cash'] as num?)?.toDouble() ?? 0.0;
    final upi = (map['upi'] as num?)?.toDouble() ?? 0.0;
    final card = (map['card'] as num?)?.toDouble() ?? 0.0;
    final total = (map['total'] as num?)?.toDouble() ?? 0.0;
    final discount = (map['discount'] as num?)?.toDouble() ?? 0.0;

    String mode = map['paymentMode']?.toString() ?? '';
    if (mode.isEmpty) {
      if (cash > 0 && upi > 0) {
        mode = 'Split (Cash+UPI)';
      } else if (upi > 0) {
        mode = 'UPI';
      } else if (card > 0) {
        mode = 'Card';
      } else if (cash > 0) {
        mode = 'Cash';
      } else {
        mode = 'Cash';
      }
    }

    final paid = (map['paid'] as num?)?.toDouble() ?? (cash + upi + card);

    final rawItems = (map['items'] as List?) ?? [];
    final lines = <InvoiceLine>[];
    for (final it in rawItems) {
      if (it is! Map) continue;
      final m = Map<dynamic, dynamic>.from(it);
      final itemName = m['name']?.toString() ?? 'Item';
      final qty = (m['qty'] as num?)?.toInt() ?? 1;
      final rate = (m['price'] as num?)?.toDouble() ??
          (m['sellingPrice'] as num?)?.toDouble() ??
          (m['rate'] as num?)?.toDouble() ??
          0.0;
      final sn = m['imei']?.toString() ??
          m['serialNo']?.toString() ??
          m['barcode']?.toString();

      int? wMonths;
      final wStr = m['warranty']?.toString() ?? '';
      if (wStr.contains('1 Year') || wStr.contains('12 Month')) {
        wMonths = 12;
      } else if (wStr.contains('6 Month')) {
        wMonths = 6;
      } else if (wStr.contains('3 Month')) {
        wMonths = 3;
      } else if (wStr.contains('1 Month')) {
        wMonths = 1;
      }

      lines.add(InvoiceLine(
        name: itemName,
        qty: qty,
        rate: rate,
        serialNo: (sn != null && sn.isNotEmpty) ? sn : null,
        warrantyMonths: wMonths,
      ));
    }

    return InvoiceData(
      invoiceNo: invNo,
      date: dt,
      customerName: name,
      customerPhone: (phone != null && phone.isNotEmpty) ? phone : null,
      paymentMode: mode,
      lines: lines,
      discount: discount,
      paid: paid > 0 ? paid : total,
    );
  }
}

// ───────────────────────── Style ─────────────────────────

const _ink = PdfColor.fromInt(0xFF111111);
const _red = PdfColor.fromInt(0xFFE31E24);
const _green = PdfColor.fromInt(0xFF1E7A3C);
const _greenBg = PdfColor.fromInt(0xFFEAF6EE);
const _muted = PdfColor.fromInt(0xFF777777);
const _body = PdfColor.fromInt(0xFF444444);
const _rule = PdfColor.fromInt(0xFFE3E3E3);
const _panel = PdfColor.fromInt(0xFFFAFAFA);

final _money = NumberFormat('#,##,##0.00', 'en_IN');
final _dateFmt = DateFormat('dd MMM yyyy');
String _rs(double v) => '₹${_money.format(v)}';

DateTime _addMonths(DateTime d, int m) {
  final y = d.year + (d.month - 1 + m) ~/ 12;
  final mo = (d.month - 1 + m) % 12 + 1;
  final lastDay = DateTime(y, mo + 1, 0).day;
  return DateTime(y, mo, d.day > lastDay ? lastDay : d.day);
}

// ───────────────────────── Font Cache ─────────────────────────

pw.Font? _cachedRegular;
pw.Font? _cachedSemi;
pw.Font? _cachedBold;
pw.Font? _cachedLight;

// ───────────────────────── Builder ─────────────────────────

Future<Uint8List> buildInvoicePdf(InvoiceData d,
    {ShopInfo shop = const ShopInfo()}) async {
  Future<pw.Font> f(String n) async {
    try {
      return pw.Font.ttf(await rootBundle.load('assets/fonts/$n.ttf'));
    } catch (_) {
      try {
        switch (n) {
          case 'Inter-SemiBold':
            return await PdfGoogleFonts.interSemiBold().timeout(const Duration(seconds: 2));
          case 'Inter-Bold':
            return await PdfGoogleFonts.interBold().timeout(const Duration(seconds: 2));
          case 'Inter-Light':
            return await PdfGoogleFonts.interLight().timeout(const Duration(seconds: 2));
          default:
            return await PdfGoogleFonts.interRegular().timeout(const Duration(seconds: 2));
        }
      } catch (_) {
        return pw.Font.helvetica();
      }
    }
  }

  _cachedRegular ??= await f('Inter-Regular');
  _cachedSemi ??= await f('Inter-SemiBold');
  _cachedBold ??= await f('Inter-Bold');
  _cachedLight ??= await f('Inter-Light');

  final regular = _cachedRegular!;
  final semi = _cachedSemi!;
  final bold = _cachedBold!;
  final light = _cachedLight!;

  Future<pw.MemoryImage?> img(String path) async {
    try {
      return pw.MemoryImage((await rootBundle.load(path)).buffer.asUint8List());
    } catch (_) {
      return null;
    }
  }

  final logo = await img('assets/logo.png');
  final seal = await img('assets/seal.png');

  pw.TextStyle t(double size,
          {pw.Font? font, PdfColor color = _ink, double spacing = 0}) =>
      pw.TextStyle(
          font: font ?? regular,
          fontSize: size,
          color: color,
          letterSpacing: spacing);

  pw.Widget label(String s, {PdfColor color = _muted}) => pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 4),
      child: pw.Text(s, style: t(7, font: semi, color: color, spacing: 1.4)));

  pw.Widget totRow(String k, String v, {PdfColor color = _ink, pw.Font? font}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 3),
        child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(k, style: t(9.5, color: color, font: font)),
              pw.Text(v, style: t(9.5, color: color, font: font)),
            ]),
      );

  pw.Widget signLine(String top, String bottom) => pw.Container(
        width: 160,
        padding: const pw.EdgeInsets.only(top: 5),
        decoration: const pw.BoxDecoration(
            border: pw.Border(top: pw.BorderSide(color: PdfColors.grey500))),
        child: pw.Column(children: [
          pw.Text(top.isEmpty ? ' ' : top, style: t(8, font: bold)),
          pw.Text(bottom, style: t(8, color: _body)),
        ]),
      );

  pw.Widget cell(pw.Widget c, [pw.Alignment a = pw.Alignment.topLeft]) =>
      pw.Container(
          alignment: a,
          padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          child: c);

  final warrantyLines = d.lines.where((l) => l.hasWarranty).toList();

  final doc = pw.Document(title: d.invoiceNo, author: shop.name);

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: pw.EdgeInsets.zero,
    theme: pw.ThemeData.withFont(base: regular, bold: bold),

    // Brand bar: red + black
    header: (ctx) => pw.Row(children: [
      pw.Expanded(flex: 28, child: pw.Container(height: 5, color: _red)),
      pw.Expanded(flex: 72, child: pw.Container(height: 5, color: _ink)),
    ]),

    footer: (ctx) => pw.Column(children: [
      if (ctx.pageNumber == ctx.pagesCount)
        pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 11),
          child: pw.RichText(
              text: pw.TextSpan(children: [
            pw.TextSpan(
                text: 'Thank you for choosing TekFix Digital.  ',
                style: t(9, font: bold)),
            pw.TextSpan(
                text: 'We look forward to serving you again.',
                style: t(9, color: _body)),
          ])),
        ),
      pw.Container(
        color: _ink,
        padding: const pw.EdgeInsets.symmetric(horizontal: 40, vertical: 6),
        child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text('This is a computer-generated invoice.',
                  style: t(7, color: PdfColors.grey400, spacing: .8)),
              pw.Text(
                  ctx.pagesCount > 1
                      ? 'Page ${ctx.pageNumber}/${ctx.pagesCount}  ·  Powered by TekFix POS'
                      : 'Powered by TekFix POS',
                  style: t(7, color: PdfColors.grey400, spacing: .8)),
            ]),
      ),
    ]),

    build: (ctx) => [
      pw.Padding(
        padding: const pw.EdgeInsets.fromLTRB(40, 30, 40, 0),
        child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // ── Brand + shop details
              pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          logo != null
                              ? pw.Image(logo, height: 40)
                              : pw.Text(shop.name, style: t(20, font: bold)),
                          pw.SizedBox(height: 6),
                          pw.Text(shop.tagline,
                              style: t(7, color: _muted, spacing: 2.2)),
                        ]),
                    pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.end,
                        children: [
                          for (final s in [
                            shop.address,
                            shop.phone,
                            shop.email,
                            if (shop.gstin != null) 'GSTIN: ${shop.gstin}',
                          ])
                            pw.Padding(
                                padding: const pw.EdgeInsets.only(bottom: 2),
                                child: pw.Text(s, style: t(8, color: _body))),
                        ]),
                  ]),

              // ── Title + meta
              pw.SizedBox(height: 22),
              pw.Container(
                padding: const pw.EdgeInsets.only(bottom: 10),
                decoration: const pw.BoxDecoration(
                    border: pw.Border(
                        bottom: pw.BorderSide(color: _ink, width: 1.2))),
                child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      pw.Text('INVOICE', style: t(26, font: light, spacing: 6)),
                      pw.Table(
                          columnWidths: const {
                            0: pw.IntrinsicColumnWidth(),
                            1: pw.IntrinsicColumnWidth(),
                          },
                          children: [
                            for (final r in [
                              ['Invoice No', d.invoiceNo],
                              ['Date', _dateFmt.format(d.date)],
                            ])
                              pw.TableRow(children: [
                                pw.Padding(
                                    padding: const pw.EdgeInsets.only(
                                        right: 14, bottom: 2),
                                    child: pw.Text(r[0],
                                        style: t(8.5, color: _muted))),
                                pw.Align(
                                    alignment: pw.Alignment.centerRight,
                                    child: pw.Text(r[1],
                                        style: t(8.5, font: semi))),
                              ]),
                          ]),
                    ]),
              ),

              // ── Bill to / Payment
              pw.SizedBox(height: 14),
              pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Expanded(
                        child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: [
                          label('BILL TO'),
                          pw.Text(d.customerName, style: t(12.5, font: bold)),
                          if (d.customerPhone != null)
                            pw.Padding(
                                padding: const pw.EdgeInsets.only(top: 2),
                                child: pw.Text(d.customerPhone!,
                                    style: t(9, color: _body))),
                        ])),
                    pw.Expanded(
                        child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: [
                          label('PAYMENT'),
                          pw.Text(d.paymentMode, style: t(12.5, font: bold)),
                          pw.SizedBox(height: 5),
                          pw.Container(
                            padding: const pw.EdgeInsets.symmetric(
                                horizontal: 9, vertical: 3),
                            decoration: pw.BoxDecoration(
                                color: d.isPaid ? _greenBg : const PdfColor.fromInt(0xFFFDECEC),
                                borderRadius: pw.BorderRadius.circular(20)),
                            child: pw.Text(
                                d.isPaid
                                    ? 'PAID IN FULL'
                                    : 'BALANCE DUE ${_rs(d.balance)}',
                                style: t(7,
                                    font: bold,
                                    color: d.isPaid ? _green : _red,
                                    spacing: 1.3)),
                          ),
                        ])),
                  ]),

              // ── Items table
              pw.SizedBox(height: 18),
              pw.Table(
                columnWidths: const {
                  0: pw.FixedColumnWidth(32),
                  1: pw.FlexColumnWidth(),
                  2: pw.FixedColumnWidth(44),
                  3: pw.FixedColumnWidth(78),
                  4: pw.FixedColumnWidth(84),
                },
                children: [
                  pw.TableRow(
                      decoration: const pw.BoxDecoration(color: _ink),
                      children: [
                        for (final h in [
                          ['#', pw.Alignment.centerLeft],
                          ['ITEM DESCRIPTION', pw.Alignment.centerLeft],
                          ['QTY', pw.Alignment.center],
                          ['RATE (₹)', pw.Alignment.centerRight],
                          ['AMOUNT (₹)', pw.Alignment.centerRight],
                        ])
                          pw.Container(
                              alignment: h[1] as pw.Alignment,
                              padding: const pw.EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 7),
                              child: pw.Text(h[0] as String,
                                  style: t(7.5,
                                      font: semi,
                                      color: PdfColors.white,
                                      spacing: 1))),
                      ]),
                  for (var i = 0; i < d.lines.length; i++)
                    pw.TableRow(
                      decoration: const pw.BoxDecoration(
                          border: pw.Border(
                              bottom: pw.BorderSide(color: _rule, width: .8))),
                      children: [
                        cell(pw.Text((i + 1).toString().padLeft(2, '0'),
                            style: t(9.5))),
                        cell(pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: [
                              pw.Text(d.lines[i].name,
                                  style: t(10, font: semi)),
                              if ((d.lines[i].serialNo ?? '').isNotEmpty)
                                pw.Padding(
                                    padding: const pw.EdgeInsets.only(top: 2),
                                    child: pw.Text(
                                        'S/N: ${d.lines[i].serialNo}',
                                        style: t(7.5, color: _muted))),
                            ])),
                        cell(pw.Text('${d.lines[i].qty}', style: t(9.5)),
                            pw.Alignment.topCenter),
                        cell(pw.Text(_money.format(d.lines[i].rate),
                            style: t(9.5)), pw.Alignment.topRight),
                        cell(pw.Text(_money.format(d.lines[i].amount),
                            style: t(9.5)), pw.Alignment.topRight),
                      ],
                    ),
                ],
              ),

              // ── Words + totals
              pw.SizedBox(height: 14),
              pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Expanded(
                        child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: [
                          label('AMOUNT IN WORDS'),
                          pw.Text(amountInWords(d.total),
                              style: t(9, font: semi)),
                          if (d.discount > 0)
                            pw.Padding(
                                padding: const pw.EdgeInsets.only(top: 7),
                                child: pw.Text(
                                    'You saved ${_rs(d.discount)} on this purchase',
                                    style: t(8.5, font: semi, color: _green))),
                        ])),
                    pw.SizedBox(width: 30),
                    pw.SizedBox(
                      width: 212,
                      child: pw.Column(children: [
                        totRow('Subtotal', _rs(d.subtotal)),
                        if (d.discount > 0)
                          totRow('Discount', '− ${_rs(d.discount)}',
                              color: _body),
                        pw.Container(
                          margin: const pw.EdgeInsets.symmetric(vertical: 4),
                          padding: const pw.EdgeInsets.fromLTRB(9, 8, 9, 8),
                          decoration: const pw.BoxDecoration(
                              color: _ink,
                              border: pw.Border(
                                  left: pw.BorderSide(color: _red, width: 3))),
                          child: pw.Row(
                              mainAxisAlignment:
                                  pw.MainAxisAlignment.spaceBetween,
                              children: [
                                pw.Text('Total',
                                    style: t(10, color: PdfColors.white)),
                                pw.Text(_rs(d.total),
                                    style: t(13.5,
                                        font: bold, color: PdfColors.white)),
                              ]),
                        ),
                        totRow('Paid (${d.paymentMode})', _rs(d.paid),
                            color: _body),
                        totRow('Balance Due', _rs(d.balance), font: bold),
                      ]),
                    ),
                  ]),

              // ── Warranty card + WhatsApp help
              pw.SizedBox(height: 18),
              pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Expanded(
                      child: pw.Container(
                        padding: const pw.EdgeInsets.fromLTRB(12, 10, 12, 10),
                        decoration: const pw.BoxDecoration(
                          color: _panel,
                          border: pw.Border(
                            left: pw.BorderSide(color: _red, width: 3),
                            top: pw.BorderSide(color: _rule),
                            right: pw.BorderSide(color: _rule),
                            bottom: pw.BorderSide(color: _rule),
                          ),
                        ),
                        child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: [
                              label('YOUR WARRANTY', color: _red),
                              if (warrantyLines.isEmpty)
                                pw.Text(
                                    'No warranty applies to the items on this invoice.',
                                    style: t(8.5, color: _body))
                              else
                                for (final l in warrantyLines)
                                  pw.Padding(
                                    padding: const pw.EdgeInsets.only(top: 4),
                                    child: pw.Column(
                                        crossAxisAlignment:
                                            pw.CrossAxisAlignment.start,
                                        children: [
                                          pw.Row(children: [
                                            pw.Expanded(
                                                child: pw.Text(l.name,
                                                    style: t(9, font: semi))),
                                            pw.Text('Valid until ',
                                                style: t(8.5)),
                                            pw.Text(
                                                _dateFmt.format(_addMonths(
                                                    d.date, l.warrantyMonths!)),
                                                style: t(10.5, font: bold)),
                                          ]),
                                          pw.Text(
                                              '${l.warrantyMonths} months'
                                              '${(l.serialNo ?? '').isNotEmpty ? ' · S/N ${l.serialNo}' : ''}',
                                              style: t(7.5, color: _muted)),
                                        ]),
                                  ),
                              if (warrantyLines.isNotEmpty)
                                pw.Padding(
                                    padding: const pw.EdgeInsets.only(top: 6),
                                    child: pw.Text(
                                        'Keep this invoice safe for warranty claims.',
                                        style: t(7.5, color: _muted))),
                            ]),
                      ),
                    ),
                    pw.SizedBox(width: 14),
                    pw.Container(
                      width: 176,
                      padding: const pw.EdgeInsets.all(10),
                      decoration: pw.BoxDecoration(
                          border: pw.Border.all(color: _rule),
                          borderRadius: pw.BorderRadius.circular(4)),
                      child: pw.Row(children: [
                        pw.BarcodeWidget(
                          barcode: pw.Barcode.qrCode(),
                          data: 'https://wa.me/${shop.whatsapp}',
                          width: 58,
                          height: 58,
                          drawText: false,
                        ),
                        pw.SizedBox(width: 9),
                        pw.Expanded(
                            child: pw.Column(
                                crossAxisAlignment: pw.CrossAxisAlignment.start,
                                mainAxisAlignment: pw.MainAxisAlignment.center,
                                children: [
                              pw.Text('Need help?', style: t(8.5, font: bold)),
                              pw.SizedBox(height: 2),
                              pw.Text('Scan to chat on WhatsApp',
                                  style: t(7.5, color: _body)),
                              pw.Text(shop.phone, style: t(7.5, color: _body)),
                            ])),
                      ]),
                    ),
                  ]),

              // ── Terms
              pw.SizedBox(height: 14),
              label('WARRANTY TERMS'),
              for (var i = 0; i < d.terms.length; i++)
                pw.Padding(
                    padding: const pw.EdgeInsets.only(bottom: 3),
                    child: pw.Text('${i + 1}. ${d.terms[i]}',
                        style: t(7.8, color: _body))),

              // ── Signatures + seal
              pw.SizedBox(height: seal != null ? 6 : 40),
              pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    // Customer signs only on credit bills (balance due)
                    if (!d.isPaid)
                      signLine('', 'Customer Signature')
                    else
                      pw.SizedBox(),
                    pw.Column(children: [
                      if (seal != null)
                        pw.Opacity(
                            opacity: 0.85,
                            child: pw.Image(seal, width: 72, height: 72)),
                      pw.SizedBox(height: 4),
                      signLine('For ${shop.name}', 'Authorised Signatory'),
                    ]),
                  ]),
            ]),
      ),
    ],
  ));

  return doc.save();
}

// ───────────────────────── High-level Print & Share APIs ─────────────────────────

/// Prints the premium A4 invoice using the system print dialog.
Future<void> printA4Invoice(InvoiceData data, {ShopInfo shop = const ShopInfo()}) async {
  final bytes = await buildInvoicePdf(data, shop: shop);
  await Printing.layoutPdf(
    name: 'Invoice_${data.invoiceNo}',
    onLayout: (_) async => bytes,
  );
}

/// Shares the premium A4 invoice as a PDF file (e.g. via WhatsApp or email).
Future<void> shareA4InvoicePdf(InvoiceData data, {ShopInfo shop = const ShopInfo()}) async {
  final bytes = await buildInvoicePdf(data, shop: shop);
  await Printing.sharePdf(
    bytes: bytes,
    filename: '${data.invoiceNo}.pdf',
  );
}

// ───────────────────────── Amount in words (Indian system) ─────────────────────────

String amountInWords(double amount) {
  final rupees = amount.floor();
  final paise = ((amount - rupees) * 100).round();
  var s = 'Rupees ${_inWords(rupees)}';
  if (paise > 0) s += ' and ${_inWords(paise)} Paise';
  return '$s Only';
}

const _ones = [
  '', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine',
  'Ten', 'Eleven', 'Twelve', 'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen',
  'Seventeen', 'Eighteen', 'Nineteen'
];
const _tens = [
  '', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty',
  'Ninety'
];

String _inWords(int n) {
  if (n == 0) return 'Zero';
  String two(int x) => x < 20
      ? _ones[x]
      : '${_tens[x ~/ 10]}${x % 10 > 0 ? ' ${_ones[x % 10]}' : ''}';
  String three(int x) {
    final h = x ~/ 100, r = x % 100;
    return [if (h > 0) '${_ones[h]} Hundred', if (r > 0) two(r)].join(' ');
  }

  final parts = <String>[];
  final crore = n ~/ 10000000;
  n %= 10000000;
  final lakh = n ~/ 100000;
  n %= 100000;
  final thousand = n ~/ 1000;
  n %= 1000;
  if (crore > 0) parts.add('${_inWords(crore)} Crore');
  if (lakh > 0) parts.add('${two(lakh)} Lakh');
  if (thousand > 0) parts.add('${two(thousand)} Thousand');
  if (n > 0) parts.add(three(n));
  return parts.join(' ');
}
