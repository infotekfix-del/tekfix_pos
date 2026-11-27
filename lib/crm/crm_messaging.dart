// Phase 5: segments, message templates, WhatsApp sending (wa.me now, Cloud
// API later), message log, campaign queue/report and automations.
//
// Pure Dart (hive + uuid): unit-testable. Only customers with
// whatsappOptIn == true and doNotMessage != true are ever messaged.
//
// Policy: NO unofficial bulk-sending tools and NO automation of personal
// WhatsApp. Step 1 (WaMeSender) opens one wa.me chat per tap; the person at
// the counter presses Send in WhatsApp. Step 2 (CloudApiSender) is an
// interface stub for the official WhatsApp Business Cloud API.

import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

import 'customer_crm.dart';
import 'customer_history.dart';
import 'customer_models.dart';
import 'customer_search.dart';
import 'phone_utils.dart';

// Synced boxes (SyncEngine collections in brackets)
const String kBoxCrmTemplates = 'tek_crm_templates'; // message_templates
const String kBoxCrmCampaigns = 'tek_crm_campaigns'; // campaigns
const String kBoxMessageLog = 'tek_message_log'; // message_log
const String kBoxCrmSettings = 'tek_crm_settings'; // crm_settings
const List<String> kCrmMessagingBoxes = [
  kBoxCrmTemplates,
  kBoxCrmCampaigns,
  kBoxMessageLog,
  kBoxCrmSettings,
];

const _uuid = Uuid();

Map<String, dynamic> _m(dynamic v) => v is Map
    ? {for (final e in v.entries) '${e.key}': e.value}
    : <String, dynamic>{};

DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

// =========================================================== segments
class SegmentFilter {
  final int? noPurchaseDays; // no purchase in the last N days
  final int? minSpentPaise; // total spent above X
  final String? boughtItem; // bought item name / category containing Y
  final bool birthdayThisMonth;
  final bool pendingBalance;

  const SegmentFilter({
    this.noPurchaseDays,
    this.minSpentPaise,
    this.boughtItem,
    this.birthdayThisMonth = false,
    this.pendingBalance = false,
  });

  bool get isEmpty =>
      noPurchaseDays == null &&
      minSpentPaise == null &&
      (boughtItem ?? '').trim().isEmpty &&
      !birthdayThisMonth &&
      !pendingBalance;

  Map<String, dynamic> toMap() => {
        'noPurchaseDays': noPurchaseDays,
        'minSpentPaise': minSpentPaise,
        'boughtItem': boughtItem,
        'birthdayThisMonth': birthdayThisMonth,
        'pendingBalance': pendingBalance,
      };

  factory SegmentFilter.fromMap(Map m) => SegmentFilter(
        noPurchaseDays: (m['noPurchaseDays'] as num?)?.toInt(),
        minSpentPaise: (m['minSpentPaise'] as num?)?.toInt(),
        boughtItem: m['boughtItem'] as String?,
        birthdayThisMonth: m['birthdayThisMonth'] == true,
        pendingBalance: m['pendingBalance'] == true,
      );

  /// Human-readable summary (bilingual) for campaign lists.
  String describe() {
    final p = <String>[];
    if (noPurchaseDays != null) p.add('No purchase in $noPurchaseDays days');
    if (minSpentPaise != null) p.add('Spent > ₹${minSpentPaise! ~/ 100}');
    if ((boughtItem ?? '').trim().isNotEmpty) p.add('Bought "$boughtItem"');
    if (birthdayThisMonth) p.add('Birthday this month');
    if (pendingBalance) p.add('Pending balance');
    return p.isEmpty ? 'All opted-in customers' : p.join(' • ');
  }
}

/// Month of a stored birthday ("yyyy-MM-dd", "MM-dd" or "dd/MM/yyyy").
int? birthdayMonth(String? b) {
  final s = (b ?? '').trim();
  if (s.isEmpty) return null;
  final iso = DateTime.tryParse(s);
  if (iso != null) return iso.month;
  final md = RegExp(r'^(\d{1,2})-(\d{1,2})$').firstMatch(s);
  if (md != null) return int.parse(md.group(1)!);
  final dmy = RegExp(r'^(\d{1,2})[/.](\d{1,2})').firstMatch(s);
  if (dmy != null) return int.parse(dmy.group(2)!);
  return null;
}

