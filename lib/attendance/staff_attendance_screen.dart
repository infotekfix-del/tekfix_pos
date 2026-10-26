import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../auth/auth_controller.dart';
import '../main.dart' show Db, toast, ServicesView;
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
          backgroundColor: const Color(0xFF1E293B),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          icon: const Icon(Icons.location_on_rounded, size: 48, color: Color(0xFF38BDF8)),
          title: const Text(
            'ലൊക്കേഷൻ അനുമതി (Location Consent)',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: const Text(
            'നിങ്ങൾ ചെക്ക്-ഇൻ / ചെക്ക്-ഔട്ട് ചെയ്യുന്ന സമയത്ത് മാത്രം നിങ്ങളുടെ സാന്നിധ്യം ഉറപ്പുവരുത്താനായി ലൊക്കേഷൻ ശേഖരിക്കുന്നതാണ്. ആപ്പ് ഉപയോഗിക്കാത്ത സമയത്തോ തുടർച്ചയായോ ലൊക്കേഷൻ ട്രാക്ക് ചെയ്യില്ല.\n\n'
            '(Location is captured ONLY when you tap Check-in or Check-out to verify your attendance. Continuous tracking is NEVER done).',
            style: TextStyle(fontSize: 13.5, height: 1.4, color: Colors.white70),
          ),
          actions: [
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
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
      HapticFeedback.lightImpact();
      toast(context, 'ഇന്നത്തെ ഡ്യൂട്ടി ഇതിനകം അവസാനിപ്പിച്ചു (Completed for today)');
      return;
    }

    if (isCheckedIn) {
      HapticFeedback.heavyImpact();
      // Check-out Flow: First verify hours, then Cash Register
      final worked = DateTime.now().difference(record.checkIn!).inMinutes / 60.0;
      final shift = AttendanceService.instance.getShiftConfig();

      if (worked < shift.halfDayThresholdHours) {
        final confirmShort = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            icon: const Icon(Icons.warning_amber_rounded, size: 40, color: Colors.orange),
            title: const Text(
              'കുറഞ്ഞ ജോലി സമയം (Short Duty)',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            content: Text(
              'നിങ്ങൾ ${worked.toStringAsFixed(1)} മണിക്കൂർ മാത്രമേ ജോലി ചെയ്തിട്ടുള്ളൂ (കുറഞ്ഞത് ${shift.halfDayThresholdHours} മണിക്കൂർ വേണം).\n\nഡ്യൂട്ടി അവസാനിപ്പിക്കാൻ ഉറപ്പാണോ?',
              style: const TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('തുടരുക (Cancel)', style: TextStyle(color: Colors.white70)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.orange.shade700),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('ചെക്ക്-ഔട്ട് ചെയ്യുക'),
              ),
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
            backgroundColor: const Color(0xFF4F46E5),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      } catch (e) {
        if (mounted) _showErrorDialog(e);
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    } else {
      // Check-in Flow
      HapticFeedback.mediumImpact();
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
            backgroundColor: const Color(0xFF10B981),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
            backgroundColor: const Color(0xFF1E293B),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            icon: const Icon(Icons.point_of_sale_rounded, size: 40, color: Color(0xFF38BDF8)),
            title: const Text(
              TekStrings.cashRegisterTitle,
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    TekStrings.cashRegisterDesc,
                    style: TextStyle(fontSize: 12.5, color: Colors.white70),
                  ),
                  const SizedBox(height: 14),

                  // Shift sales summary table
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF334155)),
                    ),
                    child: Column(
                      children: [
                        _summaryRow('ബില്ലുകളുടെ എണ്ണം (Bills)', '$billCount'),
                        _summaryRow('ക്യാഷ് വിൽപ്പന (Cash Sales)', '₹${expectedCash.toStringAsFixed(2)}'),
                        _summaryRow('UPI / QR വിൽപ്പന', '₹${upi.toStringAsFixed(2)}'),
                        if (card > 0) _summaryRow('കാർഡ് വിൽപ്പന', '₹${card.toStringAsFixed(2)}'),
                        const Divider(height: 14, color: Color(0xFF334155)),
                        _summaryRow('ആകെ വിൽപ്പന (Shift Total)', '₹${grandTotal.toStringAsFixed(2)}', isBold: true),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  TextField(
                    controller: cashCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                    onChanged: (_) => setD(() {}),
                    decoration: InputDecoration(
                      labelText: TekStrings.labelClosingCash,
                      labelStyle: const TextStyle(color: Colors.white70),
                      prefixText: '₹ ',
                      prefixStyle: const TextStyle(color: Color(0xFF38BDF8), fontWeight: FontWeight.bold),
                      hintText: 'എണ്ണി തിട്ടപ്പെടുത്തിയ ക്യാഷ്',
                      filled: true,
                      fillColor: const Color(0xFF0F172A),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFF334155)),
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: mismatch ? Colors.red.withValues(alpha: 0.15) : Colors.green.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: mismatch ? Colors.red.shade400 : Colors.green.shade400,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          mismatch ? Icons.warning_amber_rounded : Icons.check_circle_outline,
                          size: 20,
                          color: mismatch ? Colors.red.shade300 : Colors.green.shade300,
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
                              color: mismatch ? Colors.red.shade200 : Colors.green.shade200,
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
                child: const Text('റദ്ദാക്കുക (Cancel)', style: TextStyle(color: Colors.white70)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF2563EB),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
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
      padding: const EdgeInsets.symmetric(vertical: 2.5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: isBold ? Colors.white : Colors.white70,
              fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 12.5,
              color: isBold ? const Color(0xFF38BDF8) : Colors.white,
              fontWeight: isBold ? FontWeight.bold : FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  void _showErrorDialog(dynamic e) {
    final err = e.toString().replaceFirst('Exception: ', '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        icon: const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 40),
        title: const Text('ശ്രദ്ധിക്കുക (Attention)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Text(err, style: const TextStyle(color: Colors.white70)),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF2563EB)),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('ശരി (OK)'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
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
      bottomNavigationBar: _buildFloatingBottomNav(),
    );
  }

  // Modern Floating Bottom Navigation Bar with Active Pill Indicator & Micro-animations
  Widget _buildFloatingBottomNav() {
    final navItems = [
      (Icons.how_to_reg_rounded, TekStrings.tabAttendance),
      (Icons.build_circle_rounded, TekStrings.tabRepairs),
      (Icons.notifications_active_rounded, TekStrings.tabAlerts),
      (Icons.point_of_sale_rounded, TekStrings.tabPos),
      (Icons.shopping_bag_rounded, 'Orders'),
    ];

    return Container(
      color: Colors.transparent,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Container(
        height: 66,
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B).withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFF334155), width: 1.2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: List.generate(navItems.length, (idx) {
            final isSelected = _activeTab == idx;
            final (icon, label) = navItems[idx];

            return Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => _activeTab = idx);
                },
                child: Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOutCubic,
                    padding: EdgeInsets.symmetric(
                      horizontal: isSelected ? 12 : 8,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      gradient: isSelected
                          ? const LinearGradient(
                              colors: [Color(0xFF2563EB), Color(0xFF1D4ED8)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            )
                          : null,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: isSelected
                          ? [
                              BoxShadow(
                                color: const Color(0xFF2563EB).withValues(alpha: 0.4),
                                blurRadius: 10,
                                offset: const Offset(0, 3),
                              )
                            ]
                          : null,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          icon,
                          size: 22,
                          color: isSelected ? Colors.white : Colors.white60,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                            color: isSelected ? Colors.white : Colors.white60,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildAttendanceScaffold(BuildContext context) {
    final now = DateTime.now();
    final shift = AttendanceService.instance.getShiftConfig();

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: SafeArea(
        child: StreamBuilder<AttendanceRecord?>(
          stream: AttendanceService.instance.streamTodayAttendance(widget.shopId, widget.staffId),
          builder: (context, snapshot) {
            final record = snapshot.data ?? AttendanceService.instance.getCachedTodayAttendance(widget.staffId);
            final isCheckedIn = record?.checkIn != null;
            final isCheckedOut = record?.checkOut != null;

            return SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 1. Modern Top Profile Card & Header
                    _buildModernHeaderCard(record, isCheckedIn, isCheckedOut, shift),
                    const SizedBox(height: 16),

                    // Date Pill Header
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B).withValues(alpha: 0.8),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xFF334155)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.calendar_today_rounded, size: 14, color: Color(0xFF38BDF8)),
                            const SizedBox(width: 8),
                            Text(
                              _dateFormat.format(now),
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: Colors.white70,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // 2. Work & Duty Overview Card
                    _buildDutyOverviewCard(record, isCheckedIn, isCheckedOut, shift),
                    const SizedBox(height: 20),

                    // 3. Redesigned Primary Actions (Curved Interactive Action Card)
                    _buildPrimaryActionCard(record, isCheckedIn, isCheckedOut),
                    const SizedBox(height: 24),

                    // 4. Quick Access Grid (Industry-Standard Dashboard)
                    _buildQuickAccessGrid(isCheckedIn, isCheckedOut),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // 1. Modern Profile Card Header with Status Chip & Avatar
  Widget _buildModernHeaderCard(
    AttendanceRecord? record,
    bool isCheckedIn,
    bool isCheckedOut,
    ShiftConfig shift,
  ) {
    final staffInitials = widget.staffName.isNotEmpty
        ? widget.staffName.trim().split(' ').map((w) => w.isNotEmpty ? w[0] : '').take(2).join().toUpperCase()
        : 'ST';

    // Status state
    final statusColor = isCheckedOut
        ? Colors.blueGrey
        : (isCheckedIn ? const Color(0xFF10B981) : const Color(0xFFF59E0B));
    final statusLabel = isCheckedOut
        ? 'Shift Ended'
        : (isCheckedIn ? 'Active • On Duty' : 'Not Punched In');

    // Shift timing label
    final shiftStartStr = '${shift.startHour > 12 ? shift.startHour - 12 : shift.startHour}:${shift.startMinute.toString().padLeft(2, '0')} ${shift.startHour >= 12 ? 'PM' : 'AM'}';
    final shiftEndStr = '${shift.endHour > 12 ? shift.endHour - 12 : shift.endHour}:${shift.endMinute.toString().padLeft(2, '0')} ${shift.endHour >= 12 ? 'PM' : 'AM'}';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF334155), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              // Avatar with glowing gradient ring
              Container(
                padding: const EdgeInsets.all(2.5),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: isCheckedIn && !isCheckedOut
                        ? [const Color(0xFF10B981), const Color(0xFF38BDF8)]
                        : [const Color(0xFF64748B), const Color(0xFF334155)],
                  ),
                ),
                child: CircleAvatar(
                  radius: 26,
                  backgroundColor: const Color(0xFF0F172A),
                  child: Text(
                    staffInitials,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),

              // Staff details & Shop badge
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.staffName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFF2563EB).withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: const Color(0xFF3B82F6).withValues(alpha: 0.4)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.storefront_rounded, size: 12, color: Color(0xFF60A5FA)),
                              const SizedBox(width: 4),
                              Text(
                                widget.shopId.toUpperCase(),
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF93C5FD),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          '• Staff Portal',
                          style: TextStyle(fontSize: 11.5, color: Colors.white54),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Action buttons: App Update & Sign Out
              IconButton(
                tooltip: 'Check Updates',
                icon: const Icon(Icons.system_update_rounded, color: Color(0xFF38BDF8), size: 22),
                onPressed: () => AppUpdateService.instance.checkForUpdate(
                  context,
                  autoShowDialog: true,
                  showToastIfLatest: true,
                ),
              ),
              IconButton(
                tooltip: 'Sign Out (ലോഗൗട്ട്)',
                icon: const Icon(Icons.logout_rounded, color: Color(0xFFEF4444), size: 22),
                onPressed: () => _confirmSignOut(context),
              ),
            ],
          ),

          const Divider(height: 20, color: Color(0xFF334155)),

          // Secondary row: Shift Duration & Animated Status Chip
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Shift duration label
              Row(
                children: [
                  const Icon(Icons.schedule_rounded, size: 15, color: Colors.white60),
                  const SizedBox(width: 6),
                  Text(
                    'Shift: $shiftStartStr - $shiftEndStr',
                    style: const TextStyle(fontSize: 11.5, color: Colors.white70),
                  ),
                ],
              ),

              // Animated Pulsing Status Chip
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: statusColor.withValues(alpha: 0.5)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Pulsing Dot
                    _buildPulsingDot(statusColor, isCheckedIn && !isCheckedOut),
                    const SizedBox(width: 6),
                    Text(
                      statusLabel,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: statusColor,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPulsingDot(Color color, bool isActive) {
    if (!isActive) {
      return Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
    }
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.7, end: 1.0),
      duration: const Duration(milliseconds: 1000),
      curve: Curves.easeInOut,
      builder: (context, val, child) {
        return Container(
          width: 8 * val,
          height: 8 * val,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.8),
                blurRadius: 6 * val,
                spreadRadius: 1 * val,
              ),
            ],
          ),
        );
      },
    );
  }

  // 2. Work & Duty Overview Card with 4 Clean Metric Tiles
  Widget _buildDutyOverviewCard(
    AttendanceRecord? record,
    bool isCheckedIn,
    bool isCheckedOut,
    ShiftConfig shift,
  ) {
    final double worked = isCheckedIn && record?.checkIn != null
        ? (isCheckedOut
            ? record!.workedHours
            : DateTime.now().difference(record!.checkIn!).inMinutes / 60.0)
        : 0.0;

    final hours = worked.floor();
    final minutes = ((worked - hours) * 60).round();
    final timerDisplay = isCheckedIn
        ? '${hours.toString().padLeft(2, '0')}h ${minutes.toString().padLeft(2, '0')}m'
        : '-- : --';

    final checkInDisplay = isCheckedIn && record?.checkIn != null
        ? _timeFormat.format(record!.checkIn!)
        : 'Not started';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF334155), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Card Title
          const Row(
            children: [
              Icon(Icons.dashboard_customize_rounded, size: 18, color: Color(0xFF38BDF8)),
              SizedBox(width: 8),
              Text(
                'Work & Shift Overview (ഡ്യൂട്ടി വിവരങ്ങൾ)',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // 2x2 Metric Grid
          Row(
            children: [
              // Metric 1: Live Working Timer
              Expanded(
                child: _buildMetricTile(
                  icon: Icons.timer_rounded,
                  iconColor: const Color(0xFF10B981),
                  title: 'Working Time',
                  value: timerDisplay,
                  subtitle: isCheckedOut ? 'Final Duration' : (isCheckedIn ? 'Live Active' : 'Offline'),
                  highlight: isCheckedIn && !isCheckedOut,
                ),
              ),
              const SizedBox(width: 10),
              // Metric 2: Shift Target
              Expanded(
                child: _buildMetricTile(
                  icon: Icons.flag_rounded,
                  iconColor: const Color(0xFF8B5CF6),
                  title: 'Shift Target',
                  value: '${shift.fullShiftHours.toStringAsFixed(1)} hrs',
                  subtitle: 'Min ${shift.halfDayThresholdHours}h required',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              // Metric 3: Check-in Time
              Expanded(
                child: _buildMetricTile(
                  icon: Icons.login_rounded,
                  iconColor: const Color(0xFF38BDF8),
                  title: 'Punch-in Time',
                  value: checkInDisplay,
                  subtitle: isCheckedIn ? 'Recorded at counter' : 'Waiting check-in',
                ),
              ),
              const SizedBox(width: 10),
              // Metric 4: Owner Approval Status
              Expanded(
                child: _buildApprovalTile(record),
              ),
            ],
          ),

          // Late Arrival Banner
          if (record != null && record.isLate) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, size: 18, color: Colors.orange),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'സമയപരിധി കഴിഞ്ഞുള്ള വരവ് (Late Arrival Recorded)',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.bold,
                        color: Colors.orangeAccent,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMetricTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String value,
    required String subtitle,
    bool highlight = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: highlight ? iconColor.withValues(alpha: 0.4) : const Color(0xFF334155),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: iconColor),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Colors.white60),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: highlight ? iconColor : Colors.white,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: Colors.white38),
          ),
        ],
      ),
    );
  }

  Widget _buildApprovalTile(AttendanceRecord? r) {
    String label;
    Color color;
    IconData icon;

    if (r == null || r.checkIn == null) {
      label = 'Not Logged';
      color = Colors.grey;
      icon = Icons.radio_button_unchecked_rounded;
    } else if (r.isApproved) {
      label = TekStrings.badgeApproved;
      color = const Color(0xFF10B981);
      icon = Icons.verified_rounded;
    } else if (r.isRejected) {
      label = TekStrings.badgeRejected;
      color = const Color(0xFFEF4444);
      icon = Icons.cancel_rounded;
    } else if (r.isAdjusted) {
      label = TekStrings.badgeAdjusted;
      color = const Color(0xFFA855F7);
      icon = Icons.edit_note_rounded;
    } else {
      label = TekStrings.badgePendingApproval;
      color = const Color(0xFFF59E0B);
      icon = Icons.hourglass_top_rounded;
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.shield_outlined, size: 16, color: Color(0xFF60A5FA)),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Owner Approval',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: Colors.white60),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          const Text(
            'Admin verified',
            style: TextStyle(fontSize: 10, color: Colors.white38),
          ),
        ],
      ),
    );
  }

  // 3. Modern Curved Elevated Primary Action Button
  Widget _buildPrimaryActionCard(
    AttendanceRecord? record,
    bool isCheckedIn,
    bool isCheckedOut,
  ) {
    if (isCheckedOut) {
      // Shift Completed Summary Card
      return Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.5), width: 1.2),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF10B981).withValues(alpha: 0.15),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.task_alt_rounded, color: Color(0xFF10B981), size: 28),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'ഇന്നത്തെ ഡ്യൂട്ടി പൂർത്തിയായി!',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Worked: ${record?.workedHours.toStringAsFixed(1) ?? "0"} hrs • Cash register reconciled',
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    if (isCheckedIn) {
      // Check-out Button with Warm Amber/Deep-Orange Glow
      return GestureDetector(
        onTap: _loading ? null : () => _handleTap(record),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFF59E0B), Color(0xFFEA580C), Color(0xFFDC2626)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFEA580C).withValues(alpha: 0.4),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: _loading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                      )
                    : const Icon(Icons.point_of_sale_rounded, color: Colors.white, size: 26),
              ),
              const SizedBox(width: 16),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Check-out & Close Register',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'ക്യാഷ് എണ്ണി തിട്ടപ്പെടുത്തി ഡ്യൂട്ടി അവസാനിപ്പിക്കുക',
                      style: TextStyle(fontSize: 11.5, color: Colors.white70),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios_rounded, color: Colors.white70, size: 18),
            ],
          ),
        ),
      );
    }

    // Check-in Button with Vibrant Emerald/Teal Glow
    return GestureDetector(
      onTap: _loading ? null : () => _handleTap(record),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF10B981), Color(0xFF059669), Color(0xFF047857)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF10B981).withValues(alpha: 0.4),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: _loading
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                    )
                  : const Icon(Icons.fingerprint_rounded, color: Colors.white, size: 28),
            ),
            const SizedBox(width: 16),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Tap to Check-in & Unlock POS',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'ഹാജർ രേഖപ്പെടുത്തി സെയിൽസ് അൺലോക്ക് ചെയ്യുക',
                    style: TextStyle(fontSize: 11.5, color: Colors.white70),
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios_rounded, color: Colors.white70, size: 18),
          ],
        ),
      ),
    );
  }

  // 4. Quick Access Grid (Industry-Standard Dashboard)
  Widget _buildQuickAccessGrid(bool isCheckedIn, bool isCheckedOut) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.bolt_rounded, size: 18, color: Color(0xFFF59E0B)),
            SizedBox(width: 8),
            Text(
              'Quick Access & Actions (ദ്രുത സേവനങ്ങൾ)',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // 2x2 Grid of Rounded Action Cards
        Row(
          children: [
            // Card 1: Quick Sale / POS
            Expanded(
              child: _buildQuickCard(
                icon: Icons.point_of_sale_rounded,
                iconGradient: const [Color(0xFF3B82F6), Color(0xFF1D4ED8)],
                title: 'Quick Sale / POS',
                subtitle: 'New bill & barcode sale',
                badgeText: 'Instant',
                onTap: () {
                  HapticFeedback.lightImpact();
                  setState(() => _activeTab = 3);
                },
              ),
            ),
            const SizedBox(width: 12),
            // Card 2: Create Repair Ticket
            Expanded(
              child: _buildQuickCard(
                icon: Icons.build_circle_rounded,
                iconGradient: const [Color(0xFF8B5CF6), Color(0xFF6D28D9)],
                title: 'Repair Ticket',
                subtitle: 'Customer device intake',
                badgeText: 'Repairs',
                onTap: () {
                  HapticFeedback.lightImpact();
                  setState(() => _activeTab = 1);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            // Card 3: Stock Check & Orders
            Expanded(
              child: _buildQuickCard(
                icon: Icons.inventory_2_rounded,
                iconGradient: const [Color(0xFF10B981), Color(0xFF0F766E)],
                title: 'Stock & Orders',
                subtitle: 'Spare parts & accessories',
                badgeText: 'Catalog',
                onTap: () {
                  HapticFeedback.lightImpact();
                  setState(() => _activeTab = 4);
                },
              ),
            ),
            const SizedBox(width: 12),
            // Card 4: WhatsApp Dispatch & Dues
            Expanded(
              child: _buildQuickCard(
                icon: Icons.mark_chat_unread_rounded,
                iconGradient: const [Color(0xFF25D366), Color(0xFF128C7E)],
                title: 'WhatsApp & Dues',
                subtitle: 'Ready alerts & follow-ups',
                badgeText: 'Dispatch',
                onTap: () {
                  HapticFeedback.lightImpact();
                  setState(() => _activeTab = 2);
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildQuickCard({
    required IconData icon,
    required List<Color> iconGradient,
    required String title,
    required String subtitle,
    required String badgeText,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF334155)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: iconGradient),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: Colors.white, size: 20),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: iconGradient.first.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    badgeText,
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.bold,
                      color: iconGradient.first,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10.5, color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmSignOut(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('ലോഗൗട്ട് ചെയ്യണോ?', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: const Text('നിങ്ങൾ അക്കൗണ്ടിൽ നിന്ന് പുറത്തുകടക്കണോ?', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('വേണ്ട', style: TextStyle(color: Colors.white70)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('ലോഗൗട്ട്'),
          ),
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
  }
}
