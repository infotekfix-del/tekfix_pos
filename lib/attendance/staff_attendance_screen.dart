import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../auth/auth_controller.dart';
import '../main.dart' show Db, toast;
import '../notifications/notification_drawer.dart';
import '../notifications/notification_service.dart';
import '../notifications/staff_notifications_screen.dart';
import '../orders/staff_orders_screen.dart';
import '../pos/staff_pos_screen.dart';
import '../reminders/reminders_screen.dart';
import '../repairs/staff_repairs_screen.dart';
import '../shared/tek_pos_strings.dart';
import '../update/app_update_service.dart';
import 'attendance_models.dart';
import 'attendance_service.dart';
import '../theme/tek_tokens.dart';

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
          isCheckOut: true,
        );

        if (!mounted) return;
        final timeStr = _timeFormat.format(DateTime.now());
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('ഡ്യൂട്ടി അവസാനിപ്പിച്ചു ($timeStr) - ${res.record.dutyStage}'),
            backgroundColor: TekColors.primary,
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
          isCheckOut: false,
        );

        if (!mounted) return;
        final timeStr = _timeFormat.format(DateTime.now());
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('ചെക്ക്-ഇൻ രേഖപ്പെടുത്തി ($timeStr) - POS അൺലോക്ക് ചെയ്തു'),
            backgroundColor: TekColors.success,
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
            backgroundColor: TekColors.bgCard,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: const BorderSide(color: TekColors.border),
            ),
            icon: const Icon(Icons.point_of_sale_rounded, size: 40, color: TekColors.secondary),
            title: const Text(
              TekStrings.cashRegisterTitle,
              style: TextStyle(
                color: TekColors.textPrimary,
                fontWeight: FontWeight.bold,
                fontFamilyFallback: TekTypography.malayalamFallback,
              ),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    TekStrings.cashRegisterDesc,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: TekColors.textSecondary,
                      fontFamilyFallback: TekTypography.malayalamFallback,
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Shift sales summary table
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: TekColors.bgSecondary,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: TekColors.border),
                    ),
                    child: Column(
                      children: [
                        _summaryRow('ബില്ലുകളുടെ എണ്ണം (Bills)', '$billCount'),
                        _summaryRow('ക്യാഷ് വിൽപ്പന (Cash Sales)', '₹${expectedCash.toStringAsFixed(2)}'),
                        _summaryRow('UPI / QR വിൽപ്പന', '₹${upi.toStringAsFixed(2)}'),
                        if (card > 0) _summaryRow('കാർഡ് വിൽപ്പന', '₹${card.toStringAsFixed(2)}'),
                        const Divider(height: 14, color: TekColors.border),
                        _summaryRow('ആകെ വിൽപ്പന (Shift Total)', '₹${grandTotal.toStringAsFixed(2)}', isBold: true),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  TextField(
                    controller: cashCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(color: TekColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
                    onChanged: (_) => setD(() {}),
                    decoration: InputDecoration(
                      labelText: TekStrings.labelClosingCash,
                      labelStyle: const TextStyle(color: TekColors.textSecondary),
                      prefixText: '₹ ',
                      prefixStyle: const TextStyle(color: TekColors.secondary, fontWeight: FontWeight.bold),
                      hintText: 'എണ്ണി തിട്ടപ്പെടുത്തിയ ക്യാഷ്',
                      filled: true,
                      fillColor: TekColors.bgSecondary,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: TekColors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: TekColors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: TekColors.primary, width: 1.5),
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: mismatch
                          ? TekColors.error.withValues(alpha: 0.12)
                          : TekColors.success.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: mismatch
                            ? TekColors.error.withValues(alpha: 0.5)
                            : TekColors.success.withValues(alpha: 0.5),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          mismatch ? Icons.warning_amber_rounded : Icons.check_circle_outline,
                          size: 20,
                          color: mismatch ? TekColors.error : TekColors.success,
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
                              color: mismatch ? const Color(0xFFFECDD3) : const Color(0xFFBBF7D0),
                              fontFamilyFallback: TekTypography.malayalamFallback,
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
                child: const Text('റദ്ദാക്കുക (Cancel)', style: TextStyle(color: TekColors.textSecondary)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: TekColors.primary,
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
              color: isBold ? TekColors.textPrimary : TekColors.textSecondary,
              fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
              fontFamilyFallback: TekTypography.malayalamFallback,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 12.5,
              color: isBold ? TekColors.secondary : TekColors.textPrimary,
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
        backgroundColor: TekColors.bgCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: TekColors.border),
        ),
        icon: const Icon(Icons.error_outline_rounded, color: TekColors.error, size: 40),
        title: const Text(
          'ശ്രദ്ധിക്കുക (Attention)',
          style: TextStyle(
            color: TekColors.textPrimary,
            fontWeight: FontWeight.bold,
            fontFamilyFallback: TekTypography.malayalamFallback,
          ),
        ),
        content: Text(
          err,
          style: const TextStyle(
            color: TekColors.textSecondary,
            fontFamilyFallback: TekTypography.malayalamFallback,
          ),
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: TekColors.primary),
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
      backgroundColor: TekColors.bgMain,
      body: IndexedStack(
        index: _activeTab,
        children: [
          _buildAttendanceScaffold(context),
          StaffRepairsScreen(
            shopId: widget.shopId,
            staffId: widget.staffId,
            staffName: widget.staffName,
          ),
          StaffNotificationsScreen(
            shopId: widget.shopId,
            staffId: widget.staffId,
            staffName: widget.staffName,
            onNavigateTab: (targetTab) => setState(() => _activeTab = targetTab),
          ),
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

  // Modern Floating Bottom Navigation Bar with Safe Area, Active Glow Pill & Malayalam/English support
  Widget _buildFloatingBottomNav() {
    final navItems = [
      (Icons.how_to_reg_rounded, 'ഹാജർ', 'Attendance'),
      (Icons.build_circle_rounded, 'സർവീസ്', 'Repairs'),
      (Icons.notifications_active_rounded, 'അറിയിപ്പ്', 'Alerts'),
      (Icons.point_of_sale_rounded, 'സെയിൽസ്', 'Sales POS'),
      (Icons.shopping_bag_rounded, 'ഓർഡറുകൾ', 'Orders'),
    ];

    return SafeArea(
      top: false,
      left: false,
      right: false,
      bottom: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
        child: Container(
          height: 68,
          decoration: BoxDecoration(
            color: TekColors.bgSecondary.withValues(alpha: 0.98),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: TekColors.border, width: 1.2),
            boxShadow: TekColors.floatingNavShadow,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: List.generate(navItems.length, (idx) {
              final isSelected = _activeTab == idx;
              final (icon, labelMl, labelEn) = navItems[idx];

              return Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() => _activeTab = idx);
                  },
                  child: Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      padding: EdgeInsets.symmetric(
                        horizontal: isSelected ? 10 : 4,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        gradient: isSelected ? TekColors.primaryGradient : null,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: isSelected ? TekColors.primaryGlow : null,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (idx == 2)
                            StreamBuilder<int>(
                              stream: NotificationService.instance.streamUnreadCount(widget.shopId, widget.staffId),
                              builder: (context, snap) {
                                final count = snap.data ?? 0;
                                return Badge(
                                  isLabelVisible: count > 0,
                                  label: Text('$count', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white)),
                                  backgroundColor: TekColors.error,
                                  child: Icon(
                                    icon,
                                    size: 21,
                                    color: isSelected
                                        ? TekColors.textPrimary
                                        : TekColors.textSecondary,
                                  ),
                                );
                              },
                            )
                          else
                            Icon(
                              icon,
                              size: 21,
                              color: isSelected
                                  ? TekColors.textPrimary
                                  : TekColors.textSecondary,
                            ),
                          const SizedBox(height: 2),
                          Text(
                            labelMl,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight:
                                  isSelected ? FontWeight.bold : FontWeight.w600,
                              color: isSelected
                                  ? TekColors.textPrimary
                                  : TekColors.textSecondary,
                              fontFamilyFallback:
                                  TekTypography.malayalamFallback,
                            ),
                          ),
                          Text(
                            labelEn,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 8.5,
                              fontWeight: isSelected
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                              color: isSelected
                                  ? TekColors.textPrimary.withValues(alpha: 0.85)
                                  : TekColors.textMuted,
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
      ),
    );
  }

  Widget _buildAttendanceScaffold(BuildContext context) {
    final now = DateTime.now();
    final shift = AttendanceService.instance.getShiftConfig();

    return Scaffold(
      backgroundColor: TekColors.bgMain,
      body: SafeArea(
        child: StreamBuilder<AttendanceRecord?>(
          stream: AttendanceService.instance.streamTodayAttendance(widget.shopId, widget.staffId),
          builder: (context, snapshot) {
            final record = snapshot.data ?? AttendanceService.instance.getCachedTodayAttendance(widget.staffId);
            final isCheckedIn = record?.checkIn != null;
            final isCheckedOut = record?.checkOut != null;

            return SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 1. Modern Top Header: Logo, Profile Avatar, Name, Shop Badge, Notifications, Sign-Out
                    _buildModernHeaderCard(record, isCheckedIn, isCheckedOut, shift),
                    const SizedBox(height: 14),

                    // Date Pill Header
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: TekColors.bgSecondary,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: TekColors.border),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.calendar_today_rounded, size: 14, color: TekColors.secondary),
                            const SizedBox(width: 8),
                            Text(
                              _dateFormat.format(now),
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: TekColors.textPrimary,
                                fontFamilyFallback: TekTypography.malayalamFallback,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // 2. Work & Duty Overview Card
                    _buildDutyOverviewCard(record, isCheckedIn, isCheckedOut, shift),
                    const SizedBox(height: 18),

                    // 3. Primary Action Card (Check-in / Check-out / Shift Completed)
                    _buildPrimaryActionCard(record, isCheckedIn, isCheckedOut),
                    const SizedBox(height: 20),

                    // 4. Quick Access Shortcuts Grid
                    _buildQuickAccessGrid(isCheckedIn, isCheckedOut),
                    const SizedBox(height: 22),

                    // 5. Real-Time Attendance History Section (Past 14 Days)
                    _buildAttendanceHistorySection(),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // 1. Modern Profile Card Header with Brand Logo, Staff Avatar, Shop Badge, Notifications
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
        ? TekColors.textMuted
        : (isCheckedIn ? TekColors.success : TekColors.warning);
    final statusLabel = isCheckedOut
        ? 'Shift Ended'
        : (isCheckedIn ? 'Active • On Duty' : 'Not Punched In');

    // Shift timing label
    final shiftStartStr = '${shift.startHour > 12 ? shift.startHour - 12 : shift.startHour}:${shift.startMinute.toString().padLeft(2, '0')} ${shift.startHour >= 12 ? 'PM' : 'AM'}';
    final shiftEndStr = '${shift.endHour > 12 ? shift.endHour - 12 : shift.endHour}:${shift.endMinute.toString().padLeft(2, '0')} ${shift.endHour >= 12 ? 'PM' : 'AM'}';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TekColors.bgCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: TekColors.border, width: 1.2),
        boxShadow: TekColors.cardShadow,
      ),
      child: Column(
        children: [
          Row(
            children: [
              // Logo Badge
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: TekColors.primaryGradient,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: TekColors.primaryGlow,
                ),
                child: const Icon(Icons.bolt_rounded, size: 28, color: Colors.white),
              ),
              const SizedBox(width: 12),

              // Staff details & Shop badge
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            widget.staffName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TekTypography.titleMedium.copyWith(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: TekColors.primary.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: TekColors.primary.withValues(alpha: 0.4)),
                          ),
                          child: Text(
                            widget.shopId.toUpperCase(),
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: TekColors.secondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 10,
                          backgroundColor: TekColors.bgSecondary,
                          child: Text(
                            staffInitials,
                            style: const TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              color: TekColors.secondary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Text(
                          'Staff Member • Authenticated',
                          style: TextStyle(fontSize: 11, color: TekColors.textSecondary),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Notification alerts shortcut with Live Unread Badge & Drawer
              StreamBuilder<int>(
                stream: NotificationService.instance.streamUnreadCount(widget.shopId, widget.staffId),
                builder: (context, unreadSnap) {
                  final unreadCount = unreadSnap.data ?? 0;
                  return IconButton(
                    tooltip: 'അറിയിപ്പുകൾ (Alerts & Notifications)',
                    icon: Badge(
                      isLabelVisible: unreadCount > 0,
                      label: Text(
                        '$unreadCount',
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      backgroundColor: TekColors.error,
                      child: const Icon(Icons.notifications_active_rounded, color: TekColors.secondary, size: 22),
                    ),
                    onPressed: () {
                      HapticFeedback.lightImpact();
                      NotificationDrawer.show(
                        context,
                        shopId: widget.shopId,
                        staffId: widget.staffId,
                        staffName: widget.staffName,
                        onNavigateTab: (idx) => setState(() => _activeTab = idx),
                      );
                    },
                  );
                },
              ),

              // App Update Action
              IconButton(
                tooltip: 'Check Updates',
                icon: const Icon(Icons.system_update_rounded, color: TekColors.info, size: 21),
                onPressed: () => AppUpdateService.instance.checkForUpdate(
                  context,
                  autoShowDialog: true,
                  showToastIfLatest: true,
                ),
              ),

              // Sign Out Action
              IconButton(
                tooltip: 'Sign Out (ലോഗൗട്ട്)',
                icon: const Icon(Icons.logout_rounded, color: TekColors.error, size: 21),
                onPressed: () => _confirmSignOut(context),
              ),
            ],
          ),

          const Divider(height: 20, color: TekColors.border),

          // Secondary row: Shift Duration & Animated Status Chip
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Shift duration label
              Row(
                children: [
                  const Icon(Icons.schedule_rounded, size: 15, color: TekColors.textSecondary),
                  const SizedBox(width: 6),
                  Text(
                    'Shift: $shiftStartStr - $shiftEndStr',
                    style: const TextStyle(fontSize: 11.5, color: TekColors.textSecondary),
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
        color: TekColors.bgCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: TekColors.border, width: 1.2),
        boxShadow: TekColors.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.dashboard_customize_rounded, size: 18, color: TekColors.secondary),
              const SizedBox(width: 8),
              Text(
                'Work & Shift Overview (ഡ്യൂട്ടി വിവരങ്ങൾ)',
                style: TekTypography.titleMedium.copyWith(fontSize: 14),
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
                  iconColor: TekColors.success,
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
                  iconColor: TekColors.secondary,
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
                  iconColor: TekColors.primaryLight,
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
                color: TekColors.warning.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: TekColors.warning.withValues(alpha: 0.4)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, size: 18, color: TekColors.warning),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'സമയപരിധി കഴിഞ്ഞുള്ള വരവ് (Late Arrival Recorded)',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.bold,
                        color: TekColors.warning,
                        fontFamilyFallback: TekTypography.malayalamFallback,
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
        color: TekColors.bgSecondary,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: highlight ? iconColor.withValues(alpha: 0.5) : TekColors.border,
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
                  style: const TextStyle(fontSize: 11, color: TekColors.textSecondary),
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
              color: highlight ? iconColor : TekColors.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: TekColors.textMuted),
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
      color = TekColors.textMuted;
      icon = Icons.radio_button_unchecked_rounded;
    } else if (r.isApproved) {
      label = TekStrings.badgeApproved;
      color = TekColors.success;
      icon = Icons.verified_rounded;
    } else if (r.isRejected) {
      label = TekStrings.badgeRejected;
      color = TekColors.error;
      icon = Icons.cancel_rounded;
    } else if (r.isAdjusted) {
      label = TekStrings.badgeAdjusted;
      color = TekColors.secondary;
      icon = Icons.edit_note_rounded;
    } else {
      label = TekStrings.badgePendingApproval;
      color = TekColors.warning;
      icon = Icons.hourglass_top_rounded;
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TekColors.bgSecondary,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: TekColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.shield_outlined, size: 16, color: TekColors.secondary),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Owner Approval',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: TekColors.textSecondary),
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
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: color,
                    fontFamilyFallback: TekTypography.malayalamFallback,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          const Text(
            'Admin verified',
            style: TextStyle(fontSize: 10, color: TekColors.textMuted),
          ),
        ],
      ),
    );
  }

  // 3. Modern Curved Elevated Primary Action Button (Check-in / Check-out)
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
          color: TekColors.bgCard,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: TekColors.success.withValues(alpha: 0.5), width: 1.2),
          boxShadow: [
            BoxShadow(
              color: TekColors.success.withValues(alpha: 0.15),
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
                color: TekColors.success.withValues(alpha: 0.18),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.task_alt_rounded, color: TekColors.success, size: 28),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'ഇന്നത്തെ ഡ്യൂട്ടി പൂർത്തിയായി!',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: TekColors.textPrimary,
                      fontFamilyFallback: TekTypography.malayalamFallback,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Worked: ${record?.workedHours.toStringAsFixed(1) ?? "0"} hrs • Cash register reconciled',
                    style: const TextStyle(fontSize: 12, color: TekColors.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    if (isCheckedIn) {
      // Check-out Button with Warm Amber Glow
      return GestureDetector(
        onTap: _loading ? null : () => _handleTap(record),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [TekColors.warning, Color(0xFFEA580C), TekColors.error],
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
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Colors.white70,
                        fontFamilyFallback: TekTypography.malayalamFallback,
                      ),
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

    // Check-in Button with Vibrant Emerald Glow
    return GestureDetector(
      onTap: _loading ? null : () => _handleTap(record),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [TekColors.success, Color(0xFF16A34A), Color(0xFF15803D)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: TekColors.success.withValues(alpha: 0.4),
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
                    style: TextStyle(
                      fontSize: 11.5,
                      color: Colors.white70,
                      fontFamilyFallback: TekTypography.malayalamFallback,
                    ),
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

  // 4. Quick Access Grid
  Widget _buildQuickAccessGrid(bool isCheckedIn, bool isCheckedOut) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.bolt_rounded, size: 18, color: TekColors.warning),
            const SizedBox(width: 8),
            Text(
              'Quick Access & Actions (ദ്രുത സേവനങ്ങൾ)',
              style: TekTypography.titleMedium.copyWith(fontSize: 14),
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
                iconGradient: const [TekColors.primary, TekColors.primaryDark],
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
                iconGradient: const [TekColors.secondary, Color(0xFF7C3AED)],
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
                iconGradient: const [TekColors.success, Color(0xFF0F766E)],
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
            // Card 4: Payment Reminders & Dues (ബാക്കി തുക)
            Expanded(
              child: _buildQuickCard(
                icon: Icons.mark_chat_unread_rounded,
                iconGradient: const [Color(0xFF25D366), Color(0xFF128C7E)],
                title: 'Dues & Reminders',
                subtitle: 'ബാക്കി തുക & WhatsApp alerts',
                badgeText: 'Reminders',
                onTap: () {
                  HapticFeedback.lightImpact();
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => RemindersScreen(
                        shopId: widget.shopId,
                        staffId: widget.staffId,
                        staffName: widget.staffName,
                        isOwner: false,
                      ),
                    ),
                  );
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
          color: TekColors.bgCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: TekColors.border),
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
                color: TekColors.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10.5, color: TekColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  // 5. Real-Time Attendance History Section (Past 14 Days with Status Badges)
  Widget _buildAttendanceHistorySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                const Icon(Icons.history_rounded, size: 18, color: TekColors.secondary),
                const SizedBox(width: 8),
                Text(
                  'ഹാജർ ചരിത്രം (Attendance History)',
                  style: TekTypography.titleMedium.copyWith(fontSize: 14),
                ),
              ],
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: TekColors.bgSecondary,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: TekColors.border),
              ),
              child: const Text(
                'Past 14 Days',
                style: TextStyle(
                  fontSize: 10,
                  color: TekColors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        StreamBuilder<List<AttendanceRecord>>(
          stream: AttendanceService.instance.streamStaffAttendanceHistory(widget.shopId, widget.staffId),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(strokeWidth: 2, color: TekColors.primary),
                ),
              );
            }

            final list = snapshot.data ?? [];
            if (list.isEmpty) {
              return Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: TekColors.bgCard,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: TekColors.border),
                ),
                child: const Center(
                  child: Column(
                    children: [
                      Icon(Icons.event_note_rounded, size: 36, color: TekColors.textMuted),
                      SizedBox(height: 8),
                      Text(
                        'ഹാജർ വിവരങ്ങൾ ലഭ്യമല്ല (No attendance history records)',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: TekColors.textSecondary,
                          fontFamilyFallback: TekTypography.malayalamFallback,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }

            return ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: list.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final r = list[index];
                return _buildHistoryCard(r);
              },
            );
          },
        ),
      ],
    );
  }

  Widget _buildHistoryCard(AttendanceRecord r) {
    Color badgeColor;
    String badgeText;
    IconData badgeIcon;

    if (r.isApproved) {
      badgeColor = TekColors.success;
      badgeText = 'Approved';
      badgeIcon = Icons.verified_rounded;
    } else if (r.isRejected) {
      badgeColor = TekColors.error;
      badgeText = 'Rejected';
      badgeIcon = Icons.cancel_rounded;
    } else if (r.isAdjusted) {
      badgeColor = TekColors.secondary;
      badgeText = 'Adjusted';
      badgeIcon = Icons.edit_note_rounded;
    } else {
      badgeColor = TekColors.warning;
      badgeText = 'Pending';
      badgeIcon = Icons.hourglass_top_rounded;
    }

    final inTimeStr = r.checkIn != null ? _timeFormat.format(r.checkIn!) : '--:--';
    final outTimeStr = r.checkOut != null ? _timeFormat.format(r.checkOut!) : (r.checkIn != null ? 'Active' : '--:--');

    DateTime? parsedDate;
    try {
      parsedDate = DateTime.parse(r.date);
    } catch (_) {}
    final dateDisplay = parsedDate != null ? DateFormat('EEE, dd MMM yyyy').format(parsedDate) : r.date;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: TekColors.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: TekColors.border, width: 1.1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.event_available_rounded, size: 15, color: TekColors.secondary),
                  const SizedBox(width: 6),
                  Text(
                    dateDisplay,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: TekColors.textPrimary,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: badgeColor.withValues(alpha: 0.5)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(badgeIcon, size: 12, color: badgeColor),
                    const SizedBox(width: 4),
                    Text(
                      badgeText,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                        color: badgeColor,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    const Icon(Icons.login_rounded, size: 14, color: TekColors.success),
                    const SizedBox(width: 4),
                    Text(
                      inTimeStr,
                      style: const TextStyle(
                        fontSize: 12,
                        color: TekColors.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Text('→', style: TextStyle(color: TekColors.textMuted)),
                    const SizedBox(width: 6),
                    Icon(Icons.logout_rounded, size: 14, color: r.checkOut != null ? TekColors.error : TekColors.warning),
                    const SizedBox(width: 4),
                    Text(
                      outTimeStr,
                      style: const TextStyle(
                        fontSize: 12,
                        color: TekColors.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: TekColors.bgSecondary,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${r.workedHours.toStringAsFixed(1)} hrs',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: TekColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          if (r.cashRegister != null && (r.cashRegister!['mismatch'] == true)) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: TekColors.warning.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.warning_amber_rounded, size: 12, color: TekColors.warning),
                  SizedBox(width: 4),
                  Text(
                    'Cash register mismatch flagged',
                    style: TextStyle(fontSize: 10, color: TekColors.warning, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmSignOut(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TekColors.bgCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: TekColors.border),
        ),
        title: const Text(
          'ലോഗൗട്ട് ചെയ്യണോ?',
          style: TextStyle(
            color: TekColors.textPrimary,
            fontWeight: FontWeight.bold,
            fontFamilyFallback: TekTypography.malayalamFallback,
          ),
        ),
        content: const Text(
          'നിങ്ങൾ അക്കൗണ്ടിൽ നിന്ന് പുറത്തുകടക്കണോ? (Do you want to sign out?)',
          style: TextStyle(
            color: TekColors.textSecondary,
            fontFamilyFallback: TekTypography.malayalamFallback,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('വേണ്ട (Cancel)', style: TextStyle(color: TekColors.textSecondary)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: TekColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('ലോഗൗട്ട് (Sign Out)'),
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
