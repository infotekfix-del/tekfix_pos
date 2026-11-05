import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/auth_controller.dart';
import '../main.dart' show Db, toast;
import '../theme/tek_tokens.dart';
import 'add_expense_dialog.dart';
import 'expense_models.dart';
import 'expense_service.dart';
import '../rent/daily_rent_history_view.dart';

class ExpenseManagementScreen extends StatefulWidget {
  final String shopId;

  const ExpenseManagementScreen({super.key, required this.shopId});

  @override
  State<ExpenseManagementScreen> createState() =>
      _ExpenseManagementScreenState();
}

class _ExpenseManagementScreenState extends State<ExpenseManagementScreen> {
  final TextEditingController _searchCtrl = TextEditingController();

  String _dateFilter =
      'This Month'; // Today, Yesterday, This Week, This Month, Custom
  DateTimeRange? _customDateRange;
  String _selectedCategory = 'All';
  String _selectedPaymentMode = 'All'; // All, CASH, BANK
  String _selectedStaff = 'All';

  bool _isLoading = true;
  List<ExpenseItem> _allExpenses = [];
  ExpenseMetrics _metrics = ExpenseMetrics.empty();
  StreamSubscription<List<ExpenseItem>>? _expenseSub;

  @override
  void initState() {
    super.initState();
    _initStream();
  }

  @override
  void dispose() {
    _expenseSub?.cancel();
    _expenseSub = null;
    _searchCtrl.dispose();
    super.dispose();
  }

  void _initStream() {
    final sId = widget.shopId.isNotEmpty
        ? widget.shopId
        : Db.setting('shop_id', 'tekfix');

    _expenseSub?.cancel();
    _expenseSub = ExpenseService.instance.streamExpenses(sId).listen((list) async {
      final metrics =
          await ExpenseService.instance.computeExpenseMetrics(shopId: sId);
      if (mounted) {
        setState(() {
          _allExpenses = list;
          _metrics = metrics;
          _isLoading = false;
        });
      }
    }, onError: (e) {
      debugPrint('[ExpenseManagementScreen] Stream error: $e');
      if (mounted) setState(() => _isLoading = false);
    });
  }

  Future<void> _loadData() async {
    final sId = widget.shopId.isNotEmpty
        ? widget.shopId
        : Db.setting('shop_id', 'tekfix');
    try {
      final list = await ExpenseService.instance.getAllExpenses(sId);
      final metrics =
          await ExpenseService.instance.computeExpenseMetrics(shopId: sId);
      if (mounted) {
        setState(() {
          _allExpenses = list;
          _metrics = metrics;
          _isLoading = false;
        });
      }
    } catch (_) {}
  }

  bool _matchesDate(DateTime dt) {
    final now = DateTime.now();
    switch (_dateFilter) {
      case 'Today':
        return dt.year == now.year &&
            dt.month == now.month &&
            dt.day == now.day;
      case 'Yesterday':
        final yest = now.subtract(const Duration(days: 1));
        return dt.year == yest.year &&
            dt.month == yest.month &&
            dt.day == yest.day;
      case 'This Week':
        final startOfWeek = now.subtract(Duration(days: now.weekday - 1));
        final start =
            DateTime(startOfWeek.year, startOfWeek.month, startOfWeek.day);
        return !dt.isBefore(start);
      case 'This Month':
        return dt.year == now.year && dt.month == now.month;
      case 'Custom':
        if (_customDateRange != null) {
          final start = DateTime(_customDateRange!.start.year,
              _customDateRange!.start.month, _customDateRange!.start.day);
          final end = DateTime(
              _customDateRange!.end.year,
              _customDateRange!.end.month,
              _customDateRange!.end.day,
              23,
              59,
              59);
          return !dt.isBefore(start) && !dt.isAfter(end);
        }
        return true;
      default:
        return true;
    }
  }

  List<ExpenseItem> get _filteredExpenses {
    final q = _searchCtrl.text.trim().toLowerCase();
    return _allExpenses.where((exp) {
      // Date filter
      if (!_matchesDate(exp.expenseDate)) return false;

      // Category filter
      if (_selectedCategory != 'All' && exp.category != _selectedCategory) {
        return false;
      }

      // Payment Mode filter
      if (_selectedPaymentMode != 'All' &&
          exp.paymentMode != _selectedPaymentMode) {
        return false;
      }

      // Staff filter
      if (_selectedStaff != 'All' && exp.recordedByName != _selectedStaff) {
        return false;
      }

      // Search query
      if (q.isNotEmpty) {
        final title = exp.title.toLowerCase();
        final cat = exp.category.toLowerCase();
        final staff = exp.recordedByName.toLowerCase();
        final notes = exp.notes.toLowerCase();
        final amt = exp.amount.toString();
        if (!title.contains(q) &&
            !cat.contains(q) &&
            !staff.contains(q) &&
            !notes.contains(q) &&
            !amt.contains(q)) {
          return false;
        }
      }

      return true;
    }).toList();
  }

