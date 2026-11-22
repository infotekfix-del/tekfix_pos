// Customer-facing screen (Customer View / second monitor).
//
// DATA MINIMISATION: the screen receives ONLY a [CustomerDisplayState].
// It never gets Item, Party, Sale or inventory objects, so it cannot show
// stock, purchase price, other customers or anything internal. The state is
// built by [posBuildDisplayState], which copies just name / qty / selling
// price (and the last 4 IMEI digits) from each bill line.
//
// This library does not import main.dart, Hive or Firestore.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'pos_cart_logic.dart' show posImeiMasked;
import 'pos_theme.dart';

enum DisplayPhase { idle, bill, thanks }

enum DisplayPayStatus { waiting, received, partial, due }

extension DisplayPayStatusLabel on DisplayPayStatus {
  String get label => switch (this) {
        DisplayPayStatus.waiting => 'Waiting for payment (കാത്തിരിക്കുന്നു)',
        DisplayPayStatus.received => 'Payment received (ലഭിച്ചു)',
        DisplayPayStatus.partial => 'Partially paid (ഭാഗികമായി അടച്ചു)',
        DisplayPayStatus.due => 'Due (ബാക്കി)',
      };
}

@immutable
class CustomerDisplayLine {
  final String name;
  final int qty;
  final double unitPrice;
  final double lineTotal;
  final String maskedId; // "IMEI ••••5678" or ''
  const CustomerDisplayLine({
    required this.name,
    required this.qty,
    required this.unitPrice,
    required this.lineTotal,
    this.maskedId = '',
  });

  Map<String, dynamic> toMap() => {
        'name': name,
        'qty': qty,
        'unitPrice': unitPrice,
        'lineTotal': lineTotal,
        'maskedId': maskedId,
      };

  @override
  bool operator ==(Object other) =>
      other is CustomerDisplayLine &&
      other.name == name &&
      other.qty == qty &&
      other.unitPrice == unitPrice &&
      other.lineTotal == lineTotal &&
      other.maskedId == maskedId;

  @override
  int get hashCode => Object.hash(name, qty, unitPrice, lineTotal, maskedId);
}

/// Everything the customer may see, and nothing else.
@immutable
class CustomerDisplayState {
  final DisplayPhase phase;
  final String shopName;
  final String tagline;
  final String customerName; // '' = walk-in
  final double previousDue; // selected customer's old due (0 = none)
  final List<CustomerDisplayLine> lines;
  final double subtotal;
  final double discount;
  final double tax; // only when the invoice shows tax (0 = hidden)
  final double roundOff; // 0 = hidden
  final double total;
  final double totalDueAfterBill; // 0 = hidden
  final DisplayPayStatus paymentStatus;
  final String? upiQrPayload; // shown only when the cashier asks for UPI
  final String message; // welcome / thank-you text

  const CustomerDisplayState({
    required this.phase,
    this.shopName = 'TEKFIX DIGITAL',
    this.tagline = 'Smart Mobile Care & Digital Solutions',
    this.customerName = '',
    this.previousDue = 0,
    this.lines = const [],
    this.subtotal = 0,
    this.discount = 0,
    this.tax = 0,
    this.roundOff = 0,
    this.total = 0,
    this.totalDueAfterBill = 0,
    this.paymentStatus = DisplayPayStatus.waiting,
    this.upiQrPayload,
    this.message = '',
  });

  /// Plain map (for a second window: only primitives cross over).
  Map<String, dynamic> toMap() => {
        'phase': phase.name,
        'shopName': shopName,
        'tagline': tagline,
        'customerName': customerName,
        'previousDue': previousDue,
        'lines': [for (final l in lines) l.toMap()],
        'subtotal': subtotal,
        'discount': discount,
        'tax': tax,
        'roundOff': roundOff,
        'total': total,
        'totalDueAfterBill': totalDueAfterBill,
        'paymentStatus': paymentStatus.name,
        'upiQrPayload': upiQrPayload,
        'message': message,
      };

