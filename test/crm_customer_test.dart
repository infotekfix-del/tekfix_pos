// Customer CRM Phase 1/2 tests: phone normalisation, duplicate prevention,
// index updates (save / edit / return / delete / sync arrival), migration
// idempotency. Pure Hive in a temp directory — touches no real shop data.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/crm/customer_crm.dart';
import 'package:tekfix_erp_pos/crm/customer_migration.dart';
import 'package:tekfix_erp_pos/crm/customer_models.dart';
import 'package:tekfix_erp_pos/crm/phone_utils.dart';

void main() {
  // ------------------------------------------------------------ phone utils
  group('normalizePhone', () {
    test('accepts common Indian formats and returns 10 digits', () {
      const want = '9847012345';
      for (final raw in [
        '9847012345',
        '98470 12345',
        '98470-12345',
        '+91 98470 12345',
        '+91-9847012345',
        '919847012345',
        '09847012345',
        '00919847012345',
        ' (+91) 98470-123-45 ',
      ]) {
        expect(normalizePhone(raw), want, reason: raw);
      }
    });

    test('rejects invalid numbers', () {
      for (final raw in [
        null,
        '',
        '12345',
        '1234567890', // must start 6-9
        '5847012345',
        '98470123456', // 11 digits, no trunk 0
        '9847012345678',
        'abcdefghij',
      ]) {
        expect(normalizePhone(raw), isNull, reason: '$raw');
      }
    });

    test('phoneError allows empty (walk-in) and flags bad input', () {
      expect(phoneError(''), isNull);
      expect(phoneError(null), isNull);
      expect(phoneError('98470 12345'), isNull);
      expect(phoneError('12345'), isNotNull);
    });

    test('toPaise uses integer paise', () {
      expect(toPaise(199.99), 19999);
      expect(toPaise('250'), 25000);
      expect(toPaise(null), 0);
      expect(toPaise(0.1 + 0.2), 30);
    });
  });

  // ----------------------------------------------------------- crm + index
  late Directory tmp;
  late Box parties, sales;
  late CustomerCrm crm;
  var run = 0;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('tekfix_crm_test_');
    Hive.init(tmp.path);
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  setUp(() async {
    run++;
    await CustomerCrm.maybeInstance?.stopWatching();
    for (final b in kCrmIndexBoxes) {
      if (Hive.isBoxOpen(b)) await Hive.box(b).deleteFromDisk();
    }
    parties = await Hive.openBox('parties_$run');
    sales = await Hive.openBox('sales_$run');
    crm = await CustomerCrm.open(parties: parties, sales: sales);
  });

  Map<String, dynamic> sale(String inv, double total,
          {String? cid, String phone = '', String when = '2026-11-01T10:00:00Z'}) =>
      {
        '_id': CustomerCrm.newId(),
        'invoice': inv,
        'saleDate': when,
        'total': total,
        'customerPhone': phone,
        'customerName': 'X',
        if (cid != null) 'customerId': cid,
        'items': [
          {'name': 'Item $inv', 'qty': 1, 'price': total}
        ],
        'status': 'SOLD',
      };

  group('duplicate prevention', () {
    test('createCustomer blocks a second customer with the same phone', () async {
      final a = await crm.createCustomer(name: 'Anu', phone: '+91 98470 12345');
      expect(a.phone, '9847012345');
      expect(
          () => crm.createCustomer(name: 'Anu 2', phone: '09847012345'),
          throwsA(isA<DuplicatePhoneException>()
              .having((e) => e.existing.id, 'existing id', a.id)));
      expect(parties.length, 1);
    });

    test('createCustomer rejects invalid phone', () async {
      expect(() => crm.createCustomer(name: 'B', phone: '12345'),
          throwsA(isA<FormatException>()));
    });

    test('prepareCustomerParty: blocks duplicate, allows editing self', () async {
      final a = await crm.createCustomer(name: 'Anu', phone: '9847012345');
      expect(
          () => crm.prepareCustomerParty(
              {'name': 'New', 'phone': '98470-12345', 'type': 'Customer'}),
          throwsA(isA<DuplicatePhoneException>()));
      final existing = Map<String, dynamic>.from(parties.get(a.key) as Map);
      final out = crm.prepareCustomerParty(
          {'name': 'Anu K', 'phone': '+919847012345', 'type': 'Customer'},
          existing: existing);
      expect(out['_id'], a.id);
      expect(out['phone'], '9847012345');
      expect(out['createdAt'], existing['createdAt']);
    });

    test('suppliers are not subject to customer phone uniqueness', () async {
      await crm.createCustomer(name: 'Anu', phone: '9847012345');
      final out = crm.prepareCustomerParty(
          {'name': 'Vendor', 'phone': '9847012345', 'type': 'Supplier'});
      expect(out['phone'], '9847012345');
    });

    test('resolveForBill: walk-in, existing, and new number', () async {
      expect(await crm.resolveForBill(phoneRaw: '', name: ''), isNull);
      final a = await crm.createCustomer(name: 'Anu', phone: '9847012345');
      final again =
          await crm.resolveForBill(phoneRaw: '98470 12345', name: 'Anu');
      expect(again!.id, a.id);
      final created =
          await crm.resolveForBill(phoneRaw: '9000000001', name: 'Biju');
      expect(created!.name, 'Biju');
      expect(parties.length, 2);
      expect(() => crm.resolveForBill(phoneRaw: '123', name: 'x'),
          throwsA(isA<FormatException>()));
    });
  });

  group('index updates', () {
    test('sale save/edit/return/delete keep stats in sync', () async {
      final a = await crm.createCustomer(name: 'Anu', phone: '9847012345');
      final k1 = await sales.add(sale('INV-1', 100.50, cid: a.id));
      final k2 = await sales.add(
          sale('INV-2', 200, cid: a.id, when: '2026-11-05T10:00:00Z'));
      await crm.idle;
      var c = crm.lookupByPhone('98470 12345')!;
      expect(c.billCount, 2);
      expect(c.totalSpentPaise, 30050);
      expect(c.lastPurchaseAt, DateTime.parse('2026-11-05T10:00:00Z'));
      expect(crm.salesOf(a.id, limit: 1).single.value['invoice'], 'INV-2');

      // edit amount
      final s1 = Map<String, dynamic>.from(sales.get(k1) as Map)..['total'] = 150.0;
      await sales.put(k1, s1);
      await crm.idle;
      expect(crm.byId(a.id)!.totalSpentPaise, 35000);

      // full return excluded from totals but stays in history
      final s2 = Map<String, dynamic>.from(sales.get(k2) as Map)
        ..['returned'] = true
        ..['status'] = 'RETURNED';
      await sales.put(k2, s2);
      await crm.idle;
      c = crm.byId(a.id)!;
      expect(c.billCount, 1);
      expect(c.totalSpentPaise, 15000);
      expect(crm.salesOf(a.id).length, 2);

      // delete
      await sales.delete(k1);
      await crm.idle;
      expect(crm.byId(a.id)!.billCount, 0);
      expect(crm.salesOf(a.id).length, 1);
    });

    test('unlinked sale is linked by phone; partial returnedAmount is netted',
        () async {
      final a = await crm.createCustomer(name: 'Anu', phone: '9847012345');
      await sales.add(sale('INV-9', 500, phone: '+91 98470 12345')
        ..['returnedAmount'] = 100);
      await crm.idle;
      expect(crm.byId(a.id)!.totalSpentPaise, 40000);
    });

    test('phone change moves the index entry', () async {
      final a = await crm.createCustomer(name: 'Anu', phone: '9847012345');
      final p = Map<String, dynamic>.from(parties.get(a.key) as Map)
        ..['phone'] = '9000000002';
      await parties.put(a.key, p);
      await crm.idle;
      expect(crm.lookupByPhone('9847012345'), isNull);
      expect(crm.lookupByPhone('9000000002')!.id, a.id);
    });

    test('party deleted -> lookup gone; sale arriving before party (sync)',
        () async {
      // a synced sale referencing a customer that is not on this device yet
      const remoteId = 'remote-customer-uuid';
      await sales.add(sale('INV-R', 300, cid: remoteId));
      await crm.idle;
      expect(crm.byId(remoteId), isNull);
      // the party arrives later through sync
      await parties.add({
        '_id': remoteId,
        'name': 'Remote',
        'phone': '9000000003',
        'type': 'Customer',
        'createdAt': '2026-01-01T00:00:00Z',
      });
      await crm.idle;
      final c = crm.lookupByPhone('9000000003')!;
      expect(c.billCount, 1);
      expect(c.totalSpentPaise, 30000);
      await parties.delete(c.key);
      await crm.idle;
      expect(crm.lookupByPhone('9000000003'), isNull);
    });

    test('offline duplicates from two devices resolve deterministically',
        () async {
      await parties.add({
        '_id': 'bbb',
        'name': 'Later',
        'phone': '9000000004',
        'type': 'Customer',
        'createdAt': '2026-11-02T00:00:00Z',
      });
      await parties.add({
        '_id': 'aaa',
        'name': 'Earlier',
        'phone': '9000000004',
        'type': 'Customer',
        'createdAt': '2026-11-01T00:00:00Z',
      });
      await crm.idle;
      expect(crm.lookupByPhone('9000000004')!.id, 'aaa');
      await crm.rebuildIndexes();
      expect(crm.lookupByPhone('9000000004')!.id, 'aaa');
      expect(crm.duplicatePhones(), ['9000000004']);
    });

    test('rebuildIndexes reproduces incremental stats exactly', () async {
      final a = await crm.createCustomer(name: 'Anu', phone: '9847012345');
      for (var i = 0; i < 5; i++) {
        await sales.add(sale('INV-$i', 10.0 * (i + 1), cid: a.id,
            when: '2026-11-0${i + 1}T10:00:00Z'));
      }
      await crm.idle;
      final before = crm.byId(a.id)!;
      final r = await crm.rebuildIndexes();
      final after = crm.byId(a.id)!;
      expect(r.indexedSales, 5);
      expect(after.totalSpentPaise, before.totalSpentPaise);
      expect(after.billCount, 5);
      expect(after.firstPurchaseAt, before.firstPurchaseAt);
    });

    test('ensureIndexes rebuilds after an interrupted update', () async {
      final a = await crm.createCustomer(name: 'Anu', phone: '9847012345');
      await crm.stopWatching(); // simulate app killed: writes not indexed
      await sales.add(sale('INV-X', 99, cid: a.id));
      expect(crm.byId(a.id)!.billCount, 0);
      expect(await crm.ensureIndexes(), isTrue);
      expect(crm.byId(a.id)!.billCount, 1);
    });
  });

  group('migration', () {
    test('dry run writes nothing; apply links; second run is a no-op',
        () async {
      await parties.add({'name': 'Old Cust', 'phone': '098470 12345', 'type': 'Customer'});
      await parties.add({'name': 'Vendor', 'phone': '9000000009', 'type': 'Supplier'});
      Map<String, dynamic> old(String inv, String phone, String name,
              {String when = '2026-10-01T10:00:00Z'}) =>
          {'invoice': inv, 'createdAt': when, 'total': 100.0,
           'customerPhone': phone, 'customerName': name, 'items': []};
      await sales.add(old('A1', '9847012345', 'Old Cust'));
      await sales.add(old('A2', '+91 90000 00001', 'Walk-in Customer'));
      await sales.add(old('A3', '9000000001', 'Biju',
          when: '2026-10-05T10:00:00Z'));
      await sales.add(old('A4', '', 'Walk-in Customer'));
      await sales.add(old('A5', '12345', 'Bad'));
      await crm.idle;

      final m = CustomerMigration(crm);
      final snapshotParties = parties.toMap().toString();
      final snapshotSales = sales.toMap().toString();
      final dry = await m.dryRun();
      expect(parties.toMap().toString(), snapshotParties);
      expect(sales.toMap().toString(), snapshotSales);
      expect(dry.salesToLink, 3);
      expect(dry.customersToCreate, 1);
      expect(dry.partiesToUpdate, 1); // supplier untouched
      expect(dry.salesNoCustomer, 2);
      expect(dry.invalidPhones, 1);

      expect(() => m.apply(backupDone: false), throwsStateError);
      final applied = await m.apply(backupDone: true);
      expect(applied.applied, isTrue);

      final biju = crm.lookupByPhone('9000000001')!;
      expect(biju.name, 'Biju'); // real name wins over "Walk-in"
      expect(biju.billCount, 2);
      final oldC = crm.lookupByPhone('9847012345')!;
      expect(oldC.billCount, 1);
      final p = parties.get(oldC.key) as Map;
      expect(p['phone'], '9847012345');
      expect(p['phoneRaw'], '098470 12345'); // original kept
      final a2 = sales.values.cast<Map>().firstWhere((s) => s['invoice'] == 'A2');
      expect(a2['customerId'], biju.id);
      expect(a2['customerPhoneRaw'], '+91 90000 00001');

      final partiesAfter = parties.length;
      final again = await m.dryRun();
      expect(again.nothingToDo, isTrue);
      final reapplied = await m.apply(backupDone: true);
      expect(reapplied.salesToLink, 0);
      expect(parties.length, partiesAfter); // no duplicate customers
    });
  });

  test('CrmCustomer.canMessage respects opt-in and do-not-message', () {
    final c = CrmCustomer.from(1, {
      '_id': 'x',
      'name': 'A',
      'phone': '9847012345',
      'whatsappOptIn': true,
      'doNotMessage': true,
    }, null);
    expect(c.canMessage, isFalse);
  });
}
