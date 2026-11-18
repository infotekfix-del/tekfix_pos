// Phase 4: search by name / full phone / partial phone, Malayalam-safe.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:tekfix_erp_pos/crm/customer_crm.dart';
import 'package:tekfix_erp_pos/crm/customer_search.dart';

void main() {
  group('searchKey / partyMatchScore', () {
    test('Malayalam chillu encodings match each other', () {
      // ൽ (atomic chillu) vs ല് + ZWJ (old encoding)
      expect(searchKey('അനിൽ'), searchKey('അനില്‍'));
      expect(partyMatchScore({'name': 'അനില്‍ കുമാർ'}, 'അനിൽ'), greaterThan(0));
      expect(partyMatchScore({'name': 'ശ്രീധരൻ'}, 'ശ്രീ'), 70);
    });

    test('name: case-insensitive, prefix beats contains', () {
      final p = {'name': 'Anu Krishnan', 'phone': '9847012345'};
      expect(partyMatchScore(p, 'anu krishnan'), 90);
      expect(partyMatchScore(p, 'ANU'), 70);
      expect(partyMatchScore(p, 'kris'), 50);
      expect(partyMatchScore(p, 'shna'), 30);
      expect(partyMatchScore(p, 'anu 2345'), 20); // name + last digits
      expect(partyMatchScore(p, 'biju'), 0);
    });

    test('phone: full (any format), last 4, middle digits', () {
      final p = {'name': 'Anu', 'phone': '+91 98470 12345'};
      expect(partyMatchScore(p, '09847012345'), 100);
      expect(partyMatchScore(p, '2345'), 80);
      expect(partyMatchScore(p, '470 1'), 60);
      expect(partyMatchScore(p, '1111'), 0);
      expect(partyMatchScore({'name': 'No phone'}, '2345'), 0);
      expect(isPhoneQuery('12'), isFalse); // too short to treat as phone
    });
  });

  group('CustomerCrm.searchCustomers', () {
    late CustomerCrm crm;
    late Box parties, sales;

    setUpAll(() async {
      final tmp = Directory.systemTemp.createTempSync('tekfix_crm_search_');
      Hive.init(tmp.path);
      parties = await Hive.openBox('p_search');
      sales = await Hive.openBox('s_search');
      crm = await CustomerCrm.open(parties: parties, sales: sales);
      final a = await crm.createCustomer(name: 'Anu', phone: '9847012345');
      final b = await crm.createCustomer(name: 'Anoop', phone: '9000012345');
      await crm.createCustomer(name: 'Biju', phone: '9000000001');
      await parties.add(
          {'name': 'Anu Traders', 'phone': '9847099999', 'type': 'Supplier'});
      await sales.add({
        '_id': CustomerCrm.newId(),
        'invoice': 'INV-B',
        'saleDate': '2026-11-15T10:00:00Z',
        'total': 999.0,
        'customerId': b.id,
        'items': [
          {'name': 'Earphones', 'qty': 1}
        ],
      });
      await sales.add({
        '_id': CustomerCrm.newId(),
        'invoice': 'INV-A',
        'saleDate': '2026-11-01T10:00:00Z',
        'total': 100.0,
        'customerId': a.id,
        'items': [],
      });
      await crm.idle;
    });

    tearDownAll(() => Hive.close());

    test('last 4 digits finds both, most recent purchase first', () {
      final r = crm.searchCustomers('2345');
      expect(r.map((h) => h.customer.name), ['Anoop', 'Anu']);
      expect(r.first.lastItem, 'Earphones');
      expect(r.first.lastSale!['invoice'], 'INV-B');
    });

    test('full phone in any format is an exact single hit', () {
      final r = crm.searchCustomers('+91-98470 12345');
      expect(r.single.customer.name, 'Anu');
      expect(r.single.score, 100);
    });

    test('name search ranks exact > prefix and excludes suppliers', () {
      final r = crm.searchCustomers('anu');
      expect(r.first.customer.name, 'Anu');
      expect(r.map((h) => h.customer.name), isNot(contains('Anu Traders')));
      expect(crm.searchCustomers('an').map((h) => h.customer.name),
          containsAll(['Anu', 'Anoop']));
    });

    test('empty / no match / limit', () {
      expect(crm.searchCustomers(''), isEmpty);
      expect(crm.searchCustomers('zzz'), isEmpty);
      expect(crm.searchCustomers('an', limit: 1), hasLength(1));
      expect(crm.searchCustomers('9'), isEmpty); // <3 digits is not a phone query
    });
  });
}
