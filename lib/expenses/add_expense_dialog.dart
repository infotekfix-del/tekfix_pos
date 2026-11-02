import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../auth/auth_controller.dart';
import '../main.dart' show Db, toast;
import '../theme/tek_tokens.dart';
import 'expense_models.dart';
import 'expense_service.dart';

class AddExpenseDialog extends StatefulWidget {
  final String? initialCategory;
  final VoidCallback? onExpenseSaved;

  const AddExpenseDialog({
    super.key,
    this.initialCategory,
    this.onExpenseSaved,
  });

  static Future<ExpenseItem?> show(
    BuildContext context, {
    String? initialCategory,
    VoidCallback? onExpenseSaved,
  }) {
    final isWide = MediaQuery.of(context).size.width >= 700;
    if (isWide) {
      return showDialog<ExpenseItem?>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 580),
            child: AddExpenseDialog(
              initialCategory: initialCategory,
              onExpenseSaved: onExpenseSaved,
            ),
          ),
        ),
      );
    } else {
      return showModalBottomSheet<ExpenseItem?>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) => AddExpenseDialog(
          initialCategory: initialCategory,
          onExpenseSaved: onExpenseSaved,
        ),
      );
    }
  }

  @override
  State<AddExpenseDialog> createState() => _AddExpenseDialogState();
}

class _AddExpenseDialogState extends State<AddExpenseDialog> {
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  late String _category;
  String _paymentMode = ExpensePaymentMode.cash;
  DateTime _expenseDate = DateTime.now();

  PlatformFile? _pickedFile;
  Uint8List? _fileBytes;
  bool _isSubmitting = false;
  String? _errorMessage;

  final List<String> _quickSuggestions = [
    'Packing Covers',
    'Tea & Snacks',
    'Electricity Bill',
    'Pen and Notebook',
    'Shop Cleaning',
    'Travel & Auto Fare',
  ];