int? birthdayDay(String? b) {
  final s = (b ?? '').trim();
  final iso = DateTime.tryParse(s);
  if (iso != null) return iso.day;
  final md = RegExp(r'^(\d{1,2})-(\d{1,2})$').firstMatch(s);
  if (md != null) return int.parse(md.group(2)!);
  final dmy = RegExp(r'^(\d{1,2})[/.](\d{1,2})').firstMatch(s);
  if (dmy != null) return int.parse(dmy.group(1)!);
  return null;
}

/// All indexed customers (one pass over parties).
List<CrmCustomer> allCustomers(CustomerCrm crm) {
  final out = <CrmCustomer>[];
  for (final k in crm.parties.keys) {
    final p = crm.parties.get(k);
    if (p is! Map || !isCustomerParty(p) || p['_id'] == null) continue;
    out.add(CrmCustomer.from(k, p, crm.stats.get('${p['_id']}') as Map?));
  }
  return out;
}

/// Customers matching ALL set filters. Only messageable customers
/// (opt-in, not do-not-message, valid phone) are ever returned.
/// [categoryOf] maps a sale line to its item category (app supplies it).
List<CrmCustomer> evaluateSegment(
  CustomerCrm crm,
  SegmentFilter f, {
  DateTime? now,
  String? Function(Map line)? categoryOf,
}) {
  final n = now ?? DateTime.now();
  final item = searchKey(f.boughtItem);
  final out = <CrmCustomer>[];
  for (final c in allCustomers(crm)) {
    if (!c.canMessage) continue;
    if (f.noPurchaseDays != null) {
      final cutoff = n.subtract(Duration(days: f.noPurchaseDays!));
      final ref = c.lastPurchaseAt ?? c.createdAt;
      if (ref != null && ref.isAfter(cutoff)) continue;
    }
    if (f.minSpentPaise != null && c.totalSpentPaise <= f.minSpentPaise!) {
      continue;
    }
    if (f.birthdayThisMonth && birthdayMonth(c.birthday) != n.month) continue;
    if (f.pendingBalance && c.balancePaise <= 0) continue;
    if (item.isNotEmpty) {
      final hit = crm.salesOf(c.id).any((e) =>
          !isSaleReturnedMap(e.value) &&
          saleLines(e.value).any((l) =>
              searchKey('${l['name'] ?? ''}').contains(item) ||
              searchKey('${l['category'] ?? categoryOf?.call(l) ?? ''}')
                  .contains(item)));
      if (!hit) continue;
    }
    out.add(c);
  }
  out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}

// ========================================================== templates
/// Added to every promotional message so customers can always opt out.
const String kOptOutLine =
    'ഇനി മെസ്സേജുകൾ വേണ്ടെങ്കിൽ STOP എന്ന് മറുപടി അയക്കുക. (Reply STOP to stop messages)';

class MsgTemplate {
  final String id;
  final String name;
  final String body;
  final String kind; // promo | birthday | missyou | warranty | service | thankyou
  final bool promotional;
  const MsgTemplate({
    required this.id,
    required this.name,
    required this.body,
    this.kind = 'promo',
    this.promotional = true,
  });

  Map<String, dynamic> toMap() => {
        '_id': id,
        'name': name,
        'body': body,
        'kind': kind,
        'promotional': promotional,
      };

  factory MsgTemplate.fromMap(Map m) => MsgTemplate(
        id: '${m['_id']}',
        name: '${m['name'] ?? ''}',
        body: '${m['body'] ?? ''}',
        kind: '${m['kind'] ?? 'promo'}',
        promotional: m['promotional'] != false,
      );
}

const kTemplatePlaceholders = ['{name}', '{lastItem}', '{shopName}', '{offer}'];