  static CustomerDisplayState fromMap(Map m) {
    double d(String k) => (m[k] as num?)?.toDouble() ?? 0;
    return CustomerDisplayState(
      phase: DisplayPhase.values.firstWhere((p) => p.name == m['phase'],
          orElse: () => DisplayPhase.idle),
      shopName: '${m['shopName'] ?? ''}',
      tagline: '${m['tagline'] ?? ''}',
      customerName: '${m['customerName'] ?? ''}',
      previousDue: d('previousDue'),
      lines: [
        for (final l in (m['lines'] as List?) ?? const [])
          if (l is Map)
            CustomerDisplayLine(
              name: '${l['name'] ?? ''}',
              qty: (l['qty'] as num?)?.toInt() ?? 0,
              unitPrice: (l['unitPrice'] as num?)?.toDouble() ?? 0,
              lineTotal: (l['lineTotal'] as num?)?.toDouble() ?? 0,
              maskedId: '${l['maskedId'] ?? ''}',
            )
      ],
      subtotal: d('subtotal'),
      discount: d('discount'),
      tax: d('tax'),
      roundOff: d('roundOff'),
      total: d('total'),
      totalDueAfterBill: d('totalDueAfterBill'),
      paymentStatus: DisplayPayStatus.values.firstWhere(
          (p) => p.name == m['paymentStatus'],
          orElse: () => DisplayPayStatus.waiting),
      upiQrPayload: m['upiQrPayload'] as String?,
      message: '${m['message'] ?? ''}',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CustomerDisplayState && _eq(other.toMap(), toMap());

  @override
  int get hashCode => toMap().toString().hashCode;
}

bool _eq(Map a, Map b) => a.toString() == b.toString();

const String kDisplayThanks =
    'Thank you for shopping with TekFix Digital (നന്ദി)';
const String kDisplayWelcome = 'Welcome to TEKFIX DIGITAL (സ്വാഗതം)';

double _n(dynamic v) =>
    v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;
int _q(dynamic v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;

/// Builds the customer state from the bill on the counter. Copies ONLY the
/// line name, qty and selling price (+ masked IMEI): never cost, stock,
/// supplier or keys.
CustomerDisplayState posBuildDisplayState({
  required List<Map> cart,
  required String customerName,
  required double previousDue,
  required double subtotal,
  required double discount,
  required double total,
  required double creditThisBill, // part of this bill going on credit
  required bool paymentConfirmed, // UPI/card confirmed by the cashier
  String? upiQrPayload,
  String welcome = kDisplayWelcome,
  String shopName = 'TEKFIX DIGITAL',
}) {
  if (cart.isEmpty) {
    return CustomerDisplayState(
      phase: DisplayPhase.idle,
      shopName: shopName,
      message: welcome.trim().isEmpty ? kDisplayWelcome : welcome.trim(),
    );
  }
  final lines = [
    for (final l in cart)
      CustomerDisplayLine(
        name: '${l['name'] ?? ''}',
        qty: _q(l['qty']),
        unitPrice: _n(l['price']),
        lineTotal: _n(l['price']) * _q(l['qty']),
        maskedId: posImeiMasked('${l['imei'] ?? ''}'),
      ),
  ];
  final prev = previousDue > 0 ? previousDue : 0.0;
  final credit = creditThisBill > 0 ? creditThisBill : 0.0;
  return CustomerDisplayState(
    phase: DisplayPhase.bill,
    shopName: shopName,
    customerName: customerName.trim(),
    previousDue: prev,
    lines: lines,
    subtotal: subtotal,
    discount: discount,
    total: total,
    totalDueAfterBill: prev > 0 || credit > 0 ? prev + credit : 0,
    paymentStatus:
        paymentConfirmed ? DisplayPayStatus.received : DisplayPayStatus.waiting,
    upiQrPayload: paymentConfirmed ? null : upiQrPayload,
  );
}

/// Thank-you state from a SAVED bill's amounts (only numbers are passed).
CustomerDisplayState posThanksState({
  required double total,
  required double paid,
  required double due,
  required String customerName,
  double previousDue = 0,
  String shopName = 'TEKFIX DIGITAL',
}) {
  final status = due <= 0.004
      ? DisplayPayStatus.received
      : paid > 0
          ? DisplayPayStatus.partial
          : DisplayPayStatus.due;
  return CustomerDisplayState(
    phase: DisplayPhase.thanks,
    shopName: shopName,
    customerName: customerName.trim(),
    total: total,
    previousDue: previousDue > 0 ? previousDue : 0,
    totalDueAfterBill: previousDue > 0 || due > 0
        ? (previousDue > 0 ? previousDue : 0) + due
        : 0,
    paymentStatus: status,
    message: kDisplayThanks,
  );
}

// ------------------------------------------------------------------- view
final NumberFormat _money =
    NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 2);
String _rs(double v) {
  final s = _money.format(v);
  return s.endsWith('.00') ? s.substring(0, s.length - 3) : s;
}

/// Read-only customer screen: no buttons, no fields, no gestures.
class CustomerDisplayView extends StatelessWidget {
  final CustomerDisplayState state;
  const CustomerDisplayView({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: PosTokens.bg,
      child: SafeArea(
        child: AnimatedSwitcher(
          duration: PosTokens.fast,
          child: switch (state.phase) {
            DisplayPhase.idle => _Idle(state: state, key: const ValueKey('i')),
            DisplayPhase.thanks =>
              _Thanks(state: state, key: const ValueKey('t')),
            DisplayPhase.bill => _Bill(state: state, key: const ValueKey('b')),
          },
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  final CustomerDisplayState state;
  final double scale;
  const _Brand({required this.state, this.scale = 1});

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(state.shopName,
              style: TextStyle(
                  fontSize: 26 * scale,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.2,
                  color: PosTokens.primaryDark)),
          Text(state.tagline,
              style: TextStyle(
                  fontSize: 14 * scale,
                  fontWeight: FontWeight.w600,
                  color: PosTokens.secondary)),
        ],
      );
}

class _Idle extends StatelessWidget {
  final CustomerDisplayState state;
  const _Idle({super.key, required this.state});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.all(26),
              decoration: const BoxDecoration(
                  color: PosTokens.primarySoft, shape: BoxShape.circle),
              child: const Icon(Icons.storefront_rounded,
                  size: 64, color: PosTokens.primary),
            ),
            const SizedBox(height: 24),
            FittedBox(child: _Brand(state: state, scale: 1.6)),
            const SizedBox(height: 24),
            Text(state.message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 22,
                    height: 1.4,
                    fontWeight: FontWeight.w700,
                    color: PosTokens.muted)),
          ]),
        ),
      );
}

