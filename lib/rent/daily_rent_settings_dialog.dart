import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../auth/auth_controller.dart';
import '../expenses/expense_models.dart';
import '../main.dart' show Db, toast;
import '../theme/tek_tokens.dart';
import 'rent_models.dart';
import 'rent_service.dart';

class DailyRentSettingsDialog extends StatefulWidget {
  final String? shopId;
  final VoidCallback? onSettingsSaved;

  const DailyRentSettingsDialog({
    super.key,
    this.shopId,
    this.onSettingsSaved,
  });

  static Future<void> show(
    BuildContext context, {
    String? shopId,
    VoidCallback? onSettingsSaved,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: DailyRentSettingsDialog(
            shopId: shopId,
            onSettingsSaved: onSettingsSaved,
          ),
        ),
      ),
    );
  }

  @override
  State<DailyRentSettingsDialog> createState() => _DailyRentSettingsDialogState();
}

class _DailyRentSettingsDialogState extends State<DailyRentSettingsDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _amountCtrl;
  late final TextEditingController _landlordCtrl;
  late final TextEditingController _notesCtrl;

  bool _isLoading = true;
  bool _isSaving = false;
  DailyRentSettings? _currentSettings;

  String _defaultMode = ExpensePaymentMode.cash;
  RentScheduleType _scheduleType = RentScheduleType.everyDay;
  bool _isActive = true;
  DateTime _effectiveDate = DateTime(2026, 1, 1);
  List<int> _operatingDays = [1, 2, 3, 4, 5, 6, 7];

  @override
  void initState() {
    super.initState();
    _amountCtrl = TextEditingController();
    _landlordCtrl = TextEditingController();
    _notesCtrl = TextEditingController();
    _loadSettings();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _landlordCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    setState(() => _isLoading = true);
    final sId = widget.shopId ?? Db.setting('shop_id', 'tekfix');
    final s = await RentService.instance.getSettings(shopId: sId);
    if (mounted) {
      setState(() {
        _currentSettings = s;
        _amountCtrl.text = s.dailyRentAmount.toStringAsFixed(0);
        _landlordCtrl.text = s.landlordName;
        _notesCtrl.text = s.notes;
        _defaultMode = s.defaultPaymentMode;
        _scheduleType = s.scheduleType;
        _isActive = s.isActive;
        _effectiveDate = s.effectiveDate;
        _operatingDays = List<int>.from(s.operatingDays);
        _isLoading = false;
      });
    }
  }

  Future<void> _save() async {
    if (_isSaving) return;
    if (!_formKey.currentState!.validate()) return;

    final amt = double.tryParse(_amountCtrl.text.trim()) ?? 0.0;
    if (amt <= 0) {
      toast(context, 'Valid positive daily rent amount required', error: true);
      return;
    }

    setState(() => _isSaving = true);
    HapticFeedback.mediumImpact();

    final auth = context.read<AuthController>();
    final sId = widget.shopId ?? auth.shopId;
    final staffId = auth.uid.isNotEmpty ? auth.uid : 'admin';
    final staffName = auth.name.isNotEmpty ? auth.name : 'Admin';

    final updated = (_currentSettings ?? DailyRentSettings(effectiveDate: _effectiveDate)).copyWith(
      dailyRentAmount: amt,
      dailyRentAmountPaise: (amt * 100).round(),
      landlordName: _landlordCtrl.text.trim(),
      defaultPaymentMode: _defaultMode,
      scheduleType: _scheduleType,
      isActive: _isActive,
      effectiveDate: _effectiveDate,
      operatingDays: _operatingDays,
      notes: _notesCtrl.text.trim(),
    );

    try {
      await RentService.instance.saveSettings(
        shopId: sId,
        newSettings: updated,
        staffId: staffId,
        staffName: staffName,
      );

      if (mounted) {
        toast(context, 'Daily Rent settings saved successfully (വാടക വിവരങ്ങൾ സേവ് ചെയ്തു)!');
        widget.onSettingsSaved?.call();
        Navigator.pop(context);
      }
    } catch (e) {
      setState(() => _isSaving = false);
      if (mounted) toast(context, 'Failed saving rent settings: $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: TekColors.bgCard,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: TekColors.border, width: 1.5),
      ),
      child: _isLoading
          ? const Center(heightFactor: 4, child: CircularProgressIndicator(color: Color(0xFFF59E0B)))
          : Form(
              key: _formKey,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Header
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(Icons.tune_rounded, color: Color(0xFFF59E0B), size: 20),
                            ),
                            const SizedBox(width: 10),
                            const Text(
                              'Daily Rent Settings',
                              style: TextStyle(
                                color: TekColors.textPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded, color: TekColors.textSecondary),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // Active Status Switch
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      activeColor: const Color(0xFFF59E0B),
                      title: const Text('Rent Module Active (വാടക സജീവം)', style: TextStyle(color: TekColors.textPrimary, fontSize: 13.5, fontWeight: FontWeight.w600)),
                      subtitle: const Text('Enable or pause automatic rent schedule', style: TextStyle(color: TekColors.textMuted, fontSize: 11.5)),
                      value: _isActive,
                      onChanged: (v) => setState(() => _isActive = v),
                    ),

                    const Divider(color: TekColors.border),
                    const SizedBox(height: 8),

                    // Daily Rent Amount
                    TextFormField(
                      controller: _amountCtrl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      style: const TextStyle(color: TekColors.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
                      decoration: InputDecoration(
                        labelText: 'Configured Daily Rent Amount (പ്രതിദിന വാടക) *',
                        prefixText: '₹ ',
                        prefixStyle: const TextStyle(color: TekColors.primary, fontWeight: FontWeight.bold),
                        filled: true,
                        fillColor: TekColors.bgSecondary,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: TekColors.border)),
                      ),
                      validator: (v) {
                        final n = double.tryParse(v?.trim() ?? '');
                        if (n == null || n <= 0) return 'Valid positive amount required';
                        return null;
                      },
                    ),

                    const SizedBox(height: 12),

                    // Landlord Name
                    TextFormField(
                      controller: _landlordCtrl,
                      style: const TextStyle(color: TekColors.textPrimary, fontSize: 13),
                      decoration: InputDecoration(
                        labelText: 'Landlord / Property Owner Name',
                        filled: true,
                        fillColor: TekColors.bgSecondary,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: TekColors.border)),
                      ),
                    ),

                    const SizedBox(height: 12),

                    // Default Payment Mode
                    Row(
                      children: [
                        const Text('Default Mode: ', style: TextStyle(color: TekColors.textSecondary, fontSize: 12.5)),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: const Text('Cash in Hand'),
                          selected: _defaultMode == ExpensePaymentMode.cash,
                          selectedColor: const Color(0xFFF59E0B).withValues(alpha: 0.25),
                          onSelected: (_) => setState(() => _defaultMode = ExpensePaymentMode.cash),
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: const Text('Bank / UPI'),
                          selected: _defaultMode == ExpensePaymentMode.bank,
                          selectedColor: TekColors.secondary.withValues(alpha: 0.25),
                          onSelected: (_) => setState(() => _defaultMode = ExpensePaymentMode.bank),
                        ),
                      ],
                    ),

                    const SizedBox(height: 12),

                    // Schedule Type
                    DropdownButtonFormField<RentScheduleType>(
                      value: _scheduleType,
                      dropdownColor: TekColors.bgCard,
                      decoration: InputDecoration(
                        labelText: 'Rent Schedule Policy (വാടക കണക്കാക്കേണ്ട ദിവസങ്ങൾ)',
                        filled: true,
                        fillColor: TekColors.bgSecondary,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: TekColors.border)),
                      ),
                      items: RentScheduleType.values.map((s) {
                        return DropdownMenuItem(
                          value: s,
                          child: Text(s.label, style: const TextStyle(color: TekColors.textPrimary, fontSize: 13)),
                        );
                      }).toList(),
                      onChanged: (v) {
                        if (v != null) setState(() => _scheduleType = v);
                      },
                    ),

                    const SizedBox(height: 12),

                    // Operating Days Checkboxes (if operating days only)
                    if (_scheduleType == RentScheduleType.operatingDaysOnly) ...[
                      const Text('Operating Days:', style: TextStyle(color: TekColors.textSecondary, fontSize: 12)),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        children: [
                          _dayChip(1, 'Mon'),
                          _dayChip(2, 'Tue'),
                          _dayChip(3, 'Wed'),
                          _dayChip(4, 'Thu'),
                          _dayChip(5, 'Fri'),
                          _dayChip(6, 'Sat'),
                          _dayChip(7, 'Sun'),
                        ],
                      ),
                      const SizedBox(height: 12),
                    ],

                    // Effective Date
                    InkWell(
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _effectiveDate,
                          firstDate: DateTime(2024, 1, 1),
                          lastDate: DateTime.now().add(const Duration(days: 365)),
                        );
                        if (picked != null) {
                          setState(() => _effectiveDate = picked);
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        decoration: BoxDecoration(
                          color: TekColors.bgSecondary,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: TekColors.border),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Rent Rate Effective Date: ${DateFormat('dd MMM yyyy').format(_effectiveDate)}',
                              style: const TextStyle(color: TekColors.textPrimary, fontSize: 12.5),
                            ),
                            const Icon(Icons.calendar_today_rounded, size: 16, color: TekColors.primary),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 12),

                    // Notes
                    TextFormField(
                      controller: _notesCtrl,
                      maxLines: 2,
                      style: const TextStyle(color: TekColors.textPrimary, fontSize: 13),
                      decoration: InputDecoration(
                        labelText: 'Rental Agreement / Terms Notes',
                        filled: true,
                        fillColor: TekColors.bgSecondary,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: TekColors.border)),
                      ),
                    ),

                    const SizedBox(height: 20),

                    // Save Button
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFF59E0B),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _isSaving ? null : _save,
                      icon: _isSaving
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2))
                          : const Icon(Icons.check_circle_rounded, size: 18),
                      label: Text(_isSaving ? 'Saving...' : 'Save Settings', style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _dayChip(int day, String name) {
    final sel = _operatingDays.contains(day);
    return FilterChip(
      label: Text(name),
      selected: sel,
      selectedColor: const Color(0xFFF59E0B).withValues(alpha: 0.3),
      onSelected: (val) {
        setState(() {
          if (val) {
            _operatingDays.add(day);
          } else {
            _operatingDays.remove(day);
          }
        });
      },
    );
  }
}
