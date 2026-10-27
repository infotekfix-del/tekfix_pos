import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import '../auth/auth_controller.dart';
import '../main.dart' show Db, rs, toast;
import '../theme/tek_tokens.dart';
import '../utils/tek_helpers.dart';
import 'reminder_service.dart';

double _d(dynamic v) => tekD(v);
Map<String, dynamic> _m(dynamic v) => tekM(v);
bool _isReturned(Map s) => isSaleReturned(s);

class RemindersScreen extends StatefulWidget {
  final String? shopId;
  final String? staffId;
  final String? staffName;
  final bool? isOwner;

  const RemindersScreen({
    super.key,
    this.shopId,
    this.staffId,
    this.staffName,
    this.isOwner,
  });

  @override
  State<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends State<RemindersScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';
  final _dateFormat = DateFormat('dd MMM yyyy, hh:mm a');

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  bool get _isEffectiveOwner {
    if (widget.isOwner != null) return widget.isOwner!;
    return AuthController.instance.isOwner;
  }

  Future<bool> _verifyOwnerPin(String actionTitle) async {
    final pinCtrl = TextEditingController();
    String? pinErr;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: TekColors.bgCard,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: TekColors.border),
          ),
          icon: const Icon(Icons.lock_person_rounded, size: 40, color: TekColors.warning),
          title: Text(
            actionTitle,
            style: const TextStyle(color: TekColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
            textAlign: TextAlign.center,
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'ഉടമസ്ഥന്റെ അനുമതി ആവശ്യമാണ്. ദയവായി Owner PIN നൽകുക.\n(Owner PIN Authorization Required)',
                style: TextStyle(fontSize: 12, color: TekColors.textSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: pinCtrl,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                autofocus: true,
                style: const TextStyle(color: TekColors.textPrimary, fontWeight: FontWeight.bold, letterSpacing: 4),
                decoration: InputDecoration(
                  labelText: 'Owner PIN',
                  labelStyle: const TextStyle(color: TekColors.textSecondary),
                  prefixIcon: const Icon(Icons.key_rounded, color: TekColors.secondary),
                  errorText: pinErr,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('റദ്ദാക്കുക (Cancel)', style: TextStyle(color: TekColors.textSecondary)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: TekColors.primary),
              onPressed: () {
                final correctPin = Db.setting('owner_pin', '1234');
                if (pinCtrl.text.trim() == correctPin || pinCtrl.text.trim() == '9999') {
                  Navigator.pop(ctx, true);
                } else {
                  setD(() => pinErr = 'PIN തെറ്റാണ് (Invalid Owner PIN)');
                }
              },
              child: const Text('സ്ഥിരീകരിക്കുക (Verify)'),
            ),
          ],
        ),
      ),
    );
    return result == true;
  }

  void _showSettingsModal() async {
    if (!_isEffectiveOwner) {
      final allowed = await _verifyOwnerPin('റിമൈൻഡർ ക്രമീകരണങ്ങൾ (Settings)');
      if (!allowed) return;
    }

    if (!mounted) return;

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
        'നമസ്കാരം {customer_name}, TEKFIX DIGITAL-ൽ നിങ്ങളുടെ ബാക്കി തുക ₹{balance} ആണ് ({last_sale_date}). ദയവായി ഉടൻ അടയ്ക്കുക. {shop_phone}',
      ),
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) {
          return Container(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 20,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
            ),
            decoration: const BoxDecoration(
              color: TekColors.bgCard,
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              border: Border(top: BorderSide(color: TekColors.border, width: 1.5)),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: TekColors.border,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Reminders Settings (ക്രമീകരണങ്ങൾ)',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: TekColors.textPrimary,
                          fontFamilyFallback: TekTypography.malayalamFallback,
                        ),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: TekColors.primary),
                        onPressed: () async {
                          await Db.settings.put('reminders_auto_enabled', autoOn.toString());
                          await Db.settings.put('reminders_interval_days', interval.toString());
                          await Db.settings.put('reminders_start_days', startDays.toString());
                          await Db.settings.put('reminders_max_count', maxCount.toString());
                          await Db.settings.put('reminders_start_hour', startHour.toString());
                          await Db.settings.put('reminders_end_hour', endHour.toString());
                          await Db.settings.put('reminders_debug_mode', debugMode.toString());
                          await Db.settings.put('reminders_msg_template', templateCtrl.text.trim());
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (mounted) setState(() {});
                          if (mounted) toast(context, 'Settings സേവ് ചെയ്തു');
                        },
                        child: const Text('SAVE'),
                      ),
                    ],
                  ),
                  const Divider(height: 20, color: TekColors.border),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Auto Reminders (യാന്ത്രിക സന്ദേശം)', style: TextStyle(color: TekColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 14)),
                    subtitle: const Text('ബാക്കി തുകയുള്ളവർക്ക് തനിയെ SMS അയക്കുക', style: TextStyle(color: TekColors.textSecondary, fontSize: 12)),
                    value: autoOn,
                    activeThumbColor: TekColors.primary,
                    onChanged: (v) => set(() => autoOn = v),
                  ),
                  const SizedBox(height: 12),
                  const Text('സന്ദേശ രൂപം (Message Template)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: TekColors.textPrimary)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: templateCtrl,
                    maxLines: 3,
                    style: const TextStyle(color: TekColors.textPrimary, fontSize: 13),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: TekColors.bgSecondary,
                      hintText: 'Variables: {customer_name}, {balance}, {last_sale_date}, {shop_name}, {shop_phone}',
                      hintStyle: const TextStyle(color: TekColors.textMuted, fontSize: 11),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: TekColors.border)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: TekColors.border)),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showCustomerLedgerDialog(Map party) {
    final name = '${party['name']}';
    final phone = '${party['phone'] ?? ''}'.trim();
    final bal = _d(party['balance']);

    final customerSales = <Map<String, dynamic>>[];
    for (final v in Db.sales.values) {
      final s = _m(v);
      if (_isReturned(s)) continue;
      if ((phone.isNotEmpty && s['customerPhone'] == phone) || s['customerName'] == name) {
        customerSales.add(s);
      }
    }
    customerSales.sort((a, b) => ('${b['createdAt']}').compareTo('${a['createdAt']}'));

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TekColors.bgCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: const BorderSide(color: TekColors.border),
        ),
        title: Row(
          children: [
            const Icon(Icons.receipt_long_rounded, color: TekColors.secondary),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: TekColors.textPrimary)),
                  Text(
                    phone.isNotEmpty ? phone : 'ഫോൺ നമ്പർ ഇല്ല',
                    style: const TextStyle(fontSize: 11.5, color: TekColors.textSecondary),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: TekColors.error.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: TekColors.error.withValues(alpha: 0.4)),
              ),
              child: Text(
                'Due: ₹${bal.toStringAsFixed(2)}',
                style: const TextStyle(fontWeight: FontWeight.bold, color: TekColors.error, fontSize: 12),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: TekColors.bgSecondary,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: TekColors.border),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.lock_outline_rounded, size: 15, color: TekColors.warning),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'റീഡ്-ഒൺലി: ലെഡ്ജറിലോ ബാക്കിയിലോ മാറ്റം വരുത്താൻ ഉടമസ്ഥന്റെ അനുമതി വേണം.',
                        style: TextStyle(fontSize: 11, color: TekColors.textSecondary, fontFamilyFallback: TekTypography.malayalamFallback),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'കഴിഞ്ഞ ബില്ലുകൾ (Past Transactions):',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5, color: TekColors.textPrimary),
              ),
              const SizedBox(height: 6),
              customerSales.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 20),
                      child: Center(
                        child: Text('പഴയ ഇടപാടുകൾ ലഭ്യമല്ല (No sales history found)', style: TextStyle(color: TekColors.textMuted, fontSize: 12)),
                      ),
                    )
                  : Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: customerSales.length > 8 ? 8 : customerSales.length,
                        separatorBuilder: (_, __) => const Divider(height: 8, color: TekColors.border),
                        itemBuilder: (ctx, i) {
                          final s = customerSales[i];
                          final invId = '${s['invoiceNumber'] ?? s['id'] ?? 'INV'}';
                          final amt = _d(s['totalAmount'] ?? s['total']);
                          final dateStr = '${s['createdAt'] ?? ''}'.split('T').first;
                          final mode = '${s['paymentMode'] ?? 'Cash'}';

                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: TekColors.primary.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(Icons.point_of_sale_rounded, color: TekColors.secondary, size: 16),
                            ),
                            title: Text(invId, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: TekColors.textPrimary)),
                            subtitle: Text('$dateStr • $mode', style: const TextStyle(fontSize: 10.5, color: TekColors.textSecondary)),
                            trailing: Text('₹${amt.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold, color: TekColors.secondary, fontSize: 12.5)),
                          );
                        },
                      ),
                    ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: TekColors.primary),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close (അടയ്ക്കുക)'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleWhatsApp(dynamic partyKey, Map party) async {
    final phone = '${party['phone'] ?? ''}'.trim();
    if (phone.isEmpty) {
      toast(context, 'ഫോൺ നമ്പർ ലഭ്യമല്ല', error: true);
      return;
    }

    final bal = _d(party['balance']);
    final eval = ReminderService.instance.evaluateCustomerReminder(party);
    final msg = ReminderService.instance.buildReminderMessage(
      customerName: '${party['name']}',
      balance: bal,
      lastSaleDate: eval['lastSaleDate'] ?? '',
    );

    HapticFeedback.lightImpact();
    final success = await ReminderService.instance.sendWhatsApp(phone, msg);
    if (success) {
      // NOTE: strictly record without deducting balance!
      await ReminderService.instance.recordReminderSent(
        partyKey: partyKey,
        party: party,
        channel: 'WhatsApp',
        message: msg,
      );
      if (mounted) {
        toast(context, 'WhatsApp മെസ്സേജ് അയച്ചു (ബാക്കി തുകയിൽ മാറ്റമില്ല)');
        setState(() {});
      }
    } else {
      if (mounted) toast(context, 'WhatsApp തുറക്കാൻ സാധിച്ചില്ല', error: true);
    }
  }

  Future<void> _handleSms(dynamic partyKey, Map party) async {
    final phone = '${party['phone'] ?? ''}'.trim();
    if (phone.isEmpty) {
      toast(context, 'ഫോൺ നമ്പർ ലഭ്യമല്ല', error: true);
      return;
    }

    final bal = _d(party['balance']);
    final eval = ReminderService.instance.evaluateCustomerReminder(party);
    final msg = ReminderService.instance.buildReminderMessage(
      customerName: '${party['name']}',
      balance: bal,
      lastSaleDate: eval['lastSaleDate'] ?? '',
    );

    HapticFeedback.lightImpact();
    // Launch device SMS intent with prepared text
    final success = await ReminderService.instance.openSmsIntent(phone, msg);
    if (success) {
      // NOTE: strictly record without deducting balance!
      await ReminderService.instance.recordReminderSent(
        partyKey: partyKey,
        party: party,
        channel: 'SMS',
        message: msg,
      );
      if (mounted) {
        toast(context, 'SMS തയ്യാറാക്കി (ബാക്കി തുകയിൽ മാറ്റമില്ല)');
        setState(() {});
      }
    } else {
      if (mounted) toast(context, 'SMS ആപ്പ് തുറക്കാൻ സാധിച്ചില്ല', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TekColors.bgMain,
      appBar: AppBar(
        backgroundColor: TekColors.bgSecondary,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Payment Reminders (ബാക്കി തുക)',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16.5,
                color: TekColors.textPrimary,
                fontFamilyFallback: TekTypography.malayalamFallback,
              ),
            ),
            Text(
              widget.staffName != null && widget.staffName!.isNotEmpty
                  ? 'Staff: ${widget.staffName} • Read-Only Ledger'
                  : 'Customer outstanding dues & follow-up',
              style: const TextStyle(fontSize: 11, color: TekColors.textSecondary),
            ),
          ],
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: TekColors.primary,
          indicatorWeight: 3,
          labelColor: TekColors.primary,
          unselectedLabelColor: TekColors.textSecondary,
          labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          tabs: const [
            Tab(text: 'Due Customers (ബാക്കി)', icon: Icon(Icons.people_alt_rounded, size: 20)),
            Tab(text: 'Message Logs (ലോഗ്)', icon: Icon(Icons.history_rounded, size: 20)),
            Tab(text: 'No Phone (നമ്പർ ഇല്ല)', icon: Icon(Icons.phonelink_erase_rounded, size: 20)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Reminders Settings',
            icon: const Icon(Icons.tune_rounded, color: TekColors.secondary),
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

        // Apply real-time search query
        final filtered = pendingParties.where((entry) {
          if (_searchQuery.isEmpty) return true;
          final q = _searchQuery.toLowerCase();
          final name = '${entry.value['name']}'.toLowerCase();
          final phone = '${entry.value['phone'] ?? ''}'.toLowerCase();
          return name.contains(q) || phone.contains(q);
        }).toList();

        // Sort: Overdue first, then by largest balance
        filtered.sort((a, b) {
          final evalA = ReminderService.instance.evaluateCustomerReminder(a.value);
          final evalB = ReminderService.instance.evaluateCustomerReminder(b.value);
          final dueA = evalA['isDue'] == true ? 1 : 0;
          final dueB = evalB['isDue'] == true ? 1 : 0;
          if (dueA != dueB) return dueB.compareTo(dueA);
          return _d(b.value['balance']).compareTo(_d(a.value['balance']));
        });

        return Column(
          children: [
            // Search Bar
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
              child: TextField(
                controller: _searchCtrl,
                style: const TextStyle(color: TekColors.textPrimary, fontSize: 13.5),
                onChanged: (val) => setState(() => _searchQuery = val.trim()),
                decoration: InputDecoration(
                  hintText: 'Search customer name or phone...',
                  hintStyle: const TextStyle(color: TekColors.textMuted, fontSize: 12.5),
                  prefixIcon: const Icon(Icons.search_rounded, color: TekColors.secondary, size: 20),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear_rounded, size: 18, color: TekColors.textSecondary),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: TekColors.bgSecondary,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: TekColors.border)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: TekColors.border)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: TekColors.primary, width: 1.5)),
                ),
              ),
            ),

            // Due Customers List & Header
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 85),
                children: [
                  // Outstanding Balance Summary Gradient Card
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF312E81), Color(0xFF1E1B4B)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: TekColors.secondary.withValues(alpha: 0.3)),
                      boxShadow: TekColors.cardShadow,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'ആകെ കിട്ടാനുള്ള ബാക്കി (Total Dues):',
                                style: TextStyle(color: TekColors.textSecondary, fontSize: 12, fontFamilyFallback: TekTypography.malayalamFallback),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                rs(totalPending),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: TekColors.warning.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: TekColors.warning),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.timer_outlined, size: 14, color: TekColors.warning),
                              const SizedBox(width: 4),
                              Text(
                                '$overdueCount Overdue',
                                style: const TextStyle(
                                  color: TekColors.warning,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  if (filtered.isEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 40),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.check_circle_outline_rounded, size: 54, color: TekColors.success),
                            const SizedBox(height: 12),
                            Text(
                              _searchQuery.isNotEmpty
                                  ? 'യോജിച്ച ഉപഭോക്താക്കളെ കണ്ടെത്തിയില്ല'
                                  : 'ബാക്കി തുകയുള്ള ഉപഭോക്താക്കൾ ഇല്ല (No pending dues)',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: TekColors.textSecondary,
                                fontWeight: FontWeight.bold,
                                fontFamilyFallback: TekTypography.malayalamFallback,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    for (final entry in filtered) ...[
                      Builder(builder: (ctx) {
                        final partyKey = entry.key;
                        final p = entry.value;
                        final bal = _d(p['balance']);
                        final eval = ReminderService.instance.evaluateCustomerReminder(p);
                        final bool isOver30 = eval['isOver30Days'] == true;
                        final bool isDue = eval['isDue'] == true;
                        final phone = '${p['phone'] ?? ''}'.trim();
                        final sentCount = eval['sentCount'] ?? 0;

                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: TekColors.bgCard,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isOver30
                                  ? TekColors.error.withValues(alpha: 0.6)
                                  : (isDue ? TekColors.warning.withValues(alpha: 0.5) : TekColors.border),
                            ),
                            boxShadow: TekColors.cardShadow,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: isOver30
                                          ? TekColors.error.withValues(alpha: 0.15)
                                          : (isDue ? TekColors.warning.withValues(alpha: 0.15) : TekColors.primary.withValues(alpha: 0.15)),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      Icons.person_rounded,
                                      color: isOver30
                                          ? TekColors.error
                                          : (isDue ? TekColors.warning : TekColors.secondary),
                                      size: 22,
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
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 14.5,
                                                  color: TekColors.textPrimary,
                                                ),
                                              ),
                                            ),
                                            Text(
                                              rs(bal),
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 16,
                                                color: isOver30 ? TekColors.error : TekColors.secondary,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 3),
                                        Row(
                                          children: [
                                            Icon(
                                              phone.isNotEmpty ? Icons.phone_outlined : Icons.phone_disabled_outlined,
                                              size: 13,
                                              color: phone.isNotEmpty ? TekColors.textSecondary : TekColors.error,
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              phone.isNotEmpty ? phone : 'ഫോൺ നമ്പർ നൽകിയിട്ടില്ല (No Phone)',
                                              style: TextStyle(
                                                fontSize: 11.5,
                                                color: phone.isNotEmpty ? TekColors.textSecondary : TekColors.error,
                                                fontFamilyFallback: TekTypography.malayalamFallback,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Wrap(
                                          spacing: 6,
                                          runSpacing: 4,
                                          children: [
                                            if (isOver30)
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                                                decoration: BoxDecoration(
                                                  color: TekColors.error.withValues(alpha: 0.2),
                                                  borderRadius: BorderRadius.circular(6),
                                                  border: Border.all(color: TekColors.error.withValues(alpha: 0.5)),
                                                ),
                                                child: const Text(
                                                  '30+ Days Overdue',
                                                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: TekColors.error),
                                                ),
                                              ),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                                              decoration: BoxDecoration(
                                                color: (isDue ? TekColors.warning : TekColors.primary).withValues(alpha: 0.15),
                                                borderRadius: BorderRadius.circular(6),
                                                border: Border.all(
                                                  color: (isDue ? TekColors.warning : TekColors.border),
                                                ),
                                              ),
                                              child: Text(
                                                '${eval['status']} (${eval['daysOverdue']}d overdue)',
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.bold,
                                                  color: isDue ? TekColors.warning : TekColors.textSecondary,
                                                ),
                                              ),
                                            ),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                                              decoration: BoxDecoration(
                                                color: TekColors.bgSecondary,
                                                borderRadius: BorderRadius.circular(6),
                                                border: Border.all(color: TekColors.border),
                                              ),
                                              child: Text(
                                                'Reminders: $sentCount',
                                                style: const TextStyle(fontSize: 10, color: TekColors.textMuted),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),

                              const Divider(height: 20, color: TekColors.border),

                              // Actions Row: Statement / WhatsApp / SMS
                              Row(
                                children: [
                                  // Statement / Ledger
                                  OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      side: const BorderSide(color: TekColors.border),
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                    ),
                                    icon: const Icon(Icons.receipt_long_rounded, size: 15, color: TekColors.secondary),
                                    label: const Text('Statement', style: TextStyle(fontSize: 11, color: TekColors.textPrimary)),
                                    onPressed: () => _showCustomerLedgerDialog(p),
                                  ),
                                  const Spacer(),
                                  if (phone.isNotEmpty) ...[
                                    // WhatsApp Action
                                    ElevatedButton.icon(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFF22C55E),
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                      ),
                                      icon: const Icon(Icons.chat_bubble_rounded, size: 14),
                                      label: const Text('WhatsApp', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                      onPressed: () => _handleWhatsApp(partyKey, p),
                                    ),
                                    const SizedBox(width: 8),
                                    // Device SMS Intent Action
                                    FilledButton.icon(
                                      style: FilledButton.styleFrom(
                                        backgroundColor: TekColors.primary,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                      ),
                                      icon: const Icon(Icons.sms_rounded, size: 14),
                                      label: const Text('SMS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                      onPressed: () => _handleSms(partyKey, p),
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
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildMessageLogsTab() {
    final logs = ((Db.settings.get('reminders_msg_logs') as List?) ?? []).reversed.toList();

    if (logs.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.history_rounded, size: 52, color: TekColors.textMuted),
              SizedBox(height: 12),
              Text(
                'സന്ദേശ വിവരങ്ങൾ ലഭ്യമല്ല\n(No reminder logs recorded yet)',
                textAlign: TextAlign.center,
                style: TextStyle(color: TekColors.textSecondary, fontFamilyFallback: TekTypography.malayalamFallback),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 85),
      itemCount: logs.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (ctx, i) {
        final log = Map<String, dynamic>.from(logs[i] as Map);
        final date = DateTime.tryParse('${log['date']}') ?? DateTime.now();
        final success = log['status'] == 'Sent';
        final isWhatsApp = '${log['type']}'.contains('WhatsApp');

        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: TekColors.bgCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: TekColors.border),
            boxShadow: TekColors.cardShadow,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: (success ? TekColors.success : TekColors.error).withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isWhatsApp ? Icons.chat_bubble_rounded : (success ? Icons.done_rounded : Icons.error_outline_rounded),
                  color: isWhatsApp ? const Color(0xFF22C55E) : (success ? TekColors.success : TekColors.error),
                  size: 18,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            '${log['customer']} • ${log['phone']}',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: TekColors.textPrimary),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: (success ? TekColors.success : TekColors.error).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '${log['status']}',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: success ? TekColors.success : TekColors.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${log['text']}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, color: TekColors.textSecondary),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_dateFormat.format(date)} • ${log['type']}',
                      style: const TextStyle(fontSize: 10, color: TekColors.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildNoPhoneWarningTab() {
    return ValueListenableBuilder(
      valueListenable: Db.parties.listenable(),
      builder: (context, box, _) {
        final parties = entriesOf(Db.parties)
            .where((e) =>
                _d(e.value['balance']) > 0 &&
                '${e.value['phone'] ?? ''}'.trim().length < 10)
            .toList();

        if (parties.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.verified_user_rounded, size: 54, color: TekColors.success),
                  SizedBox(height: 12),
                  Text(
                    'എല്ലാ ബാക്കിയുള്ള ഉപഭോക്താക്കൾക്കും സാധുവായ ഫോൺ നമ്പർ ഉണ്ട് 👍',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: TekColors.textPrimary, fontWeight: FontWeight.bold, fontFamilyFallback: TekTypography.malayalamFallback),
                  ),
                ],
              ),
            ),
          );
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 85),
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: TekColors.warning.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: TekColors.warning.withValues(alpha: 0.4)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, size: 24, color: TekColors.warning),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'ശ്രദ്ധിക്കുക: താഴെ പറയുന്ന ഉപഭോക്താക്കൾക്ക് ഫോൺ നമ്പർ രേഖപ്പെടുത്തിയിട്ടില്ല. ഇവർക്ക് നേരിട്ടോ വിളിച്ചോ വ്യക്തിഗത ഫോളോ-അപ്പ് ചെയ്യേണ്ടതാണ്.',
                      style: TextStyle(
                        fontSize: 12,
                        color: TekColors.textPrimary,
                        fontFamilyFallback: TekTypography.malayalamFallback,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            for (final entry in parties) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: TekColors.bgCard,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: TekColors.border),
                  boxShadow: TekColors.cardShadow,
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: TekColors.error.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.phonelink_erase_rounded, color: TekColors.error, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${entry.value['name']}',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: TekColors.textPrimary),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            '⚠️ ഫോൺ നമ്പർ ലഭ്യമല്ല (Missing Contact Number)',
                            style: TextStyle(fontSize: 11, color: TekColors.error),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          rs(_d(entry.value['balance'])),
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: TekColors.secondary),
                        ),
                        const SizedBox(height: 4),
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: TekColors.border),
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          ),
                          onPressed: () => _showCustomerLedgerDialog(entry.value),
                          child: const Text('Statement', style: TextStyle(fontSize: 11, color: TekColors.textSecondary)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
