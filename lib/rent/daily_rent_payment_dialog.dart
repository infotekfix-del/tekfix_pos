import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../auth/auth_controller.dart';
import '../expenses/expense_models.dart';
import '../main.dart' show Db, toast;
import '../theme/tek_tokens.dart';
import 'rent_models.dart';
import 'rent_service.dart';

class DailyRentPaymentDialog extends StatefulWidget {
  final String? shopId;
  final DateTime? initialDate;
  final VoidCallback? onPaymentSuccess;

  const DailyRentPaymentDialog({
    super.key,
    this.shopId,
    this.initialDate,
    this.onPaymentSuccess,
  });

  static Future<bool?> show(
    BuildContext context, {
    String? shopId,
    DateTime? initialDate,
    VoidCallback? onPaymentSuccess,
  }) {
    final isWide = MediaQuery.of(context).size.width >= 700;

    if (isWide) {
      return showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 580),
            child: DailyRentPaymentDialog(
              shopId: shopId,
              initialDate: initialDate,
              onPaymentSuccess: onPaymentSuccess,
            ),
          ),
        ),
      );
    } else {
      return showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => DailyRentPaymentDialog(
          shopId: shopId,
          initialDate: initialDate,
          onPaymentSuccess: onPaymentSuccess,
        ),
      );
    }
  }

  @override
  State<DailyRentPaymentDialog> createState() => _DailyRentPaymentDialogState();
}

