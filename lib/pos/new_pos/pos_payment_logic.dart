// New POS payment helpers. Pure Dart (unit-testable).
//
// The bill still stores exactly what the existing checkout stores: `cash`
// and `upi` (UPI or card) amounts, the rest becomes `due` (credit). The
// payment modes below only decide which of those two amounts the cashier
// fills in; "amount received" and "change" are counter help, not stored.

enum PosPayMode { cash, upi, credit, split }

/// Amounts written to the existing Cash / UPI-Card fields for a mode.
/// Split keeps whatever the cashier typed (null = leave as typed).
({double cash, double upi})? posPaymentFor(PosPayMode mode, double total) {
  switch (mode) {
    case PosPayMode.cash:
      return (cash: total, upi: 0);
    case PosPayMode.upi:
      return (cash: 0, upi: total);
    case PosPayMode.credit:
      return (cash: 0, upi: 0);
    case PosPayMode.split:
      return null;
  }
}

/// Cash handed over by the customer. Empty = exact amount.
/// Less than the bill is refused (use Split / Credit for the rest).
({double change, String? error}) posTender(double total, String text) {
  final t = text.trim();
  if (t.isEmpty) return (change: 0, error: null);
  final v = double.tryParse(t);
  if (v == null || v < 0) {
    return (change: 0, error: 'Enter a valid amount (ശരിയായ തുക നൽകുക)');
  }
  if (v + 0.001 < total) {
    final short = ((total - v) * 100).round() / 100;
    return (
      change: 0,
      error: 'Received is ₹${_n(short)} less than the bill – use Split or '
          'Credit (തുക കുറവാണ്)'
    );
  }
  return (change: ((v - total) * 100).round() / 100, error: null);
}

String _n(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

/// Quick cash buttons: Exact, ₹500, ₹1000, ₹2000.
const List<int> kPosQuickCash = [500, 1000, 2000];

/// UPI ID shape check (name@bank).
bool posValidVpa(String v) =>
    RegExp(r'^[A-Za-z0-9.\-_]{2,256}@[A-Za-z][A-Za-z0-9.\-]{1,64}$')
        .hasMatch(v.trim());

/// Dynamic UPI QR payload:
/// upi://pay?pa=<VPA>&pn=<name>&am=<amount>&cu=INR&tn=<note>
String posUpiUri({
  required String vpa,
  required String payee,
  required double amount,
  required String note,
}) {
  final am = amount.toStringAsFixed(2);
  return 'upi://pay?pa=${vpa.trim()}'
      '&pn=${Uri.encodeComponent(payee.trim())}'
      '&am=$am&cu=INR'
      '&tn=${Uri.encodeComponent(note.trim())}';
}