class _Thanks extends StatelessWidget {
  final CustomerDisplayState state;
  const _Thanks({super.key, required this.state});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.check_circle_rounded,
                size: 96, color: PosTokens.success),
            const SizedBox(height: 18),
            Text(state.message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    color: PosTokens.text)),
            const SizedBox(height: 14),
            Text(_rs(state.total),
                style: PosTokens.grandTotal.copyWith(fontSize: 44)),
            const SizedBox(height: 10),
            _StatusPill(status: state.paymentStatus, big: true),
            if (state.totalDueAfterBill > 0) ...[
              const SizedBox(height: 14),
              Text('Total due (ആകെ ബാക്കി): ${_rs(state.totalDueAfterBill)}',
                  style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: PosTokens.error)),
            ],
          ]),
        ),
      );
}

class _StatusPill extends StatelessWidget {
  final DisplayPayStatus status;
  final bool big;
  const _StatusPill({required this.status, this.big = false});

  @override
  Widget build(BuildContext context) {
    final (Color c, IconData i) = switch (status) {
      DisplayPayStatus.waiting => (PosTokens.warning, Icons.hourglass_top),
      DisplayPayStatus.received => (PosTokens.success, Icons.check_circle),
      DisplayPayStatus.partial => (PosTokens.warning, Icons.timelapse),
      DisplayPayStatus.due => (PosTokens.error, Icons.schedule),
    };
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: big ? 16 : 12, vertical: big ? 10 : 8),
      decoration: BoxDecoration(
          color: c.withValues(alpha: 0.12), borderRadius: PosTokens.br),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(i, color: c, size: big ? 24 : 20),
        const SizedBox(width: 8),
        Flexible(
          child: Text(status.label,
              style: TextStyle(
                  fontSize: big ? 18 : 15,
                  fontWeight: FontWeight.w800,
                  color: c)),
        ),
      ]),
    );
  }
}

