import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../auth/auth_controller.dart';
import '../main.dart' show Db, toast;
import '../theme/tek_tokens.dart';
import 'owner_finance_models.dart';
import 'owner_finance_service.dart';
import 'owner_ledger_view.dart';

class OwnerWithdrawalDialog extends StatefulWidget {
  final String? shopId;
  final VoidCallback? onWithdrawalSuccess;

  const OwnerWithdrawalDialog({
    super.key,
    this.shopId,
    this.onWithdrawalSuccess,
  });

  static Future<bool?> show(
    BuildContext context, {
    String? shopId,
    VoidCallback? onWithdrawalSuccess,
  }) {
    final isDesktop = MediaQuery.of(context).size.width >= 650;
    if (isDesktop) {
      return showDialog<bool>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 540),
            child: OwnerWithdrawalDialog(
              shopId: shopId,
              onWithdrawalSuccess: onWithdrawalSuccess,
            ),
          ),
        ),
      );
    } else {
      return showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) => Padding(
          padding:
              EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: OwnerWithdrawalDialog(
            shopId: shopId,
            onWithdrawalSuccess: onWithdrawalSuccess,
          ),
        ),
      );
    }
  }

  @override
  State<OwnerWithdrawalDialog> createState() => _OwnerWithdrawalDialogState();
}

class _OwnerWithdrawalDialogState extends State<OwnerWithdrawalDialog> {
  final _amountCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  DateTime _selectedDate = DateTime.now();
  String _paymentMode = 'CASH'; // CASH or BANK
  bool _isLoading = true;
  bool _isSubmitting = false;

  OwnerSalarySettings? _settings;
  OwnerMonthlyQuotaMetrics _quotaMetrics =
      OwnerMonthlyQuotaMetrics.empty(DateTime.now());

  double _enteredAmount = 0.0;

  @override
  void initState() {
    super.initState();
    _amountCtrl.addListener(_onAmountChanged);
    _loadMetrics();
  }