/// Default templates. Fixed ids -> every device seeds the SAME synced record.
const kDefaultTemplates = <MsgTemplate>[
  MsgTemplate(
    id: 'tpl_default_offer',
    name: 'Offer (ഓഫർ)',
    body: 'നമസ്കാരം {name}, {shopName}-ൽ പുതിയ ഓഫർ: {offer}. '
        'ഇന്ന് തന്നെ വരൂ!\n\nHi {name}, new offer at {shopName}: {offer}.',
  ),
  // --- TEKFIX Digital offer templates (2026-11-20). {offer} is typed per
  // campaign in the Segment tab; {name} is each customer's name.
  MsgTemplate(
    id: 'tpl_tekfix_porting',
    name: 'Porting offer (പോർട്ടിംഗ് ഓഫർ)',
    body: '📢 Special Porting Offer 🔥\n\n'
        'നമസ്കാരം {name},\n'
        '📱 നിങ്ങളുടെ നിലവിലുള്ള മൊബൈൽ നമ്പർ മാറ്റാതെ തന്നെ പോർട്ട് ചെയ്യൂ!\n\n'
        '🎁 {offer}\n\n'
        '✅ നമ്പർ അതേപടി\n'
        '✅ എളുപ്പത്തിലുള്ള പോർട്ടിംഗ്\n'
        '✅ മികച്ച നെറ്റ്‌വർക്ക് അനുഭവം\n\n'
        '💥 ഇത്തരത്തിലുള്ള കിടിലൻ ഓഫറുകളും മൊബൈൽ അപ്‌ഡേറ്റുകളും ആദ്യം അറിയാൻ ഞങ്ങളുടെ WhatsApp ഗ്രൂപ്പിൽ ഇപ്പോൾ തന്നെ ജോയിൻ ചെയ്യൂ.\n'
        '👉 https://chat.whatsapp.com/I7sRCtHYu4d2kIqIc4z5Zv\n\n'
        '📍 TEKFIX Digital, Irumbuzhi\n'
        '📞 7034093101',
  ),
  MsgTemplate(
    id: 'tpl_tekfix_special_day',
    name: 'Special day offer (ഇന്നത്തെ സ്പെഷ്യൽ ഓഫർ)',
    body: '🎉 ഇന്നത്തെ സ്പെഷ്യൽ ഓഫർ 🎉\n\n'
        'നമസ്കാരം {name},\n'
        'TEKFIX Digital-ൽ ഇന്ന് മാത്രം:\n\n'
        '🔥 {offer}\n\n'
        '⏰ ഓഫർ ഇന്ന് മാത്രം / സ്റ്റോക്ക് തീരുന്നതുവരെ.\n'
        '🛍️ ഇന്ന് തന്നെ കടയിൽ വരൂ!\n\n'
        '👉 കൂടുതൽ ഓഫറുകൾക്ക് ഞങ്ങളുടെ WhatsApp ഗ്രൂപ്പ്: https://chat.whatsapp.com/I7sRCtHYu4d2kIqIc4z5Zv\n\n'
        '📍 TEKFIX Digital, Irumbuzhi\n'
        '📞 7034093101',
  ),
  MsgTemplate(
    id: 'tpl_tekfix_new_launch',
    name: 'New product launch (പുതിയ പ്രോഡക്റ്റ്)',
    body: '🚀 പുതിയ പ്രോഡക്റ്റ് എത്തി! 🚀\n\n'
        'നമസ്കാരം {name},\n'
        'TEKFIX Digital-ൽ ഇപ്പോൾ ലഭ്യമാണ്:\n\n'
        '✨ {offer}\n\n'
        '✅ ഒറിജിനൽ പ്രോഡക്റ്റ്, വാറന്റിയോടെ\n'
        '✅ മികച്ച വില\n'
        '✅ കടയിൽ വന്ന് നേരിട്ട് കാണാം\n\n'
        '📲 വിലയും സ്റ്റോക്കും അറിയാൻ ഈ മെസ്സേജിന് മറുപടി അയക്കുക.\n\n'
        '👉 WhatsApp ഗ്രൂപ്പ്: https://chat.whatsapp.com/I7sRCtHYu4d2kIqIc4z5Zv\n\n'
        '📍 TEKFIX Digital, Irumbuzhi\n'
        '📞 7034093101',
  ),
  MsgTemplate(
    id: 'tpl_tekfix_festival',
    name: 'Festival / season offer (ഉത്സവ ഓഫർ)',
    body: '🎊 ഉത്സവകാല ഓഫർ 🎊\n\n'
        'നമസ്കാരം {name},\n'
        'ഈ ഉത്സവകാലത്ത് TEKFIX Digital-ൽ പ്രത്യേക ഓഫറുകൾ:\n\n'
        '🎁 {offer}\n\n'
        '📱 മൊബൈൽ • ആക്സസറീസ് • റീചാർജ് • സർവീസ്\n'
        '⏰ പരിമിത കാലത്തേക്ക് മാത്രം!\n\n'
        '👉 WhatsApp ഗ്രൂപ്പ്: https://chat.whatsapp.com/I7sRCtHYu4d2kIqIc4z5Zv\n\n'
        '📍 TEKFIX Digital, Irumbuzhi\n'
        '📞 7034093101',
  ),
  MsgTemplate(
    id: 'tpl_default_missyou',
    name: 'We miss you (കുറേ നാളായി കണ്ടിട്ട്)',
    kind: 'missyou',
    body: 'നമസ്കാരം {name}, കുറേ നാളായി {shopName}-ൽ കണ്ടിട്ട്! '
        '{lastItem} എങ്ങനെയുണ്ട്? {offer}\n\nWe miss you at {shopName}!',
  ),
  MsgTemplate(
    id: 'tpl_default_birthday',
    name: 'Birthday wish (ജന്മദിനാശംസ)',
    kind: 'birthday',
    body: 'ജന്മദിനാശംസകൾ {name}! 🎂 {shopName} കുടുംബത്തിന്റെ ആശംസകൾ. {offer}\n\n'
        'Happy birthday {name}! Best wishes from {shopName}.',
  ),
  MsgTemplate(
    id: 'tpl_default_warranty',
    name: 'Warranty ending (വാറന്റി തീരുന്നു)',
    kind: 'warranty',
    promotional: false,
    body: 'നമസ്കാരം {name}, നിങ്ങളുടെ {lastItem} വാറന്റി ഉടൻ തീരും. '
        'എന്തെങ്കിലും പ്രശ്നമുണ്ടെങ്കിൽ {shopName}-ൽ വരൂ.\n\n'
        'Hi {name}, the warranty on your {lastItem} ends soon.',
  ),
  MsgTemplate(
    id: 'tpl_default_service',
    name: 'Service ready (സർവീസ് റെഡി)',
    kind: 'service',
    promotional: false,
    body: 'നമസ്കാരം {name}, നിങ്ങളുടെ {lastItem} റിപ്പയർ കഴിഞ്ഞു, {shopName}-ൽ നിന്ന് വാങ്ങാം.\n\n'
        'Hi {name}, your {lastItem} is ready for pickup at {shopName}.',
  ),
];

