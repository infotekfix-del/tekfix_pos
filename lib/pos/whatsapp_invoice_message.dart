// Branded TEKFIX DIGITAL WhatsApp invoice message (Malayalam).
//
// Pure Dart (intl only) so it is unit-testable. Works on the invoice maps the
// app already stores (POS sale, staff POS sale, service bill) and never
// changes them: totals, GST, discount and round-off are read, not computed.
// All money is handled as integer paise.

import 'dart:io' show Platform;

import 'package:intl/intl.dart';

// ---- Brand details (fixed by the owner's template) -------------------------
const String kWaBrandName = 'TEKFIX DIGITAL';
const String kWaBrandTagline =
    'Smart Mobile Care & Digital Solutions | Irumbuzhi';
/// Fallback when Settings has no Google review link: opens Google Maps on
/// the shop (the old share.google link is dead: "this URL isn't available").
/// Set the real "Ask for reviews" link (https://g.page/r/.../review) in
/// After-Sales Follow-ups -> Settings -> Google review URL.
const String kWaGoogleReviewFallbackUrl =
    'https://www.google.com/maps/search/?api=1&query=TEKFIX+DIGITAL+Irumbuzhi';
const String kWaCustomerCare = '+91 70340 93101';
// Full URL: a bare "tekfix.digital" is auto-linked by WhatsApp as a website.
const String kWaInstagramUrl = 'https://www.instagram.com/tekfix.digital';
const String kWaRule = '━━━━━━━━━━━━━━━';

/// Icons used in the message. WhatsApp Desktop on Windows turns emojis in a
/// pre-filled wa.me message into a diamond, so Windows uses plain Unicode
/// symbols that WhatsApp does not treat as emoji; phones keep real emojis.
class WaIcons {
  final String assurance, review, link, phone, instagram, warranty, paid;
  const WaIcons(this.assurance, this.review, this.link, this.phone,
      this.instagram, this.warranty, this.paid);
  static const emoji = WaIcons('🛡️', '⭐', '👉', '📞', '📸', '↳', '✅');
  static const plain = WaIcons('✦', '★', '➤', '✆', '✦', '↳', '✓');
}

/// Emojis everywhere except Windows desktop (see [WaIcons]).
bool get waUseEmoji {
  try {
    return !Platform.isWindows;
  } catch (_) {
    return true;
  }
}

// Same formatter family as the app's rs(): en_IN currency, Indian grouping
// (1,29,999.00), always two decimals; the template supplies the ₹.
final NumberFormat _money =
    NumberFormat.currency(locale: 'en_IN', symbol: '', decimalDigits: 2);
final DateFormat _date = DateFormat('dd MMM yyyy'); // app's dayFormat
final DateFormat _time = DateFormat('hh:mm a'); // app's dtFormat time part

/// Rupees (num / numeric String / null) -> integer paise, half away from zero.
int waPaise(dynamic rupees) {
  final v = rupees is num
      ? rupees.toDouble()
      : (double.tryParse('${rupees ?? ''}'.trim()) ?? 0.0);
  return (v * 100).round();
}

/// "₹1,250.00" style amount (without the ₹; the template adds it).
String waAmount(int paise) => _money.format(paise / 100).trim();

enum InvoicePaymentStatus { paid, partial, pending }

class InvoicePaymentSummary {
  final int totalPaise;
  final int paidPaise;
  final int balancePaise;
  final InvoicePaymentStatus status;
  const InvoicePaymentSummary(
      this.totalPaise, this.paidPaise, this.balancePaise, this.status);
}

bool _has(Map m, String k) => m.containsKey(k) && m[k] != null;

