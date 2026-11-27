// Service job intake: the customer messages (device received / ready for
// pickup) and the device sticker label (TSPL for the TVS label printer).
//
// Pure Dart (no Flutter imports) so it is unit-testable. Printing and
// sending live in job_intake_actions.dart.
import 'package:intl/intl.dart';

import '../barcode/tspl_generator.dart';
import '../crm/phone_utils.dart';
import '../pos/whatsapp_invoice_message.dart';

final DateFormat _date = DateFormat('dd MMM yyyy');
final DateFormat _time = DateFormat('hh:mm a');
final DateFormat _labelDate = DateFormat('dd/MM/yy');

/// Single-line text for WhatsApp: no newlines or formatting characters.
String _one(dynamic v) => '${v ?? ''}'
    .replaceAll(RegExp(r'[\r\n]+'), ' ')
    .replaceAll(RegExp(r'[*_~`]'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

DateTime? _parseDate(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  return DateTime.tryParse('$v'.trim());
}

int _paise(dynamic rupees) => toPaise(rupees);

/// Estimate, advance and balance of a job in paise.
({int estimate, int advance, int balance}) jobMoney(Map job) {
  final est = _paise(job['finalAmount'] ?? job['estimatedCost']);
  final adv = _paise(job['advance']);
  final bal = est - adv;
  return (estimate: est, advance: adv, balance: bal < 0 ? 0 : bal);
}

/// "Redmi Note 12 (Mobile)" / "Mobile" / "Device".
String jobDeviceName(Map job) {
  final model = _one(job['brandModel']);
  final type = _one(job['productType']);
  if (model.isEmpty) return type.isEmpty ? 'Device' : type;
  if (type.isEmpty || model.toLowerCase().contains(type.toLowerCase())) {
    return model;
  }
  return '$model ($type)';
}

String _customer(Map job) {
  final n = _one(job['customerName']);
  return n.isEmpty ? 'Valued Customer' : n;
}

/// WhatsApp message sent when the device is handed over (job created).
String jobReceivedMessage(Map job, {bool? emoji, DateTime? now}) {
  final ic = (emoji ?? waUseEmoji) ? WaIcons.emoji : WaIcons.plain;
  final when = _parseDate(job['createdAt']) ?? now ?? DateTime.now();
  final m = jobMoney(job);
  final serial = _one(job['serial']);
  final acc = _one(job['accessories']);
  final due = _parseDate(job['expectedDelivery']);
  final b = StringBuffer()
    ..writeln('*$kWaBrandName*')
    ..writeln('_${kWaBrandTagline}_')
    ..writeln(kWaRule)
    ..writeln()
    ..writeln('പ്രിയപ്പെട്ട *${_customer(job)}*,')
    ..writeln('നിങ്ങളുടെ ഉപകരണം സർവീസിനായി ഞങ്ങൾ സ്വീകരിച്ചു ${ic.paid}')
    ..writeln()
    ..writeln('*Job ID:* `${_one(job['jobId'])}`')
    ..writeln('*തീയതി:* ${_date.format(when)} | ${_time.format(when)}')
    ..writeln('*ഉപകരണം:* ${jobDeviceName(job)}');
  if (serial.isNotEmpty) b.writeln('*IMEI / Serial:* $serial');
  b.writeln('*പരാതി:* ${_one(job['complaint'])}');
  if (acc.isNotEmpty) b.writeln('*ആക്സസറീസ്:* $acc');
  b
    ..writeln()
    ..writeln(kWaRule);
  if (m.estimate > 0) b.writeln('*എസ്റ്റിമേറ്റ്:* ₹${waAmount(m.estimate)}');
  if (m.advance > 0) b.writeln('*അഡ്വാൻസ് ലഭിച്ചു:* ₹${waAmount(m.advance)}');
  if (m.estimate > 0 && m.advance > 0) {
    b.writeln('*ബാക്കി:* ₹${waAmount(m.balance)}');
  }
  if (due != null) {
    b.writeln('*പ്രതീക്ഷിക്കുന്ന ഡെലിവറി:* ${_date.format(due)}');
  }
  if (m.estimate <= 0 && m.advance <= 0 && due == null) {
    b.writeln('_പരിശോധനയ്ക്ക് ശേഷം തുക അറിയിക്കും_');
  }
  b
    ..writeln(kWaRule)
    ..writeln()
    ..writeln('▸ എസ്റ്റിമേറ്റ് പരിശോധനയ്ക്ക് ശേഷം മാറാം; മാറ്റമുണ്ടെങ്കിൽ ഞങ്ങൾ വിളിച്ച് അറിയിക്കും.')
    ..writeln('▸ ഉപകരണം തിരികെ വാങ്ങുമ്പോൾ ഈ Job ID കാണിക്കുക.')
    ..writeln()
    ..writeln('${ic.phone} *കസ്റ്റമർ കെയർ:* $kWaCustomerCare')
    ..write('_നന്ദി!_');
  return b.toString();
}

/// WhatsApp message sent when the job is marked Ready.
String jobReadyMessage(Map job, {bool? emoji}) {
  final ic = (emoji ?? waUseEmoji) ? WaIcons.emoji : WaIcons.plain;
  final m = jobMoney(job);
  final b = StringBuffer()
    ..writeln('*$kWaBrandName*')
    ..writeln(kWaRule)
    ..writeln()
    ..writeln('പ്രിയപ്പെട്ട *${_customer(job)}*,')
    ..writeln(
        'നിങ്ങളുടെ *${jobDeviceName(job)}* റിപ്പയർ പൂർത്തിയായി, വാങ്ങാൻ തയ്യാറാണ് ${ic.paid}')
    ..writeln()
    ..writeln('*Job ID:* `${_one(job['jobId'])}`');
  if (m.balance > 0) {
    b.writeln('*അടയ്ക്കാനുള്ള തുക:* ₹${waAmount(m.balance)}');
  }
  b
    ..writeln()
    ..writeln('കടയിൽ വരുമ്പോൾ ഈ Job ID കാണിക്കുക.')
    ..writeln('${ic.phone} *കസ്റ്റമർ കെയർ:* $kWaCustomerCare')
    ..write('_നന്ദി!_');
  return b.toString();
}

/// Short English SMS (Malayalam SMS costs 2-3x more per message).
String jobReceivedSms(Map job) {
  final m = jobMoney(job);
  final due = _parseDate(job['expectedDelivery']);
  final parts = <String>[
    'TEKFIX DIGITAL: Dear ${labelText(_customer(job)).isEmpty ? 'Customer' : labelText(_customer(job))}, '
        'your ${labelText(jobDeviceName(job))} is received for service. '
        'Job ID ${_one(job['jobId'])}.',
    if (m.estimate > 0) 'Est Rs.${_rs(m.estimate)}.',
    if (m.advance > 0) 'Adv Rs.${_rs(m.advance)}.',
    if (due != null) 'Expected ${DateFormat('dd MMM').format(due)}.',
    'Ph $kWaCustomerCare',
  ];
  return parts.join(' ');
}

String jobReadySms(Map job) {
  final m = jobMoney(job);
  return 'TEKFIX DIGITAL: Your ${labelText(jobDeviceName(job))} '
      '(Job ${_one(job['jobId'])}) is ready for pickup.'
      '${m.balance > 0 ? ' Amount due Rs.${_rs(m.balance)}.' : ''}'
      ' Ph $kWaCustomerCare';
}

/// Rupees for label/SMS: "2500" or "2500.50".
String _rs(int paise) =>
    paise % 100 == 0 ? '${paise ~/ 100}' : (paise / 100).toStringAsFixed(2);

// ---------------------------------------------------------------- the label

/// Printable ASCII only (label printer fonts have no Malayalam) and no `"`
/// (the TSPL string delimiter).
String labelText(String s) => s
    .replaceAll('"', "'")
    .replaceAll('₹', 'Rs.')
    .replaceAll(RegExp(r'[^\x20-\x7E]'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String _cut(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max - 2)}..';

/// Word-wraps [s] into at most [lines] lines of [max] chars.
List<String> _wrap(String s, int max, int lines) {
  final out = <String>[];
  var cur = '';
  var truncated = false;
  for (final w in s.split(' ')) {
    if (w.isEmpty) continue;
    final next = cur.isEmpty ? w : '$cur $w';
    if (next.length <= max) {
      cur = next;
      continue;
    }
    if (cur.isNotEmpty) {
      out.add(cur);
      if (out.length == lines) {
        truncated = true; // words left over
        cur = '';
        break;
      }
    }
    cur = w; // a single over-long word is cut below
  }
  if (cur.isNotEmpty) out.add(cur);
  final res = [for (final l in out) _cut(l, max)];
  if (truncated && res.isNotEmpty) {
    final l = res.last;
    res[res.length - 1] =
        l.length + 2 <= max ? '$l..' : '${l.substring(0, max - 2)}..';
  }
  return res;
}

/// The text lines printed above the barcode. The phone lock code is never
/// printed (the sticker is on the outside of the phone).
List<String> jobLabelLines(Map job, {int maxChars = 34, DateTime? now}) {
  final when = _parseDate(job['createdAt']) ?? now ?? DateTime.now();
  final m = jobMoney(job);
  final name = labelText(_one(job['customerName']));
  final device = labelText(jobDeviceName(job));
  final phone = normalizePhone('${job['phone'] ?? ''}');
  final head = 'TEKFIX ${_labelDate.format(when)}'
      '${phone == null ? '' : ' ..${phone.substring(6)}'}';
  final who = [device, if (name.isNotEmpty) name].join(' / ');
  final prob = labelText('Prob: ${_one(job['complaint'])}');
  final money = [
    if (m.estimate > 0) 'Est:Rs.${_rs(m.estimate)}',
    if (m.advance > 0) 'Adv:Rs.${_rs(m.advance)}',
  ].join(' ');
  return [
    _cut(head, maxChars),
    _cut(who, maxChars),
    ..._wrap(prob, maxChars, 2),
    if (money.isNotEmpty) _cut(money, maxChars),
  ];
}

/// TSPL for one device sticker: text lines + Code128 of the Job ID.
/// [widthMm]/[heightMm]/[gapMm] come from the barcode printer settings.
String jobLabelTspl(
  Map job, {
  double widthMm = 38,
  double heightMm = 25,
  double gapMm = 3,
  int referenceX = 0,
  int referenceY = 0,
  int density = 8,
  int speed = 3,
  int copies = 1,
  DateTime? now,
}) {
  const margin = 12; // dots (1.5 mm)
  final widthDots = (widthMm * 8).round();
  final printable = widthDots - 2 * margin;
  final maxChars = printable ~/ TsplGenerator.font1Advance;
  final code = labelText(_one(job['jobId']));
  final data = code.isEmpty ? 'SRV' : code;
  final lines = jobLabelLines(job, maxChars: maxChars, now: now);

  final b = StringBuffer()
    ..writeln(
        'SIZE ${widthMm.toStringAsFixed(0)} mm,${heightMm.toStringAsFixed(0)} mm')
    ..writeln('GAP ${gapMm.toStringAsFixed(0)} mm,0 mm')
    ..writeln('DIRECTION 1')
    ..writeln('REFERENCE $referenceX,$referenceY')
    ..writeln('DENSITY $density')
    ..writeln('SPEED $speed')
    ..writeln('CLS');
  var y = 10;
  for (final l in lines) {
    b.writeln('TEXT $margin,$y,"1",0,1,1,"$l"');
    y += 14;
  }
  // Real Code 128 width (digit pairs); 2-dot bars when they fit.
  final modules = TsplGenerator.code128Modules(data);
  final narrow = modules * 2 <= printable ? 2 : 1;
  final bw = modules * narrow;
  final bx = ((widthDots - bw) ~/ 2).clamp(margin, widthDots);
  final heightDots = (heightMm * 8).round();
  final textY = heightDots - margin - 12;
  final barH = (textY - 2 - (y + 2)).clamp(24, 80);
  b.writeln('BARCODE $bx,${y + 2},"128",$barH,0,0,$narrow,$narrow,"$data"');
  final tx = ((widthDots - data.length * TsplGenerator.font1Advance) ~/ 2).clamp(margin, widthDots);
  b
    ..writeln('TEXT $tx,$textY,"1",0,1,1,"$data"')
    ..writeln('PRINT 1,${copies.clamp(1, 9)}')
    ..writeln();
  return b.toString();
}
