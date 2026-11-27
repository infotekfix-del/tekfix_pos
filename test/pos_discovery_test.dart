import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/pos/new_pos/pos_discovery.dart';

Map<String, dynamic> sale(String date, List<List<dynamic>> lines,
        {String status = 'SOLD'}) =>
    {
      'saleDate': date,
      'status': status,
      'items': [
        for (final l in lines) {'itemId': l[0], 'key': l[1], 'qty': l[2]}
      ],
    };

void main() {
  group('categories (UI mapping only)', () {
    PosCategory of(String c) => posCategoryOf({'category': c});

    test('categories found in the shop data map to the chips', () {
      expect(of('MOBILE'), PosCategory.mobiles);
      expect(of('ACCESSORY'), PosCategory.accessories);
      expect(of('accessories'), PosCategory.accessories);
      expect(of('CASE'), PosCategory.accessories);
      expect(of('CAMERA GLASS'), PosCategory.accessories);
      expect(of('CHARGER'), PosCategory.chargers);
      expect(of('POWER BANK'), PosCategory.chargers);
      expect(of('CABLE'), PosCategory.cables);
      expect(of('OTG'), PosCategory.cables);
      expect(of('HF'), PosCategory.earphones);
      expect(of('hf'), PosCategory.earphones);
      expect(of('HEADPHONE'), PosCategory.earphones);
      expect(of('TWS'), PosCategory.bluetooth);
      expect(of('NECK BAND'), PosCategory.bluetooth);
      expect(of('NECKBAND'), PosCategory.bluetooth);
      expect(of('SPEAKIER'), PosCategory.bluetooth);
      expect(of('REMOTE'), PosCategory.gadgets);
      expect(of('laptop'), PosCategory.gadgets);
    });

    test('unknown or empty -> Other Products', () {
      expect(of('General'), PosCategory.other);
      expect(of(''), PosCategory.other);
      expect(posCategoryOf({}), PosCategory.other);
      expect(of('OG'), PosCategory.other);
      expect(of('Consumable / Raw Material'), PosCategory.other);
    });

    test('itemType Service -> Mobile Service', () {
      expect(posCategoryOf({'category': 'General', 'itemType': 'Service'}),
          PosCategory.service);
    });

    test('mapping never changes the item', () {
      final item = {'category': 'neck band', 'name': 'X'};
      posCategoryOf(item);
      expect(item, {'category': 'neck band', 'name': 'X'});
    });

    test('every chip has a bilingual label', () {
      for (final c in PosCategory.values) {
        expect(c.label, matches(RegExp(r'^[A-Za-z ]+ \(.+\)$')));
      }
    });
  });

  group('Top Selling', () {
    final now = DateTime.utc(2026, 11, 19, 12);

    test('orders by quantity in the last 30 days', () {
      final top = posTopSelling([
        sale('2026-11-18T10:00:00Z', [
          ['a', 1, 1],
          ['b', 2, 3]
        ]),
        sale('2026-11-10T10:00:00Z', [
          ['a', 1, 1],
          ['c', 3, 1]
        ]),
      ], now: now);
      expect(top, ['b', 'a', 'c']);
    });

    test('older than 30 days and cancelled bills are skipped', () {
      final top = posTopSelling([
        sale('2026-09-01T10:00:00Z', [
          ['old', 1, 50]
        ]),
        sale('2026-11-18T10:00:00Z', [
          ['void', 2, 9]
        ], status: 'CANCELLED'),
        sale('2026-11-18T10:00:00Z', [
          ['ok', 3, 1]
        ]),
      ], now: now);
      expect(top, ['ok']);
    });

    test('ties: most recent sale first; limit respected', () {
      final top = posTopSelling([
        sale('2026-11-01T10:00:00Z', [
          ['early', 1, 2]
        ]),
        sale('2026-11-15T10:00:00Z', [
          ['late', 2, 2]
        ]),
        sale('2026-11-15T10:00:00Z', [
          ['x', 3, 1]
        ]),
      ], now: now, limit: 2);
      expect(top, ['late', 'early']);
    });

    test('lines without itemId fall back to the Hive key', () {
      final top = posTopSelling([
        sale('2026-11-18T10:00:00Z', [
          [null, 7, 2]
        ]),
      ], now: now);
      expect(top, ['k:7']);
      expect(posItemRef(7, {'name': 'no id'}), 'k:7');
      expect(posItemRef(7, {'_id': 'u1'}), 'u1');
    });

    test('createdAt is used when saleDate is missing', () {
      final top = posTopSelling([
        {
          'createdAt': '2026-11-18T10:00:00Z',
          'items': [
            {'itemId': 'a', 'qty': 1}
          ]
        }
      ], now: now);
      expect(top, ['a']);
    });
  });

  group('favorites', () {
    test('toggle adds to the front and removes', () {
      var f = posFavoritesFrom(null);
      expect(f, isEmpty);
      f = posToggleFavorite(f, 'a');
      f = posToggleFavorite(f, 'b');
      expect(f, ['b', 'a']);
      f = posToggleFavorite(f, 'a');
      expect(f, ['b']);
    });
    test('bad stored values are ignored', () {
      expect(posFavoritesFrom('x'), isEmpty);
      expect(posFavoritesFrom(['a', '', ' b ']), ['a', 'b']);
    });
  });
}