/// Payment status from the invoice's own payment records:
/// * `due` (outstanding balance) is authoritative when present — it is what
///   the POS posts to the customer's ledger;
/// * otherwise the recorded payments (cash + upi + card + applied advance /
///   paidAmount) are summed;
/// * with NO payment record at all the full amount is treated as outstanding
///   (an invoice is never assumed paid because a field is missing).
InvoicePaymentSummary invoicePaymentSummary(Map invoice) {
  final total = waPaise(invoice['total']);
  int paid;
  int balance;
  if (_has(invoice, 'due')) {
    balance = waPaise(invoice['due']);
    if (balance < 0) balance = 0;
    if (balance > total) balance = total;
    paid = total - balance;
  } else {
    final keys = ['cash', 'upi', 'card', 'advanceApplied'];
    final hasRecords =
        keys.any((k) => _has(invoice, k)) || _has(invoice, 'paidAmount');
    if (!hasRecords) {
      paid = 0;
    } else if (_has(invoice, 'paidAmount') && !keys.any((k) => _has(invoice, k))) {
      paid = waPaise(invoice['paidAmount']);
    } else {
      paid = keys.fold(0, (a, k) => a + waPaise(invoice[k]));
    }
    if (paid < 0) paid = 0;
    if (paid > total) paid = total; // change returned to the customer
    balance = total - paid;
  }
  final status = balance <= 0
      ? InvoicePaymentStatus.paid
      : (paid > 0 ? InvoicePaymentStatus.partial : InvoicePaymentStatus.pending);
  return InvoicePaymentSummary(total, paid, balance < 0 ? 0 : balance, status);
}

/// "Cash + UPI" from the recorded payment amounts ('' when none recorded).
String waPaymentModes(Map invoice) {
  final m = <String>[
    if (waPaise(invoice['cash']) > 0) 'Cash',
    if (waPaise(invoice['upi']) > 0) 'UPI',
    if (waPaise(invoice['card']) > 0) 'Card',
    if (waPaise(invoice['advanceApplied']) > 0) 'Advance',
  ];
  return m.join(' + ');
}

/// Payment block between the two rules of the template.
String paymentSummaryText(InvoicePaymentSummary s,
    {String modes = '', WaIcons icons = WaIcons.emoji}) {
  final via = modes.isEmpty ? '' : '\n_പേയ്‌മെന്റ്: ${modes}_';
  switch (s.status) {
    case InvoicePaymentStatus.paid:
      return '${icons.paid} *ആകെ അടച്ച തുക: ₹${waAmount(s.totalPaise)}* (PAID)$via';
    case InvoicePaymentStatus.partial:
      return '*ആകെ ബിൽ തുക: ₹${waAmount(s.totalPaise)}*\n'
          '*അടച്ച തുക: ₹${waAmount(s.paidPaise)}* (PARTIAL)\n'
          '*ബാക്കി തുക: ₹${waAmount(s.balancePaise)}*$via';
    case InvoicePaymentStatus.pending:
      return '*ആകെ തുക: ₹${waAmount(s.totalPaise)}* (PENDING)\n'
          '*അടയ്ക്കാനുള്ള തുക: ₹${waAmount(s.balancePaise)}*';
  }
}

bool _isPlaceholderName(String s) {
  final n = s.trim().toLowerCase();
  return n.isEmpty ||
      n == 'null' ||
      n == 'walk-in customer' ||
      n == 'walk-in' ||
      n == 'walk in' ||
      n == 'walkin' ||
      n == 'customer';
}

/// Keeps WhatsApp formatting intact: one line, no stray * _ ~ ` markers.
String _clean(String s) => s
    .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
    .replaceAll(RegExp(r'[*_~`]'), '')
    .replaceAll(RegExp(r' {2,}'), ' ')
    .trim();

String waCustomerName(Map invoice) {
  final n = _clean('${invoice['customerName'] ?? ''}');
  return _isPlaceholderName(n) ? 'Valued Customer' : n;
}

int _qty(dynamic v) {
  if (v is num) return v.toInt();
  return int.tryParse('${v ?? ''}'.trim()) ??
      (double.tryParse('${v ?? ''}'.trim())?.toInt() ?? 1);
}