  List<String> get _staffOptions {
    final names = <String>{'All'};
    for (final e in _allExpenses) {
      if (e.recordedByName.isNotEmpty) names.add(e.recordedByName);
    }
    return names.toList();
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2023),
      lastDate: now.add(const Duration(days: 1)),
      initialDateRange: _customDateRange ??
          DateTimeRange(start: now.subtract(const Duration(days: 7)), end: now),
      builder: (ctx, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(
            primary: TekColors.primary,
            surface: TekColors.bgCard,
          ),
        ),
        child: child!,
      ),
    );

    if (picked != null) {
      setState(() {
        _dateFilter = 'Custom';
        _customDateRange = picked;
      });
    }
  }

  void _showExpenseDetails(ExpenseItem exp) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(22),
        decoration: const BoxDecoration(
          color: TekColors.bgCard,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          border: Border(top: BorderSide(color: TekColors.border, width: 1.5)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: exp.isVoided
                                  ? TekColors.error.withValues(alpha: 0.15)
                                  : TekColors.primary.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: exp.isVoided
                                    ? TekColors.error
                                    : TekColors.primary,
                              ),
                            ),
                            child: Text(
                              exp.isVoided
                                  ? 'VOIDED / CANCELLED'
                                  : exp.category,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: exp.isVoided
                                    ? TekColors.error
                                    : TekColors.primary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            ExpenseCategory.toMalayalam(exp.category),
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: TekColors.textSecondary,
                              fontFamilyFallback:
                                  TekTypography.malayalamFallback,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        exp.title,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: TekColors.textPrimary,
                          decoration:
                              exp.isVoided ? TextDecoration.lineThrough : null,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '₹${exp.amount.toStringAsFixed(2)}',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: exp.isVoided
                        ? TekColors.textMuted
                        : const Color(0xFFF43F5E),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(color: TekColors.border),
            const SizedBox(height: 10),
            _detailRow(
                'Payment Mode:', ExpensePaymentMode.toDisplay(exp.paymentMode)),
            _detailRow('Expense Date:',
                DateFormat('dd MMMM yyyy, hh:mm a').format(exp.expenseDate)),
            _detailRow('Recorded By:', exp.recordedByName),
            if (exp.notes.isNotEmpty) _detailRow('Notes:', exp.notes),
            if (exp.isVoided) ...[
              _detailRow(
                  'Voided Date:',
                  exp.voidedAt != null
                      ? DateFormat('dd MMM yyyy, hh:mm a').format(exp.voidedAt!)
                      : '—'),
              _detailRow('Void Reason:', exp.voidReason ?? 'Voided by user'),
            ],
            if (exp.receiptUrl != null && exp.receiptUrl!.isNotEmpty) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: TekColors.primary),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: () async {
                  final uri = Uri.tryParse(exp.receiptUrl!);
                  if (uri != null)
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                },
                icon: const Icon(Icons.receipt_rounded,
                    size: 18, color: TekColors.primary),
                label: const Text('View Attached Receipt / Bill',
                    style: TextStyle(color: TekColors.primary)),
              ),
            ],
            const SizedBox(height: 16),
            if (!exp.isVoided) ...[
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: TekColors.error,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () {
                  Navigator.pop(ctx);
                  _confirmVoidExpense(exp);
                },
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: const Text('Void / Cancel Expense (ചിലവ് റദ്ദാക്കുക)'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(
                  fontSize: 12.5, color: TekColors.textSecondary),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: TekColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmVoidExpense(ExpenseItem exp) async {
    final reasonCtrl = TextEditingController(text: 'Entered by mistake');
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TekColors.bgCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: TekColors.border),
        ),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: TekColors.error, size: 24),
            SizedBox(width: 10),
            Text('Void Expense?'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Are you sure you want to void "${exp.title}" (₹${exp.amount.toStringAsFixed(2)})?\n\nThis will automatically reverse the ${exp.paymentMode} debit in your accounting ledger and restore the balance.',
              style:
                  const TextStyle(color: TekColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: reasonCtrl,
              decoration: const InputDecoration(
                labelText: 'Reason for voiding *',
                hintText: 'e.g. Cancelled, Duplicate entry',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel',
                style: TextStyle(color: TekColors.textSecondary)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: TekColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm Void & Reverse'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        final auth = context.read<AuthController>();
        final sId = widget.shopId.isNotEmpty
            ? widget.shopId
            : Db.setting('shop_id', 'tekfix');
        await ExpenseService.instance.voidExpense(
          shopId: sId,
          expenseId: exp.id,
          voidedByUid: auth.uid,
          voidedByName: auth.name.isNotEmpty ? auth.name : 'Staff',
          reason: reasonCtrl.text.trim(),
        );

        if (mounted) {
          toast(context, 'Expense voided and balance reversed successfully.');
          _loadData();
        }
      } catch (e) {
        if (mounted) {
          toast(context, 'Void failed: $e', error: true);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredExpenses;
    final double totalAmount = filtered
        .where((e) => !e.isVoided)
        .fold(0.0, (sum, e) => sum + e.amount);

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFFF43F5E),
        foregroundColor: Colors.white,
        onPressed: () =>
            AddExpenseDialog.show(context, onExpenseSaved: _loadData),
        icon: const Icon(Icons.add_rounded),
        label: const Text(
          'Add Expense (ചിലവ് ചേർക്കുക)',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _loadData,
        color: TekColors.primary,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            // Top App Bar
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFFF43F5E), Color(0xFFBE123C)],
                            ),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(Icons.receipt_long_rounded,
                              color: Colors.white, size: 22),
                        ),
                        const SizedBox(width: 14),
                        const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Expense Management',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: TekColors.textPrimary,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'കടയിലെ ചിലവുകൾ • Track & Control Business Expenses',
                              style: TextStyle(
                                fontSize: 12,
                                color: TekColors.textSecondary,
                                fontFamilyFallback:
                                    TekTypography.malayalamFallback,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Color(0xFFF59E0B)),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                          ),
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    DailyRentHistoryView(shopId: widget.shopId),
                              ),
                            ).then((_) => _loadData());
                          },
                          icon: const Icon(Icons.store_mall_directory_rounded,
                              size: 16, color: Color(0xFFF59E0B)),
                          label: const Text(
                            'Daily Rent (കട വാടക)',
                            style: TextStyle(
                              color: Color(0xFFF59E0B),
                              fontSize: 12.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.refresh_rounded,
                              color: TekColors.secondary),
                          onPressed: _loadData,
                          tooltip: 'Refresh Expenses',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // Four Dashboard Summary Cards (Requirement 2)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: LayoutBuilder(
                  builder: (ctx, constraints) {
                    final isWide = constraints.maxWidth >= 800;
                    if (isWide) {
                      return Row(
                        children: [
                          Expanded(
                              child: _buildMetricCard(
                                  "Today's Expenses",
                                  '₹${_metrics.todayTotal.toStringAsFixed(2)}',
                                  '${_metrics.todayCount} entries today',
                                  Icons.today_rounded,
                                  const Color(0xFFF43F5E))),
                          const SizedBox(width: 12),
                          Expanded(
                              child: _buildMetricCard(
                                  "This Month's Expenses",
                                  '₹${_metrics.thisMonthTotal.toStringAsFixed(2)}',
                                  DateFormat('MMMM yyyy')
                                      .format(DateTime.now()),
                                  Icons.calendar_month_rounded,
                                  const Color(0xFF8B5CF6))),
                          const SizedBox(width: 12),
                          Expanded(
                              child: _buildMetricCard(
                                  'Cash Expenses Today',
                                  '₹${_metrics.todayCashTotal.toStringAsFixed(2)}',
                                  'Paid from Drawer',
                                  Icons.payments_rounded,
                                  Colors.amber)),
                          const SizedBox(width: 12),
                          Expanded(
                              child: _buildMetricCard(
                                  'Bank/UPI Expenses Today',
                                  '₹${_metrics.todayBankTotal.toStringAsFixed(2)}',
                                  'Paid via Account/UPI',
                                  Icons.account_balance_rounded,
                                  const Color(0xFF00D4FF))),
                        ],
                      );
                    } else {
                      return Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                  child: _buildMetricCard(
                                      "Today's Expenses",
                                      '₹${_metrics.todayTotal.toStringAsFixed(2)}',
                                      '${_metrics.todayCount} entries',
                                      Icons.today_rounded,
                                      const Color(0xFFF43F5E))),
                              const SizedBox(width: 10),
                              Expanded(
                                  child: _buildMetricCard(
                                      "This Month",
                                      '₹${_metrics.thisMonthTotal.toStringAsFixed(2)}',
                                      DateFormat('MMM yyyy')
                                          .format(DateTime.now()),
                                      Icons.calendar_month_rounded,
                                      const Color(0xFF8B5CF6))),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                  child: _buildMetricCard(
                                      'Cash Expenses Today',
                                      '₹${_metrics.todayCashTotal.toStringAsFixed(2)}',
                                      'Drawer Cash',
                                      Icons.payments_rounded,
                                      Colors.amber)),
                              const SizedBox(width: 10),
                              Expanded(
                                  child: _buildMetricCard(
                                      'Bank/UPI Expenses',
                                      '₹${_metrics.todayBankTotal.toStringAsFixed(2)}',
                                      'Bank Account',
                                      Icons.account_balance_rounded,
                                      const Color(0xFF00D4FF))),
                            ],
                          ),
                        ],
                      );
                    }
                  },
                ),
              ),
            ),

            const SliverToBoxAdapter(child: SizedBox(height: 16)),

            // Search Bar & Filter Strip
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Search field
                    TextField(
                      controller: _searchCtrl,
                      onChanged: (_) => setState(() {}),
                      style: const TextStyle(
                          color: TekColors.textPrimary, fontSize: 13.5),
                      decoration: InputDecoration(
                        hintText:
                            'Search expenses by title, category, staff or notes...',
                        prefixIcon: const Icon(Icons.search_rounded,
                            color: TekColors.secondary),
                        suffixIcon: _searchCtrl.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear_rounded, size: 18),
                                onPressed: () {
                                  _searchCtrl.clear();
                                  setState(() {});
                                },
                              )
                            : null,
                      ),
                    ),
                    const SizedBox(height: 10),

                    // Quick Date Chips
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          ...['Today', 'Yesterday', 'This Week', 'This Month']
                              .map((d) {
                            final isSelected = _dateFilter == d;
                            return Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: ChoiceChip(
                                label: Text(d),
                                selected: isSelected,
                                selectedColor:
                                    TekColors.primary.withValues(alpha: 0.25),
                                labelStyle: TextStyle(
                                  color: isSelected
                                      ? TekColors.primary
                                      : TekColors.textSecondary,
                                  fontWeight: isSelected
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                  fontSize: 12,
                                ),
                                onSelected: (sel) {
                                  if (sel) setState(() => _dateFilter = d);
                                },
                              ),
                            );
                          }),
                          ActionChip(
                            label: Text(_dateFilter == 'Custom' &&
                                    _customDateRange != null
                                ? '${DateFormat('dd MMM').format(_customDateRange!.start)} - ${DateFormat('dd MMM').format(_customDateRange!.end)}'
                                : 'Custom Range...'),
                            avatar:
                                const Icon(Icons.date_range_rounded, size: 14),
                            onPressed: _pickCustomRange,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),

                    // Filter dropdowns: Category & Payment Mode & Staff
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          // Category Filter
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 2),
                            decoration: BoxDecoration(
                              color: TekColors.bgSecondary,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: TekColors.border),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: _selectedCategory,
                                dropdownColor: TekColors.bgCard,
                                style: const TextStyle(
                                    color: TekColors.textPrimary, fontSize: 12),
                                items: ['All', ...ExpenseCategory.all].map((c) {
                                  return DropdownMenuItem(
                                      value: c,
                                      child: Text(
                                          c == 'All' ? 'All Categories' : c));
                                }).toList(),
                                onChanged: (v) {
                                  if (v != null)
                                    setState(() => _selectedCategory = v);
                                },
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),

                          // Mode Filter
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 2),
                            decoration: BoxDecoration(
                              color: TekColors.bgSecondary,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: TekColors.border),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: _selectedPaymentMode,
                                dropdownColor: TekColors.bgCard,
                                style: const TextStyle(
                                    color: TekColors.textPrimary, fontSize: 12),
                                items: const [
                                  DropdownMenuItem(
                                      value: 'All', child: Text('All Modes')),
                                  DropdownMenuItem(
                                      value: 'CASH',
                                      child: Text('Cash in Hand')),
                                  DropdownMenuItem(
                                      value: 'BANK', child: Text('Bank / UPI')),
                                ],
                                onChanged: (v) {
                                  if (v != null)
                                    setState(() => _selectedPaymentMode = v);
                                },
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),

                          // Staff Filter
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 2),
                            decoration: BoxDecoration(
                              color: TekColors.bgSecondary,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: TekColors.border),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: _selectedStaff,
                                dropdownColor: TekColors.bgCard,
                                style: const TextStyle(
                                    color: TekColors.textPrimary, fontSize: 12),
                                items: _staffOptions.map((s) {
                                  return DropdownMenuItem(
                                      value: s,
                                      child:
                                          Text(s == 'All' ? 'All Staff' : s));
                                }).toList(),
                                onChanged: (v) {
                                  if (v != null)
                                    setState(() => _selectedStaff = v);
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SliverToBoxAdapter(child: SizedBox(height: 12)),

            // Total Filtered Bar
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: TekColors.bgSecondary,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: TekColors.border),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Showing ${filtered.length} expenses ($_dateFilter)',
                        style: const TextStyle(
                            fontSize: 12.5, color: TekColors.textSecondary),
                      ),
                      Text(
                        'Total: ₹${totalAmount.toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFF43F5E),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            const SliverToBoxAdapter(child: SizedBox(height: 10)),

            // Expenses List
            if (_isLoading)
              const SliverFillRemaining(
                child: Center(
                  child: CircularProgressIndicator(color: TekColors.primary),
                ),
              )
            else if (filtered.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: TekColors.bgSecondary,
                          shape: BoxShape.circle,
                          border: Border.all(color: TekColors.border),
                        ),
                        child: const Icon(Icons.receipt_long_rounded,
                            size: 48, color: TekColors.textMuted),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'ചിലവുകൾ ഒന്നും കണ്ടെത്തിയില്ല',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: TekColors.textPrimary,
                          fontFamilyFallback: TekTypography.malayalamFallback,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'No expenses found for the selected filters.',
                        style: TextStyle(
                            fontSize: 12.5, color: TekColors.textSecondary),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFF43F5E)),
                        onPressed: () => AddExpenseDialog.show(context,
                            onExpenseSaved: _loadData),
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Add First Expense'),
                      ),
                    ],
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, idx) {
                      final item = filtered[idx];
                      return _buildExpenseCard(item);
                    },
                    childCount: filtered.length,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricCard(
      String label, String value, String sub, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: TekColors.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: TekColors.border),
        boxShadow: TekColors.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12,
                      color: TekColors.textSecondary,
                      fontWeight: FontWeight.w500),
                ),
              ),
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 16, color: color),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: TekColors.textPrimary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            sub,
            style: TextStyle(fontSize: 10.5, color: color),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildExpenseCard(ExpenseItem item) {
    final isCash = item.isCash;
    final modeColor = isCash ? Colors.amber : const Color(0xFF00D4FF);

    return Container(
      key: ValueKey('expense_${item.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: TekColors.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: item.isVoided
              ? TekColors.error.withValues(alpha: 0.4)
              : TekColors.border,
        ),
        boxShadow: TekColors.cardShadow,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _showExpenseDetails(item),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              // Icon Badge
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: item.isVoided
                      ? TekColors.error.withValues(alpha: 0.15)
                      : modeColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  item.isVoided
                      ? Icons.block_rounded
                      : (isCash
                          ? Icons.payments_rounded
                          : Icons.account_balance_rounded),
                  color: item.isVoided ? TekColors.error : modeColor,
                  size: 20,
                ),
              ),
              const SizedBox(width: 14),

              // Title, Category & Date
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            item.title,
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.bold,
                              color: item.isVoided
                                  ? TekColors.textMuted
                                  : TekColors.textPrimary,
                              decoration: item.isVoided
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (item.receiptUrl != null) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.attach_file_rounded,
                              size: 14, color: TekColors.secondary),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Text(
                          item.category,
                          style: const TextStyle(
                              fontSize: 11.5, color: TekColors.textSecondary),
                        ),
                        const SizedBox(width: 6),
                        const Text('•',
                            style: TextStyle(
                                color: TekColors.textMuted, fontSize: 10)),
                        const SizedBox(width: 6),
                        Text(
                          DateFormat('dd MMM, hh:mm a')
                              .format(item.expenseDate),
                          style: const TextStyle(
                              fontSize: 11, color: TekColors.textMuted),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'By ${item.recordedByName}',
                      style: const TextStyle(
                          fontSize: 11, color: TekColors.textMuted),
                    ),
                  ],
                ),
              ),

              // Amount & Payment Mode Badge
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '₹${item.amount.toStringAsFixed(2)}',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: item.isVoided
                          ? TekColors.textMuted
                          : const Color(0xFFF43F5E),
                      decoration:
                          item.isVoided ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: modeColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                      border:
                          Border.all(color: modeColor.withValues(alpha: 0.5)),
                    ),
                    child: Text(
                      item.isVoided ? 'VOID' : (isCash ? 'CASH' : 'BANK/UPI'),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: item.isVoided ? TekColors.error : modeColor,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
