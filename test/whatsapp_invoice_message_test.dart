// Branded TEKFIX DIGITAL WhatsApp invoice message.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/pos/whatsapp_invoice_message.dart';

Map<String, dynamic> inv({
  String name = 'Anu',
  String phone = '9847012345',
  double total = 1500,
  double? cash,
  double? upi,
  double? card,
  double? due,
  List<Map<String, dynamic>>? items,
  String when = '2026-11-18T09:15:00Z',
}) =>
    {
      'invoice': 'INV-W0042',
      'saleDate': when,
      'customerName': name,
      'customerPhone': phone,
      'items': items ??
          [
            {'name': 'Tempered Glass', 'qty': 2, 'price': 250.0},
            {'name': 'Type-C Charger', 'qty': 1, 'price': 1000.0},
          ],
      'total': total,
      if (cash != null) 'cash': cash,
      if (upi != null) 'upi': upi,
      if (card != null) 'card': card,
      if (due != null) 'due': due,
    };

void main() {
  group('payment status (integer paise)', () {
    test('1. fully paid', () {
      final s = invoicePaymentSummary(inv(cash: 500, upi: 1000, due: 0));
      expect(s.status, InvoicePaymentStatus.paid);
      expect(s.totalPaise, 150000);
      expect(s.balancePaise, 0);
      final m = buildWhatsAppInvoiceMessage(inv(cash: 500, upi: 1000, due: 0));
      expect(m, contains('*ആകെ അടച്ച തുക: ₹1,500.00* (PAID)'));
      expect(m, isNot(contains('PARTIAL')));
    });

    test('2. partially paid', () {
      final i = inv(cash: 1000, due: 500);
      final s = invoicePaymentSummary(i);
      expect(s.status, InvoicePaymentStatus.partial);
      expect(s.paidPaise, 100000);
      expect(s.balancePaise, 50000);
      final m = buildWhatsAppInvoiceMessage(i);
      expect(
          m,
          contains('━━━━━━━━━━━━━━━\n'
              '*ആകെ ബിൽ തുക: ₹1,500.00*\n'
              '*അടച്ച തുക: ₹1,000.00* (PARTIAL)\n'
              '*ബാക്കി തുക: ₹500.00*\n'
              '_പേയ്‌മെന്റ്: Cash_\n'
              '━━━━━━━━━━━━━━━'));
    });

    test('3. completely pending', () {
      final i = inv(cash: 0, upi: 0, due: 1500);
      expect(invoicePaymentSummary(i).status, InvoicePaymentStatus.pending);
      final m = buildWhatsAppInvoiceMessage(i);
      expect(m, contains('*ആകെ തുക: ₹1,500.00* (PENDING)\n'
          '*അടയ്ക്കാനുള്ള തുക: ₹1,500.00*'));
    });

    test('never PAID just because payment fields are missing', () {
      final s = invoicePaymentSummary(inv()); // no due / cash / upi / card
      expect(s.status, InvoicePaymentStatus.pending);
      expect(s.balancePaise, 150000);
    });

    test('payments without a due field are summed (staff POS / service)', () {
      expect(invoicePaymentSummary(inv(cash: 700, card: 800)).status,
          InvoicePaymentStatus.paid);
      expect(invoicePaymentSummary(inv(upi: 300)).status,
          InvoicePaymentStatus.partial);
      // service bill: advance applied + net paid
      final svc = {
        'total': 1300.0,
        'cash': 800.0,
        'advanceApplied': 500.0,
      };
      expect(invoicePaymentSummary(svc).status, InvoicePaymentStatus.paid);
      // overpayment (change returned) is PAID, not negative balance
      final over = invoicePaymentSummary(inv(cash: 2000));
      expect(over.balancePaise, 0);
      expect(over.paidPaise, 150000);
    });

    test('paise rounding: no floating-point drift', () {
      // 0.1 + 0.2 style values must still balance exactly
      final s = invoicePaymentSummary(
          {'total': 0.3, 'cash': 0.1, 'upi': 0.2});
      expect(s.status, InvoicePaymentStatus.paid);
      expect(s.balancePaise, 0);
      final p = invoicePaymentSummary({'total': 199.99, 'due': 0.01});
      expect(p.status, InvoicePaymentStatus.partial);
      expect(p.paidPaise, 19998);
    });
  });

  group('message content', () {
    test('4. multiple products, one line each, exact format', () {
      final m = buildWhatsAppInvoiceMessage(inv(due: 0, cash: 1500));
      expect(m, contains('*പർച്ചേസ് വിവരങ്ങൾ:*\n'
          '▸ *Tempered Glass* (2 Nos × ₹250.00) — *₹500.00*\n'
          '▸ *Type-C Charger* (1 Nos × ₹1,000.00) — *₹1,000.00*\n'));
    });

    test('header, invoice number, date/time, footer match the template', () {
      final m = buildWhatsAppInvoiceMessage(inv(due: 0, cash: 1500));
      expect(m, startsWith('*TEKFIX DIGITAL*\n'
          '_Smart Mobile Care & Digital Solutions | Irumbuzhi_\n'
          '━━━━━━━━━━━━━━━\n\n'
          'പ്രിയപ്പെട്ട *Anu*,\n'));
      expect(m, contains('*ഇൻവോയ്സ് നമ്പർ:* `INV-W0042`\n'));
      final local = DateTime.parse('2026-11-18T09:15:00Z').toLocal();
      final hh = local.hour % 12 == 0 ? 12 : local.hour % 12;
      expect(
          m,
          contains('*തീയതി:* 18 Nov 2026 | '
              '${hh.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}'));
      expect(m, contains('$kWaGoogleReviewFallbackUrl\n'));
      expect(m, contains('*കസ്റ്റമർ കെയർ:* +91 70340 93101\n'));
      expect(m, contains('*Instagram:* https://www.instagram.com/tekfix.digital\n'));
      expect(m, isNot(contains(' tekfix.digital\n'))); // never a bare domain
      expect(m, endsWith('_നന്ദി, വീണ്ടും കാണാം!_'));
    });

    test('5. Malayalam customer name kept as is', () {
      final m = buildWhatsAppInvoiceMessage(inv(name: 'അനിൽ കുമാർ', due: 0));
      expect(m, contains('പ്രിയപ്പെട്ട *അനിൽ കുമാർ*,'));
    });

    test('6. long product names stay on one line, markers stripped', () {
      final long = 'Samsung Galaxy S24 Ultra 5G (Titanium Gray, 12GB RAM, '
          '256GB Storage) *Official* Warranty_Pack\nwith box';
      final m = buildWhatsAppInvoiceMessage(inv(
          due: 0,
          items: [
            {'name': long, 'qty': 1, 'price': 129999}
          ]));
      final line = m.split('\n').firstWhere((l) => l.startsWith('▸'));
      expect(line, contains('Samsung Galaxy S24 Ultra 5G'));
      expect(line, contains('Official WarrantyPack with box'));
      expect(line, endsWith('— *₹1,29,999.00*'));
    });

    test('7. empty / walk-in customer name -> Valued Customer', () {
      for (final n in ['', '  ', 'Walk-in Customer', 'null']) {
        expect(buildWhatsAppInvoiceMessage(inv(name: n, due: 0)),
            contains('പ്രിയപ്പെട്ട *Valued Customer*,'));
      }
      final noKey = inv(due: 0)..remove('customerName');
      expect(buildWhatsAppInvoiceMessage(noKey), contains('*Valued Customer*'));
    });

    test('8. zero-decimal and decimal amounts formatted with 2 decimals', () {
      final m = buildWhatsAppInvoiceMessage(inv(
          total: 349.5,
          due: 0,
          items: [
            {'name': 'Cable', 'qty': 3, 'price': 99},
            {'name': 'Pouch', 'qty': 1, 'price': '52.50'},
          ]));
      expect(m, contains('(3 Nos × ₹99.00) — *₹297.00*'));
      expect(m, contains('(1 Nos × ₹52.50) — *₹52.50*'));
      expect(m, contains('*ആകെ അടച്ച തുക: ₹349.50* (PAID)'));
    });

    test('staff POS lines (unitPrice / lineTotal) are supported', () {
      final m = buildWhatsAppInvoiceMessage({
        'invoice': 'POS-1',
        'items': [
          {'name': 'Glass', 'qty': 2, 'unitPrice': 150.0, 'lineTotal': 300.0}
        ],
        'total': 300.0,
        'cash': 300.0,
      });
      expect(m, contains('▸ *Glass* (2 Nos × ₹150.00) — *₹300.00*'));
    });

    test('empty item list is handled', () {
      final m = buildWhatsAppInvoiceMessage(inv(items: const [], due: 0));
      expect(m, contains('*പർച്ചേസ് വിവരങ്ങൾ:*\n▸ _'));
      final noItems = inv(due: 0)..remove('items');
      expect(() => buildWhatsAppInvoiceMessage(noItems), returnsNormally);
    });
  });

  group('WhatsApp URL', () {
    test('9. Malayalam, emoji, ₹, line breaks and URL survive encoding once',
        () {
      final msg = buildWhatsAppInvoiceMessage(inv(name: 'അനു 😊', due: 0),
          emoji: true);
      final uri = whatsAppInvoiceUri('+91 98470-12345', msg);
      expect(uri.host, 'wa.me');
      expect(uri.path, '/919847012345');
      final raw = uri.toString();
      final encodedPart = raw.substring(raw.indexOf('?text=') + 6);
      expect(encodedPart, Uri.encodeComponent(msg)); // encoded exactly once
      expect(encodedPart, isNot(contains('%25'))); // no double encoding
      expect(encodedPart, contains('%0A')); // line breaks
      expect(encodedPart, isNot(contains('+'))); // spaces are %20, not +
      expect(Uri.decodeComponent(encodedPart), msg);
      expect(uri.queryParameters['text'], msg);
      expect(msg, contains('₹'));
      expect(msg, contains('🛡️'));
    });

    test('phone normalisation (existing rule) and no-phone fallback', () {
      expect(waPhoneNumber('98470 12345'), '919847012345');
      expect(waPhoneNumber('09847012345'), '919847012345');
      expect(waPhoneNumber('919847012345'), '919847012345');
      expect(waPhoneNumber(''), '');
      final u = whatsAppInvoiceUri('', 'hi there');
      expect(u.host, 'api.whatsapp.com');
      expect(u.queryParameters['text'], 'hi there');
    });

    test('10. missing phone / WhatsApp launch failure handled safely',
        () async {
      Uri? opened;
      Future<bool> ok(Uri u) async {
        opened = u;
        return true;
      }

      expect(await openWhatsAppInvoice(inv(due: 0), launcher: ok),
          WhatsAppInvoiceResult.opened);
      expect(opened!.host, 'wa.me');

      expect(await openWhatsAppInvoice(inv(phone: '', due: 0), launcher: ok),
          WhatsAppInvoiceResult.noPhone);
      expect(
          await openWhatsAppInvoice(inv(phone: '', due: 0),
              launcher: ok, requirePhone: false),
          WhatsAppInvoiceResult.opened);

      expect(
          await openWhatsAppInvoice(inv(due: 0), launcher: (_) async => false),
          WhatsAppInvoiceResult.launchFailed);
      expect(
          await openWhatsAppInvoice(inv(due: 0),
              launcher: (_) async => throw Exception('No WhatsApp')),
          WhatsAppInvoiceResult.launchFailed);
    });
  });

  test('11/12. invoice data is read-only: totals and record unchanged', () {
    final i = inv(cash: 1000, due: 500);
    final before = jsonEncode(i);
    buildWhatsAppInvoiceMessage(i);
    invoicePaymentSummary(i);
    whatsAppInvoiceUri('9847012345', 'x');
    expect(jsonEncode(i), before);
  });

  group('v2 improvements', () {
    bool hasEmoji(String s) => s.runes.any((r) =>
        r > 0xFFFF || // all pictographic emoji outside the BMP
        const {0x2B50, 0x2705, 0xFE0F, 0x260E, 0x2714}.contains(r));

    test('Windows (plain) message contains no emoji (no ◆ in WhatsApp Desktop)',
        () {
      final m = buildWhatsAppInvoiceMessage(inv(cash: 1500, due: 0),
          emoji: false);
      expect(hasEmoji(m), isFalse);
      expect(m, contains('★ *ഞങ്ങളുടെ സേവനം ഇഷ്ടമായോ?*'));
      expect(m, contains('✆ *കസ്റ്റമർ കെയർ:* +91 70340 93101'));
      expect(m, contains('✓ *ആകെ അടച്ച തുക: ₹1,500.00* (PAID)'));
    });

    test('phone (emoji) message keeps emojis', () {
      final m =
          buildWhatsAppInvoiceMessage(inv(cash: 1500, due: 0), emoji: true);
      expect(m, contains('🛡️ *കസ്റ്റമർ അഷ്വറൻസ്:*'));
      expect(m, contains('⭐ *ഞങ്ങളുടെ സേവനം ഇഷ്ടമായോ?*'));
      expect(m, contains('✅ *ആകെ അടച്ച തുക'));
    });

    test('Google review link: saved setting wins, otherwise working fallback',
        () {
      const saved = 'https://g.page/r/CTekfixDemo/review';
      final m = buildWhatsAppInvoiceMessage(inv(due: 0), reviewUrl: saved);
      expect(m, contains('$saved\n'));
      expect(m, isNot(contains('share.google')));
      final f = buildWhatsAppInvoiceMessage(inv(due: 0), reviewUrl: '  ');
      expect(f, contains(kWaGoogleReviewFallbackUrl));
      // the review URL survives encoding inside the wa.me link
      final u = whatsAppInvoiceUri('9847012345', m);
      expect(u.queryParameters['text'], contains(saved));
    });

    test('warranty line under items that have a warranty', () {
      final m = buildWhatsAppInvoiceMessage(inv(due: 0, items: [
        {'name': 'Redmi Note 13', 'qty': 1, 'price': 15000, 'warranty': '1 Year'},
        {'name': 'Glass', 'qty': 1, 'price': 200, 'warranty': 'No Warranty'},
      ]), emoji: false);
      expect(m, contains('— *₹15,000.00*\n    ↳ _വാറന്റി: 1 Year_\n▸ *Glass*'));
      expect(m, isNot(contains('No Warranty')));
    });

    test('discount shows subtotal and discount; total unchanged', () {
      final i = inv(due: 0, cash: 1400, total: 1400)
        ..['subtotal'] = 1500.0
        ..['discount'] = 100.0;
      final m = buildWhatsAppInvoiceMessage(i);
      expect(m, contains('*ഉപതുക:* ₹1,500.00\n*കിഴിവ്:* −₹100.00\n'));
      expect(m, contains('ആകെ അടച്ച തുക: ₹1,400.00* (PAID)'));
      expect(m, isNot(contains('PARTIAL')));
    });

    test('payment method line from recorded payments only', () {
      expect(waPaymentModes(inv(cash: 500, upi: 1000)), 'Cash + UPI');
      expect(waPaymentModes({'total': 100, 'card': 100.0}), 'Card');
      expect(waPaymentModes(inv()), '');
      final pending =
          buildWhatsAppInvoiceMessage(inv(cash: 0, due: 1500), emoji: false);
      expect(pending, isNot(contains('പേയ്‌മെന്റ്:')));
    });
  });
}