/// "6 Months" etc., or '' for no warranty.
String waWarranty(Map line) {
  final w = _clean('${line['warranty'] ?? ''}');
  final l = w.toLowerCase();
  if (w.isEmpty || l == 'null' || l.contains('no warranty') || l == '0 days') {
    return '';
  }
  return w;
}

/// One line per item:
/// ▸ *Name* (2 Nos × ₹150.00) — *₹300.00*
/// plus an indented warranty line when the item has a warranty.
String waItemLine(Map line, {WaIcons icons = WaIcons.emoji}) {
  final name = _clean('${line['name'] ?? line['itemName'] ?? 'Item'}');
  final qty = _qty(line['qty'] ?? line['quantity'] ?? 1);
  final unit = waPaise(line['price'] ?? line['unitPrice'] ?? line['rate']);
  final total = line['lineTotal'] ?? line['amount'];
  final lineTotal = total != null ? waPaise(total) : unit * qty;
  final w = waWarranty(line);
  return '▸ *${name.isEmpty ? 'Item' : name}* '
          '($qty Nos × ₹${waAmount(unit)}) — *₹${waAmount(lineTotal)}*' +
      (w.isEmpty ? '' : '\n    ${icons.warranty} _വാറന്റി: ${w}_');
}

String waItemsList(Map invoice, {WaIcons icons = WaIcons.emoji}) {
  final items = [
    for (final e in (invoice['items'] as List?) ?? const [])
      if (e is Map) e
  ];
  if (items.isEmpty) return '▸ _വിവരങ്ങൾ ലഭ്യമല്ല (No item details)_';
  return items.map((l) => waItemLine(l, icons: icons)).join('\n');
}

/// Invoice moment: saleDate (backdated bills) else createdAt else date.
/// Accepts ISO strings, DateTime, epoch millis and Firestore Timestamps.
DateTime? waInvoiceDate(Map invoice) {
  for (final k in ['saleDate', 'createdAt', 'date']) {
    final v = invoice[k];
    if (v == null) continue;
    if (v is DateTime) return v.toLocal();
    if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
    final p = DateTime.tryParse('$v');
    if (p != null) return p.toLocal();
    try {
      final d = (v as dynamic).toDate();
      if (d is DateTime) return d.toLocal();
    } catch (_) {}
  }
  return null;
}