/// Fills placeholders; promotional messages always end with [kOptOutLine].
String renderTemplate(
  MsgTemplate t, {
  required String name,
  String lastItem = '',
  String shopName = '',
  String offer = '',
}) {
  var s = t.body
      .replaceAll('{name}', name)
      .replaceAll('{lastItem}', lastItem.isEmpty ? 'product' : lastItem)
      .replaceAll('{shopName}', shopName)
      .replaceAll('{offer}', offer);
  s = s.replaceAll(RegExp(r'[ \t]+\n'), '\n').trim();
  if (t.promotional && !s.contains('STOP')) s = '$s\n\n$kOptOutLine';
  return s;
}

// ============================================================ senders
class SendResult {
  final bool ok;
  final String status; // sent | opened | failed
  final String? error;
  const SendResult(this.ok, this.status, [this.error]);
}

/// Abstraction so the official Cloud API can replace wa.me later.
abstract class WhatsAppSender {
  String get channel;

  /// true = a person must press Send inside WhatsApp (wa.me).
  bool get needsUserTap;
  Future<SendResult> send({required String phone, required String text});
}

/// Step 1: opens wa.me/<91phone>?text=... (one customer per tap).
class WaMeSender implements WhatsAppSender {
  WaMeSender(this.launch);
  final Future<bool> Function(Uri url) launch;

  @override
  String get channel => 'wa.me';
  @override
  bool get needsUserTap => true;

  static Uri link(String phone, String text) =>
      Uri.https('wa.me', '/91${normalizePhone(phone) ?? phoneDigits(phone)}',
          {'text': text});

