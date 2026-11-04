import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../main.dart' show Db;
import '../theme/tek_tokens.dart';
import 'daily_rent_payment_dialog.dart';
import 'daily_rent_settings_dialog.dart';
import 'rent_models.dart';
import 'rent_service.dart';

class DailyRentHistoryView extends StatefulWidget {
  final String? shopId;

  const DailyRentHistoryView({super.key, this.shopId});

  @override
  State<DailyRentHistoryView> createState() => _DailyRentHistoryViewState();
}

class _DailyRentHistoryViewState extends State<DailyRentHistoryView> {
  DateTime? _customStartDate;
  DateTime? _customEndDate;
  String _dateFilterMode = 'THIS_MONTH'; // THIS_MONTH, PREV_MONTH, CUSTOM
  String _selectedStatus = 'ALL'; // ALL, PAID, PENDING
  String _selectedMode = 'ALL'; // ALL, CASH, BANK

  bool _loading = true;
  DailyRentMetrics _metrics = DailyRentMetrics.empty();
  List<DailyRentRecord> _records = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);
    final sId = widget.shopId ?? Db.setting('shop_id', 'tekfix');

    final settings = await RentService.instance.getSettings(shopId: sId);
    final metrics = await RentService.instance.computeRentMetrics(shopId: sId);

    DateTime start;
    DateTime end;
    if (_dateFilterMode == 'THIS_MONTH') {
      start = DateTime(DateTime.now().year, DateTime.now().month, 1);
      final lastDay =
          DateTime(DateTime.now().year, DateTime.now().month + 1, 0).day;
      end = DateTime(DateTime.now().year, DateTime.now().month, lastDay);
    } else if (_dateFilterMode == 'PREV_MONTH') {
      final prev = DateTime(DateTime.now().year, DateTime.now().month - 1, 1);
      start = prev;
      final lastDay = DateTime(prev.year, prev.month + 1, 0).day;
      end = DateTime(prev.year, prev.month, lastDay);
    } else {
      start = _customStartDate ??
          DateTime(DateTime.now().year, DateTime.now().month, 1);
      end = _customEndDate ?? DateTime.now();
    }

    final history = await RentService.instance.getRentHistory(
      shopId: sId,
      startDate: start,
      endDate: end,
    );

    if (mounted) {
      setState(() {
        _metrics = metrics;
        _records = history;
        _loading = false;
      });
    }
  }

  List<DailyRentRecord> get _filteredRecords {
    return _records.where((r) {
      if (_selectedStatus != 'ALL') {
        if (_selectedStatus == 'PAID' && !r.isPaid) return false;
        if (_selectedStatus == 'PENDING' && (r.isPaid || r.status != 'PENDING'))
          return false;
      }
      if (_selectedMode != 'ALL') {
        if (_selectedMode == 'CASH' && !r.isCash) return false;
        if (_selectedMode == 'BANK' && !r.isBank) return false;
      }
      return true;
    }).toList();
  }

  void _openPaymentDialog([DateTime? dt]) {
    DailyRentPaymentDialog.show(
      context,
      shopId: widget.shopId,
      initialDate: dt ?? DateTime.now(),
      onPaymentSuccess: _loadData,
    );
  }

  void _openSettingsDialog() {
    DailyRentSettingsDialog.show(
      context,
      shopId: widget.shopId,
      onSettingsSaved: _loadData,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TekColors.mainBg,
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFFF59E0B)))
          : RefreshIndicator(
              onRefresh: _loadData,
              color: const Color(0xFFF59E0B),
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Header Bar
                    _buildHeaderBar(),
                    const SizedBox(height: 18),

                    // 5 Top Metric Summary Cards
                    _buildMetricsGrid(),
                    const SizedBox(height: 20),

                    // Filters Row
                    _buildFilterControls(),
                    const SizedBox(height: 16),

                    // Calendar / Date-wise List
                    _buildRecordsList(),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildHeaderBar() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Daily Rent Management',
              style: TextStyle(
                color: TekColors.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'കട വാടക വിവരങ്ങൾ • Daily Rent Ledger & Scheduling',
              style: TextStyle(
                color: TekColors.textSecondary,
                fontSize: 13,
                fontFamilyFallback: TekTypography.malayalamFallback,
              ),
            ),
          ],
        ),
        Row(
          children: [
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: TekColors.border),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
              onPressed: _openSettingsDialog,
              icon: const Icon(Icons.settings_outlined,
                  size: 16, color: TekColors.textPrimary),
              label: const Text('Rent Settings',
                  style: TextStyle(color: TekColors.textPrimary, fontSize: 13)),
            ),
            const SizedBox(width: 10),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFF59E0B),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              onPressed: () => _openPaymentDialog(),
              icon: const Icon(Icons.add_circle_outline_rounded, size: 18),
              label: const Text('Record Daily Rent',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMetricsGrid() {
    return LayoutBuilder(builder: (context, constraints) {
      final isWide = constraints.maxWidth >= 950;
      final crossAxisCount = isWide ? 5 : (constraints.maxWidth >= 550 ? 3 : 2);

      return GridView.count(
        crossAxisCount: crossAxisCount,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: isWide ? 1.45 : 1.35,
        children: [
          // Card A: Today's Rent
          _metricCard(
            title: "Today's Rent",
            subtitle: _metrics.todayStatus == 'PAID'
                ? "Paid (₹${_metrics.todayPaid.toStringAsFixed(0)})"
                : "Expected: ₹${_metrics.todayExpected.toStringAsFixed(0)}",
            badgeText: _metrics.todayStatus,
            badgeColor: _metrics.todayStatus == 'PAID'
                ? const Color(0xFF10B981)
                : const Color(0xFFF59E0B),
            icon: Icons.today_rounded,
            color: const Color(0xFFF59E0B),
          ),
          // Card B: Total Rent Paid This Month
          _metricCard(
            title: "Rent Paid This Month",
            subtitle: "₹${_metrics.monthTotalPaid.toStringAsFixed(0)}",
            badgeText: "Recorded",
            badgeColor: const Color(0xFF10B981),
            icon: Icons.account_balance_wallet_rounded,
            color: const Color(0xFF10B981),
          ),
          // Card C: Paid Days Count
          _metricCard(
            title: "Paid Days",
            subtitle: "${_metrics.monthPaidDays} Days",
            badgeText: "Complete",
            badgeColor: TekColors.info,
            icon: Icons.verified_rounded,
            color: TekColors.info,
          ),
          // Card D: Unpaid Days Count
          _metricCard(
            title: "Unpaid Days",
            subtitle: "${_metrics.monthUnpaidDays} Days",
            badgeText: _metrics.monthUnpaidDays > 0 ? "Pending" : "Clear",
            badgeColor: _metrics.monthUnpaidDays > 0
                ? TekColors.warning
                : const Color(0xFF10B981),
            icon: Icons.pending_actions_rounded,
            color: _metrics.monthUnpaidDays > 0
                ? TekColors.warning
                : const Color(0xFF10B981),
          ),
          // Card E: Total Outstanding Scheduled Rent
          _metricCard(
            title: "Scheduled Outstanding",
            subtitle: "₹${_metrics.monthTotalOutstanding.toStringAsFixed(0)}",
            badgeText: "Unpaid",
            badgeColor: TekColors.error,
            icon: Icons.event_busy_rounded,
            color: TekColors.error,
          ),
        ],
      );
    });
  }

  Widget _metricCard({
    required String title,
    required String subtitle,
    required String badgeText,
    required Color badgeColor,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: TekColors.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: TekColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: 16),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  badgeText,
                  style: TextStyle(
                      color: badgeColor,
                      fontSize: 10,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                    color: TekColors.textSecondary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: const TextStyle(
                    color: TekColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFilterControls() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: TekColors.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: TekColors.border),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: [
          // Date Mode Chips
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ChoiceChip(
                label: const Text('This Month'),
                selected: _dateFilterMode == 'THIS_MONTH',
                selectedColor: const Color(0xFFF59E0B).withValues(alpha: 0.25),
                onSelected: (_) {
                  setState(() => _dateFilterMode = 'THIS_MONTH');
                  _loadData();
                },
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('Previous Month'),
                selected: _dateFilterMode == 'PREV_MONTH',
                selectedColor: const Color(0xFFF59E0B).withValues(alpha: 0.25),
                onSelected: (_) {
                  setState(() => _dateFilterMode = 'PREV_MONTH');
                  _loadData();
                },
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('Custom Range'),
                selected: _dateFilterMode == 'CUSTOM',
                selectedColor: const Color(0xFFF59E0B).withValues(alpha: 0.25),
                onSelected: (_) async {
                  final picked = await showDateRangePicker(
                    context: context,
                    firstDate: DateTime(2025, 1, 1),
                    lastDate: DateTime.now().add(const Duration(days: 30)),
                  );
                  if (picked != null) {
                    setState(() {
                      _dateFilterMode = 'CUSTOM';
                      _customStartDate = picked.start;
                      _customEndDate = picked.end;
                    });
                    _loadData();
                  }
                },
              ),
            ],
          ),

          // Status & Mode Dropdowns
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButton<String>(
                value: _selectedStatus,
                dropdownColor: TekColors.bgCard,
                underline: const SizedBox.shrink(),
                style:
                    const TextStyle(color: TekColors.textPrimary, fontSize: 13),
                items: const [
                  DropdownMenuItem(value: 'ALL', child: Text('Status: All')),
                  DropdownMenuItem(
                      value: 'PAID', child: Text('Status: Paid Only')),
                  DropdownMenuItem(
                      value: 'PENDING', child: Text('Status: Pending Only')),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _selectedStatus = v);
                },
              ),
              const SizedBox(width: 14),
              DropdownButton<String>(
                value: _selectedMode,
                dropdownColor: TekColors.bgCard,
                underline: const SizedBox.shrink(),
                style:
                    const TextStyle(color: TekColors.textPrimary, fontSize: 13),
                items: const [
                  DropdownMenuItem(value: 'ALL', child: Text('Mode: All')),
                  DropdownMenuItem(
                      value: 'CASH', child: Text('Mode: Cash Only')),
                  DropdownMenuItem(
                      value: 'BANK', child: Text('Mode: Bank/UPI Only')),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _selectedMode = v);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRecordsList() {
    final list = _filteredRecords;
    if (list.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 48),
        alignment: Alignment.center,
        child: Column(
          children: [
            const Icon(Icons.event_available_rounded,
                size: 48, color: TekColors.textMuted),
            const SizedBox(height: 12),
            const Text(
              'No rent records found for this period',
              style: TextStyle(color: TekColors.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 6),
            Text(
              'തീയതി ഫിൽട്ടറുകൾ മാറ്റുകയോ പുതിയ വാടക രേഖപ്പെടുത്തുകയോ ചെയ്യുക',
              style: TextStyle(
                  color: TekColors.textMuted,
                  fontSize: 12,
                  fontFamilyFallback: TekTypography.malayalamFallback),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: list.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, idx) {
        final r = list[idx];
        final isToday = r.dateKey == RentService.toDateKey(DateTime.now());

        Color badgeBg;
        Color badgeFg;
        String badgeText;
        if (r.isPaid) {
          badgeBg = const Color(0xFF10B981).withValues(alpha: 0.15);
          badgeFg = const Color(0xFF10B981);
          badgeText = 'PAID (നൽകി)';
        } else if (r.status == 'VOIDED') {
          badgeBg = TekColors.error.withValues(alpha: 0.15);
          badgeFg = TekColors.error;
          badgeText = 'VOIDED';
        } else if (r.status == 'NOT_SCHEDULED') {
          badgeBg = TekColors.textMuted.withValues(alpha: 0.15);
          badgeFg = TekColors.textMuted;
          badgeText = 'NOT SCHEDULED';
        } else {
          badgeBg = const Color(0xFFF59E0B).withValues(alpha: 0.15);
          badgeFg = const Color(0xFFF59E0B);
          badgeText = 'PENDING (ബാക്കി)';
        }

        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: TekColors.bgCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isToday
                  ? const Color(0xFFF59E0B).withValues(alpha: 0.6)
                  : TekColors.border,
              width: isToday ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              // Calendar date icon badge
              Container(
                width: 48,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: TekColors.bgSecondary,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: TekColors.border),
                ),
                child: Column(
                  children: [
                    Text(
                      DateFormat('MMM').format(r.date).toUpperCase(),
                      style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: TekColors.textMuted),
                    ),
                    Text(
                      DateFormat('dd').format(r.date),
                      style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: TekColors.textPrimary),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 14),

              // Date & description info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          DateFormat('EEEE, dd MMM yyyy').format(r.date),
                          style: const TextStyle(
                              color: TekColors.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.bold),
                        ),
                        if (isToday) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF59E0B),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text('TODAY',
                                style: TextStyle(
                                    color: Colors.black,
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Text(
                          r.isPaid
                              ? 'Paid via ${r.paymentMode}${r.recordedByName.isNotEmpty ? " by ${r.recordedByName}" : ""}'
                              : (r.status == 'NOT_SCHEDULED'
                                  ? 'Shop Closed / Day Off'
                                  : 'Scheduled Daily Rent: ₹${r.expectedRent.toStringAsFixed(0)}'),
                          style: const TextStyle(
                              color: TekColors.textSecondary, fontSize: 12),
                        ),
                        if (r.paymentReference.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Text('• Ref: ${r.paymentReference}',
                              style: const TextStyle(
                                  color: TekColors.textMuted, fontSize: 11.5)),
                        ],
                      ],
                    ),
                  ],
                ),
              ),

              // Amount & Badge
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    r.isPaid
                        ? '₹${r.paidAmount.toStringAsFixed(0)}'
                        : '₹${r.expectedRent.toStringAsFixed(0)}',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: r.isPaid
                          ? const Color(0xFF10B981)
                          : (r.status == 'PENDING'
                              ? const Color(0xFFF59E0B)
                              : TekColors.textMuted),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: badgeBg,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      badgeText,
                      style: TextStyle(
                          color: badgeFg,
                          fontSize: 10.5,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),

              const SizedBox(width: 12),

              // Action button
              if (r.isPaid)
                IconButton(
                  tooltip: 'View Payment Details / Reversal',
                  icon: const Icon(Icons.remove_red_eye_rounded,
                      size: 20, color: TekColors.textSecondary),
                  onPressed: () => _openPaymentDialog(r.date),
                )
              else if (r.status == 'PENDING')
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFF59E0B),
                    foregroundColor: Colors.black,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    minimumSize: Size.zero,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: () => _openPaymentDialog(r.date),
                  child: const Text('Pay',
                      style:
                          TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                )
              else
                const SizedBox(width: 12),
            ],
          ),
        );
      },
    );
  }
}