  @override
  void initState() {
    super.initState();
    _category = widget.initialCategory ?? ExpenseCategory.stationeryAndPacking;
    if (!ExpenseCategory.all.contains(_category)) {
      _category = ExpenseCategory.stationeryAndPacking;
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _amountCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickAttachment() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'pdf'],
        withData: true,
      );
      if (res != null && res.files.isNotEmpty) {
        final f = res.files.first;
        setState(() {
          _pickedFile = f;
          _fileBytes = f.bytes;
        });
      }
    } catch (e) {
      debugPrint('[AddExpenseDialog] File pick error: $e');
    }
  }

  Future<void> _pickDateTime() async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: _expenseDate,
      firstDate: DateTime(2023),
      lastDate: DateTime.now().add(const Duration(days: 1)),
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

    if (pickedDate != null && mounted) {
      final pickedTime = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(_expenseDate),
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

      if (pickedTime != null) {
        setState(() {
          _expenseDate = DateTime(
            pickedDate.year,
            pickedDate.month,
            pickedDate.day,
            pickedTime.hour,
            pickedTime.minute,
          );
        });
      } else {
        setState(() {
          _expenseDate = DateTime(
            pickedDate.year,
            pickedDate.month,
            pickedDate.day,
            _expenseDate.hour,
            _expenseDate.minute,
          );
        });
      }
    }
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;

    if (!_formKey.currentState!.validate()) {
      return;
    }

    final double amount = double.tryParse(_amountCtrl.text.trim()) ?? 0.0;
    if (amount <= 0) {
      setState(() => _errorMessage = 'സാധുതയുള്ള തുക നൽകുക (Enter a valid amount)');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      final auth = context.read<AuthController>();
      final shopId = auth.shopId.isNotEmpty ? auth.shopId : Db.setting('shop_id', 'tekfix');
      final uid = auth.uid.isNotEmpty ? auth.uid : Db.setting('staff_logged_id', 'staff');
      final name = auth.name.isNotEmpty
          ? auth.name
          : Db.setting('staff_logged_name', 'Staff');

      String? uploadedUrl;
      if (_pickedFile != null && _fileBytes != null) {
        final ext = _pickedFile!.extension?.toLowerCase() ?? 'jpg';
        final mimeType = ext == 'pdf' ? 'application/pdf' : 'image/$ext';
        final tempExpId = 'EXP_${DateTime.now().millisecondsSinceEpoch}';

        uploadedUrl = await ExpenseService.instance.uploadReceiptFile(
          shopId: shopId,
          expenseId: tempExpId,
          fileName: _pickedFile!.name,
          bytes: _fileBytes!,
          mimeType: mimeType,
        );
      }

      final expense = await ExpenseService.instance.createExpense(
        shopId: shopId,
        title: _titleCtrl.text.trim(),
        category: _category,
        amount: amount,
        paymentMode: _paymentMode,
        expenseDate: _expenseDate,
        recordedByUid: uid,
        recordedByName: name,
        notes: _notesCtrl.text.trim(),
        receiptUrl: uploadedUrl,
      );

      HapticFeedback.mediumImpact();

      if (mounted) {
        toast(
          context,
          'ചിലവ് വിജയകരമായി ചേർത്തു (Expense ₹${amount.toStringAsFixed(2)} added)',
        );
        widget.onExpenseSaved?.call();
        Navigator.pop(context, expense);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'പരാജയപ്പെട്ടു: $e (Expense could not be saved)';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final recordedName = auth.name.isNotEmpty
        ? auth.name
        : Db.setting('staff_logged_name', 'Logged in User');

    return Container(
      decoration: BoxDecoration(
        color: TekColors.bgCard,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: TekColors.border, width: 1.2),
        boxShadow: TekColors.cardShadow,
      ),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
            left: 20,
            right: 20,
            top: 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
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
                    child: const Icon(
                      Icons.receipt_long_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Add Expense',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: TekColors.textPrimary,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'ചിലവുകൾ രേഖപ്പെടുത്തുക (Record Business Expense)',
                          style: TextStyle(
                            fontSize: 12,
                            color: TekColors.textSecondary,
                            fontFamilyFallback: TekTypography.malayalamFallback,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: TekColors.textSecondary),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),

              const SizedBox(height: 18),

              // Error banner if any
              if (_errorMessage != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: TekColors.error.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: TekColors.error.withValues(alpha: 0.5)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline_rounded,
                          color: TekColors.error, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(
                            color: Color(0xFFFECDD3),
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],

              // Quick Title Suggestions Chips
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: _quickSuggestions.map((s) {
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ActionChip(
                        label: Text(s, style: const TextStyle(fontSize: 11.5)),
                        backgroundColor: TekColors.bgSecondary,
                        side: const BorderSide(color: TekColors.border),
                        onPressed: () {
                          setState(() {
                            _titleCtrl.text = s;
                            if (s.contains('Tea')) {
                              _category = ExpenseCategory.refreshmentsAndFood;
                            } else if (s.contains('Electricity')) {
                              _category = ExpenseCategory.electricityAndUtility;
                            } else if (s.contains('Travel')) {
                              _category = ExpenseCategory.transportationAndTravel;
                            } else if (s.contains('Packing') || s.contains('Pen')) {
                              _category = ExpenseCategory.stationeryAndPacking;
                            }
                          });
                        },
                      ),
                    );
                  }).toList(),
                ),
              ),

              const SizedBox(height: 14),

              // Field 1: Expense Title
              TextFormField(
                controller: _titleCtrl,
                autofocus: true,
                style: const TextStyle(color: TekColors.textPrimary, fontWeight: FontWeight.w600),
                decoration: const InputDecoration(
                  labelText: 'Expense Title (ചിലവിന്റെ പേര്) *',
                  hintText: 'ഉദാ: Packing Covers, Tea & Snacks',
                  prefixIcon: Icon(Icons.edit_note_rounded, color: TekColors.secondary),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) {
                    return 'വിവരണം നൽകുക (Title is required)';
                  }
                  return null;
                },
              ),

              const SizedBox(height: 14),

              // Field 2: Category Dropdown
              DropdownButtonFormField<String>(
                value: _category,
                dropdownColor: TekColors.bgCard,
                style: const TextStyle(color: TekColors.textPrimary, fontSize: 13.5),
                decoration: const InputDecoration(
                  labelText: 'Category (വിഭാഗം) *',
                  prefixIcon: Icon(Icons.category_rounded, color: TekColors.secondary),
                ),
                items: ExpenseCategory.all.map((c) {
                  return DropdownMenuItem(
                    value: c,
                    child: Text(
                      '$c (${ExpenseCategory.toMalayalam(c)})',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamilyFallback: TekTypography.malayalamFallback),
                    ),
                  );
                }).toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _category = v);
                },
              ),

              const SizedBox(height: 14),

              // Field 3: Amount in INR
              TextFormField(
                controller: _amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(
                  color: TekColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
                decoration: const InputDecoration(
                  labelText: 'Amount (തുക) *',
                  hintText: '0.00',
                  prefixText: '₹ ',
                  prefixStyle: TextStyle(
                    color: Color(0xFFF43F5E),
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) {
                    return 'തുക നൽകുക (Amount is required)';
                  }
                  final parsed = double.tryParse(v.trim());
                  if (parsed == null || parsed <= 0) {
                    return 'സാധുതയുള്ള പോസിറ്റീവ് തുക നൽകുക';
                  }
                  return null;
                },
              ),

              const SizedBox(height: 16),

              // Field 4: Payment Mode Toggle
              const Text(
                'Payment Mode (പേയ്‌മെന്റ് രീതി) *',
                style: TextStyle(
                  fontSize: 12.5,
                  color: TekColors.textSecondary,
                  fontWeight: FontWeight.w600,
                  fontFamilyFallback: TekTypography.malayalamFallback,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _buildModeOption(
                      title: 'Cash in Hand',
                      subtitle: 'ക്യാഷ് ബോക്സ്',
                      icon: Icons.payments_rounded,
                      mode: ExpensePaymentMode.cash,
                      activeColor: Colors.amber,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _buildModeOption(
                      title: 'Bank / UPI',
                      subtitle: 'ബാങ്ക് അക്കൗണ്ട്',
                      icon: Icons.account_balance_rounded,
                      mode: ExpensePaymentMode.bank,
                      activeColor: TekColors.primary,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // Field 5 & 6: Date Picker & Paid By Info
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: _pickDateTime,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        decoration: BoxDecoration(
                          color: TekColors.bgSecondary,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: TekColors.border),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.calendar_today_rounded, size: 16, color: TekColors.secondary),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Expense Date',
                                    style: TextStyle(fontSize: 11, color: TekColors.textSecondary),
                                  ),
                                  Text(
                                    DateFormat('dd MMM yyyy, hh:mm a').format(_expenseDate),
                                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: TekColors.textPrimary),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
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
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      decoration: BoxDecoration(
                        color: TekColors.bgSecondary,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: TekColors.border),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.person_outline_rounded, size: 16, color: TekColors.secondary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Recorded By',
                                  style: TextStyle(fontSize: 11, color: TekColors.textSecondary),
                                ),
                                Text(
                                  recordedName,
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: TekColors.textPrimary),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 14),

              // Field 7: Optional Notes
              TextFormField(
                controller: _notesCtrl,
                maxLines: 2,
                style: const TextStyle(color: TekColors.textPrimary, fontSize: 13),
                decoration: const InputDecoration(
                  labelText: 'Notes (ഓപ്ഷണൽ കുറിപ്പ്)',
                  hintText: 'കൂടുതൽ വിവരങ്ങൾ...',
                  prefixIcon: Icon(Icons.notes_rounded, color: TekColors.secondary),
                ),
              ),

              const SizedBox(height: 14),

              // Field 8: Receipt Attachment
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: TekColors.bgSecondary,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: TekColors.border),
                ),
                child: Row(
                  children: [
                    Icon(
                      _pickedFile != null ? Icons.check_circle_rounded : Icons.attach_file_rounded,
                      color: _pickedFile != null ? TekColors.success : TekColors.secondary,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _pickedFile != null
                                ? _pickedFile!.name
                                : 'Attach Bill / Receipt (ബിൽ അറ്റാച്ച് ചെയ്യുക)',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: _pickedFile != null ? FontWeight.bold : FontWeight.normal,
                              color: _pickedFile != null ? TekColors.textPrimary : TekColors.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (_pickedFile != null)
                            Text(
                              '${(_pickedFile!.size / 1024).toStringAsFixed(1)} KB',
                              style: const TextStyle(fontSize: 11, color: TekColors.textMuted),
                            ),
                        ],
                      ),
                    ),
                    if (_pickedFile != null)
                      IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 18, color: TekColors.error),
                        onPressed: () => setState(() {
                          _pickedFile = null;
                          _fileBytes = null;
                        }),
                      )
                    else
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          side: const BorderSide(color: TekColors.border),
                        ),
                        onPressed: _pickAttachment,
                        icon: const Icon(Icons.upload_file_rounded, size: 16),
                        label: const Text('Browse', style: TextStyle(fontSize: 12)),
                      ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // Submit Action Button
              SizedBox(
                height: 50,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFF43F5E),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    elevation: 0,
                  ),
                  onPressed: _isSubmitting ? null : _submit,
                  icon: _isSubmitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                        )
                      : const Icon(Icons.check_circle_outline_rounded, size: 20),
                  label: Text(
                    _isSubmitting ? 'ചിലവ് രേഖപ്പെടുത്തുന്നു...' : 'Save Expense (ചിലവ് രേഖപ്പെടുത്തുക)',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      fontFamilyFallback: TekTypography.malayalamFallback,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModeOption({
    required String title,
    required String subtitle,
    required IconData icon,
    required String mode,
    required Color activeColor,
  }) {
    final isSelected = _paymentMode == mode;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => setState(() => _paymentMode = mode),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? activeColor.withValues(alpha: 0.12) : TekColors.bgSecondary,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? activeColor : TekColors.border,
            width: isSelected ? 1.6 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: isSelected ? activeColor : TekColors.textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                      color: isSelected ? activeColor : TekColors.textPrimary,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: TekColors.textSecondary,
                      fontFamilyFallback: TekTypography.malayalamFallback,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

