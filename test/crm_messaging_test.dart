// Phase 5: segments, templates, senders, queue, log, report, automations.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/crm/crm_messaging.dart';
import 'package:tekfix_erp_pos/crm/customer_crm.dart';
import 'package:tekfix_erp_pos/crm/customer_models.dart';

void main() {
  late Directory tmp;
  late CustomerCrm crm;
  late CrmMessaging m;
  late Box parties, sales;
  var run = 0;
  final now = DateTime(2026, 11, 18, 12);

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('tekfix_crm_msg_');
    Hive.init(tmp.path);
  });
  tearDownAll(() => Hive.close());

  Future<CrmCustomer> cust(String name, String phone,
      {bool optIn = true, bool dnm = false, String? birthday}) async {
    final c = await crm.createCustomer(
        name: name, phone: phone, whatsappOptIn: optIn, birthday: birthday);
    if (dnm) {
      final p = Map<String, dynamic>.from(parties.get(c.key) as Map)
        ..['doNotMessage'] = true;
      await parties.put(c.key, p);
    }
    return c;
  }

  Future<void> sale(CrmCustomer c, String when, double total,
      {String item = 'Item', String? itemId, String warranty = 'No Warranty'}) async {
    await sales.add({
      '_id': CustomerCrm.newId(),
      'invoice': 'INV-$when',
      'saleDate': when,
      'total': total,
      'customerId': c.id,
      'items': [
        {'name': item, 'qty': 1, 'itemId': itemId, 'warranty': warranty}
      ],
    });
  }

  setUp(() async {
    run++;
    await CustomerCrm.maybeInstance?.stopWatching();
    for (final b in [...kCrmIndexBoxes, ...kCrmMessagingBoxes]) {
      if (Hive.isBoxOpen(b)) await Hive.box(b).deleteFromDisk();
    }
    parties = await Hive.openBox('p_$run');
    sales = await Hive.openBox('s_$run');
    crm = await CustomerCrm.open(parties: parties, sales: sales);
    m = await CrmMessaging.open(crm);
  });

  group('segments', () {
    test('only opted-in, not do-not-message customers are included', () async {
      await cust('Anu', '9000000001');
      await cust('NoConsent', '9000000002', optIn: false);
      await cust('Stopped', '9000000003', dnm: true);
      await crm.idle;
      final r = evaluateSegment(crm, const SegmentFilter(), now: now);
      expect(r.map((c) => c.name), ['Anu']);
    });

    test('filters: no purchase in N days, spent above, item/category, '
        'birthday, pending balance', () async {
      final a = await cust('Anu', '9000000001', birthday: '1990-11-03');
      final b = await cust('Biju', '9000000002', birthday: '1992-05-10');
      final c = await cust('Cini', '9000000003');
      await sale(a, '2026-08-01T10:00:00Z', 6000, item: 'Redmi Note 13');
      await sale(b, '2026-11-10T10:00:00Z', 1200,
          item: 'Back cover', itemId: 'item-cover');
      await sale(c, '2026-11-15T10:00:00Z', 300, item: 'Cable');
      final pc = Map<String, dynamic>.from(parties.get(c.key) as Map)
        ..['balance'] = 250.0;
      await parties.put(c.key, pc);
      await crm.idle;

      List<String> names(SegmentFilter f) => evaluateSegment(crm, f,
              now: now, categoryOf: (l) => l['itemId'] == 'item-cover' ? 'Accessories' : null)
          .map((x) => x.name)
          .toList();

      expect(names(const SegmentFilter(noPurchaseDays: 60)), ['Anu']);
      expect(names(const SegmentFilter(minSpentPaise: 100000)), ['Anu', 'Biju']);
      expect(names(const SegmentFilter(boughtItem: 'redmi')), ['Anu']);
      expect(names(const SegmentFilter(boughtItem: 'accessor')), ['Biju']);
      expect(names(const SegmentFilter(birthdayThisMonth: true)), ['Anu']);
      expect(names(const SegmentFilter(pendingBalance: true)), ['Cini']);
      expect(
          names(const SegmentFilter(minSpentPaise: 100000, noPurchaseDays: 60)),
          ['Anu']);
      expect(SegmentFilter.fromMap(
              const SegmentFilter(noPurchaseDays: 30, pendingBalance: true).toMap())
          .describe(), contains('30 days'));
    });

    test('birthday formats', () {
      expect(birthdayMonth('1990-11-03'), 11);
      expect(birthdayMonth('11-03'), 11);
      expect(birthdayMonth('03/11/1990'), 11);
      expect(birthdayDay('03/11/1990'), 3);
      expect(birthdayMonth(''), isNull);
    });
  });

  group('templates', () {
    test('placeholders filled; promotional always has the opt-out line', () {
      const t = MsgTemplate(
          id: 't', name: 'x', body: 'Hi {name}, {offer} at {shopName}. {lastItem}');
      final s = renderTemplate(t,
          name: 'അനു', lastItem: 'Redmi', shopName: 'TEKFIX', offer: '10% off');
      expect(s, startsWith('Hi അനു, 10% off at TEKFIX. Redmi'));
      expect(s, endsWith(kOptOutLine));
      const tx = MsgTemplate(
          id: 't2', name: 'x', body: 'Ready {name}', promotional: false);
      expect(renderTemplate(tx, name: 'A'), 'Ready A');
      const own = MsgTemplate(id: 't3', name: 'x', body: 'Hi. Reply STOP to stop');
      expect(renderTemplate(own, name: 'A').contains(kOptOutLine), isFalse);
    });

    test('defaults seeded once with fixed ids; edit + soft delete', () async {
      final n = m.allTemplates().length;
      await m.seedDefaults();
      expect(m.allTemplates().length, n);
      expect(m.template('tpl_default_offer'), isNotNull);
      final t = await m.saveTemplate(const MsgTemplate(
          id: '', name: 'Diwali', body: 'ദീപാവലി ഓഫർ {offer}'));
      expect(m.template(t.id)!.body, contains('ദീപാവലി'));
      await m.deleteTemplate(t.id);
      expect(m.template(t.id), isNull);
      expect(m.templates.length, n + 1); // never physically removed
    });
  });

  group('senders', () {
    test('WaMeSender builds a wa.me link and rejects bad numbers', () async {
      Uri? opened;
      final s = WaMeSender((u) async {
        opened = u;
        return true;
      });
      final r = await s.send(phone: '98470 12345', text: 'ഹായ് & hi');
      expect(r.ok, isTrue);
      expect(opened!.host, 'wa.me');
      expect(opened!.path, '/919847012345');
      expect(opened!.queryParameters['text'], 'ഹായ് & hi');
      expect((await s.send(phone: '123', text: 'x')).ok, isFalse);
    });

    test('CloudApiSender is a stub', () async {
      final s = CloudApiSender(
          phoneNumberId: 'x', endpoint: Uri.parse('https://example.invalid'));
      expect(s.needsUserTap, isFalse);
      expect((await s.send(phone: '9847012345', text: 'x')).ok, isFalse);
    });
  });

  group('campaign queue, log, cap, report', () {
    test('sent/skipped leave the queue; opted-out customers drop out',
        () async {
      final a = await cust('Anu', '9000000001');
      final b = await cust('Biju', '9000000002');
      final c = await cust('Cini', '9000000003');
      await crm.idle;
      final t = m.template('tpl_default_offer')!;
      final cmp = await m.createCampaign(
          name: 'Nov',
          filter: const SegmentFilter(),
          template: t,
          customers: [a, b, c],
          offer: '10% off');
      final id = '${cmp['_id']}';
      var q = m.campaignQueue(id, shopName: 'TEKFIX');
      expect(q.map((x) => x.customer.name), ['Anu', 'Biju', 'Cini']);
      expect(q.first.text, contains('10% off'));
      expect(q.first.text, contains(kOptOutLine));

      await m.logMessage(
          customer: q[0].customer,
          templateId: t.id,
          kind: t.kind,
          status: 'sent',
          campaignId: id,
          dedupeKey: q[0].dedupeKey,
          at: DateTime.parse('2026-11-01T10:00:00Z'));
      await m.logMessage(
          customer: q[1].customer,
          templateId: t.id,
          kind: t.kind,
          status: 'skipped',
          campaignId: id,
          dedupeKey: q[1].dedupeKey);
      // Cini opts out after the campaign was built
      final pc = Map<String, dynamic>.from(parties.get(c.key) as Map)
        ..['doNotMessage'] = true;
      await parties.put(c.key, pc);
      await crm.idle;
      q = m.campaignQueue(id);
      expect(q, isEmpty);

      // Anu buys 3 days after the message -> counted; Biju (skipped) not
      await sale(a, '2026-11-04T10:00:00Z', 750);
      await sale(a, '2026-11-20T10:00:00Z', 999); // > 7 days: ignored
      await crm.idle;
      final r = m.report(id);
      expect(r.targeted, 3);
      expect(r.sent, 1);
      expect(r.skipped, 1);
      expect(r.purchasedWithin7Days, 1);
      expect(r.revenuePaise, 75000);
    });

    test('daily cap counts only today\'s sent messages', () async {
      final a = await cust('Anu', '9000000001');
      await crm.idle;
      await m.setSending(delaySec: 5, dailyCap: 2);
      for (final at in [now, now, now.subtract(const Duration(days: 1))]) {
        await m.logMessage(
            customer: a, templateId: 'x', kind: 'promo', status: 'sent', at: at);
      }
      await m.logMessage(
          customer: a, templateId: 'x', kind: 'promo', status: 'skipped', at: now);
      expect(m.sentToday(now: now), 2);
      expect(m.remainingToday(now: now), 0);
      expect(m.delaySeconds, 5);
    });
  });

  group('automations', () {
    test('everything is off by default', () async {
      final a = await cust('Anu', '9000000001', birthday: '1990-11-18');
      await sale(a, '2026-11-18T05:00:00Z', 100);
      await crm.idle;
      expect(m.automation.birthday, isFalse);
      expect(m.automationDue(now: now), isEmpty);
    });

    test('birthday, miss-you, warranty, service, thank-you + dedupe', () async {
      final a = await cust('Anu', '9000000001', birthday: '1990-11-18');
      final b = await cust('Biju', '9000000002');
      final c = await cust('Cini', '9000000003');
      await sale(b, '2026-08-01T10:00:00Z', 500, item: 'Charger');
      await sale(c, '2025-11-21T10:00:00Z', 9000,
          item: 'Vivo Y20', warranty: '1 Year'); // ends ~2026-11-21
      await sale(c, '2026-11-17T18:00:00Z', 300, item: 'Glass');
      await crm.idle;
      await m.setAutomation(const AutomationSettings(
          birthday: true,
          missYou: true,
          missYouDays: 60,
          warranty: true,
          warrantyDaysBefore: 7,
          serviceReady: true,
          thankYou: true));
      final jobs = [
        const MapEntry(1, {
          'jobId': 'SRV-1',
          'phone': '+91 90000 00003',
          'status': 'Ready',
          'brandModel': 'iPhone 11'
        }),
        const MapEntry(2, {'jobId': 'SRV-2', 'phone': '9000000003', 'status': 'In Progress'}),
      ];
      final due = m.automationDue(
          now: now,
          shopName: 'TEKFIX',
          serviceJobs: jobs,
          thankYouText: (c, s) => 'THANKS ${c.name}');
      final kinds = {for (final q in due) '${q.kind}:${q.customer.name}'};
      expect(kinds, {
        'birthday:Anu',
        'missyou:Biju',
        'warranty:Cini',
        'service:Cini',
        'thankyou:Cini',
      });
      expect(due.firstWhere((q) => q.kind == 'thankyou').text, 'THANKS Cini');
      expect(due.firstWhere((q) => q.kind == 'service').text, contains('iPhone 11'));
      expect(a.id, isNotEmpty);

      // once logged (sent or skipped) the same reminder never comes back
      for (final q in due) {
        await m.logMessage(
            customer: q.customer,
            templateId: q.templateId,
            kind: q.kind,
            status: 'sent',
            dedupeKey: q.dedupeKey);
      }
      expect(
          m.automationDue(
              now: now, serviceJobs: jobs, thankYouText: (c, s) => 'x'),
          isEmpty);
    });
  });
}