/// The full branded message (template supplied by the owner).
/// [reviewUrl]: the shop's Google review link (Settings); falls back to
/// [kWaGoogleReviewFallbackUrl]. [emoji]: null = automatic (see [WaIcons]).
String buildWhatsAppInvoiceMessage(Map invoice,
    {DateTime? fallbackDate, String? reviewUrl, bool? emoji}) {
  final ic = (emoji ?? waUseEmoji) ? WaIcons.emoji : WaIcons.plain;
  final when = waInvoiceDate(invoice) ?? fallbackDate ?? DateTime.now();
  final invNo = _clean('${invoice['invoice'] ?? invoice['invoiceId'] ?? '-'}');
  final summary = invoicePaymentSummary(invoice);
  final review = (reviewUrl ?? '').trim().isEmpty
      ? kWaGoogleReviewFallbackUrl
      : reviewUrl!.trim();
  final discount = waPaise(invoice['discount']);
  final subtotal = waPaise(invoice['subtotal']);
  final totals = discount > 0
      ? '\n*ഉപതുക:* ₹${waAmount(subtotal > 0 ? subtotal : summary.totalPaise + discount)}\n'
          '*കിഴിവ്:* −₹${waAmount(discount)}\n'
      : '';
  final modes = summary.paidPaise > 0 ? waPaymentModes(invoice) : '';
  return '*$kWaBrandName*\n'
      '_${kWaBrandTagline}_\n'
      '$kWaRule\n'
      '\n'
      'പ്രിയപ്പെട്ട *${waCustomerName(invoice)}*,\n'
      '*$kWaBrandName*-ൽ നിന്നുള്ള നിങ്ങളുടെ ഔദ്യോഗിക ഡിജിറ്റൽ ഇൻവോയ്സ് ചുവടെ ചേർക്കുന്നു.\n'
      '\n'
      '*ഇൻവോയ്സ് നമ്പർ:* `$invNo`\n'
      '*തീയതി:* ${_date.format(when)} | ${_time.format(when)}\n'
      '\n'
      '*പർച്ചേസ് വിവരങ്ങൾ:*\n'
      '${waItemsList(invoice, icons: ic)}\n'
      '$totals'
      '\n'
      '$kWaRule\n'
      '${paymentSummaryText(summary, modes: modes, icons: ic)}\n'
      '$kWaRule\n'
      '\n'
      '${ic.assurance} *കസ്റ്റമർ അഷ്വറൻസ്:*\n'
      'ഭാവിയിലെ സർവീസ് ആവശ്യങ്ങൾക്കും ബാധകമായ വാറന്റി ക്ലെയിമുകൾക്കും ഈ ഡിജിറ്റൽ ബിൽ സൂക്ഷിക്കുക.\n'
      '\n'
      '${ic.review} *ഞങ്ങളുടെ സേവനം ഇഷ്ടമായോ?*\n'
      'നിങ്ങളുടെ വിലയേറിയ അഭിപ്രായം Google-ൽ രേഖപ്പെടുത്തൂ:\n'
      '${ic.link} $review\n'
      '\n'
      '${ic.phone} *കസ്റ്റമർ കെയർ:* $kWaCustomerCare\n'
      '${ic.instagram} *Instagram:* $kWaInstagramUrl\n'
      '\n'
      '_നന്ദി, വീണ്ടും കാണാം!_';
}

/// Same rule the app already used: 10 digits -> prefix 91; a leading trunk 0
/// is dropped. Returns '' when there is no usable number.
String waPhoneNumber(String phone) {
  var d = phone.replaceAll(RegExp(r'\D'), '');
  if (d.length == 11 && d.startsWith('0')) d = d.substring(1);
  return d.length == 10 ? '91$d' : d;
}

/// wa.me link; only the message is percent-encoded (encodeComponent, once).
/// No number -> WhatsApp's "choose chat" link (existing staff-POS fallback).
Uri whatsAppInvoiceUri(String phone, String message) {
  final number = waPhoneNumber(phone);
  final text = Uri.encodeComponent(message);
  return Uri.parse(number.isEmpty
      ? 'https://api.whatsapp.com/send?text=$text'
      : 'https://wa.me/$number?text=$text');
}

/// Result of trying to open WhatsApp with an invoice.
enum WhatsAppInvoiceResult { opened, noPhone, launchFailed }

/// Builds the branded message and opens WhatsApp. [launcher] is injectable
/// for tests; the app passes url_launcher's launchUrl (external app).
/// [requirePhone] true = no number -> [WhatsAppInvoiceResult.noPhone]
/// (main POS behaviour); false = open WhatsApp's chat picker instead
/// (staff POS behaviour).
Future<WhatsAppInvoiceResult> openWhatsAppInvoice(
  Map invoice, {
  required Future<bool> Function(Uri uri) launcher,
  bool requirePhone = true,
  String? reviewUrl,
  bool? emoji,
}) async {
  final phone = '${invoice['customerPhone'] ?? ''}';
  if (requirePhone && waPhoneNumber(phone).isEmpty) {
    return WhatsAppInvoiceResult.noPhone;
  }
  final uri = whatsAppInvoiceUri(phone,
      buildWhatsAppInvoiceMessage(invoice, reviewUrl: reviewUrl, emoji: emoji));
  try {
    return await launcher(uri)
        ? WhatsAppInvoiceResult.opened
        : WhatsAppInvoiceResult.launchFailed;
  } catch (_) {
    return WhatsAppInvoiceResult.launchFailed;
  }
}
