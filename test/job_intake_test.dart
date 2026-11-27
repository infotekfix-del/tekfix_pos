import 'package:flutter_test/flutter_test.dart';
import 'package:tekfix_erp_pos/repairs/job_intake.dart';
import 'package:tekfix_erp_pos/barcode/tspl_generator.dart';

Map<String, dynamic> job({
  String name = 'Unais',
  String model = 'Redmi Note 12',
  String complaint = 'Display broken, no touch',
  num est = 2500,
  num adv = 500,
  String delivery = '2026-11-20',
  String lock = '1234',
}) =>
    {
      'jobId': 'SRV-20261118-A001',
      'customerName': name,
      'phone': '9847012345',
      'productType': 'Mobile',
      'brandModel': model,
      'serial': '356789012345678',
      'complaint': complaint,
      'accessories': 'Cover, SIM tray',
      'estimatedCost': est,
      'finalAmount': est,
      'advance': adv,
      'expectedDelivery': delivery,
      'lockCode': lock,
      'createdAt': '2026-11-18T17:40:00',
      'status': 'Received',
    };

void main() {
  group('received message', () {
    test('has job, device, complaint, money and delivery', () {
      final m = jobReceivedMessage(job(), emoji: false);
      expect(m, contains('*TEKFIX DIGITAL*'));
      expect(m, contains('പ്രിയപ്പെട്ട *Unais*'));
      expect(m, contains('*Job ID:* `SRV-20261118-A001`'));
      expect(m, contains('*ഉപകരണം:* Redmi Note 12 (Mobile)'));
      expect(m, contains('*IMEI / Serial:* 356789012345678'));
      expect(m, contains('*പരാതി:* Display broken, no touch'));
      expect(m, contains('*ആക്സസറീസ്:* Cover, SIM tray'));
      expect(m, contains('*എസ്റ്റിമേറ്റ്:* ₹2,500.00'));
      expect(m, contains('*അഡ്വാൻസ് ലഭിച്ചു:* ₹500.00'));
      expect(m, contains('*ബാക്കി:* ₹2,000.00'));
      expect(m, contains('20 Nov 2026'));
    });

    test('never contains the phone lock code', () {
      final m = jobReceivedMessage(job(lock: 'PIN-9988'), emoji: false);
      expect(m, isNot(contains('9988')));
      expect(jobReceivedSms(job(lock: 'PIN-9988')), isNot(contains('9988')));
    });

    test('no estimate yet -> "amount after checking"', () {
      final m = jobReceivedMessage(job(est: 0, adv: 0, delivery: ''),
          emoji: false);
      expect(m, isNot(contains('എസ്റ്റിമേറ്റ്:*')));
      expect(m, contains('പരിശോധനയ്ക്ക് ശേഷം തുക അറിയിക്കും'));
    });

    test('Windows icons are not emoji', () {
      final m = jobReceivedMessage(job(), emoji: false);
      expect(m.runes.any((r) => r >= 0x1F000), isFalse);
    });

    test('formatting characters in data do not break the message', () {
      final m = jobReceivedMessage(job(complaint: '*bold*\nsecond line'),
          emoji: false);
      expect(m, contains('*പരാതി:* bold second line'));
    });
  });

  group('ready message', () {
    test('shows the balance due', () {
      final m = jobReadyMessage(job(), emoji: false);
      expect(m, contains('റിപ്പയർ പൂർത്തിയായി'));
      expect(m, contains('*അടയ്ക്കാനുള്ള തുക:* ₹2,000.00'));
    });
    test('fully paid -> no amount line', () {
      final m = jobReadyMessage(job(est: 500, adv: 500), emoji: false);
      expect(m, isNot(contains('അടയ്ക്കാനുള്ള തുക')));
    });
    test('SMS is short English', () {
      final s = jobReadySms(job());
      expect(s, contains('is ready for pickup'));
      expect(s, contains('Amount due Rs.2000.'));
    });
  });

  test('received SMS', () {
    final s = jobReceivedSms(job());
    expect(s, startsWith('TEKFIX DIGITAL: Dear Unais, your Redmi Note 12'));
    expect(s, contains('Job ID SRV-20261118-A001.'));
    expect(s, contains('Est Rs.2500. Adv Rs.500.'));
    expect(s, contains('Expected 20 Nov.'));
  });

  group('label', () {
    test('lines: date, last 4 of phone, device/name, problem, money', () {
      final l = jobLabelLines(job());
      expect(l[0], 'TEKFIX 18/11/26 ..2345');
      expect(l[1], 'Redmi Note 12 (Mobile) / Unais');
      expect(l[2], 'Prob: Display broken, no touch');
      expect(l.last, 'Est:Rs.2500 Adv:Rs.500');
    });

    test('lock code is never on the sticker', () {
      final t = jobLabelTspl(job(lock: 'PIN-9988'));
      expect(t, isNot(contains('9988')));
    });

    test('Malayalam text is dropped, never sent to the printer', () {
      final l = jobLabelLines(job(name: 'ഉനൈസ്', complaint: 'ഡിസ്പ്ലേ പോയി screen'));
      expect(l[1], 'Redmi Note 12 (Mobile)');
      expect(l[2], 'Prob: screen');
      for (final line in l) {
        expect(line.runes.every((r) => r >= 0x20 && r <= 0x7E), isTrue);
      }
    });

    test('long complaint wraps to two lines and is cut', () {
      final l = jobLabelLines(job(
          complaint:
              'Display broken and touch not working, battery swelling, charging port loose, speaker low'));
      final prob = l.where((x) => !x.startsWith('TEKFIX') && !x.startsWith('Est'));
      expect(l.length, 5);
      for (final x in l) {
        expect(x.length, lessThanOrEqualTo(34));
      }
      expect(prob.last, endsWith('..'));
    });

    test('TSPL: size, barcode of the job id, fits the label', () {
      final t = jobLabelTspl(job());
      expect(t, contains('SIZE 38 mm,25 mm'));
      expect(t, contains('"128"'));
      expect(t, contains(',"SRV-20261118-A001"'));
      expect(t, contains('PRINT 1,1'));
      expect(t, isNot(contains('""'))); // no empty/broken strings
      final b = RegExp(r'BARCODE (\d+),(\d+),"128",(\d+),0,0,(\d),')
          .firstMatch(t)!;
      final x = int.parse(b[1]!), y = int.parse(b[2]!), h = int.parse(b[3]!);
      final narrow = int.parse(b[4]!);
      final width = TsplGenerator.code128Modules("SRV-20261118-A001") * narrow;
      expect(x + width, lessThanOrEqualTo(38 * 8));
      expect(y + h, lessThanOrEqualTo(25 * 8 - 24));
    });

    test('quotes in data cannot break the TSPL command', () {
      final t = jobLabelTspl(job(complaint: 'says "dead"'));
      expect(t, contains("Prob: says 'dead'"));
    });

    test('50 mm label uses the wider line length', () {
      final t = jobLabelTspl(job(), widthMm: 50);
      expect(t, contains('SIZE 50 mm,25 mm'));
    });
  });
}