  @override
  Future<SendResult> send({required String phone, required String text}) async {
    if (normalizePhone(phone) == null) {
      return const SendResult(false, 'failed', 'invalid phone');
    }
    try {
      final ok = await launch(link(phone, text));
      return ok
          ? const SendResult(true, 'opened')
          : const SendResult(false, 'failed', 'could not open WhatsApp');
    } catch (e) {
      return SendResult(false, 'failed', '$e');
    }
  }
}

/// Step 2 (interface only): WhatsApp Business Cloud API.
/// Needs a Meta business account, a phone number id, a permanent token
/// (kept server-side, never in the app) and pre-approved templates for
/// business-initiated messages. Not implemented yet.
class CloudApiSender implements WhatsAppSender {
  CloudApiSender({required this.phoneNumberId, required this.endpoint});
  final String phoneNumberId;
  final Uri endpoint; // your own backend function that holds the token

  @override
  String get channel => 'cloud_api';
  @override
  bool get needsUserTap => false;

  @override
  Future<SendResult> send({required String phone, required String text}) async =>
      const SendResult(false, 'failed', 'Cloud API sender not configured yet');
}

// ========================================================== automations
class AutomationSettings {
  final bool birthday;
  final bool missYou;
  final int missYouDays;
  final bool warranty;
  final int warrantyDaysBefore;
  final bool serviceReady;
  final bool thankYou;
  const AutomationSettings({
    this.birthday = false,
    this.missYou = false,
    this.missYouDays = 60,
    this.warranty = false,
    this.warrantyDaysBefore = 7,
    this.serviceReady = false,
    this.thankYou = false,
  });

  Map<String, dynamic> toMap() => {
        '_id': 'crm_automation',
        'birthday': birthday,
        'missYou': missYou,
        'missYouDays': missYouDays,
        'warranty': warranty,
        'warrantyDaysBefore': warrantyDaysBefore,
        'serviceReady': serviceReady,
        'thankYou': thankYou,
      };

  factory AutomationSettings.fromMap(Map m) => AutomationSettings(
        birthday: m['birthday'] == true,
        missYou: m['missYou'] == true,
        missYouDays: (m['missYouDays'] as num?)?.toInt() ?? 60,
        warranty: m['warranty'] == true,
        warrantyDaysBefore: (m['warrantyDaysBefore'] as num?)?.toInt() ?? 7,
        serviceReady: m['serviceReady'] == true,
        thankYou: m['thankYou'] == true,
      );

  AutomationSettings copyWith({
    bool? birthday,
    bool? missYou,
    int? missYouDays,
    bool? warranty,
    int? warrantyDaysBefore,
    bool? serviceReady,
    bool? thankYou,
  }) =>
      AutomationSettings(
        birthday: birthday ?? this.birthday,
        missYou: missYou ?? this.missYou,
        missYouDays: missYouDays ?? this.missYouDays,
        warranty: warranty ?? this.warranty,
        warrantyDaysBefore: warrantyDaysBefore ?? this.warrantyDaysBefore,
        serviceReady: serviceReady ?? this.serviceReady,
        thankYou: thankYou ?? this.thankYou,
      );
}

/// One message ready to send (campaign item or automation).
class QueuedMessage {
  final CrmCustomer customer;
  final String kind;
  final String templateId;
  final String text;
  final String dedupeKey; // never send the same key twice
  final String? campaignId;
  const QueuedMessage({
    required this.customer,
    required this.kind,
    required this.templateId,
    required this.text,
    required this.dedupeKey,
    this.campaignId,
  });
}

class CampaignReport {
  final int targeted, sent, skipped, purchasedWithin7Days;
  final int revenuePaise;
  const CampaignReport(this.targeted, this.sent, this.skipped,
      this.purchasedWithin7Days, this.revenuePaise);
}

// ============================================================ service
class CrmMessaging {
  CrmMessaging({
    required this.crm,
    required this.templates,
    required this.campaigns,
    required this.log,
    required this.settings,
  });

  final CustomerCrm crm;
  final Box templates, campaigns, log, settings;

  static CrmMessaging? _instance;
  static CrmMessaging? get maybeInstance => _instance;

