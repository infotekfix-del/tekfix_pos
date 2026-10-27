import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:workmanager/workmanager.dart';
import '../main.dart' show Db, rs;
import '../utils/tek_helpers.dart';

double _d(dynamic v) => tekD(v);
int _i(dynamic v) => tekI(v);
Map<String, dynamic> _m(dynamic v) => tekM(v);
bool _isReturned(Map s) => isSaleReturned(s);

/// Background entry point for Workmanager on Android
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    try {
      debugPrint('Workmanager periodic task executing: $taskName');
      await ReminderService.instance.processAllAutomaticMessages();
      return true;
    } catch (e) {
      debugPrint('Workmanager task error: $e');
      return false;
    }
  });
}

class ReminderService {
  ReminderService._();
  static final ReminderService instance = ReminderService._();

  static const MethodChannel _smsChannel =
      MethodChannel('com.example.tekfix_pos/sms');

  final DateFormat _dateFmt = DateFormat('dd MMM yyyy');

  // ---- Settings Helpers ----------------------------------------------------
  bool get isAutoRemindersEnabled =>
      Db.setting('reminders_auto_enabled', 'false') == 'true';

  int get reminderIntervalDays =>
      int.tryParse(Db.setting('reminders_interval_days', '3')) ?? 3;

  int get reminderStartDays =>
      int.tryParse(Db.setting('reminders_start_days', '3')) ?? 3;

  int get reminderStartHour =>
      int.tryParse(Db.setting('reminders_start_hour', '10')) ?? 10;

  int get reminderEndHour =>
      int.tryParse(Db.setting('reminders_end_hour', '19')) ?? 19;

  int get reminderMaxCount =>
      int.tryParse(Db.setting('reminders_max_count', '10')) ?? 10;

  bool get isFollowUpEnabled =>
      Db.setting('followup_auto_enabled', 'true') == 'true';

  int get followUp1Days =>
      int.tryParse(Db.setting('followup_1_days', '5')) ?? 5;

  int get followUp2Days =>
      int.tryParse(Db.setting('followup_2_days', '25')) ?? 25;

  bool get isDebugMode => Db.setting('reminders_debug_mode', 'false') == 'true';

