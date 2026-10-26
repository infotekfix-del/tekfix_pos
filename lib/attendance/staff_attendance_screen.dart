import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../auth/auth_controller.dart';
import '../main.dart' show Db, kPrimary, toast, ServicesView;
import '../orders/staff_orders_screen.dart';
import '../pos/staff_pos_screen.dart';
import '../reminders/reminders_screen.dart';
import '../shared/tek_pos_strings.dart';
import '../update/app_update_service.dart';
import 'attendance_models.dart';
import 'attendance_service.dart';

class StaffAttendanceScreen extends StatefulWidget {
  final String shopId;
  final String staffId;
  final String staffName;
  final VoidCallback? onSignOut;

  const StaffAttendanceScreen({
    super.key,
    required this.shopId,
    required this.staffId,
    required this.staffName,
    this.onSignOut,
  });

  @override
  State<StaffAttendanceScreen> createState() => _StaffAttendanceScreenState();
}

class _StaffAttendanceScreenState extends State<StaffAttendanceScreen> {
  int _activeTab = 0;
  bool _loading = false;
  final _timeFormat = DateFormat('hh:mm a');
  final _dateFormat = DateFormat('EEEE, dd MMMM yyyy');
  Timer? _liveTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkLocationConsent();
      AttendanceService.instance.syncOfflineQueue();
      AppUpdateService.instance.checkForUpdate(context, autoShowDialog: true);
    });

    // Update worked hours counter every minute
    _liveTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    super.dispose();
  }

  void _checkLocationConsent() {
    final consented = Db.setting('location_consent_given', 'false') == 'true';
    if (!consented) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.location_on_rounded, size: 48, color: kPrimary),
          title: const Text('ലൊക്കേഷൻ അനുമതി (Location Consent)'),
          content: const Text(
            'നിങ്ങൾ ചെക്ക്-ഇൻ / ചെക്ക്-ഔട്ട് ചെയ്യുന്ന സമയത്ത് മാത്രം നിങ്ങളുടെ സാന്നിധ്യം ഉറപ്പുവരുത്താനായി ലൊക്കേഷൻ ശേഖരിക്കുന്നതാണ്. ആപ്പ് ഉപയോഗിക്കാത്ത സമയത്തോ തുടർച്ചയായോ ലൊക്കേഷൻ ട്രാക്ക് ചെയ്യില്ല.\n\n'
            '(Location is captured ONLY when you tap Check-in or Check-out to verify your attendance. Continuous tracking is NEVER done).',
            style: TextStyle(fontSize: 13.5, height: 1.4),
          ),
          actions: [
            FilledButton(
              onPressed: () async {
                await Db.settings.put('location_consent_given', 'true');
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('സമ്മതിക്കുന്നു (I Agree)'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _handleTap(AttendanceRecord? record) async {
    if (_loading) return;

    final isCheckedIn = record != null && record.checkIn != null;
    final isCheckedOut = record != null && record.checkOut != null;

    if (isCheckedOut) {
      toast(context, 'ഇന്നത്തെ ഡ്യൂട്ടി ഇതിനകം അവസാനിപ്പിച്ചു (Completed for today)');
      return;
    }

    if (isCheckedIn) {
      // Check-out Flow: First verify hours, then Cash Register
      final worked = DateTime.now().difference(record.checkIn!).inMinutes / 60.0;
      final shift = AttendanceService.instance.getShiftConfig();

      if (worked < shift.halfDayThresholdHours) {
        final confirmShort = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            icon: const Icon(Icons.warning_amber_rounded, size: 40, color: Colors.orange),
            title: const Text('കുറഞ്ഞ ജോലി സമയം (Short Duty)'),
            content: Text(
              'നിങ്ങൾ ${worked.toStringAsFixed(1)} മണിക്കൂർ മാത്രമേ ജോലി ചെയ്തിട്ടുള്ളൂ (കുറഞ്ഞത് ${shift.halfDayThresholdHours} മണിക്കൂർ വേണം).\n\nഡ്യൂട്ടി അവസാനിപ്പിക്കാൻ ഉറപ്പാണോ?',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('തുടരുക (Cancel)')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ചെക്ക്-ഔട്ട് ചെയ്യുക')),
            ],
          ),
        );
        if (confirmShort != true) return;
      }

      // Show Shift-End Cash Register Dialog
      final countedCash = await _showCashRegisterDialog(record);
      if (countedCash == null) return; // User cancelled

      setState(() => _loading = true);
      try {
        final res = await AttendanceService.instance.recordAttendance(
          shopId: widget.shopId,
          staffId: widget.staffId,
          staffName: widget.staffName,
          closingCashInDrawer: countedCash,
        );

        if (!mounted) return;
        final timeStr = _timeFormat.format(DateTime.now());
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('ഡ്യൂട്ടി അവസാനിപ്പിച്ചു ($timeStr) - ${res.record.dutyStage}'),
            backgroundColor: Colors.indigo.shade700,
          ),
        );
      } catch (e) {
        if (mounted) _showErrorDialog(e);
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    } else {
      // Check-in Flow
      setState(() => _loading = true);
      try {
        await AttendanceService.instance.recordAttendance(
          shopId: widget.shopId,
          staffId: widget.staffId,
          staffName: widget.staffName,
        );

        if (!mounted) return;
        final timeStr = _timeFormat.format(DateTime.now());
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('ചെക്ക്-ഇൻ രേഖപ്പെടുത്തി ($timeStr) - POS അൺലോക്ക് ചെയ്തു'),
            backgroundColor: Colors.green.shade700,
          ),
        );

        // Optimistic access: auto-switch immediately to POS Sales Dashboard!
        setState(() {
          _activeTab = 3;
        });
      } catch (e) {
        if (mounted) _showErrorDialog(e);
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    }
  }

  Future<double?> _showCashRegisterDialog(AttendanceRecord record) async {
    final inTime = record.checkIn ?? DateTime.now();
    final sales = AttendanceService.instance.computeShiftSalesSummary(widget.staffId, inTime);
    final double expectedCash = (sales['cash'] as num?)?.toDouble() ?? 0.0;
    final double upi = (sales['upi'] as num?)?.toDouble() ?? 0.0;
    final double card = (sales['card'] as num?)?.toDouble() ?? 0.0;
    final int billCount = (sales['billCount'] as num?)?.toInt() ?? 0;
    final double grandTotal = (sales['total'] as num?)?.toDouble() ?? 0.0;

    final cashCtrl = TextEditingController(text: expectedCash.toStringAsFixed(0));

    return showDialog<double?>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          final double closingCash = double.tryParse(cashCtrl.text) ?? expectedCash;
          final double diff = closingCash - expectedCash;
          final bool mismatch = diff.abs() > 0.01;

          return AlertDialog(
            icon: const Icon(Icons.point_of_sale_rounded, size: 40, color: kPrimary),
            title: const Text(TekStrings.cashRegisterTitle),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    TekStrings.cashRegisterDesc,
                    style: TextStyle(fontSize: 12.5),
                  ),
                  const SizedBox(height: 14),

                  // Shift sales summary table
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey.withAlpha(20),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      children: [
                        _summaryRow('ബില്ലുകളുടെ എണ്ണം (Bills)', '$billCount'),
                        _summaryRow('ക്യാഷ് വിൽപ്പന (Cash Sales)', '₹${expectedCash.toStringAsFixed(2)}'),
                        _summaryRow('UPI / QR വിൽപ്പന', '₹${upi.toStringAsFixed(2)}'),
                        if (card > 0) _summaryRow('കാർഡ് വിൽപ്പന', '₹${card.toStringAsFixed(2)}'),
                        const Divider(height: 12),
                        _summaryRow('ആകെ വിൽപ്പന (Shift Total)', '₹${grandTotal.toStringAsFixed(2)}', isBold: true),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  TextField(
                    controller: cashCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setD(() {}),
                    decoration: const InputDecoration(
                      labelText: TekStrings.labelClosingCash,
                      prefixText: '₹ ',
                      hintText: 'എണ്ണി തിട്ടപ്പെടുത്തിയ ക്യാഷ്',
                    ),
                  ),

                  const SizedBox(height: 12),

                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: mismatch ? Colors.red.shade50 : Colors.green.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: mismatch ? Colors.red.shade300 : Colors.green.shade300,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          mismatch ? Icons.warning_amber_rounded : Icons.check_circle_outline,
                          size: 20,
                          color: mismatch ? Colors.red : Colors.green,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            mismatch
                                ? 'വ്യത്യാസം: ₹${diff.toStringAsFixed(2)} (${TekStrings.labelMismatch})'
                                : TekStrings.labelMatched,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: mismatch ? Colors.red.shade900 : Colors.green.shade900,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('റദ്ദാക്കുക (Cancel)'),
              ),
              FilledButton(
                onPressed: () {
                  final entered = double.tryParse(cashCtrl.text) ?? expectedCash;
                  Navigator.pop(ctx, entered);
                },
                child: const Text(TekStrings.btnConfirmCheckOut),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _summaryRow(String label, String value, {bool isBold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: 12, fontWeight: isBold ? FontWeight.bold : FontWeight.normal)),
          Text(value, style: TextStyle(fontSize: 12, fontWeight: isBold ? FontWeight.bold : FontWeight.normal)),
        ],
      ),
    );
  }

  void _showErrorDialog(dynamic e) {
    final err = e.toString().replaceFirst('Exception: ', '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.error_outline_rounded, color: Colors.red, size: 40),
        title: const Text('ശ്രദ്ധിക്കുക (Attention)'),
        content: Text(err),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ശരി (OK)')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _activeTab,
        children: [
          _buildAttendanceScaffold(context),
          const ServicesView(initialFilter: 'Active'),
          const RemindersScreen(),
          StaffPosScreen(
            shopId: widget.shopId,
            staffId: widget.staffId,
            staffName: widget.staffName,
            onNavigateToAttendance: () => setState(() => _activeTab = 0),
          ),
          StaffOrdersScreen(
            shopId: widget.shopId,
            staffId: widget.staffId,
            staffName: widget.staffName,
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _activeTab,
        onDestinationSelected: (idx) => setState(() => _activeTab = idx),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.how_to_reg_outlined),
            selectedIcon: Icon(Icons.how_to_reg_rounded),
            label: TekStrings.tabAttendance,
          ),
          NavigationDestination(
            icon: Icon(Icons.build_circle_outlined),
            selectedIcon: Icon(Icons.build_circle_rounded),
            label: TekStrings.tabRepairs,
          ),
          NavigationDestination(
            icon: Icon(Icons.notifications_active_outlined),
            selectedIcon: Icon(Icons.notifications_active_rounded),
            label: TekStrings.tabAlerts,
          ),
          NavigationDestination(
            icon: Icon(Icons.point_of_sale_outlined),
            selectedIcon: Icon(Icons.point_of_sale_rounded),
            label: TekStrings.tabPos,
          ),
          NavigationDestination(
            icon: Icon(Icons.shopping_bag_outlined),
            selectedIcon: Icon(Icons.shopping_bag_rounded),
            label: 'Orders (ഓർഡറുകൾ)',
          ),
        ],
      ),
    );
  }

  Widget _buildAttendanceScaffold(BuildContext context) {
    final now = DateTime.now();
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.staffName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            Text('Shop: ${widget.shopId.toUpperCase()} • Staff Portal', style: const TextStyle(fontSize: 12, color: Colors.white70)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Check for Updates (അപ്ഡേറ്റ് പരിശോധിക്കുക)',
            icon: const Icon(Icons.system_update_rounded),
            onPressed: () => AppUpdateService.instance.checkForUpdate(
              context,
              autoShowDialog: true,
              showToastIfLatest: true,
            ),
          ),
          IconButton(
            tooltip: 'Sign Out (ലോഗൗട്ട്)',
            icon: const Icon(Icons.logout_rounded),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('ലോഗൗട്ട് ചെയ്യണോ?'),
                  content: const Text('നിങ്ങൾ അക്കൗണ്ടിൽ നിന്ന് പുറത്തുകടക്കണോ?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('വേണ്ട')),
                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ലോഗൗട്ട്')),
                  ],
                ),
              );
              if (ok == true) {
                await Db.settings.put('staff_logged_in', false);
                await Db.settings.put('staff_logged_id', '');
                await Db.settings.put('staff_logged_name', '');
                await AuthController.instance.signOut();
                if (widget.onSignOut != null) widget.onSignOut!();
              }
            },
          ),
        ],
      ),
      body: StreamBuilder<AttendanceRecord?>(
        stream: AttendanceService.instance.streamTodayAttendance(widget.shopId, widget.staffId),
        builder: (context, snapshot) {
          final record = snapshot.data ?? AttendanceService.instance.getCachedTodayAttendance(widget.staffId);
          final isCheckedIn = record?.checkIn != null;
          final isCheckedOut = record?.checkOut != null;

          String statusText;
          Color statusColor;
          IconData buttonIcon;
          String buttonText;

          if (isCheckedOut) {
            statusText = '${record?.dutyStage ?? TekStrings.dutyFull}\nഡ്യൂട്ടി പൂർത്തിയായി';
            statusColor = Colors.blueGrey;
            buttonIcon = Icons.done_all_rounded;
            buttonText = 'ഇന്നത്തെ ഡ്യൂട്ടി പൂർത്തിയായി';
          } else if (isCheckedIn) {
            final worked = record!.checkIn != null
                ? DateTime.now().difference(record.checkIn!).inMinutes / 60.0
                : 0.0;
            statusText = 'ഹാജർ രേഖപ്പെടുത്തി (Present)\nജോലി ചെയ്ത സമയം: ${worked.toStringAsFixed(1)} മണിക്കൂർ';
            statusColor = Colors.green;
            buttonIcon = Icons.logout_rounded;
            buttonText = 'Check-out & Cash Register';
          } else {
            statusText = 'ഹാജർ രേഖപ്പെടുത്തിയിട്ടില്ല\n(Not Checked In)';
            statusColor = Colors.orange.shade800;
            buttonIcon = Icons.login_rounded;
            buttonText = 'Check-in ചെയ്യുക';
          }

          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _dateFormat.format(now),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Status and Badges Card
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                      decoration: BoxDecoration(
                        color: statusColor.withAlpha(25),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: statusColor.withAlpha(80)),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Icon(
                                isCheckedOut
                                    ? Icons.task_alt_rounded
                                    : (isCheckedIn ? Icons.access_time_filled_rounded : Icons.pending_actions_rounded),
                                color: statusColor,
                                size: 36,
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Text(
                                  statusText,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: statusColor,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (isCheckedIn && record != null) ...[
                            const Divider(height: 16),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                _buildBadgeChip(record),
                                if (record.isLate)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.orange.shade100,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      TekStrings.lateArrival,
                                      style: TextStyle(fontSize: 10, color: Colors.orange.shade900, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),

                    const SizedBox(height: 36),

                    // Big interactive Check-in / Check-out button
                    InkWell(
                      onTap: _loading || isCheckedOut ? null : () => _handleTap(record),
                      borderRadius: BorderRadius.circular(100),
                      child: Container(
                        width: 200,
                        height: 200,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            colors: isCheckedOut
                                ? [Colors.grey.shade400, Colors.grey.shade600]
                                : (isCheckedIn
                                    ? [Colors.orange.shade600, Colors.deepOrange.shade700]
                                    : [Colors.green.shade500, Colors.teal.shade700]),
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: (isCheckedIn ? Colors.orange : Colors.green).withAlpha(80),
                              blurRadius: 20,
                              spreadRadius: 4,
                              offset: const Offset(0, 8),
                            )
                          ],
                        ),
                        child: Center(
                          child: _loading
                              ? const CircularProgressIndicator(color: Colors.white, strokeWidth: 3.5)
                              : Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(buttonIcon, size: 52, color: Colors.white),
                                    const SizedBox(height: 12),
                                    Text(
                                      buttonText,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 28),

                    // Quick switch to POS button if checked in
                    if (isCheckedIn && !isCheckedOut)
                      FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        ),
                        onPressed: () => setState(() => _activeTab = 3),
                        icon: const Icon(Icons.point_of_sale_rounded),
                        label: const Text('സെയിൽസ് / POS തുറക്കുക (Open POS)'),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBadgeChip(AttendanceRecord r) {
    String text;
    Color color;

    if (r.isApproved) {
      text = TekStrings.badgeApproved;
      color = Colors.green;
    } else if (r.isRejected) {
      text = TekStrings.badgeRejected;
      color = Colors.red;
    } else if (r.isAdjusted) {
      text = TekStrings.badgeAdjusted;
      color = Colors.purple;
    } else {
      text = TekStrings.badgePendingApproval;
      color = Colors.amber.shade900;
    }

    return Text(
      text,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color),
    );
  }
}