class _DailyRentPaymentDialogState extends State<DailyRentPaymentDialog>
    with SingleTickerProviderStateMixin {
  late DateTime _selectedDate;
  late final TextEditingController _amountCtrl;
  late final TextEditingController _landlordCtrl;
  late final TextEditingController _refCtrl;
  late final TextEditingController _notesCtrl;
  final _formKey = GlobalKey<FormState>();

  String _paymentMode = ExpensePaymentMode.cash;
  bool _isLoading = true;
  bool _isSubmitting = false;
  DailyRentSettings? _settings;
  DailyRentRecord? _existingRecord;

  Uint8List? _attachedBytes;
  String? _attachedFileName;
  String? _attachedMimeType;

  late final AnimationController _animCtrl;
  late final Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.initialDate ?? DateTime.now();
    _amountCtrl = TextEditingController();
    _landlordCtrl = TextEditingController();
    _refCtrl = TextEditingController();
    _notesCtrl = TextEditingController();

    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _scaleAnim = CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic);
    _animCtrl.forward();

    _loadInitialState();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _landlordCtrl.dispose();
    _refCtrl.dispose();
    _notesCtrl.dispose();
    _animCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadInitialState() async {
    setState(() => _isLoading = true);
    final sId = widget.shopId ?? Db.setting('shop_id', 'tekfix');
    final settings = await RentService.instance.getSettings(shopId: sId);
    final dateKey = RentService.toDateKey(_selectedDate);
    final existing = await RentService.instance.getRentRecordForDate(dateKey, shopId: sId);

    if (mounted) {
      setState(() {
        _settings = settings;
        _existingRecord = existing;
        _isLoading = false;

        if (existing != null && existing.isPaid) {
          _amountCtrl.text = existing.paidAmount.toStringAsFixed(0);
          _paymentMode = existing.paymentMode;
          _landlordCtrl.text = existing.landlordName;
          _refCtrl.text = existing.paymentReference;
          _notesCtrl.text = existing.notes;
        } else {
          final expected = settings.getRentForDate(_selectedDate);
          _amountCtrl.text = expected > 0 ? expected.toStringAsFixed(0) : '300';
          _paymentMode = settings.defaultPaymentMode;
          _landlordCtrl.text = settings.landlordName;
        }
      });
    }
  }

  Future<void> _onDateChanged(DateTime newDate) async {
    setState(() {
      _selectedDate = newDate;
      _isLoading = true;
    });
    final sId = widget.shopId ?? Db.setting('shop_id', 'tekfix');
    final dateKey = RentService.toDateKey(newDate);
    final existing = await RentService.instance.getRentRecordForDate(dateKey, shopId: sId);
    final expected = _settings?.getRentForDate(newDate) ?? 300.0;

    if (mounted) {
      setState(() {
        _existingRecord = existing;
        _isLoading = false;
        if (existing != null && existing.isPaid) {
          _amountCtrl.text = existing.paidAmount.toStringAsFixed(0);
          _paymentMode = existing.paymentMode;
          _landlordCtrl.text = existing.landlordName;
          _refCtrl.text = existing.paymentReference;
          _notesCtrl.text = existing.notes;
        } else {
          _amountCtrl.text = expected > 0 ? expected.toStringAsFixed(0) : '300';
          _paymentMode = _settings?.defaultPaymentMode ?? ExpensePaymentMode.cash;
        }
      });
    }
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
        if (f.bytes != null) {
          final ext = f.extension?.toLowerCase() ?? 'jpg';
          final mime = ext == 'pdf' ? 'application/pdf' : 'image/$ext';
          setState(() {
            _attachedBytes = f.bytes;
            _attachedFileName = f.name;
            _attachedMimeType = mime;
          });
        }
      }
    } catch (e) {
      if (mounted) toast(context, 'File pick cancelled: $e', error: true);
    }
  }

  Future<void> _submitPayment() async {
    if (_isSubmitting) return;
    if (!_formKey.currentState!.validate()) return;

    final amt = double.tryParse(_amountCtrl.text.trim()) ?? 0.0;
    if (amt <= 0) {
      toast(context, 'ശരിയായ തുക നൽകുക (Enter a valid positive amount)', error: true);
      return;
    }

    setState(() => _isSubmitting = true);
    HapticFeedback.mediumImpact();

    final auth = context.read<AuthController>();
    final sId = widget.shopId ?? auth.shopId;
    final staffId = auth.uid.isNotEmpty ? auth.uid : 'staff_user';
    final staffName = auth.name.isNotEmpty ? auth.name : 'Staff';
    final dateKey = RentService.toDateKey(_selectedDate);

    try {
      String? receiptUrl;
      if (_attachedBytes != null && _attachedFileName != null) {
        receiptUrl = await RentService.instance.uploadReceiptFile(
          shopId: sId,
          dateKey: dateKey,
          bytes: _attachedBytes!,
          fileName: _attachedFileName!,
          mimeType: _attachedMimeType ?? 'image/jpeg',
        );
      }

      await RentService.instance.recordRentPayment(
        shopId: sId,
        dateKey: dateKey,
        paidAmount: amt,
        paymentMode: _paymentMode,
        recordedByUid: staffId,
        recordedByName: staffName,
        landlordName: _landlordCtrl.text.trim(),
        paymentReference: _refCtrl.text.trim(),
        notes: _notesCtrl.text.trim(),
        receiptUrl: receiptUrl,
      );

      if (mounted) {
        toast(
          context,
          'കട വാടക രേഖപ്പെടുത്തി (Daily Rent of ₹${amt.toStringAsFixed(0)} recorded for $dateKey)!',
        );
        widget.onPaymentSuccess?.call();
        Navigator.pop(context, true);
      }
    } on DuplicateRentPaymentException catch (dup) {
      setState(() => _isSubmitting = false);
      if (mounted) {
        toast(context, dup.message, error: true);
        _loadInitialState();
      }
    } catch (e) {
      setState(() => _isSubmitting = false);
      if (mounted) {
        toast(context, 'Rent recording failed: $e', error: true);
      }
    }
  }

  Future<void> _confirmVoidPayment() async {
    if (_existingRecord == null) return;
    final reasonCtrl = TextEditingController();

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TekColors.bgCard,
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: TekColors.error, size: 22),
            SizedBox(width: 8),
            Text('Void Daily Rent Payment?', style: TextStyle(color: TekColors.textPrimary, fontSize: 16)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Are you sure you want to void and reverse the rent payment of ₹${_existingRecord!.paidAmount.toStringAsFixed(0)} for ${_existingRecord!.dateKey}? This will restore the ${_existingRecord!.paymentMode} balance.',
              style: const TextStyle(color: TekColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reasonCtrl,
              style: const TextStyle(color: TekColors.textPrimary, fontSize: 13),
              decoration: const InputDecoration(
                labelText: 'Void Reason (നിർബന്ധമാണ്)',
                labelStyle: TextStyle(color: TekColors.textMuted, fontSize: 12),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: TekColors.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: TekColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm Void', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      final auth = context.read<AuthController>();
      final sId = widget.shopId ?? auth.shopId;
      try {
        await RentService.instance.voidRentPayment(
          shopId: sId,
          dateKey: _existingRecord!.dateKey,
          voidedByUid: auth.uid.isNotEmpty ? auth.uid : 'staff',
          voidedByName: auth.name.isNotEmpty ? auth.name : 'Staff',
          voidReason: reasonCtrl.text.trim().isNotEmpty ? reasonCtrl.text.trim() : 'Voided by user',
        );
        if (mounted) {
          toast(context, 'Rent payment reversed and balance restored successfully!');
          widget.onPaymentSuccess?.call();
          Navigator.pop(context, true);
        }
      } catch (e) {
        if (mounted) toast(context, 'Void failed: $e', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateKey = RentService.toDateKey(_selectedDate);
    final displayDate = RentService.toDisplayDate(_selectedDate);
    final isAlreadyPaid = _existingRecord != null && _existingRecord!.isPaid;
    final isToday = dateKey == RentService.toDateKey(DateTime.now());

    return ScaleTransition(
      scale: _scaleAnim,
      child: Container(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          top: 20,
          left: 20,
          right: 20,
        ),
        decoration: const BoxDecoration(
          color: TekColors.bgCard,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          border: Border(top: BorderSide(color: TekColors.border, width: 1.5)),
        ),
        child: _isLoading
            ? const Center(
                heightFactor: 4,
                child: CircularProgressIndicator(color: Color(0xFFF59E0B)),
              )
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
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [Color(0xFFF59E0B), Color(0xFFD97706)],
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Icon(
                                  Icons.store_mall_directory_rounded,
                                  color: Colors.white,
                                  size: 22,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Shop Daily Rent - $dateKey',
                                    style: const TextStyle(
                                      color: TekColors.textPrimary,
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const Text(
                                    'കട വാടക രേഖപ്പെടുത്തുക',
                                    style: TextStyle(
                                      color: TekColors.textSecondary,
                                      fontSize: 12,
                                      fontFamilyFallback: TekTypography.malayalamFallback,
                                    ),
                                  ),
                                ],
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

                      // Status Tag / Badge Banner
                      if (isAlreadyPaid)
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF10B981).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFF10B981)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.check_circle_rounded, color: Color(0xFF10B981), size: 18),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      isToday
                                          ? 'Rent Paid for Today: $displayDate (₹${_existingRecord!.paidAmount.toStringAsFixed(0)})'
                                          : 'Rent Paid: $displayDate (₹${_existingRecord!.paidAmount.toStringAsFixed(0)})',
                                      style: const TextStyle(
                                        color: Color(0xFF10B981),
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Text(
                                      'Paid by ${_existingRecord!.recordedByName} via ${_existingRecord!.paymentMode}. Daily rent has already been recorded for this date.',
                                      style: const TextStyle(
                                        color: TekColors.textSecondary,
                                        fontSize: 11.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF59E0B).withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.4)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.info_outline_rounded, color: Color(0xFFF59E0B), size: 16),
                              const SizedBox(width: 8),
                              Text(
                                isToday ? 'Rent Pending for Today ($displayDate)' : 'Rent Pending for $displayDate',
                                style: const TextStyle(
                                  color: Color(0xFFF59E0B),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),

                      const SizedBox(height: 16),

                      // Date selector button
                      InkWell(
                        onTap: isAlreadyPaid
                            ? null
                            : () async {
                                final picked = await showDatePicker(
                                  context: context,
                                  initialDate: _selectedDate,
                                  firstDate: DateTime(2025, 1, 1),
                                  lastDate: DateTime.now().add(const Duration(days: 1)),
                                );
                                if (picked != null) {
                                  _onDateChanged(picked);
                                }
                              },
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: TekColors.bgSecondary,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: TekColors.border),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.calendar_today_rounded, size: 16, color: TekColors.textSecondary),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Business Date: $displayDate',
                                    style: const TextStyle(color: TekColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
                                  ),
                                ],
                              ),
                              if (!isAlreadyPaid)
                                const Text('Change', style: TextStyle(color: TekColors.primary, fontSize: 12, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 14),

                      // Amount Input (INR)
                      TextFormField(
                        controller: _amountCtrl,
                        enabled: !isAlreadyPaid,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: const TextStyle(color: TekColors.textPrimary, fontSize: 18, fontWeight: FontWeight.bold),
                        decoration: InputDecoration(
                          labelText: 'Rent Amount (വാടക തുക) *',
                          labelStyle: const TextStyle(color: TekColors.textSecondary, fontSize: 13),
                          prefixText: '₹ ',
                          prefixStyle: const TextStyle(color: TekColors.primary, fontSize: 18, fontWeight: FontWeight.bold),
                          filled: true,
                          fillColor: TekColors.bgSecondary,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: TekColors.border)),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: TekColors.border)),
                        ),
                        validator: (v) {
                          final n = double.tryParse(v?.trim() ?? '');
                          if (n == null || n <= 0) return 'Valid positive amount required';
                          return null;
                        },
                      ),

                      const SizedBox(height: 14),

                      // Payment Mode Toggle: Cash vs Bank/UPI
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Payment Mode (പേയ്‌മെന്റ് രീതി) *',
                            style: TextStyle(color: TekColors.textSecondary, fontSize: 12, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: InkWell(
                                  onTap: isAlreadyPaid ? null : () => setState(() => _paymentMode = ExpensePaymentMode.cash),
                                  borderRadius: BorderRadius.circular(12),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    decoration: BoxDecoration(
                                      color: _paymentMode == ExpensePaymentMode.cash
                                          ? const Color(0xFFF59E0B).withValues(alpha: 0.15)
                                          : TekColors.bgSecondary,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: _paymentMode == ExpensePaymentMode.cash
                                            ? const Color(0xFFF59E0B)
                                            : TekColors.border,
                                        width: _paymentMode == ExpensePaymentMode.cash ? 1.5 : 1,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.payments_rounded,
                                          size: 18,
                                          color: _paymentMode == ExpensePaymentMode.cash
                                              ? const Color(0xFFF59E0B)
                                              : TekColors.textSecondary,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          'Cash in Hand',
                                          style: TextStyle(
                                            color: _paymentMode == ExpensePaymentMode.cash
                                                ? const Color(0xFFF59E0B)
                                                : TekColors.textSecondary,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: InkWell(
                                  onTap: isAlreadyPaid ? null : () => setState(() => _paymentMode = ExpensePaymentMode.bank),
                                  borderRadius: BorderRadius.circular(12),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    decoration: BoxDecoration(
                                      color: _paymentMode == ExpensePaymentMode.bank
                                          ? TekColors.secondary.withValues(alpha: 0.15)
                                          : TekColors.bgSecondary,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: _paymentMode == ExpensePaymentMode.bank
                                            ? TekColors.secondary
                                            : TekColors.border,
                                        width: _paymentMode == ExpensePaymentMode.bank ? 1.5 : 1,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.account_balance_rounded,
                                          size: 18,
                                          color: _paymentMode == ExpensePaymentMode.bank
                                              ? TekColors.secondary
                                              : TekColors.textSecondary,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          'Bank / UPI',
                                          style: TextStyle(
                                            color: _paymentMode == ExpensePaymentMode.bank
                                                ? TekColors.secondary
                                                : TekColors.textSecondary,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),

                      const SizedBox(height: 14),

                      // Optional fields: Landlord Name & Ref
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _landlordCtrl,
                              enabled: !isAlreadyPaid,
                              style: const TextStyle(color: TekColors.textPrimary, fontSize: 13),
                              decoration: InputDecoration(
                                labelText: 'Landlord Name (കെട്ടിട ഉടമ)',
                                labelStyle: const TextStyle(color: TekColors.textSecondary, fontSize: 12),
                                filled: true,
                                fillColor: TekColors.bgSecondary,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: TekColors.border)),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextFormField(
                              controller: _refCtrl,
                              enabled: !isAlreadyPaid,
                              style: const TextStyle(color: TekColors.textPrimary, fontSize: 13),
                              decoration: InputDecoration(
                                labelText: 'UPI Ref / Txn ID',
                                labelStyle: const TextStyle(color: TekColors.textSecondary, fontSize: 12),
                                filled: true,
                                fillColor: TekColors.bgSecondary,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: TekColors.border)),
                              ),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 14),

                      // Notes
                      TextFormField(
                        controller: _notesCtrl,
                        enabled: !isAlreadyPaid,
                        maxLines: 2,
                        style: const TextStyle(color: TekColors.textPrimary, fontSize: 13),
                        decoration: InputDecoration(
                          labelText: 'Notes / Remarks (കുറിപ്പ്)',
                          labelStyle: const TextStyle(color: TekColors.textSecondary, fontSize: 12),
                          filled: true,
                          fillColor: TekColors.bgSecondary,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: TekColors.border)),
                        ),
                      ),

                      const SizedBox(height: 14),

                      // Attachment / Receipt Photo
                      if (!isAlreadyPaid) ...[
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: TekColors.border),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            padding: const EdgeInsets.symmetric(vertical: 11),
                          ),
                          onPressed: _pickAttachment,
                          icon: const Icon(Icons.attach_file_rounded, size: 16, color: TekColors.primary),
                          label: Text(
                            _attachedFileName != null
                                ? 'Receipt: $_attachedFileName'
                                : 'Attach Rent Slip / Receipt (ഓപ്ഷണൽ)',
                            style: const TextStyle(fontSize: 12.5, color: TekColors.textPrimary),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(height: 18),
                      ],

                      // Actions
                      if (isAlreadyPaid) ...[
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(color: TekColors.border),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                ),
                                onPressed: () => Navigator.pop(context),
                                icon: const Icon(Icons.close_rounded, size: 16),
                                label: const Text('Close'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: TekColors.error,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                ),
                                onPressed: _confirmVoidPayment,
                                icon: const Icon(Icons.undo_rounded, size: 16),
                                label: const Text('Void / Reverse'),
                              ),
                            ),
                          ],
                        ),
                      ] else ...[
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFF59E0B),
                            foregroundColor: Colors.black,
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          onPressed: _isSubmitting ? null : _submitPayment,
                          icon: _isSubmitting
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2),
                                )
                              : const Icon(Icons.check_circle_rounded, size: 20),
                          label: Text(
                            _isSubmitting ? 'Recording Rent...' : 'Record Rent Payment (വാടക നൽകുക)',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}