  // ---- Native SMS Channel Methods ------------------------------------------
  Future<bool> hasSmsPermission() async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      final res = await _smsChannel.invokeMethod<bool>('hasSmsPermission');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> requestSmsPermission() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _smsChannel.invokeMethod('requestSmsPermission');
    } catch (_) {}
  }

  Future<bool> isBatteryOptimizationIgnored() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    try {
      final res = await _smsChannel
          .invokeMethod<bool>('isBatteryOptimizationIgnored');
      return res ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<void> requestIgnoreBatteryOptimization() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _smsChannel.invokeMethod('requestIgnoreBatteryOptimization');
    } catch (_) {}
  }

  /// Sends silent multi-part SMS using native Android SmsManager.
  Future<bool> sendSilentSms(String phone, String message) async {
    final cleanPhone = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (cleanPhone.length < 10) {
      throw Exception('സാധുവായ ഫോൺ നമ്പർ അല്ല (Invalid phone number)');
    }

    if (kIsWeb || !Platform.isAndroid) {
      debugPrint('SMS mock (Non-Android): $cleanPhone -> $message');
      return true;
    }

    final hasPerm = await hasSmsPermission();
    if (!hasPerm) {
      await requestSmsPermission();
      throw Exception('SMS അയക്കാനുള്ള അനുമതി നൽകിയിട്ടില്ല (SEND_SMS required)');
    }

    final res = await _smsChannel.invokeMethod<bool>('sendSms', {
      'phone': cleanPhone,
      'message': message,
    });
    return res ?? false;
  }

  /// Opens WhatsApp with prefilled message via wa.me URL.
  Future<bool> sendWhatsApp(String phone, String message) async {
    var p = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (p.startsWith('0')) p = p.substring(1);
    if (!p.startsWith('91') && p.length == 10) p = '91$p';

    final uri = Uri.parse(
        'https://wa.me/$p?text=${Uri.encodeComponent(message)}');
    if (await canLaunchUrl(uri)) {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    return false;
  }

  /// Opens device SMS app intent with pre-filled message text.
  Future<bool> openSmsIntent(String phone, String message) async {
    var clean = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    final uri = Uri.parse('sms:$clean?body=${Uri.encodeComponent(message)}');
    if (await canLaunchUrl(uri)) {
      return await launchUrl(uri);
    }
    return false;
  }

  /// Records a sent reminder without deducting or modifying the customer's balance.
  Future<void> recordReminderSent({
    required dynamic partyKey,
    required Map party,
    required String channel, // 'WhatsApp' or 'SMS'
    required String message,
  }) async {
    final count = _i(party['reminderCount']) + 1;
    party['lastReminderAt'] = DateTime.now().toIso8601String();
    party['reminderCount'] = count;
    // Strictly preserve balance!
    await Db.parties.put(partyKey, party);

    await logSentMessage(
      type: 'Payment Reminder ($channel)',
      customerName: '${party['name']}',
      phone: '${party['phone'] ?? ''}',
      text: message,
      success: true,
    );
  }

  // ---- Template Formatting -------------------------------------------------
  String buildReminderMessage({
    required String customerName,
    required double balance,
    required String lastSaleDate,
  }) {
    final tpl = Db.setting(
      'reminders_msg_template',
      'നമസ്കാരം {customer_name}, TEKFIX MOBILE HUB-ൽ നിങ്ങളുടെ ബാക്കി തുക ₹{balance} ആണ് ({last_sale_date}). ദയവായി ഉടൻ അടയ്ക്കുക. {shop_phone}',
    );
    final shopName = Db.setting('shop_name', 'TEKFIX MOBILE HUB');
    final shopPhone = Db.setting('shop_phone', '9876543210');

    return tpl
        .replaceAll('{customer_name}', customerName)
        .replaceAll('{balance}', rs(balance).replaceAll('₹', ''))
        .replaceAll('{last_sale_date}', lastSaleDate)
        .replaceAll('{shop_name}', shopName)
        .replaceAll('{shop_phone}', shopPhone);
  }

  String buildFollowUp1Message({
    required String customerName,
    required String itemName,
    required String saleDate,
  }) {
    final tpl = Db.setting(
      'followup_1_template',
      'നമസ്കാരം {customer_name}, TEKFIX MOBILE HUB-ൽ നിന്ന് വാങ്ങിയ {item_name} നല്ല രീതിയിൽ പ്രവർത്തിക്കുന്നുണ്ടല്ലോ? എന്തെങ്കിലും കംപ്ലയിന്റ് ഉണ്ടെങ്കിൽ ഈ നമ്പറിൽ ബന്ധപ്പെടുക: {shop_phone}. നന്ദി!',
    );
    final shopName = Db.setting('shop_name', 'TEKFIX MOBILE HUB');
    final shopPhone = Db.setting('shop_phone', '9876543210');
    final reviewUrl = Db.setting('google_review_url', '');

    var msg = tpl
        .replaceAll('{customer_name}', customerName)
        .replaceAll('{item_name}', itemName)
        .replaceAll('{sale_date}', saleDate)
        .replaceAll('{shop_name}', shopName)
        .replaceAll('{shop_phone}', shopPhone);

    if (reviewUrl.isNotEmpty && Db.setting('include_review_link') == 'true') {
      msg += '\nGoogle Review: $reviewUrl';
    }
    return msg;
  }

  String buildFollowUp2Message({
    required String customerName,
    required String itemName,
    required String warrantyEnd,
  }) {
    final tpl = Db.setting(
      'followup_2_template',
      'നമസ്കാരം {customer_name}, നിങ്ങളുടെ {item_name}-ന് {warranty_end} വരെ വാറണ്ടി ഉണ്ട്. എന്തെങ്കിലും പ്രശ്നം ഉണ്ടെങ്കിൽ ഉടൻ അറിയിക്കുക: {shop_phone}.',
    );
    final shopName = Db.setting('shop_name', 'TEKFIX MOBILE HUB');
    final shopPhone = Db.setting('shop_phone', '9876543210');

    return tpl
        .replaceAll('{customer_name}', customerName)
        .replaceAll('{item_name}', itemName)
        .replaceAll('{warranty_end}', warrantyEnd)
        .replaceAll('{shop_name}', shopName)
        .replaceAll('{shop_phone}', shopPhone);
  }

  // ---- Logging -------------------------------------------------------------
  Future<void> logSentMessage({
    required String type, // 'Reminder', 'FollowUp1', 'FollowUp2'
    required String customerName,
    required String phone,
    required String text,
    required bool success,
    String? error,
  }) async {
    final logs =
        (Db.settings.get('reminders_msg_logs') as List?)?.toList() ?? [];
    logs.add({
      'date': DateTime.now().toIso8601String(),
      'type': type,
      'customer': customerName,
      'phone': phone,
      'text': text,
      'status': success ? 'Sent' : 'Failed',
      'error': error,
    });
    if (logs.length > 500) logs.removeRange(0, logs.length - 500);
    await Db.settings.put('reminders_msg_logs', logs);
  }

  // ---- Due Evaluation & Background Processing ------------------------------
  bool isWithinAllowedTimeWindow() {
    if (isDebugMode) return true; // Debug mode bypasses time window
    final now = DateTime.now();
    return now.hour >= reminderStartHour && now.hour < reminderEndHour;
  }

  /// Calculates days overdue and status for a customer with pending balance.
  Map<String, dynamic> evaluateCustomerReminder(Map party) {
    final bal = _d(party['balance']);
    if (bal <= 0) return {'isDue': false, 'status': 'Cleared'};

    if (party['remindersDisabled'] == true) {
      return {'isDue': false, 'status': 'Paused'};
    }

    final now = DateTime.now();
    final promisedDateStr = '${party['promisedDate'] ?? ''}';
    if (promisedDateStr.isNotEmpty) {
      final promised = DateTime.tryParse(promisedDateStr);
      if (promised != null && now.isBefore(promised)) {
        return {
          'isDue': false,
          'status': 'Promised on ${_dateFmt.format(promised)}',
          'nextDate': promised,
        };
      }
    }

    final sentCount = _i(party['reminderCount']);
    if (sentCount >= reminderMaxCount) {
      return {'isDue': false, 'status': 'Needs personal follow-up'};
    }

    // Find the latest unpaid sale date for this customer
    DateTime? lastSaleDate;
    final phone = '${party['phone'] ?? ''}';
    final name = '${party['name'] ?? ''}';

    for (final v in Db.sales.values) {
      final s = _m(v);
      if (_isReturned(s)) continue;
      if (s['customerPhone'] == phone || s['customerName'] == name) {
        final d = DateTime.tryParse('${s['createdAt']}');
        if (d != null && (lastSaleDate == null || d.isAfter(lastSaleDate))) {
          lastSaleDate = d;
        }
      }
    }
    lastSaleDate ??= DateTime.now().subtract(const Duration(days: 4));

    final interval = _i(party['customIntervalDays']) > 0
        ? _i(party['customIntervalDays'])
        : reminderIntervalDays;

    final lastReminderStr = '${party['lastReminderAt'] ?? ''}';
    DateTime nextDue;
    if (lastReminderStr.isNotEmpty) {
      final lastRem = DateTime.tryParse(lastReminderStr) ?? lastSaleDate;
      nextDue = lastRem.add(Duration(days: interval));
    } else {
      nextDue = lastSaleDate.add(Duration(days: reminderStartDays));
    }

    final daysOverdue = now.difference(lastSaleDate).inDays;
    final isDue = now.isAfter(nextDue);

    return {
      'isDue': isDue,
      'status': isDue ? 'Due' : 'Scheduled',
      'daysOverdue': daysOverdue,
      'nextDate': nextDue,
      'lastSaleDate': _dateFmt.format(lastSaleDate),
      'sentCount': sentCount,
      'isOver30Days': daysOverdue >= 30,
    };
  }

  /// Sends reminder for a specific party key and updates metadata.
  Future<bool> sendReminderForParty(dynamic partyKey, Map party) async {
    final phone = '${party['phone'] ?? ''}'.trim();
    if (phone.isEmpty) {
      throw Exception('ഫോൺ നമ്പർ ലഭ്യമല്ല (No mobile number)');
    }

    final bal = _d(party['balance']);
    final eval = evaluateCustomerReminder(party);
    final saleDateStr = eval['lastSaleDate'] ?? _dateFmt.format(DateTime.now());

    final msg = buildReminderMessage(
      customerName: '${party['name']}',
      balance: bal,
      lastSaleDate: saleDateStr,
    );

    try {
      await sendSilentSms(phone, msg);
      final count = _i(party['reminderCount']) + 1;
      party['lastReminderAt'] = DateTime.now().toIso8601String();
      party['reminderCount'] = count;
      await Db.parties.put(partyKey, party);

      await logSentMessage(
        type: 'Payment Reminder',
        customerName: '${party['name']}',
        phone: phone,
        text: msg,
        success: true,
      );
      return true;
    } catch (e) {
      await logSentMessage(
        type: 'Payment Reminder',
        customerName: '${party['name']}',
        phone: phone,
        text: msg,
        success: false,
        error: e.toString(),
      );
      rethrow;
    }
  }

  /// Evaluates and runs automatic periodic checks for both Reminders and Follow-ups.
  Future<void> processAllAutomaticMessages() async {
    if (!isWithinAllowedTimeWindow()) {
      debugPrint('Skipping automatic sending: outside allowed time window');
      return;
    }

    // 1. Process Pending Balance Reminders
    if (isAutoRemindersEnabled) {
      for (final entry in entriesOf(Db.parties)) {
        final p = entry.value;
        final bal = _d(p['balance']);
        if (bal <= 0) continue;

        final eval = evaluateCustomerReminder(p);
        if (eval['isDue'] == true) {
          final phone = '${p['phone'] ?? ''}'.trim();
          if (phone.length >= 10) {
            try {
              await sendReminderForParty(entry.key, p);
            } catch (e) {
              debugPrint('Error sending auto reminder to ${p['name']}: $e');
            }
          }
        }
      }
    }

    // 2. Process After-Sales Follow-ups
    if (isFollowUpEnabled) {
      await processAllDueFollowUps();
    }
  }

  /// Collects all sale items eligible for follow-ups and returns structured list.
  List<Map<String, dynamic>> getEligibleFollowUps() {
    final list = <Map<String, dynamic>>[];
    final now = DateTime.now();

    for (final saleEntry in entriesOf(Db.sales)) {
      final s = saleEntry.value;
      if (_isReturned(s)) continue;

      final saleDate = DateTime.tryParse('${s['createdAt']}') ?? now;
      final customerName = '${s['customerName'] ?? 'Customer'}';
      final customerPhone = '${s['customerPhone'] ?? ''}'.trim();
      final items = (s['items'] as List?) ?? [];

      for (var i = 0; i < items.length; i++) {
        final item = _m(items[i]);
        final warranty = '${item['warranty'] ?? ''}';
        final hasWarranty = warranty.isNotEmpty && warranty != 'No Warranty';
        final followUpEnabled =
            item['followUpEnabled'] == true || hasWarranty;

        if (!followUpEnabled) continue;

        // Calculate warranty end date if applicable
        DateTime? warrantyEnd;
        if (warranty.contains('1 Year')) {
          warrantyEnd = DateTime(saleDate.year + 1, saleDate.month, saleDate.day);
        } else if (warranty.contains('6 Months')) {
          warrantyEnd = DateTime(saleDate.year, saleDate.month + 6, saleDate.day);
        } else if (warranty.contains('3 Months')) {
          warrantyEnd = DateTime(saleDate.year, saleDate.month + 3, saleDate.day);
        }

        // Follow up 1 due: saleDate + followUp1Days
        final fu1Due = saleDate.add(Duration(days: followUp1Days));
        final fu1Sent = item['followUp1SentAt'] != null;

        // Follow up 2 due: earlier of day 25 or 3 days before warranty expiry
        DateTime? fu2Due;
        if (warrantyEnd != null) {
          final nearExpiry = warrantyEnd.subtract(const Duration(days: 3));
          final day25 = saleDate.add(Duration(days: followUp2Days));
          fu2Due = nearExpiry.isBefore(day25) ? nearExpiry : day25;
        } else {
          fu2Due = saleDate.add(Duration(days: followUp2Days));
        }
        final fu2Sent = item['followUp2SentAt'] != null;

        list.add({
          'saleKey': saleEntry.key,
          'itemIndex': i,
          'itemName': item['name'] ?? 'Item',
          'customerName': customerName,
          'customerPhone': customerPhone,
          'saleDate': _dateFmt.format(saleDate),
          'saleDateTime': saleDate,
          'warranty': warranty,
          'warrantyEnd':
              warrantyEnd != null ? _dateFmt.format(warrantyEnd) : 'N/A',
          'fu1Due': fu1Due,
          'fu1Sent': fu1Sent,
          'fu2Due': fu2Due,
          'fu2Sent': fu2Sent,
          'skipped': item['followUpSkipped'] == true,
        });
      }
    }
    return list;
  }

  Future<void> processAllDueFollowUps() async {
    final followUps = getEligibleFollowUps();
    final now = DateTime.now();

    for (final fu in followUps) {
      if (fu['skipped'] == true) continue;
      final phone = '${fu['customerPhone']}';
      if (phone.length < 10) continue;

      // Follow-up 1
      if (!fu['fu1Sent'] && now.isAfter(fu['fu1Due'])) {
        try {
          await sendFollowUp1(fu);
        } catch (_) {}
      } else if (!fu['fu2Sent'] && fu['fu2Due'] != null && now.isAfter(fu['fu2Due'])) {
        try {
          await sendFollowUp2(fu);
        } catch (_) {}
      }
    }
  }

  Future<void> sendFollowUp1(Map<String, dynamic> fu) async {
    final msg = buildFollowUp1Message(
      customerName: fu['customerName'],
      itemName: fu['itemName'],
      saleDate: fu['saleDate'],
    );
    await sendSilentSms(fu['customerPhone'], msg);

    // Update sale item in Hive
    final saleKey = fu['saleKey'];
    final sale = _m(Db.sales.get(saleKey));
    final items = (sale['items'] as List?)?.toList() ?? [];
    if (fu['itemIndex'] < items.length) {
      final item = Map<String, dynamic>.from(items[fu['itemIndex']] as Map);
      item['followUp1SentAt'] = DateTime.now().toIso8601String();
      items[fu['itemIndex']] = item;
      sale['items'] = items;
      await Db.sales.put(saleKey, sale);
    }

    await logSentMessage(
      type: 'Follow-Up 1',
      customerName: fu['customerName'],
      phone: fu['customerPhone'],
      text: msg,
      success: true,
    );
  }

  Future<void> sendFollowUp2(Map<String, dynamic> fu) async {
    final msg = buildFollowUp2Message(
      customerName: fu['customerName'],
      itemName: fu['itemName'],
      warrantyEnd: fu['warrantyEnd'],
    );
    await sendSilentSms(fu['customerPhone'], msg);

    final saleKey = fu['saleKey'];
    final sale = _m(Db.sales.get(saleKey));
    final items = (sale['items'] as List?)?.toList() ?? [];
    if (fu['itemIndex'] < items.length) {
      final item = Map<String, dynamic>.from(items[fu['itemIndex']] as Map);
      item['followUp2SentAt'] = DateTime.now().toIso8601String();
      items[fu['itemIndex']] = item;
      sale['items'] = items;
      await Db.sales.put(saleKey, sale);
    }

    await logSentMessage(
      type: 'Follow-Up 2',
      customerName: fu['customerName'],
      phone: fu['customerPhone'],
      text: msg,
      success: true,
    );
  }

  Future<void> skipFollowUp(Map<String, dynamic> fu) async {
    final saleKey = fu['saleKey'];
    final sale = _m(Db.sales.get(saleKey));
    final items = (sale['items'] as List?)?.toList() ?? [];
    if (fu['itemIndex'] < items.length) {
      final item = Map<String, dynamic>.from(items[fu['itemIndex']] as Map);
      item['followUpSkipped'] = true;
      items[fu['itemIndex']] = item;
      sale['items'] = items;
      await Db.sales.put(saleKey, sale);
    }
  }

  /// Initializes Workmanager periodic background task on Android.
  Future<void> initBackgroundWorkmanager() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await Workmanager().initialize(
        callbackDispatcher,
      );
      await Workmanager().registerPeriodicTask(
        'tekfix_periodic_reminders',
        'tekfix_periodic_reminders_task',
        frequency: const Duration(minutes: 30),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
        constraints: Constraints(
          networkType: NetworkType.notRequired,
        ),
      );
    } catch (e) {
      debugPrint('Workmanager init error: $e');
    }
  }
}
