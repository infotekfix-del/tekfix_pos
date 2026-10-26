import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import '../main.dart' show Db, rs, toast, AppCard;
import '../utils/tek_helpers.dart';
import 'reminder_service.dart';

double _d(dynamic v) => tekD(v);
Map<String, dynamic> _m(dynamic v) => tekM(v);

class RemindersScreen extends StatefulWidget {
  const RemindersScreen({super.key});

  @override
  State<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends State<RemindersScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _dateFormat = DateFormat('dd MMM yyyy, hh:mm a');
  final _dayFormat = DateFormat('dd MMM yyyy');

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _showSettingsModal() {
    bool autoOn = ReminderService.instance.isAutoRemindersEnabled;
    int interval = ReminderService.instance.reminderIntervalDays;
    int startDays = ReminderService.instance.reminderStartDays;
    int maxCount = ReminderService.instance.reminderMaxCount;
    int startHour = ReminderService.instance.reminderStartHour;
    int endHour = ReminderService.instance.reminderEndHour;
    bool debugMode = ReminderService.instance.isDebugMode;

    final templateCtrl = TextEditingController(
      text: Db.setting(
        'reminders_msg_template',
        'നമസ്കാരം {customer_name}, TEKFIX MOBILE HUB-ൽ നിങ്ങളുടെ ബാക്കി തുക ₹{balance} ആണ് ({last_sale_date}). ദയവായി ഉടൻ അടയ്ക്കുക. {shop_phone}',
      ),
    );
    final testNumberCtrl = TextEditingController(
      text: Db.setting('shop_phone', ''),
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) {
          return Scaffold(
            appBar: AppBar(
              title: const Text('Reminders Settings'),
              actions: [
                TextButton(
                  onPressed: () async {
                    await Db.settings
                        .put('reminders_auto_enabled', autoOn.toString());
                    await Db.settings
                        .put('reminders_interval_days', interval.toString());
                    await Db.settings
                        .put('reminders_start_days', startDays.toString());
                    await Db.settings
                        .put('reminders_max_count', maxCount.toString());
                    await Db.settings
                        .put('reminders_start_hour', startHour.toString());
                    await Db.settings
                        .put('reminders_end_hour', endHour.toString());
                    await Db.settings
                        .put('reminders_debug_mode', debugMode.toString());
                    await Db.settings
                        .put('reminders_msg_template', templateCtrl.text.trim());
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (mounted) setState(() {});
                    if (mounted) toast(context, 'Settings സേവ് ചെയ്തു');
                  },
                  child: const Text('SAVE', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SwitchListTile(
                  title: const Text('Auto Reminders (യാന്ത്രിക സന്ദേശം)'),
                  subtitle: const Text('ബാക്കി തുകയുള്ളവർക്ക് തനിയെ SMS അയക്കുക'),
                  value: autoOn,
                  onChanged: (v) => set(() => autoOn = v),
                ),
                const Divider(),
                ListTile(
                  title: const Text('ആദ്യ സന്ദേശം (Start Rule)'),
                  subtitle: Text('വിൽപന കഴിഞ്ഞ് $startDays ദിവസത്തിന് ശേഷം'),
                  trailing: DropdownButton<int>(
                    value: startDays,
                    items: [1, 2, 3, 4]
                        .map((n) => DropdownMenuItem(value: n, child: Text('$n ദിവസം')))
                        .toList(),
                    onChanged: (v) => set(() => startDays = v!),
                  ),
                ),
                ListTile(
                  title: const Text('തുടർ സന്ദേശങ്ങൾ (Reminder Interval)'),
                  subtitle: Text('ഓരോ $interval ദിവസം കൂടുമ്പോൾ വീണ്ടും അയക്കുക'),
                  trailing: DropdownButton<int>(
                    value: interval,
                    items: [1, 2, 3, 4]
                        .map((n) => DropdownMenuItem(value: n, child: Text('$n ദിവസം')))
                        .toList(),
                    onChanged: (v) => set(() => interval = v!),
                  ),
                ),
                ListTile(
                  title: const Text('പരമാവധി സന്ദേശങ്ങൾ (Max Reminders)'),
                  subtitle: Text('$maxCount തവണ അയച്ച ശേഷം വ്യക്തിഗത ഫോളോ-അപ്പ്'),
                  trailing: DropdownButton<int>(
                    value: maxCount,
                    items: [5, 10, 15, 20]
                        .map((n) => DropdownMenuItem(value: n, child: Text('$n എണ്ണം')))
                        .toList(),
                    onChanged: (v) => set(() => maxCount = v!),
                  ),
                ),
                ListTile(
                  title: const Text('സന്ദേശം അയക്കുന്ന സമയം (Time Window)'),
                  subtitle: Text('$startHour:00 AM മുതൽ $endHour:00 PM വരെ മാത്രം'),
                ),
                const Divider(),
                const Text('സന്ദേശ രൂപം (Message Template)',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
                const SizedBox(height: 6),
                TextField(
                  controller: templateCtrl,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'Variables: {customer_name}, {balance}, {last_sale_date}, {shop_name}, {shop_phone}',
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  color: Colors.amber.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('ടെസ്റ്റ് സന്ദേശം അയക്കുക (Test Message)',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: testNumberCtrl,
                                keyboardType: TextInputType.phone,
                                decoration: const InputDecoration(
                                  labelText: 'നിങ്ങളുടെ ഫോൺ നമ്പർ',
                                  isDense: true,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: () async {
                                final phone = testNumberCtrl.text.trim();
                                if (phone.length < 10) {
                                  toast(ctx, 'ശരിയായ ഫോൺ നമ്പർ നൽകുക');
                                  return;
                                }
                                final sampleMsg = ReminderService.instance
                                    .buildReminderMessage(
                                  customerName: 'Test Customer',
                                  balance: 1500,
                                  lastSaleDate: _dayFormat.format(DateTime.now()),
                                );
                                try {
                                  await ReminderService.instance
                                      .sendSilentSms(phone, sampleMsg);
                                  if (ctx.mounted) {
                                    toast(ctx, 'ടെസ്റ്റ് SMS വിജയകരമായി അയച്ചു!');
                                  }
                                } catch (e) {
                                  if (ctx.mounted) {
                                    toast(ctx, 'SMS പരാജയപ്പെട്ടു: $e', error: true);
                                  }
                                }
                              },
                              child: const Text('Send Test'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  title: const Text('ടെസ്റ്റിംഗ് മോഡ് (Debug Mode - 1 Min)'),
                  subtitle: const Text('സമയം നോക്കാതെ ഉടൻ ടെസ്റ്റ് ചെയ്യാൻ'),
                  value: debugMode,
                  onChanged: (v) => set(() => debugMode = v),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Payment Reminders (ബാക്കി തുക)'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Due Customers', icon: Icon(Icons.people_alt_rounded)),
            Tab(text: 'Message Logs', icon: Icon(Icons.history_rounded)),
            Tab(text: 'No Phone Warning', icon: Icon(Icons.phonelink_erase_rounded)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.tune_rounded),
            onPressed: _showSettingsModal,
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildDueCustomersTab(),
          _buildMessageLogsTab(),
          _buildNoPhoneWarningTab(),
        ],
      ),
    );
  }

  Widget _buildDueCustomersTab() {
    return ValueListenableBuilder(
      valueListenable: Db.parties.listenable(),
      builder: (context, box, _) {
        final pendingParties = <MapEntry<dynamic, Map<String, dynamic>>>[];
        double totalPending = 0;
        int overdueCount = 0;

        for (final k in Db.parties.keys) {
          final p = _m(Db.parties.get(k));
          final bal = _d(p['balance']);
          if (bal > 0) {
            totalPending += bal;
            final eval = ReminderService.instance.evaluateCustomerReminder(p);
            if (eval['isDue'] == true) overdueCount++;
            pendingParties.add(MapEntry(k, p));
          }
        }

        // Sort: Overdue first, then by largest balance
        pendingParties.sort((a, b) {
          final evalA = ReminderService.instance.evaluateCustomerReminder(a.value);
          final evalB = ReminderService.instance.evaluateCustomerReminder(b.value);
          final dueA = evalA['isDue'] == true ? 1 : 0;
          final dueB = evalB['isDue'] == true ? 1 : 0;
          if (dueA != dueB) return dueB.compareTo(dueA);
          return _d(b.value['balance']).compareTo(_d(a.value['balance']));
        });

        if (pendingParties.isEmpty) {
          return const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle_outline, size: 56, color: Colors.green),
                SizedBox(height: 12),
                Text('ബാക്കി തുകയുള്ള ഉപഭോക്താക്കൾ ഇല്ല (No pending dues)',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
          );
        }

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.indigo.shade800, Colors.blue.shade900],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('ആകെ കിട്ടാനുള്ള തുക (Total Pending)',
                            style: TextStyle(color: Colors.white70, fontSize: 13)),
                        const SizedBox(height: 4),
                        Text(rs(totalPending),
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 24,
                                fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                  Chip(
                    backgroundColor: Colors.amber.shade400,
                    label: Text(
                      '$overdueCount Overdue',
                      style: const TextStyle(
                          color: Colors.black87, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            for (final entry in pendingParties) ...[
              Builder(builder: (ctx) {
                final partyKey = entry.key;
                final p = entry.value;
                final bal = _d(p['balance']);
                final eval = ReminderService.instance.evaluateCustomerReminder(p);
                final bool isOver30 = eval['isOver30Days'] == true;
                final bool isDue = eval['isDue'] == true;
                final phone = '${p['phone'] ?? ''}'.trim();

                return AppCard(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CircleAvatar(
                            backgroundColor: isOver30
                                ? Colors.red.shade100
                                : (isDue ? Colors.amber.shade100 : Colors.blue.shade50),
                            child: Icon(
                              Icons.person_outline_rounded,
                              color: isOver30
                                  ? Colors.red.shade900
                                  : (isDue ? Colors.amber.shade900 : Colors.blue.shade800),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        '${p['name']}',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15,
                                          color: isOver30 ? Colors.red.shade800 : null,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      rs(bal),
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                        color: isOver30 ? Colors.red.shade700 : Colors.blue.shade900,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  phone.isNotEmpty ? phone : '⚠️ ഫോൺ നമ്പർ ഇല്ല',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: phone.isNotEmpty
                                        ? Theme.of(context).colorScheme.onSurfaceVariant
                                        : Colors.red,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 4,
                                  children: [
                                    if (isOver30)
                                      const Chip(
                                        visualDensity: VisualDensity.compact,
                                        label: Text('30+ Days Overdue',
                                            style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.white)),
                                        backgroundColor: Colors.red,
                                      ),
                                    Chip(
                                      visualDensity: VisualDensity.compact,
                                      label: Text(
                                        '${eval['status']} (${eval['daysOverdue']} days)',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: isDue ? Colors.amber.shade900 : Colors.grey.shade700,
                                        ),
                                      ),
                                      backgroundColor: isDue ? Colors.amber.shade100 : Colors.grey.shade200,
                                    ),
                                    Chip(
                                      visualDensity: VisualDensity.compact,
                                      label: Text('Sent: ${eval['sentCount']}',
                                          style: const TextStyle(fontSize: 10)),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (phone.isNotEmpty) ...[
                            OutlinedButton.icon(
                              icon: const Icon(Icons.chat_bubble_outline_rounded, size: 16, color: Colors.green),
                              label: const Text('WhatsApp', style: TextStyle(color: Colors.green, fontSize: 12)),
                              onPressed: () async {
                                final msg = ReminderService.instance
                                    .buildReminderMessage(
                                  customerName: '${p['name']}',
                                  balance: bal,
                                  lastSaleDate: eval['lastSaleDate'] ?? '',
                                );
                                await ReminderService.instance.sendWhatsApp(phone, msg);
                              },
                            ),
                            const SizedBox(width: 8),
                            FilledButton.icon(
                              icon: const Icon(Icons.send_rounded, size: 16),
                              label: const Text('Send SMS', style: TextStyle(fontSize: 12)),
                              onPressed: () async {
                                try {
                                  await ReminderService.instance
                                      .sendReminderForParty(partyKey, p);
                                  if (context.mounted) {
                                    toast(context, '${p['name']}-ലേക്ക് SMS അയച്ചു');
                                    setState(() {});
                                  }
                                } catch (e) {
                                  if (context.mounted) {
                                    toast(context, 'SMS പരാജയപ്പെട്ടു: $e', error: true);
                                  }
                                }
                              },
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                );
              }),
            ],
          ],
        );
      },
    );
  }

  Widget _buildMessageLogsTab() {
    final logs =
        ((Db.settings.get('reminders_msg_logs') as List?) ?? []).reversed.toList();

    if (logs.isEmpty) {
      return const Center(child: Text('സന്ദേശ വിവരങ്ങൾ ലഭ്യമല്ല (No logs)'));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: logs.length,
      itemBuilder: (ctx, i) {
        final log = Map<String, dynamic>.from(logs[i] as Map);
        final date = DateTime.tryParse('${log['date']}') ?? DateTime.now();
        final success = log['status'] == 'Sent';

        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: success ? Colors.green.shade100 : Colors.red.shade100,
              child: Icon(
                success ? Icons.done_rounded : Icons.error_outline_rounded,
                color: success ? Colors.green.shade800 : Colors.red.shade800,
              ),
            ),
            title: Text('${log['customer']} • ${log['phone']}',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${log['text']}', style: const TextStyle(fontSize: 11.5)),
                const SizedBox(height: 2),
                Text(
                  '${_dateFormat.format(date)} • ${log['type']}',
                  style: TextStyle(fontSize: 10.5, color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
            trailing: !success
                ? IconButton(
                    icon: const Icon(Icons.refresh_rounded, color: Colors.blue),
                    onPressed: () async {
                      try {
                        await ReminderService.instance
                            .sendSilentSms('${log['phone']}', '${log['text']}');
                        if (mounted) {
                          toast(context, 'വീണ്ടും അയച്ചു (Retried successfully)');
                        }
                      } catch (e) {
                        if (mounted) {
                          toast(context, 'പരാജയപ്പെട്ടു: $e', error: true);
                        }
                      }
                    },
                  )
                : null,
          ),
        );
      },
    );
  }

  Widget _buildNoPhoneWarningTab() {
    final parties = entriesOf(Db.parties)
        .where((e) =>
            _d(e.value['balance']) > 0 &&
            '${e.value['phone'] ?? ''}'.trim().length < 10)
        .toList();

    if (parties.isEmpty) {
      return const Center(
        child: Text('എല്ലാ ബാക്കിയുള്ള ഉപഭോക്താക്കൾക്കും ഫോൺ നമ്പർ ഉണ്ട് 👍'),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: parties.length,
      itemBuilder: (ctx, i) {
        final p = parties[i].value;
        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: ListTile(
            leading: const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 32),
            title: Text('${p['name']}', style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text('ബാക്കി തുക: ${rs(_d(p['balance']))}\nഫോൺ നമ്പർ നൽകിയിട്ടില്ല. വ്യക്തിഗത ഫോളോ-അപ്പ് ചെയ്യുക.'),
          ),
        );
      },
    );
  }
}
