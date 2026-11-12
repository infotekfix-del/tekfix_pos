import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme/tek_tokens.dart';
import 'recharge_models.dart';
import 'recharge_service.dart';

/// Interactive Dialog to Top-Up Wallet (Mode A: Credit Load vs Mode B: Own Money)
class WalletTopUpDialog extends StatefulWidget {
  final String shopId;
  final String staffId;
  final String staffName;
  final RechargeOperator? initialOperator;
  final RechargeFundingType initialFundingType;

  const WalletTopUpDialog({
    super.key,
    required this.shopId,
    required this.staffId,
    required this.staffName,
    this.initialOperator,
    this.initialFundingType = RechargeFundingType.distributorCredit,
  });

  static Future<bool?> show(
    BuildContext context, {
    required String shopId,
    required String staffId,
    required String staffName,
    RechargeOperator? initialOperator,
    RechargeFundingType initialFundingType =
        RechargeFundingType.distributorCredit,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => WalletTopUpDialog(
        shopId: shopId,
        staffId: staffId,
        staffName: staffName,
        initialOperator: initialOperator,
        initialFundingType: initialFundingType,
      ),
    );
  }

  @override
  State<WalletTopUpDialog> createState() => _WalletTopUpDialogState();
}

class _WalletTopUpDialogState extends State<WalletTopUpDialog> {
  late RechargeFundingType _fundingType;
  late RechargeOperator _operator;
  String _selectedDistributorId = 'DIST_APEX_AIRTEL';
  final _amountController = TextEditingController();
  final _refController = TextEditingController();
  final _notesController = TextEditingController();
  bool _submitting = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _fundingType = widget.initialFundingType;
    _operator = widget.initialOperator ?? RechargeOperator.jio;
  }

  @override
  void dispose() {
    _amountController.dispose();
    _refController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final amt = double.tryParse(_amountController.text.trim()) ?? 0.0;
    if (amt <= 0) {
      setState(() => _errorMessage = 'സാധുവായ തുക നൽകുക (Enter a valid amount)');
      return;
    }

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      if (_fundingType == RechargeFundingType.ownMoney) {
        await RechargeService.instance.recordOwnMoneyTopUp(
          shopId: widget.shopId,
          operator: _operator,
          amount: amt,
          staffId: widget.staffId,
          staffName: widget.staffName,
          referenceId: _refController.text.trim().isNotEmpty
              ? _refController.text.trim()
              : null,
          description: _notesController.text.trim().isNotEmpty
              ? _notesController.text.trim()
              : 'Own Bank Transfer Top-Up to ${_operator.displayName}',
        );
      } else {
        await RechargeService.instance.recordDistributorCreditLoad(
          shopId: widget.shopId,
          operator: _operator,
          distributorId: _selectedDistributorId,
          amount: amt,
          staffId: widget.staffId,
          staffName: widget.staffName,
          referenceNumber: _refController.text.trim().isNotEmpty
              ? _refController.text.trim()
              : null,
          notes: _notesController.text.trim().isNotEmpty
              ? _notesController.text.trim()
              : 'Credit stock load for ${_operator.displayName}',
        );
      }

      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _errorMessage = e.toString().replaceAll('Exception: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(locale: 'en_IN', symbol: '₹');

    return AlertDialog(
      backgroundColor: TekColors.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: const Row(
        children: [
          Icon(Icons.add_card_rounded, color: TekColors.electricCyan),
          SizedBox(width: 10),
          Text(
            'Load Wallet Float / വാലറ്റ് ലോഡ്',
            style: TextStyle(
              color: TekColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Funding Mode Selector
              const Text('Funding Type / ഫണ്ടിംഗ് രീതി:',
                  style: TextStyle(color: TekColors.textSecondary, fontSize: 12)),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: _buildChoiceChip(
                      label: 'Distributor Credit',
                      sublabel: 'ഡിസ്ട്രിബ്യൂട്ടർ ക്രെഡിറ്റ്',
                      isSelected: _fundingType ==
                          RechargeFundingType.distributorCredit,
                      activeColor: TekColors.warning,
                      onTap: () => setState(() => _fundingType =
                          RechargeFundingType.distributorCredit),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildChoiceChip(
                      label: 'Own Money',
                      sublabel: 'സ്വന്തം ബാങ്ക് പണം',
                      isSelected:
                          _fundingType == RechargeFundingType.ownMoney,
                      activeColor: TekColors.electricCyan,
                      onTap: () => setState(() =>
                          _fundingType = RechargeFundingType.ownMoney),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Operator Dropdown
              const Text('Operator / ഓപ്പറേറ്റർ:',
                  style: TextStyle(color: TekColors.textSecondary, fontSize: 12)),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: TekColors.elevatedSurface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: TekColors.borderSubtle),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<RechargeOperator>(
                    value: _operator,
                    isExpanded: true,
                    dropdownColor: TekColors.cardBg,
                    items: RechargeOperator.values.map((op) {
                      return DropdownMenuItem(
                        value: op,
                        child: Text(
                          '${op.displayName} (${op.malayalam})',
                          style: const TextStyle(
                              color: TekColors.textPrimary, fontSize: 13),
                        ),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) setState(() => _operator = val);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // If Distributor Credit Mode: Distributor Dropdown
              if (_fundingType == RechargeFundingType.distributorCredit) ...[
                const Text('Distributor / വിതരണക്കാരൻ:',
                    style: TextStyle(
                        color: TekColors.textSecondary, fontSize: 12)),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: TekColors.elevatedSurface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: TekColors.borderSubtle),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _selectedDistributorId,
                      isExpanded: true,
                      dropdownColor: TekColors.cardBg,
                      items: DistributorItem.defaultPresets.map((d) {
                        return DropdownMenuItem(
                          value: d.id,
                          child: Text(
                            d.name,
                            style: const TextStyle(
                                color: TekColors.textPrimary, fontSize: 12.5),
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setState(() => _selectedDistributorId = val);
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 14),
              ],

              // Amount Input
              const Text('Stock Load Amount / തുക (₹):',
                  style: TextStyle(color: TekColors.textSecondary, fontSize: 12)),
              const SizedBox(height: 6),
              TextField(
                controller: _amountController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(
                    color: TekColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  prefixText: '₹ ',
                  prefixStyle: const TextStyle(
                      color: TekColors.electricCyan,
                      fontWeight: FontWeight.bold),
                  filled: true,
                  fillColor: TekColors.elevatedSurface,
                  hintText: 'e.g. 5000',
                  hintStyle: const TextStyle(color: TekColors.textMuted),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: TekColors.borderSubtle),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: TekColors.electricCyan),
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // Quick Amount Chips
              Wrap(
                spacing: 8,
                children: [1000, 2000, 5000, 10000].map((amt) {
                  return ActionChip(
                    backgroundColor: TekColors.elevatedSurface,
                    label: Text(currency.format(amt),
                        style: const TextStyle(
                            fontSize: 11, color: TekColors.textPrimary)),
                    onPressed: () =>
                        _amountController.text = amt.toString(),
                  );
                }).toList(),
              ),
              const SizedBox(height: 14),

              // Reference / Voucher
              TextField(
                controller: _refController,
                style: const TextStyle(color: TekColors.textPrimary, fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Reference Number / ബാങ്ക് റഫറൻസ് (Optional)',
                  labelStyle:
                      const TextStyle(color: TekColors.textSecondary, fontSize: 12),
                  filled: true,
                  fillColor: TekColors.elevatedSurface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: TekColors.borderSubtle),
                  ),
                ),
              ),

              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                Text(
                  _errorMessage!,
                  style:
                      const TextStyle(color: TekColors.error, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel',
              style: TextStyle(color: TekColors.textSecondary)),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          style: FilledButton.styleFrom(
            backgroundColor: _fundingType == RechargeFundingType.ownMoney
                ? TekColors.electricCyan
                : TekColors.warning,
            foregroundColor: Colors.black,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.black),
                )
              : Text(_fundingType == RechargeFundingType.ownMoney
                  ? 'Confirm Own Top-Up'
                  : 'Confirm Credit Load'),
        ),
      ],
    );
  }

  Widget _buildChoiceChip({
    required String label,
    required String sublabel,
    required bool isSelected,
    required Color activeColor,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? activeColor.withValues(alpha: 0.15)
              : TekColors.elevatedSurface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? activeColor : TekColors.borderSubtle,
            width: isSelected ? 1.6 : 1.0,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                color: isSelected ? activeColor : TekColors.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              sublabel,
              style: const TextStyle(color: TekColors.textMuted, fontSize: 9.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// Interactive Dialog to Pay a Distributor (Partial or Full Settlement)
class DistributorPaymentDialog extends StatefulWidget {
  final String shopId;
  final String staffId;
  final String staffName;
  final DistributorProfile? preselectedDistributor;

  const DistributorPaymentDialog({
    super.key,
    required this.shopId,
    required this.staffId,
    required this.staffName,
    this.preselectedDistributor,
  });

  static Future<bool?> show(
    BuildContext context, {
    required String shopId,
    required String staffId,
    required String staffName,
    DistributorProfile? preselectedDistributor,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => DistributorPaymentDialog(
        shopId: shopId,
        staffId: staffId,
        staffName: staffName,
        preselectedDistributor: preselectedDistributor,
      ),
    );
  }

  @override
  State<DistributorPaymentDialog> createState() =>
      _DistributorPaymentDialogState();
}

class _DistributorPaymentDialogState extends State<DistributorPaymentDialog> {
  late String _selectedDistId;
  DistributorProfile? _distributor;
  String _paymentMode = 'CASH'; // CASH, BANK, UPI
  final _amountController = TextEditingController();
  final _refController = TextEditingController();
  final _notesController = TextEditingController();
  bool _loading = true;
  bool _submitting = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _selectedDistId =
        widget.preselectedDistributor?.id ?? 'DIST_APEX_AIRTEL';
    _distributor = widget.preselectedDistributor;
    _loadDistributor();
  }

  @override
  void dispose() {
    _amountController.dispose();
    _refController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _loadDistributor() async {
    setState(() => _loading = true);
    final dist = await RechargeService.instance
        .getDistributor(shopId: widget.shopId, distributorId: _selectedDistId);
    if (mounted) {
      setState(() {
        _distributor = dist;
        _loading = false;
      });
    }
  }

  Future<void> _submit() async {
    final amt = double.tryParse(_amountController.text.trim()) ?? 0.0;
    if (amt <= 0) {
      setState(() => _errorMessage = 'സാധുവായ തുക നൽകുക (Enter a valid amount)');
      return;
    }

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      final res = await RechargeService.instance.recordDistributorPayment(
        shopId: widget.shopId,
        distributorId: _selectedDistId,
        amount: amt,
        paymentMode: _paymentMode,
        staffId: widget.staffId,
        staffName: widget.staffName,
        referenceNumber: _refController.text.trim().isNotEmpty
            ? _refController.text.trim()
            : null,
        notes: _notesController.text.trim().isNotEmpty
            ? _notesController.text.trim()
            : 'Payment via $_paymentMode',
      );

      if (mounted) {
        Navigator.of(context).pop(true);
        DistributorPaymentReceiptDialog.show(context, receipt: res.receipt);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _errorMessage = e.toString().replaceAll('Exception: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(locale: 'en_IN', symbol: '₹');
    final outstanding = _distributor?.currentOutstanding ?? 0.0;

    return AlertDialog(
      backgroundColor: TekColors.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: const Row(
        children: [
          Icon(Icons.payment_rounded, color: Color(0xFFF59E0B)),
          SizedBox(width: 10),
          Text(
            'Distributor Payout Settlement',
            style: TextStyle(
              color: TekColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Distributor Selector
              const Text('Select Distributor / വിതരണക്കാരൻ:',
                  style: TextStyle(color: TekColors.textSecondary, fontSize: 12)),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: TekColors.elevatedSurface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: TekColors.borderSubtle),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedDistId,
                    isExpanded: true,
                    dropdownColor: TekColors.cardBg,
                    items: DistributorItem.defaultPresets.map((d) {
                      return DropdownMenuItem(
                        value: d.id,
                        child: Text(
                          d.name,
                          style: const TextStyle(
                              color: TekColors.textPrimary, fontSize: 12.5),
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) {
                        setState(() => _selectedDistId = val);
                        _loadDistributor();
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // Outstanding Due Banner
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: const Color(0xFFF59E0B).withValues(alpha: 0.35)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Current Outstanding Due:',
                            style: TextStyle(
                                color: TekColors.textSecondary, fontSize: 11)),
                        Text('ഇനി നൽകാനുള്ള ബാക്കി തുക',
                            style: TextStyle(
                                color: TekColors.textMuted, fontSize: 9.5)),
                      ],
                    ),
                    _loading
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: Color(0xFFF59E0B)))
                        : Text(
                            currency.format(outstanding),
                            style: const TextStyle(
                              color: Color(0xFFF59E0B),
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // Payment Mode Selector
              const Text('Payment Source / നൽകുന്ന രീതി:',
                  style: TextStyle(color: TekColors.textSecondary, fontSize: 12)),
              const SizedBox(height: 6),
              Row(
                children: [
                  _buildPaymentChip('CASH', 'Cash Drawer', Icons.payments),
                  const SizedBox(width: 8),
                  _buildPaymentChip('BANK', 'Bank Transfer', Icons.account_balance),
                  const SizedBox(width: 8),
                  _buildPaymentChip('UPI', 'Shop UPI', Icons.qr_code),
                ],
              ),
              const SizedBox(height: 14),

              // Amount Input
              const Text('Payment Amount / നൽകുന്ന തുക (₹):',
                  style: TextStyle(color: TekColors.textSecondary, fontSize: 12)),
              const SizedBox(height: 6),
              TextField(
                controller: _amountController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(
                    color: TekColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  prefixText: '₹ ',
                  prefixStyle: const TextStyle(
                      color: Color(0xFFF59E0B),
                      fontWeight: FontWeight.bold),
                  filled: true,
                  fillColor: TekColors.elevatedSurface,
                  hintText: 'e.g. 5000',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: TekColors.borderSubtle),
                  ),
                ),
              ),
              const SizedBox(height: 8),

              // Full Settlement Button
              if (outstanding > 0)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () {
                      _amountController.text = outstanding.toStringAsFixed(2);
                    },
                    icon: const Icon(Icons.check_circle_outline, size: 14),
                    label: Text(
                        'Full Settlement (${currency.format(outstanding)})',
                        style: const TextStyle(fontSize: 11)),
                  ),
                ),

              // Reference
              TextField(
                controller: _refController,
                style: const TextStyle(color: TekColors.textPrimary, fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Receipt / Voucher Reference (Optional)',
                  labelStyle:
                      const TextStyle(color: TekColors.textSecondary, fontSize: 12),
                  filled: true,
                  fillColor: TekColors.elevatedSurface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),

              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                Text(_errorMessage!,
                    style:
                        const TextStyle(color: TekColors.error, fontSize: 12)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel',
              style: TextStyle(color: TekColors.textSecondary)),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFF59E0B),
            foregroundColor: Colors.black,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.black),
                )
              : const Text('Confirm Settlement Payout'),
        ),
      ],
    );
  }

  Widget _buildPaymentChip(String mode, String label, IconData icon) {
    final isSelected = _paymentMode == mode;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _paymentMode = mode),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFFF59E0B).withValues(alpha: 0.15)
                : TekColors.elevatedSurface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected ? const Color(0xFFF59E0B) : TekColors.borderSubtle,
              width: isSelected ? 1.6 : 1.0,
            ),
          ),
          child: Column(
            children: [
              Icon(icon,
                  size: 16,
                  color: isSelected
                      ? const Color(0xFFF59E0B)
                      : TekColors.textSecondary),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  color:
                      isSelected ? TekColors.textPrimary : TekColors.textMuted,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Modal Sheet displaying Operator Wallet Ledger
class WalletLedgerSheet extends StatelessWidget {
  final String shopId;
  final RechargeOperator? operator;

  const WalletLedgerSheet({super.key, required this.shopId, this.operator});

  static void show(BuildContext context,
      {required String shopId, RechargeOperator? operator}) {
    showModalBottomSheet(
      context: context,
      backgroundColor: TekColors.cardBg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scrollCtrl) => WalletLedgerSheet(
          shopId: shopId,
          operator: operator,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(locale: 'en_IN', symbol: '₹');
    final wId = operator != null ? RechargeService.getWalletId(operator!) : null;
    final entries =
        RechargeService.instance.getLocalWalletLedger(walletId: wId);

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    operator != null
                        ? '${operator!.displayName} Wallet Ledger'
                        : 'All Operator Wallets Ledger',
                    style: const TextStyle(
                      color: TekColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Text('വാലറ്റ് ഇടപാടുകളുടെ പൂർണ്ണ ചരിത്രം',
                      style: TextStyle(
                          color: TekColors.textSecondary, fontSize: 11)),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.close, color: TekColors.textSecondary),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(height: 1, color: TekColors.borderSubtle),
          const SizedBox(height: 8),
          Expanded(
            child: entries.isEmpty
                ? const Center(
                    child: Text('ഇടപാടുകൾ ലഭ്യമല്ല (No ledger records yet)',
                        style: TextStyle(color: TekColors.textMuted)),
                  )
                : ListView.separated(
                    itemCount: entries.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 10, color: TekColors.borderSubtle),
                    itemBuilder: (context, i) {
                      final e = entries[entries.length - 1 - i];
                      final isDebit = e.entryType == 'RECHARGE_DEBIT';

                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          backgroundColor: isDebit
                              ? TekColors.error.withValues(alpha: 0.15)
                              : TekColors.success.withValues(alpha: 0.15),
                          child: Icon(
                            isDebit
                                ? Icons.arrow_upward_rounded
                                : Icons.arrow_downward_rounded,
                            color:
                                isDebit ? TekColors.error : TekColors.success,
                            size: 18,
                          ),
                        ),
                        title: Text(
                          '${e.entryType}: ${e.description}',
                          style: const TextStyle(
                              color: TekColors.textPrimary,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          'Mode: ${e.fundingType.label} • Balance: ${currency.format(e.balanceAfterPaise / 100.0)}',
                          style: const TextStyle(
                              color: TekColors.textMuted, fontSize: 10.5),
                        ),
                        trailing: Text(
                          '${isDebit ? '-' : '+'}${currency.format(e.amount)}',
                          style: TextStyle(
                            color:
                                isDebit ? TekColors.error : TekColors.success,
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Modal Sheet displaying Distributor Outstanding Ledger
class DistributorLedgerSheet extends StatelessWidget {
  final String shopId;
  final String? distributorId;

  const DistributorLedgerSheet({super.key, required this.shopId, this.distributorId});

  static void show(BuildContext context,
      {required String shopId, String? distributorId}) {
    showModalBottomSheet(
      context: context,
      backgroundColor: TekColors.cardBg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scrollCtrl) => DistributorLedgerSheet(
          shopId: shopId,
          distributorId: distributorId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(locale: 'en_IN', symbol: '₹');
    final entries = RechargeService.instance
        .getLocalDistributorLedger(distributorId: distributorId);

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Distributor Credit Ledger Statement',
                    style: TextStyle(
                      color: TekColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text('ക്രെഡിറ്റ് സ്റ്റോക്കും നൽകിയ പേയ്‌മെന്റുകളും',
                      style: TextStyle(
                          color: TekColors.textSecondary, fontSize: 11)),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.close, color: TekColors.textSecondary),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(height: 1, color: TekColors.borderSubtle),
          const SizedBox(height: 8),
          Expanded(
            child: entries.isEmpty
                ? const Center(
                    child: Text('ഇടപാടുകൾ ലഭ്യമല്ല (No distributor ledger entries)',
                        style: TextStyle(color: TekColors.textMuted)),
                  )
                : ListView.separated(
                    itemCount: entries.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 10, color: TekColors.borderSubtle),
                    itemBuilder: (context, i) {
                      final e = entries[entries.length - 1 - i];
                      final isCreditReceived =
                          e.entryType == 'CREDIT_RECEIVED';

                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          backgroundColor: isCreditReceived
                              ? const Color(0xFFF59E0B).withValues(alpha: 0.15)
                              : TekColors.success.withValues(alpha: 0.15),
                          child: Icon(
                            isCreditReceived
                                ? Icons.add_circle_outline
                                : Icons.check_circle_outline,
                            color: isCreditReceived
                                ? const Color(0xFFF59E0B)
                                : TekColors.success,
                            size: 18,
                          ),
                        ),
                        title: Text(
                          '${e.distributorName}: ${e.description}',
                          style: const TextStyle(
                              color: TekColors.textPrimary,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          'Remaining Due: ${currency.format(e.outstandingAfterPaise / 100.0)}',
                          style: const TextStyle(
                              color: TekColors.textMuted, fontSize: 10.5),
                        ),
                        trailing: Text(
                          '${isCreditReceived ? '+' : '-'}${currency.format(e.amount)}',
                          style: TextStyle(
                            color: isCreditReceived
                                ? const Color(0xFFF59E0B)
                                : TekColors.success,
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Interactive Dialog for Float Recovery (Contra Cash Deposit to Bank / UPI Settlement)
class RechargeFloatRecoveryDialog extends StatefulWidget {
  final String shopId;
  final String staffId;
  final String staffName;

  const RechargeFloatRecoveryDialog({
    super.key,
    required this.shopId,
    required this.staffId,
    required this.staffName,
  });

  static Future<bool?> show(
    BuildContext context, {
    required String shopId,
    required String staffId,
    required String staffName,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => RechargeFloatRecoveryDialog(
        shopId: shopId,
        staffId: staffId,
        staffName: staffName,
      ),
    );
  }

  @override
  State<RechargeFloatRecoveryDialog> createState() =>
      _RechargeFloatRecoveryDialogState();
}

class _RechargeFloatRecoveryDialogState
    extends State<RechargeFloatRecoveryDialog> {
  FloatDepositType _depositType = FloatDepositType.cashDeposit;
  final _amountController = TextEditingController();
  final _refController = TextEditingController();
  final _notesController = TextEditingController();
  String _selectedBankAccount = 'PRIMARY_STORE_BANK';
  final bool _isConfirmed = true;
  bool _loading = true;
  bool _submitting = false;
  String? _errorMessage;
  RechargeFloatSummary? _floatSummary;

  final currency = NumberFormat.currency(locale: 'en_IN', symbol: '₹');

  static const _bankOptions = [
    {'id': 'PRIMARY_STORE_BANK', 'name': 'Primary Current Account (SBI)'},
    {'id': 'FEDERAL_BANK_01', 'name': 'Federal Bank (Shop A/C)'},
    {'id': 'HDFC_RECHARGE_ACC', 'name': 'HDFC Digital Float A/C'},
    {'id': 'CANARA_STORE_ACC', 'name': 'Canara Bank Current A/C'},
  ];

  @override
  void initState() {
    super.initState();
    _loadSummary();
  }

  @override
  void dispose() {
    _amountController.dispose();
    _refController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _loadSummary() async {
    setState(() => _loading = true);
    final summary = await RechargeService.instance
        .getRechargeFloatSummary(shopId: widget.shopId);
    if (mounted) {
      setState(() {
        _floatSummary = summary;
        _loading = false;
      });
    }
  }

  Future<void> _submit() async {
    final amt = double.tryParse(_amountController.text.trim()) ?? 0.0;
    if (amt <= 0) {
      setState(() =>
          _errorMessage = 'സാധുവായ തുക നൽകുക (Please enter a valid amount)');
      return;
    }

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      final bank = _bankOptions.firstWhere(
        (b) => b['id'] == _selectedBankAccount,
        orElse: () => _bankOptions.first,
      );

      await RechargeService.instance.recordRechargeFloatDeposit(
        shopId: widget.shopId,
        depositType: _depositType,
        amount: amt,
        bankAccountId: bank['id']!,
        bankAccountName: bank['name']!,
        staffId: widget.staffId,
        staffName: widget.staffName,
        referenceNumber: _refController.text.trim().isNotEmpty
            ? _refController.text.trim()
            : null,
        notes: _notesController.text.trim().isNotEmpty
            ? _notesController.text.trim()
            : 'Recharge Float Deposit to ${bank['name']}',
        isConfirmed: _isConfirmed,
      );

      if (mounted) {
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '₹${amt.toStringAsFixed(2)} വിജയകരമായി ബാങ്കിലേക്ക് നിക്ഷേപിച്ചു (Float deposit confirmed)',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            backgroundColor: TekColors.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _errorMessage = e.toString().replaceAll('Exception: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final availableCash = _floatSummary?.rechargeCashRemaining ?? 0.0;
    final totalDeposited = _floatSummary?.rechargeCashDeposited ?? 0.0;

    return AlertDialog(
      backgroundColor: TekColors.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: const Row(
        children: [
          Icon(Icons.currency_exchange_rounded, color: TekColors.electricCyan),
          SizedBox(width: 10),
          Text(
            'Recharge Float Recovery',
            style: TextStyle(
              color: TekColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Summary Banner
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: TekColors.elevatedSurface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: TekColors.borderSubtle),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Recharge Cash in Drawer:',
                            style: TextStyle(
                                color: TekColors.textSecondary, fontSize: 11)),
                        const Text('കൗണ്ടറിലെ റീചാർജ് ക്യാഷ്',
                            style: TextStyle(
                                color: TekColors.textMuted, fontSize: 9.5)),
                        const SizedBox(height: 4),
                        _loading
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 1.5,
                                    color: TekColors.electricCyan))
                            : Text(
                                currency.format(availableCash),
                                style: const TextStyle(
                                  color: TekColors.electricCyan,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const Text('Deposited Today:',
                            style: TextStyle(
                                color: TekColors.textSecondary, fontSize: 11)),
                        const Text('ഇന്ന് നിക്ഷേപിച്ചത്',
                            style: TextStyle(
                                color: TekColors.textMuted, fontSize: 9.5)),
                        const SizedBox(height: 4),
                        Text(
                          currency.format(totalDeposited),
                          style: const TextStyle(
                            color: TekColors.success,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // Deposit Type Selector
              const Text('Recovery Transfer Channel:',
                  style:
                      TextStyle(color: TekColors.textSecondary, fontSize: 12)),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => setState(
                          () => _depositType = FloatDepositType.cashDeposit),
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: _depositType == FloatDepositType.cashDeposit
                              ? TekColors.electricCyan.withValues(alpha: 0.15)
                              : TekColors.elevatedSurface,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: _depositType == FloatDepositType.cashDeposit
                                ? TekColors.electricCyan
                                : TekColors.borderSubtle,
                            width: _depositType == FloatDepositType.cashDeposit
                                ? 1.6
                                : 1.0,
                          ),
                        ),
                        child: const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Cash Deposit',
                                style: TextStyle(
                                    color: TekColors.textPrimary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold)),
                            Text('Drawer -> Bank',
                                style: TextStyle(
                                    color: TekColors.textMuted, fontSize: 9.5)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: InkWell(
                      onTap: () => setState(
                          () => _depositType = FloatDepositType.upiSettlement),
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: _depositType == FloatDepositType.upiSettlement
                              ? TekColors.primaryBlue.withValues(alpha: 0.15)
                              : TekColors.elevatedSurface,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color:
                                _depositType == FloatDepositType.upiSettlement
                                    ? TekColors.primaryBlue
                                    : TekColors.borderSubtle,
                            width: _depositType ==
                                    FloatDepositType.upiSettlement
                                ? 1.6
                                : 1.0,
                          ),
                        ),
                        child: const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('UPI Settlement',
                                style: TextStyle(
                                    color: TekColors.textPrimary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold)),
                            Text('Auto Digital Bank',
                                style: TextStyle(
                                    color: TekColors.textMuted, fontSize: 9.5)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Destination Bank Account
              const Text('Destination Bank Account / ബാങ്ക് അക്കൗണ്ട്:',
                  style:
                      TextStyle(color: TekColors.textSecondary, fontSize: 12)),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: TekColors.elevatedSurface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: TekColors.borderSubtle),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedBankAccount,
                    isExpanded: true,
                    dropdownColor: TekColors.cardBg,
                    items: _bankOptions.map((b) {
                      return DropdownMenuItem(
                        value: b['id'],
                        child: Text(
                          b['name']!,
                          style: const TextStyle(
                              color: TekColors.textPrimary, fontSize: 12.5),
                        ),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) setState(() => _selectedBankAccount = val);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // Amount Input
              const Text('Deposit Amount / നിക്ഷേപിക്കുന്ന തുക (₹):',
                  style:
                      TextStyle(color: TekColors.textSecondary, fontSize: 12)),
              const SizedBox(height: 6),
              TextField(
                controller: _amountController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(
                    color: TekColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  prefixText: '₹ ',
                  prefixStyle: const TextStyle(
                      color: TekColors.electricCyan,
                      fontWeight: FontWeight.bold),
                  filled: true,
                  fillColor: TekColors.elevatedSurface,
                  hintText: 'e.g. 2000',
                  hintStyle: const TextStyle(color: TekColors.textMuted),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: TekColors.borderSubtle),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: TekColors.electricCyan),
                  ),
                ),
              ),
              const SizedBox(height: 8),

              // Quick Amount Chips
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (availableCash > 0)
                    ActionChip(
                      backgroundColor:
                          TekColors.electricCyan.withValues(alpha: 0.15),
                      label: Text('All Available (${currency.format(availableCash)})',
                          style: const TextStyle(
                              fontSize: 11,
                              color: TekColors.electricCyan,
                              fontWeight: FontWeight.bold)),
                      onPressed: () => _amountController.text =
                          availableCash.toStringAsFixed(2),
                    ),
                  ...[1000, 2000, 5000].map((amt) {
                    return ActionChip(
                      backgroundColor: TekColors.elevatedSurface,
                      label: Text(currency.format(amt),
                          style: const TextStyle(
                              fontSize: 11, color: TekColors.textPrimary)),
                      onPressed: () => _amountController.text = amt.toString(),
                    );
                  }),
                ],
              ),
              const SizedBox(height: 14),

              // Reference / Slip
              TextField(
                controller: _refController,
                style:
                    const TextStyle(color: TekColors.textPrimary, fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'Bank Deposit Slip / Ref No (Optional)',
                  labelStyle: const TextStyle(
                      color: TekColors.textSecondary, fontSize: 12),
                  filled: true,
                  fillColor: TekColors.elevatedSurface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: TekColors.borderSubtle),
                  ),
                ),
              ),

              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                Text(
                  _errorMessage!,
                  style: const TextStyle(color: TekColors.error, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel',
              style: TextStyle(color: TekColors.textSecondary)),
        ),
        FilledButton.icon(
          onPressed: _submitting ? null : _submit,
          style: FilledButton.styleFrom(
            backgroundColor: TekColors.electricCyan,
            foregroundColor: Colors.black,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          icon: _submitting
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.black),
                )
              : const Icon(Icons.check_circle_rounded, size: 16),
          label: const Text('Confirm Bank Deposit'),
        ),
      ],
    );
  }
}

/// Printable Distributor Payment Receipt Dialog
class DistributorPaymentReceiptDialog extends StatelessWidget {
  final DistributorPaymentReceipt receipt;

  const DistributorPaymentReceiptDialog({
    super.key,
    required this.receipt,
  });

  static Future<void> show(BuildContext context,
      {required DistributorPaymentReceipt receipt}) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => DistributorPaymentReceiptDialog(receipt: receipt),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(locale: 'en_IN', symbol: '₹');
    final dateFormat = DateFormat('dd MMM yyyy, hh:mm a');

    return AlertDialog(
      backgroundColor: TekColors.cardBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Row(
            children: [
              Icon(Icons.receipt_long_rounded, color: TekColors.success),
              SizedBox(width: 8),
              Text(
                'Payment Receipt',
                style: TextStyle(
                  color: TekColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: TekColors.success.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Text(
              'PAID',
              style: TextStyle(
                color: TekColors.success,
                fontSize: 11,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Store Header
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: TekColors.elevatedSurface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: TekColors.borderSubtle),
                ),
                child: Column(
                  children: [
                    const Text(
                      'TEKFIX ERP & POS',
                      style: TextStyle(
                        color: TekColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.0,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'Distributor Settlement Voucher',
                      style: TextStyle(
                        color: TekColors.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Voucher No: ${receipt.receiptNo}',
                      style: const TextStyle(
                        color: TekColors.electricCyan,
                        fontSize: 10.5,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // Key Transaction Details Table
              _buildReceiptRow('Distributor:', receipt.distributorName),
              _buildReceiptRow('Operator Channel:', receipt.operatorName),
              _buildReceiptRow('Payment Date & Time:',
                  dateFormat.format(receipt.paymentDate)),
              _buildReceiptRow('Payment Mode:', receipt.paymentMode),
              if (receipt.referenceNumber.isNotEmpty)
                _buildReceiptRow(
                    'Ref Number / Voucher:', receipt.referenceNumber),
              _buildReceiptRow('Authorized Staff:', receipt.staffName),

              const Divider(color: TekColors.borderSubtle, height: 20),

              // Financial Figures
              _buildReceiptRow(
                'Previous Outstanding:',
                currency.format(receipt.previousOutstanding),
              ),
              _buildReceiptRow(
                'Amount Paid Today:',
                currency.format(receipt.amount),
                valueColor: TekColors.success,
                isBold: true,
              ),
              _buildReceiptRow(
                'Remaining Outstanding Due:',
                currency.format(receipt.remainingOutstanding),
                valueColor: receipt.remainingOutstanding > 0
                    ? const Color(0xFFF59E0B)
                    : TekColors.success,
                isBold: true,
              ),

              if (receipt.notes.isNotEmpty) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Notes: ${receipt.notes}',
                    style: const TextStyle(
                      color: TekColors.textMuted,
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close',
              style: TextStyle(color: TekColors.textSecondary)),
        ),
        FilledButton.icon(
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content:
                    Text('Payment Receipt sent to thermal printer / PDF queue'),
                duration: Duration(seconds: 2),
              ),
            );
            Navigator.of(context).pop();
          },
          icon: const Icon(Icons.print_rounded, size: 16),
          label: const Text('Print Receipt'),
          style: FilledButton.styleFrom(
            backgroundColor: TekColors.electricCyan,
            foregroundColor: Colors.black,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ],
    );
  }

  Widget _buildReceiptRow(String label, String value,
      {Color? valueColor, bool isBold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(
                  color: TekColors.textSecondary, fontSize: 11.5)),
          Text(
            value,
            style: TextStyle(
              color: valueColor ?? TekColors.textPrimary,
              fontSize: isBold ? 13 : 12,
              fontWeight: isBold ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