  @override
  void dispose() {
    _amountCtrl.removeListener(_onAmountChanged);
    _amountCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  void _onAmountChanged() {
    final v = double.tryParse(_amountCtrl.text.trim()) ?? 0.0;
    if (v != _enteredAmount) {
      setState(() => _enteredAmount = v);
    }
  }

  Future<void> _loadMetrics() async {
    final sId = widget.shopId ?? Db.setting('shop_id', 'tekfix');
    try {
      final s = await OwnerFinanceService.instance.getSettings(shopId: sId);
      final q = await OwnerFinanceService.instance.getQuotaMetrics(
        shopId: sId,
        forDate: _selectedDate,
      );
      if (mounted) {
        setState(() {
          _settings = s;
          _quotaMetrics = q;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _selectDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2025),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      builder: (context, child) {
        return Theme(
          data: ThemeData.dark().copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFF8B5CF6),
              surface: Color(0xFF111B35),
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null && picked != _selectedDate) {
      setState(() {
        _selectedDate = picked;
        _isLoading = true;
      });
      _loadMetrics();
    }
  }

  Future<void> _submitWithdrawal() async {
    if (!_formKey.currentState!.validate()) return;
    if (_enteredAmount <= 0) {
      toast(context, 'ശരിയായ തുക നൽകുക (Enter a valid amount)', error: true);
      return;
    }

    setState(() => _isSubmitting = true);
    HapticFeedback.mediumImpact();

    final auth = context.read<AuthController>();
    final sId = widget.shopId ?? auth.shopId;
    final staffId = auth.uid.isNotEmpty ? auth.uid : 'owner';
    final staffName = auth.name.isNotEmpty ? auth.name : 'Shop Owner';

    try {
      final item = await OwnerFinanceService.instance.recordWithdrawal(
        shopId: sId,
        amount: _enteredAmount,
        paymentMode: _paymentMode,
        recordedByUid: staffId,
        recordedByName: staffName,
        date: _selectedDate,
        notes: _notesCtrl.text.trim(),
      );

      if (mounted) {
        String msg =
            'Withdrawal of ₹${_enteredAmount.toStringAsFixed(0)} recorded successfully!';
        if (item.isSplit) {
          msg =
              '₹${item.salaryPortion.toStringAsFixed(0)} recorded as Salary + ₹${item.drawingsPortion.toStringAsFixed(0)} as Drawings!';
        } else if (item.hasDrawings) {
          msg =
              '₹${item.drawingsPortion.toStringAsFixed(0)} recorded as Owner Excess Drawings!';
        } else {
          msg =
              '₹${item.salaryPortion.toStringAsFixed(0)} recorded as Owner Salary!';
        }
        toast(context, msg);
        widget.onWithdrawalSuccess?.call();
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSubmitting = false);
        toast(context, 'Error: $e', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final monthName = OwnerFinanceService.toDisplayDate(
      DateTime(_selectedDate.year, _selectedDate.month, 1),
    ).split(' ')[1]; // e.g. "Nov"

    final remaining = _quotaMetrics.remainingSalaryThisMonth;
    final isLimitReached = _quotaMetrics.isQuotaFull;

    // Split calculations for dynamic real-time preview
    double previewSalary = 0.0;
    double previewDrawings = 0.0;
    if (_enteredAmount > 0) {
      if (remaining <= 0) {
        previewSalary = 0.0;
        previewDrawings = _enteredAmount;
      } else if (_enteredAmount <= remaining) {
        previewSalary = _enteredAmount;
        previewDrawings = 0.0;
      } else {
        previewSalary = remaining;
        previewDrawings = _enteredAmount - remaining;
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: TekColors.mainBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: TekColors.border.withValues(alpha: 0.8), width: 1.2),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 32,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. Header with Title & Close Button
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF8B5CF6), Color(0xFF6D28D9)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.account_balance_wallet_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Owner Cash Withdrawal',
                          style: TextStyle(
                            fontSize: 16.5,
                            fontWeight: FontWeight.bold,
                            color: TekColors.textPrimary,
                          ),
                        ),
                        Text(
                          'ഉടമയുടെ പിൻവലിക്കൽ • Base ₹20,000 Quota',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: TekColors.textSecondary,
                            fontFamilyFallback: TekTypography.malayalamFallback,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded,
                        color: TekColors.textSecondary),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),

              const SizedBox(height: 18),

              // 2. Salary Quota Progress Card
              if (_isLoading)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Color(0xFF8B5CF6)),
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: TekColors.cardBg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isLimitReached
                          ? const Color(0xFFF59E0B).withValues(alpha: 0.5)
                          : const Color(0xFF8B5CF6).withValues(alpha: 0.35),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(
                                isLimitReached
                                    ? Icons.warning_amber_rounded
                                    : Icons.donut_large_rounded,
                                size: 16,
                                color: isLimitReached
                                    ? const Color(0xFFF59E0B)
                                    : const Color(0xFF8B5CF6),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                "Owner Salary Quota ($monthName ${DateTime.now().year})",
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: TekColors.textPrimary,
                                ),
                              ),
                            ],
                          ),
                          Text(
                            "₹${_quotaMetrics.usedSalaryThisMonth.toStringAsFixed(0)} / ₹${_quotaMetrics.monthlyLimit.toStringAsFixed(0)}",
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.bold,
                              color: isLimitReached
                                  ? const Color(0xFFF59E0B)
                                  : const Color(0xFF8B5CF6),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: _quotaMetrics.quotaPercentage,
                          minHeight: 8,
                          backgroundColor: TekColors.elevatedSurface,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            isLimitReached
                                ? const Color(0xFFF59E0B)
                                : const Color(0xFF8B5CF6),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (isLimitReached)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color:
                                const Color(0xFFF59E0B).withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: const Color(0xFFF59E0B)
                                    .withValues(alpha: 0.3)),
                          ),
                          child: const Row(
                            children: [
                              Icon(Icons.info_outline_rounded,
                                  size: 14, color: Color(0xFFF59E0B)),
                              SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  "Salary Limit Reached — Excess will be recorded as Owner Drawings (ശമ്പള പരിധി കഴിഞ്ഞു - അധികം പിൻവലിക്കലായി രേഖപ്പെടുത്തും)",
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFFF59E0B),
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              "Remaining Salary Quota: ₹${remaining.toStringAsFixed(0)}",
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: Color(0xFF10B981),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (_quotaMetrics.excessDrawingsThisMonth > 0)
                              Text(
                                "Excess Drawings: ₹${_quotaMetrics.excessDrawingsThisMonth.toStringAsFixed(0)}",
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFFA78BFA),
                                ),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),

              const SizedBox(height: 16),

              // 3. Date & Mode Selector Row
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: _selectDate,
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: TekColors.cardBg,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: TekColors.border),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.calendar_today_rounded,
                                size: 16, color: Color(0xFF8B5CF6)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('Date (തീയതി)',
                                      style: TextStyle(
                                          fontSize: 10,
                                          color: TekColors.textSecondary)),
                                  Text(
                                    OwnerFinanceService.toDisplayDate(
                                        _selectedDate),
                                    style: const TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w600,
                                      color: TekColors.textPrimary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: TekColors.cardBg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: TekColors.border),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: _modeOption('CASH', 'Cash in Hand (ക്യാഷ്)'),
                          ),
                          Expanded(
                            child: _modeOption('BANK', 'Bank / UPI (ബാങ്ക്)'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // 4. Withdrawal Amount Input
              TextFormField(
                controller: _amountCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                autofocus: true,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
                decoration: InputDecoration(
                  labelText: 'Withdrawal Amount (പിൻവലിക്കുന്ന തുക)',
                  labelStyle: const TextStyle(
                      color: TekColors.textSecondary, fontSize: 13),
                  prefixText: '₹ ',
                  prefixStyle: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF8B5CF6),
                  ),
                  filled: true,
                  fillColor: TekColors.cardBg,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
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
                    borderSide:
                        const BorderSide(color: Color(0xFF8B5CF6), width: 1.8),
                  ),
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty)
                    return 'തുക നൽകുക (Amount required)';
                  final n = double.tryParse(val.trim());
                  if (n == null || n <= 0) return 'ശരിയായ പോസിറ്റീവ് തുക നൽകുക';
                  return null;
                },
              ),

              const SizedBox(height: 8),

              // Quick Amount Chips
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _quickAmountChip(2000),
                  _quickAmountChip(5000),
                  _quickAmountChip(10000),
                  if (remaining > 0 &&
                      remaining != 2000 &&
                      remaining != 5000 &&
                      remaining != 10000)
                    _quickAmountChip(remaining,
                        label:
                            'Full Salary (₹${remaining.toStringAsFixed(0)})'),
                ],
              ),

              const SizedBox(height: 14),

              // 5. Dynamic Real-time Split Preview Card
              if (_enteredAmount > 0)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: TekColors.elevatedSurface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: const Color(0xFF8B5CF6).withValues(alpha: 0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "AUTO-CLASSIFICATION PREVIEW:",
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: Color(0xFF8B5CF6),
                        ),
                      ),
                      const SizedBox(height: 6),
                      if (previewSalary > 0)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.check_circle_outline_rounded,
                                    size: 14, color: Color(0xFF10B981)),
                                SizedBox(width: 6),
                                Text(
                                  "Owner Salary (OPEX Expense):",
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: TekColors.textPrimary),
                                ),
                              ],
                            ),
                            Text(
                              "₹${previewSalary.toStringAsFixed(0)}",
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF10B981),
                              ),
                            ),
                          ],
                        ),
                      if (previewDrawings > 0) ...[
                        if (previewSalary > 0) const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.account_balance_outlined,
                                    size: 14, color: Color(0xFFA78BFA)),
                                SizedBox(width: 6),
                                Text(
                                  "Owner Drawings (Equity Withdrawal):",
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: TekColors.textPrimary),
                                ),
                              ],
                            ),
                            Text(
                              "₹${previewDrawings.toStringAsFixed(0)}",
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFFA78BFA),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),

              const SizedBox(height: 14),

              // 6. Notes Input
              TextFormField(
                controller: _notesCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 13.5),
                decoration: InputDecoration(
                  labelText: 'Notes / Reason (കുറിപ്പ് / കാരണം - ഓപ്ഷണൽ)',
                  labelStyle: const TextStyle(
                      color: TekColors.textSecondary, fontSize: 12),
                  filled: true,
                  fillColor: TekColors.cardBg,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: TekColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: TekColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF8B5CF6)),
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // 7. Submit Action Button
              ElevatedButton(
                onPressed: _isSubmitting ? null : _submitWithdrawal,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF8B5CF6),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  elevation: 4,
                ),
                child: _isSubmitting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.check_rounded, size: 18),
                          const SizedBox(width: 8),
                          Text(
                            _enteredAmount > 0
                                ? 'Record Withdrawal (₹${_enteredAmount.toStringAsFixed(0)})'
                                : 'Record Withdrawal (രേഖപ്പെടുത്തുക)',
                            style: const TextStyle(
                                fontSize: 14.5, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
              ),

              const SizedBox(height: 10),

              // Link to View Owner Ledger
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const OwnerLedgerView()),
                  );
                },
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.menu_book_rounded,
                        size: 15, color: Color(0xFFA78BFA)),
                    SizedBox(width: 6),
                    Text(
                      'View Owner Salary & Drawings Ledger (ലെഡ്ജർ കാണുക)',
                      style: TextStyle(color: Color(0xFFA78BFA), fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _modeOption(String mode, String label) {
    final isSelected = _paymentMode == mode;
    return GestureDetector(
      onTap: () => setState(() => _paymentMode = mode),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF8B5CF6) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Text(
            mode == 'CASH' ? 'Cash' : 'Bank/UPI',
            style: TextStyle(
              fontSize: 12,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
              color: isSelected ? Colors.white : TekColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _quickAmountChip(double amt, {String? label}) {
    return InkWell(
      onTap: () {
        _amountCtrl.text = amt.toStringAsFixed(0);
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: TekColors.cardBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: TekColors.border),
        ),
        child: Text(
          label ?? '₹${amt.toStringAsFixed(0)}',
          style: const TextStyle(fontSize: 11, color: TekColors.textSecondary),
        ),
      ),
    );
  }
}