class _Bill extends StatelessWidget {
  final CustomerDisplayState state;
  const _Bill({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= 800;
      final lines = _lines();
      final side = _summary();
      return Padding(
        padding: const EdgeInsets.all(24),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: _Brand(state: state)),
            if (state.customerName.isNotEmpty)
              Flexible(
                child: Text(state.customerName,
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: PosTokens.text)),
              ),
          ]),
          const SizedBox(height: 18),
          Expanded(
            child: wide
                ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(flex: 3, child: lines),
                    const SizedBox(width: 24),
                    Expanded(
                        flex: 2, child: SingleChildScrollView(child: side)),
                  ])
                : ListView(children: [
                    SizedBox(height: 320, child: lines),
                    const SizedBox(height: 16),
                    side,
                  ]),
          ),
        ]),
      );
    });
  }

  Widget _lines() => Container(
        decoration: BoxDecoration(
          color: PosTokens.surface,
          borderRadius: PosTokens.br,
          border: Border.all(color: PosTokens.border),
        ),
        child: Column(children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 14, 18, 10),
            child: Row(children: [
              Expanded(child: Text('Item (ഐറ്റം)', style: _h)),
              SizedBox(width: 60, child: Text('Qty', style: _h)),
              SizedBox(
                  width: 110,
                  child: Text('Price', textAlign: TextAlign.right, style: _h)),
              SizedBox(
                  width: 120,
                  child: Text('Amount', textAlign: TextAlign.right, style: _h)),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount: state.lines.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final l = state.lines[i];
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  child: Row(children: [
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    color: PosTokens.text)),
                            if (l.maskedId.isNotEmpty)
                              Text(l.maskedId,
                                  style: PosTokens.label.copyWith(
                                      fontSize: 14,
                                      fontFeatures: PosTokens.tabular)),
                          ]),
                    ),
                    SizedBox(width: 60, child: Text('${l.qty}', style: _cell)),
                    SizedBox(
                        width: 110,
                        child: Text(_rs(l.unitPrice),
                            textAlign: TextAlign.right, style: _cell)),
                    SizedBox(
                        width: 120,
                        child: Text(_rs(l.lineTotal),
                            textAlign: TextAlign.right,
                            style:
                                _cell.copyWith(fontWeight: FontWeight.w900))),
                  ]),
                );
              },
            ),
          ),
        ]),
      );

  Widget _summary() {
    Widget row(String k, String v, {Color? color, bool big = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(
                child: Text(k,
                    style: TextStyle(
                        fontSize: big ? 18 : 16,
                        fontWeight: FontWeight.w700,
                        color: color ?? PosTokens.muted))),
            Text(v,
                style: TextStyle(
                    fontSize: big ? 20 : 17,
                    fontWeight: FontWeight.w800,
                    color: color ?? PosTokens.text,
                    fontFeatures: PosTokens.tabular)),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: PosTokens.surface,
          borderRadius: PosTokens.br,
          border: Border.all(color: PosTokens.border),
        ),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          row('Subtotal (ഉപതുക)', _rs(state.subtotal)),
          if (state.discount > 0)
            row('Discount (കിഴിവ്)', '− ${_rs(state.discount)}',
                color: PosTokens.success),
          if (state.tax > 0) row('GST', _rs(state.tax)),
          if (state.roundOff != 0) row('Round off', _rs(state.roundOff)),
          const Divider(height: 22),
          const Text('TOTAL TO PAY (അടയ്ക്കേണ്ട തുക)',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                  color: PosTokens.text)),
          FittedBox(
            alignment: Alignment.centerLeft,
            fit: BoxFit.scaleDown,
            child: Text(_rs(state.total),
                style: PosTokens.grandTotal.copyWith(fontSize: 52)),
          ),
          const SizedBox(height: 10),
          _StatusPill(status: state.paymentStatus),
        ]),
      ),
      if (state.previousDue > 0) ...[
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: PosTokens.errorSoft,
            borderRadius: PosTokens.br,
            border: Border.all(color: PosTokens.error.withValues(alpha: 0.4)),
          ),
          child: Column(children: [
            row('Old due (പഴയ ബാക്കി)', _rs(state.previousDue),
                color: PosTokens.error),
            row('Total due after this bill (ആകെ ബാക്കി)',
                _rs(state.totalDueAfterBill),
                color: PosTokens.error, big: true),
          ]),
        ),
      ] else if (state.totalDueAfterBill > 0) ...[
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: PosTokens.warningSoft, borderRadius: PosTokens.br),
          child: row('Total due after this bill (ആകെ ബാക്കി)',
              _rs(state.totalDueAfterBill),
              color: PosTokens.warning, big: true),
        ),
      ],
      if (state.upiQrPayload != null) ...[
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: PosTokens.surface,
            borderRadius: PosTokens.br,
            border: Border.all(color: PosTokens.accent.withValues(alpha: 0.4)),
          ),
          child: Column(children: [
            const Text('Scan to pay by UPI (UPI വഴി അടയ്ക്കാം)',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: PosTokens.accent)),
            const SizedBox(height: 10),
            Center(
              child: QrImageView(
                data: state.upiQrPayload!,
                size: 220,
                backgroundColor: Colors.white,
              ),
            ),
            Text(_rs(state.total),
                style: PosTokens.grandTotal.copyWith(fontSize: 28)),
          ]),
        ),
      ],
    ]);
  }
}

const TextStyle _h = TextStyle(
    fontSize: 14, fontWeight: FontWeight.w800, color: PosTokens.muted);
const TextStyle _cell = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w700,
    color: PosTokens.text,
    fontFeatures: PosTokens.tabular);
