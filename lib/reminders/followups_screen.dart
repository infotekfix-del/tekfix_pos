import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import '../main.dart' show Db, toast, AppCard, showServiceJobForm;
import 'reminder_service.dart';

class FollowupsScreen extends StatefulWidget {
  const FollowupsScreen({super.key});

  @override
  State<FollowupsScreen> createState() => _FollowupsScreenState();
}

class _FollowupsScreenState extends State<FollowupsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _dateFormat = DateFormat('dd MMM yyyy');

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _showSettingsModal() {
    bool autoOn = ReminderService.instance.isFollowUpEnabled;
    int f1Days = ReminderService.instance.followUp1Days;
    int f2Days = ReminderService.instance.followUp2Days;

    final tpl1Ctrl = TextEditingController(
      text: Db.setting(
        'followup_1_template',
        'നമസ്കാരം {customer_name}, TEKFIX MOBILE HUB-ൽ നിന്ന് വാങ്ങിയ {item_name} നല്ല രീതിയിൽ പ്രവർത്തിക്കുന്നുണ്ടല്ലോ? എന്തെങ്കിലും കംപ്ലയിന്റ് ഉണ്ടെങ്കിൽ ഈ നമ്പറിൽ ബന്ധപ്പെടുക: {shop_phone}. നന്ദി!',
      ),
    );
    final tpl2Ctrl = TextEditingController(
      text: Db.setting(
        'followup_2_template',
        'നമസ്കാരം {customer_name}, നിങ്ങളുടെ {item_name}-ന് {warranty_end} വരെ വാറണ്ടി ഉണ്ട്. എന്തെങ്കിലും പ്രശ്നം ഉണ്ടെങ്കിൽ ഉടൻ അറിയിക്കുക: {shop_phone}.',
      ),
    );
    final reviewUrlCtrl = TextEditingController(
      text: Db.setting('google_review_url', ''),
    );
    bool includeReview = Db.setting('include_review_link', 'false') == 'true';
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
              title: const Text('Follow-Up Settings'),
              actions: [
                TextButton(
                  onPressed: () async {
                    await Db.settings
                        .put('followup_auto_enabled', autoOn.toString());
                    await Db.settings.put('followup_1_days', f1Days.toString());
                    await Db.settings.put('followup_2_days', f2Days.toString());
                    await Db.settings
                        .put('followup_1_template', tpl1Ctrl.text.trim());
                    await Db.settings
                        .put('followup_2_template', tpl2Ctrl.text.trim());
                    await Db.settings
                        .put('google_review_url', reviewUrlCtrl.text.trim());
                    await Db.settings
                        .put('include_review_link', includeReview.toString());
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (mounted) setState(() {});
                    if (mounted) toast(context, 'Follow-up Settings സേവ് ചെയ്തു');
                  },
                  child: const Text('SAVE', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SwitchListTile(
                  title: const Text('Auto Follow-ups (വാറണ്ടി ഫോളോ-അപ്പ്)'),
                  subtitle: const Text('സാധനങ്ങൾ വാങ്ങിയവർക്ക് ക്ഷേമാന്വേഷണ SMS'),
                  value: autoOn,
                  onChanged: (v) => set(() => autoOn = v),
                ),
                const Divider(),
                ListTile(
                  title: const Text('ആദ്യ ഫോളോ-അപ്പ് (Follow-up #1)'),
                  subtitle: Text('വാങ്ങി $f1Days ദിവസത്തിന് ശേഷം'),
                  trailing: DropdownButton<int>(
                    value: f1Days,
                    items: [3, 5, 7, 10, 14]
                        .map((n) => DropdownMenuItem(value: n, child: Text('$n ദിവസം')))
                        .toList(),
                    onChanged: (v) => set(() => f1Days = v!),
                  ),
                ),
                ListTile(
                  title: const Text('രണ്ടാം ഫോളോ-അപ്പ് (Follow-up #2)'),
                  subtitle: Text('$f2Days-ാം ദിവസം അല്ലെങ്കിൽ വാറണ്ടി തീരുന്നതിന് 3 ദിവസം മുൻപ്'),
                  trailing: DropdownButton<int>(
                    value: f2Days,
                    items: [20, 25, 27, 30]
                        .map((n) => DropdownMenuItem(value: n, child: Text('$n ദിവസം')))
                        .toList(),
                    onChanged: (v) => set(() => f2Days = v!),
                  ),
                ),
                const SizedBox(height: 10),
                const Text('സന്ദേശം #1 രൂപം (Follow-Up #1 Template)',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 6),
                TextField(
                  controller: tpl1Ctrl,
                  maxLines: 3,
                  decoration: const InputDecoration(border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                const Text('സന്ദേശം #2 രൂപം (Follow-Up #2 Template)',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 6),
                TextField(
                  controller: tpl2Ctrl,
                  maxLines: 3,
                  decoration: const InputDecoration(border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  title: const Text('Google Review ലിങ്ക് ചേർക്കുക'),
                  value: includeReview,
                  onChanged: (v) => set(() => includeReview = v),
                ),
                if (includeReview)
                  TextField(
                    controller: reviewUrlCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Google Review Link (URL)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                const SizedBox(height: 12),
                Card(
                  color: Colors.teal.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: testNumberCtrl,
                            keyboardType: TextInputType.phone,
                            decoration: const InputDecoration(
                              labelText: 'ടെസ്റ്റ് ഫോൺ നമ്പർ',
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
                            final msg = ReminderService.instance
                                .buildFollowUp1Message(
                              customerName: 'Test Customer',
                              itemName: 'Fast Charger 65W',
                              saleDate: _dateFormat.format(DateTime.now()),
                            );
                            try {
                              await ReminderService.instance
                                  .sendSilentSms(phone, msg);
                              if (ctx.mounted) {
                                toast(ctx, 'ടെസ്റ്റ് Follow-up SMS അയച്ചു!');
                              }
                            } catch (e) {
                              if (ctx.mounted) {
                                toast(ctx, 'SMS പരാജയപ്പെട്ടു: $e', error: true);
                              }
                            }
                          },
                          child: const Text('Test #1'),
                        ),
                      ],
                    ),
                  ),
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
        title: const Text('After-Sales Follow-ups'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Due / Upcoming', icon: Icon(Icons.alarm_on_rounded)),
            Tab(text: 'Completed', icon: Icon(Icons.done_all_rounded)),
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
      body: ValueListenableBuilder(
        valueListenable: Db.sales.listenable(),
        builder: (context, box, _) {
          final all = ReminderService.instance.getEligibleFollowUps();
          final upcoming = all.where((f) => !f['fu1Sent'] || !f['fu2Sent']).toList();
          final completed = all.where((f) => f['fu1Sent'] == true && f['fu2Sent'] == true).toList();

          return TabBarView(
            controller: _tabController,
            children: [
              _buildList(upcoming, isCompleted: false),
              _buildList(completed, isCompleted: true),
            ],
          );
        },
      ),
    );
  }

  Widget _buildList(List<Map<String, dynamic>> items, {required bool isCompleted}) {
    if (items.isEmpty) {
      return Center(
        child: Text(isCompleted
            ? 'പൂർത്തിയായ ഫോളോ-അപ്പുകൾ ഇല്ല'
            : 'ഫോളോ-അപ്പ് ചെയ്യേണ്ട സാധനങ്ങൾ ഇല്ല'),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: items.length,
      itemBuilder: (ctx, i) {
        final fu = items[i];
        final phone = '${fu['customerPhone']}';
        final is1Due = DateTime.now().isAfter(fu['fu1Due']) && !fu['fu1Sent'];
        final is2Due = fu['fu2Due'] != null &&
            DateTime.now().isAfter(fu['fu2Due']) &&
            !fu['fu2Sent'];

        return AppCard(
          margin: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    backgroundColor: Colors.teal.shade50,
                    child: const Icon(Icons.verified_outlined, color: Colors.teal),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${fu['itemName']}',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                        Text('${fu['customerName']} • $phone',
                            style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context).colorScheme.onSurfaceVariant)),
                        const SizedBox(height: 4),
                        Text(
                          'വാങ്ങിയത്: ${fu['saleDate']} • വാറണ്ടി: ${fu['warranty']}',
                          style: const TextStyle(fontSize: 11.5, color: Colors.blueGrey),
                        ),
                        if (fu['warrantyEnd'] != 'N/A')
                          Text('വാറണ്ടി തീരുന്നത്: ${fu['warrantyEnd']}',
                              style: const TextStyle(fontSize: 11, color: Colors.teal, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ],
              ),
              const Divider(height: 18),
              Row(
                children: [
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(
                      fu['fu1Sent']
                          ? 'Follow-up #1 Sent'
                          : 'Due #1: ${_dateFormat.format(fu['fu1Due'])}',
                      style: TextStyle(fontSize: 10, color: fu['fu1Sent'] ? Colors.green : (is1Due ? Colors.red : Colors.blueGrey)),
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (fu['fu2Due'] != null)
                    Chip(
                      visualDensity: VisualDensity.compact,
                      label: Text(
                        fu['fu2Sent']
                            ? 'Follow-up #2 Sent'
                            : 'Due #2: ${_dateFormat.format(fu['fu2Due'])}',
                        style: TextStyle(fontSize: 10, color: fu['fu2Sent'] ? Colors.green : (is2Due ? Colors.red : Colors.blueGrey)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.build_circle_outlined, size: 16),
                    label: const Text('Create Ticket', style: TextStyle(fontSize: 11.5)),
                    onPressed: () {
                      showServiceJobForm(
                        context,
                        null,
                        {
                          'customerName': fu['customerName'],
                          'phone': fu['customerPhone'],
                          'brandModel': fu['itemName'],
                          'complaint': 'Complaint reported during follow-up',
                        },
                      );
                    },
                  ),
                  const SizedBox(width: 4),
                  if (!fu['fu1Sent'] || !fu['fu2Sent']) ...[
                    TextButton(
                      onPressed: () async {
                        await ReminderService.instance.skipFollowUp(fu);
                        if (mounted) setState(() {});
                        if (mounted) toast(context, 'സ്കിപ്പ് ചെയ്തു (Skipped)');
                      },
                      child: const Text('Skip', style: TextStyle(fontSize: 11.5)),
                    ),
                    const SizedBox(width: 4),
                    FilledButton.icon(
                      icon: const Icon(Icons.send_rounded, size: 15),
                      label: const Text('Send Now', style: TextStyle(fontSize: 11.5)),
                      onPressed: () async {
                        try {
                          if (!fu['fu1Sent']) {
                            await ReminderService.instance.sendFollowUp1(fu);
                          } else {
                            await ReminderService.instance.sendFollowUp2(fu);
                          }
                          if (mounted) {
                            toast(context, 'Follow-up SMS അയച്ചു');
                            setState(() {});
                          }
                        } catch (e) {
                          if (mounted) {
                            toast(context, 'പരാജയപ്പെട്ടു: $e', error: true);
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
      },
    );
  }
}