  /// [seed] false on staff devices: they never write templates (Firestore
  /// rules allow only owner/admin to write them).
  static Future<CrmMessaging> open(CustomerCrm crm, {bool seed = true}) async {
    Future<Box> ob(String n) async {
      if (Hive.isBoxOpen(n)) return Hive.box(n);
      return Hive.openBox(n);
    }

    final m = CrmMessaging(
      crm: crm,
      templates: await ob(kBoxCrmTemplates),
      campaigns: await ob(kBoxCrmCampaigns),
      log: await ob(kBoxMessageLog),
      settings: await ob(kBoxCrmSettings),
    );
    if (seed) await m.seedDefaults();
    _instance = m;
    return m;
  }

  Future<void> seedDefaults() async {
    for (final t in kDefaultTemplates) {
      if (!templates.containsKey(t.id)) await templates.put(t.id, t.toMap());
    }
  }

  // ------------------------------------------------------------ templates
  List<MsgTemplate> allTemplates() {
    final out = [
      for (final v in templates.values)
        if (v is Map && v['deleted'] != true) MsgTemplate.fromMap(v)
    ];
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  MsgTemplate? template(String id) {
    for (final k in templates.keys) {
      final v = templates.get(k);
      if (v is Map && v['_id'] == id && v['deleted'] != true) {
        return MsgTemplate.fromMap(v);
      }
    }
    return null;
  }

  Future<MsgTemplate> saveTemplate(MsgTemplate t) async {
    final id = t.id.isEmpty ? 'tpl_${_uuid.v4()}' : t.id;
    final saved = MsgTemplate(
        id: id,
        name: t.name.trim(),
        body: t.body,
        kind: t.kind,
        promotional: t.promotional);
    dynamic key = id;
    for (final k in templates.keys) {
      if (_m(templates.get(k))['_id'] == id) key = k;
    }
    await templates.put(key, saved.toMap());
    return saved;
  }

  /// Soft delete (never removes data; synced).
  Future<void> deleteTemplate(String id) async {
    for (final k in templates.keys) {
      final v = _m(templates.get(k));
      if (v['_id'] == id) await templates.put(k, {...v, 'deleted': true});
    }
  }

  // ------------------------------------------------------------- settings
  AutomationSettings get automation =>
      AutomationSettings.fromMap(_m(settings.get('crm_automation')));
  Future<void> setAutomation(AutomationSettings a) =>
      settings.put('crm_automation', a.toMap());

  int get delaySeconds =>
      (_m(settings.get('crm_sending'))['delaySec'] as num?)?.toInt() ?? 20;
  int get dailyCap =>
      (_m(settings.get('crm_sending'))['dailyCap'] as num?)?.toInt() ?? 50;
  Future<void> setSending({required int delaySec, required int dailyCap}) =>
      settings.put('crm_sending', {
        '_id': 'crm_sending',
        'delaySec': delaySec,
        'dailyCap': dailyCap,
      });

  // ------------------------------------------------------------------ log
  Iterable<Map<String, dynamic>> get _logs =>
      log.values.whereType<Map>().map(_m);

  /// Every send / skip is logged (synced to `message_log`).
  Future<Map<String, dynamic>> logMessage({
    required CrmCustomer customer,
    required String templateId,
    required String kind,
    required String status, // sent | skipped | failed
    String? campaignId,
    String? dedupeKey,
    String channel = 'wa.me',
    String text = '',
    String reason = '',
    String user = '',
    DateTime? at,
  }) async {
    final rec = <String, dynamic>{
      '_id': _uuid.v4(),
      'customerId': customer.id,
      'customerName': customer.name,
      'phone': customer.phone,
      'templateId': templateId,
      'kind': kind,
      'status': status,
      'campaignId': campaignId,
      'dedupeKey': dedupeKey,
      'channel': channel,
      'text': text,
      'reason': reason,
      'by': user,
      'at': (at ?? DateTime.now()).toUtc().toIso8601String(),
    };
    await log.add(rec);
    return rec;
  }

  /// Promotional messages sent today (local day) — for the daily cap.
  int sentToday({DateTime? now}) {
    final today = _dayOnly(now ?? DateTime.now());
    var n = 0;
    for (final l in _logs) {
      if (l['status'] != 'sent') continue;
      final at = DateTime.tryParse('${l['at']}')?.toLocal();
      if (at != null && _dayOnly(at) == today) n++;
    }
    return n;
  }

  int remainingToday({DateTime? now}) {
    final r = dailyCap - sentToday(now: now);
    return r < 0 ? 0 : r;
  }

  Set<String> _doneKeys() => {
        for (final l in _logs)
          if (l['dedupeKey'] != null &&
              (l['status'] == 'sent' || l['status'] == 'skipped'))
            '${l['dedupeKey']}'
      };

  // ------------------------------------------------------------ campaigns
  String lastItemOf(CrmCustomer c) {
    for (final e in crm.salesOf(c.id, limit: 5)) {
      if (isSaleReturnedMap(e.value)) continue;
      final l = saleLines(e.value);
      if (l.isNotEmpty) return '${l.first['name'] ?? ''}';
    }
    return '';
  }

  Future<Map<String, dynamic>> createCampaign({
    required String name,
    required SegmentFilter filter,
    required MsgTemplate template,
    required List<CrmCustomer> customers,
    String offer = '',
    String user = '',
  }) async {
    final id = 'cmp_${_uuid.v4()}';
    final rec = <String, dynamic>{
      '_id': id,
      'name': name.trim().isEmpty ? template.name : name.trim(),
      'filter': filter.toMap(),
      'filterText': filter.describe(),
      'templateId': template.id,
      'templateName': template.name,
      'offer': offer,
      'customerIds': [for (final c in customers) c.id],
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'createdBy': user,
    };
    await campaigns.put(id, rec);
    return rec;
  }

  List<Map<String, dynamic>> allCampaigns() {
    final out = [for (final v in campaigns.values) if (v is Map) _m(v)];
    out.sort((a, b) => '${b['createdAt']}'.compareTo('${a['createdAt']}'));
    return out;
  }

  Map<String, dynamic>? campaign(String id) {
    for (final v in campaigns.values) {
      if (v is Map && v['_id'] == id) return _m(v);
    }
    return null;
  }

  /// Remaining queue for a campaign (customers not yet sent/skipped).
  /// Customers who opted out since the campaign was built are excluded.
  List<QueuedMessage> campaignQueue(String campaignId, {String shopName = ''}) {
    final cmp = campaign(campaignId);
    if (cmp == null) return const [];
    final t = template('${cmp['templateId']}');
    if (t == null) return const [];
    final done = _doneKeys();
    final out = <QueuedMessage>[];
    for (final id in (cmp['customerIds'] as List?) ?? const []) {
      final key = '$campaignId|$id';
      if (done.contains(key)) continue;
      final c = crm.byId('$id');
      if (c == null || !c.canMessage) continue;
      out.add(QueuedMessage(
        customer: c,
        kind: t.kind,
        templateId: t.id,
        campaignId: campaignId,
        dedupeKey: key,
        text: renderTemplate(t,
            name: c.name,
            lastItem: lastItemOf(c),
            shopName: shopName,
            offer: '${cmp['offer'] ?? ''}'),
      ));
    }
    return out;
  }

  /// Sent / skipped counts and customers who bought within 7 days of the
  /// message (revenue from those bills).
  CampaignReport report(String campaignId) {
    final cmp = campaign(campaignId);
    final targeted = ((cmp?['customerIds'] as List?) ?? const []).length;
    var sent = 0, skipped = 0, bought = 0, revenue = 0;
    final firstSent = <String, DateTime>{};
    for (final l in _logs) {
      if (l['campaignId'] != campaignId) continue;
      if (l['status'] == 'skipped') skipped++;
      if (l['status'] != 'sent') continue;
      sent++;
      final at = DateTime.tryParse('${l['at']}');
      final cid = '${l['customerId']}';
      if (at != null &&
          (!firstSent.containsKey(cid) || at.isBefore(firstSent[cid]!))) {
        firstSent[cid] = at;
      }
    }
    firstSent.forEach((cid, at) {
      final end = at.add(const Duration(days: 7));
      var hit = false;
      for (final e in crm.salesOf(cid)) {
        if (isSaleReturnedMap(e.value)) continue;
        final w = DateTime.tryParse(saleWhen(e.value));
        if (w == null || !w.isAfter(at) || w.isAfter(end)) continue;
        hit = true;
        revenue += toPaise(e.value['total']);
      }
      if (hit) bought++;
    });
    return CampaignReport(targeted, sent, skipped, bought, revenue);
  }

  // ---------------------------------------------------------- automations
  /// Messages due today for every automation that is switched ON.
  /// Dedupe keys make each one go out at most once:
  ///   birthday|<cid>|<year>, missyou|<cid>|<lastPurchaseDay>,
  ///   warranty|<saleKey>|<item>, service|<jobId>, thankyou|<saleId>.
  List<QueuedMessage> automationDue({
    DateTime? now,
    String shopName = '',
    Iterable<MapEntry<dynamic, dynamic>> serviceJobs = const [],
    String Function(CrmCustomer c, Map<String, dynamic> sale)? thankYouText,
  }) {
    final a = automation;
    final n = now ?? DateTime.now();
    final done = _doneKeys();
    final out = <QueuedMessage>[];
    MsgTemplate tplOf(String id) =>
        template(id) ?? kDefaultTemplates.firstWhere((t) => t.id == id);

    void add(CrmCustomer c, String kind, String tplId, String key,
        {String lastItem = '', String? text}) {
      if (done.contains(key) || !c.canMessage) return;
      if (out.any((q) => q.dedupeKey == key)) return;
      final body = text ??
          renderTemplate(tplOf(tplId),
              name: c.name,
              lastItem: lastItem.isEmpty ? lastItemOf(c) : lastItem,
              shopName: shopName);
      out.add(QueuedMessage(
        customer: c,
        kind: kind,
        templateId: tplId,
        dedupeKey: key,
        text: body,
      ));
    }

    final anyCustomerRule = a.birthday || a.missYou || a.warranty || a.thankYou;
    if (anyCustomerRule) {
      for (final c in allCustomers(crm)) {
        if (!c.canMessage) continue;
        if (a.birthday &&
            birthdayMonth(c.birthday) == n.month &&
            birthdayDay(c.birthday) == n.day) {
          add(c, 'birthday', 'tpl_default_birthday',
              'birthday|${c.id}|${n.year}');
        }
        if (a.missYou &&
            c.lastPurchaseAt != null &&
            n.difference(c.lastPurchaseAt!).inDays >= a.missYouDays) {
          final d = c.lastPurchaseAt!.toUtc().toIso8601String().substring(0, 10);
          add(c, 'missyou', 'tpl_default_missyou', 'missyou|${c.id}|$d');
        }
        if (a.warranty || a.thankYou) {
          final sales = crm.salesOf(c.id, limit: 50);
          if (a.warranty) {
            for (final w in warrantyLines(sales)) {
              final left = _dayOnly(w.expires).difference(_dayOnly(n)).inDays;
              if (left >= 0 && left <= a.warrantyDaysBefore) {
                add(c, 'warranty', 'tpl_default_warranty',
                    'warranty|${w.saleKey}|${w.item}',
                    lastItem: w.item);
              }
            }
          }
          if (a.thankYou) {
            for (final e in sales) {
              final s = e.value;
              final w = DateTime.tryParse(saleWhen(s));
              if (w == null || isSaleReturnedMap(s)) continue;
              if (n.difference(w).inHours > 48 || w.isAfter(n)) continue;
              final key = 'thankyou|${s['_id'] ?? e.key}';
              add(c, 'thankyou', 'thankyou', key,
                  text: thankYouText?.call(c, s) ??
                      'നന്ദി {name}! / Thank you for shopping at $shopName.'
                          .replaceAll('{name}', c.name));
            }
          }
        }
      }
    }
    if (a.serviceReady) {
      for (final e in serviceJobs) {
        final j = _m(e.value);
        if ('${j['status']}' != 'Ready') continue;
        final c = crm.lookupByPhone('${j['phone'] ?? ''}');
        if (c == null) continue;
        add(c, 'service', 'tpl_default_service',
            'service|${j['jobId'] ?? e.key}',
            lastItem: '${j['brandModel'] ?? j['productType'] ?? ''}'.trim());
      }
    }
    return out;
  }
}
