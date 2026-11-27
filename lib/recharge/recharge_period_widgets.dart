// ============================================================================
// TEKFIX ERP - QUICK RECHARGE: period reconciliation, operator breakdown and
// operator-wise distributor settlement (UI). Keeps the existing dark navy /
// neon-glass look (TekColors). Owner-only screens; all postings go through
// RechargeAccountingService (online-only, server-authoritative).
// ============================================================================

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme/tek_tokens.dart';
import 'recharge_accounting_backend.dart';
import 'recharge_accounting_service.dart';
import 'recharge_models.dart';
import 'recharge_period_accounting.dart';
import 'recharge_service.dart';

// ---------------------------------------------------------------------------
// Status colours: GREEN verified/matched, ORANGE pending, RED discrepancy /
// shortage, BLUE advance / excess.
// ---------------------------------------------------------------------------
const Color kPeriodGreen = TekColors.success;
const Color kPeriodOrange = Color(0xFFF59E0B);
const Color kPeriodRed = TekColors.error;
const Color kPeriodBlue = TekColors.info;

Color morningStatusColor(MorningStatus s) {
  switch (s) {
    case MorningStatus.verified:
      return kPeriodGreen;
    case MorningStatus.pendingVerification:
    case MorningStatus.notEntered:
      return kPeriodOrange;
    case MorningStatus.discrepancy:
    case MorningStatus.adjustmentRequired:
    case MorningStatus.previousClosingMissing:
      return kPeriodRed;
  }
}

Color varianceStatusColor(VarianceStatus s) {
  switch (s) {
    case VarianceStatus.match:
      return kPeriodGreen;
    case VarianceStatus.shortage:
    case VarianceStatus.investigationRequired:
      return kPeriodRed;
    case VarianceStatus.excess:
      return kPeriodBlue;
  }
}

String operatorShortName(RechargeOperator op) {
  switch (op) {
    case RechargeOperator.airtel:
      return 'Airtel';
    case RechargeOperator.jio:
      return 'Jio';
    case RechargeOperator.vi:
      return 'Vi';
    case RechargeOperator.bsnl:
      return 'BSNL';
    case RechargeOperator.other:
      return 'Unassigned';
  }
}

class PeriodStatusChip extends StatelessWidget {
  final String label;
  final Color color;
  const PeriodStatusChip(this.label, this.color, {super.key});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.6)),
        ),
        child: Text(label,
            style: TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.w800)),
      );
}

String accountingErrorText(Object e) {
  if (e is AccountingException) return e.message;
  final s = e.toString();
  return s.replaceFirst(RegExp(r'^(Exception|StateError|Bad state|Invalid argument\(s\)):?\s*'), '');
}

void _toast(BuildContext context, String msg, {bool error = false}) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
    content: Text(msg),
    backgroundColor: error ? kPeriodRed.withValues(alpha: 0.95) : TekColors.elevatedSurface,
    behavior: SnackBarBehavior.floating,
  ));
}

Widget _row(String label, String value, {Color? color, bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: TextStyle(
                    color: bold ? TekColors.textPrimary : TekColors.textSecondary,
                    fontSize: 12.5,
                    fontWeight: bold ? FontWeight.w700 : FontWeight.w500)),
          ),
          Text(value,
              style: TextStyle(
                  color: color ?? TekColors.textPrimary,
                  fontSize: 13,
                  fontWeight: bold ? FontWeight.w900 : FontWeight.w700)),
        ],
      ),
    );

InputDecoration _input(String label, {String? hint, String? prefix}) => InputDecoration(
      labelText: label,
      hintText: hint,
      prefixText: prefix,
      filled: true,
      fillColor: TekColors.mainBg,
      labelStyle: const TextStyle(color: TekColors.textSecondary, fontSize: 12.5),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: TekColors.border)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: TekColors.electricCyan)),
    );

/// Dark dialog shell shared by the period dialogs.
class _PeriodDialog extends StatelessWidget {
  final String title;
  final String malayalam;
  final Widget child;
  final List<Widget> actions;
  const _PeriodDialog({
    required this.title,
    required this.malayalam,
    required this.child,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: TekColors.cardBg,
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: TekColors.border)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: TekColors.textPrimary, fontSize: 16.5, fontWeight: FontWeight.w800)),
                Text(malayalam,
                    style: const TextStyle(color: TekColors.textSecondary, fontSize: 11.5)),
                const SizedBox(height: 14),
                Flexible(child: SingleChildScrollView(child: child)),
                const SizedBox(height: 14),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: actions,
                ),
              ],
            ),
          ),
        ),
      );
}

ButtonStyle _primaryButton(Color c) => FilledButton.styleFrom(
      backgroundColor: c,
      foregroundColor: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    );

// ===========================================================================
// MORNING ENTRY (raw -> already recorded -> unexplained -> classify)
// ===========================================================================

class MorningEntryDialog extends StatefulWidget {
  final String shopId;
  final AccountingActor actor;
  final OperatorPeriodState state;
  final List<DistributorProfile> distributors;
  const MorningEntryDialog({
    super.key,
    required this.shopId,
    required this.actor,
    required this.state,
    required this.distributors,
  });

  static Future<bool?> show(BuildContext context,
          {required String shopId,
          required AccountingActor actor,
          required OperatorPeriodState state,
          required List<DistributorProfile> distributors}) =>
      showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => MorningEntryDialog(
            shopId: shopId, actor: actor, state: state, distributors: distributors),
      );

  @override
  State<MorningEntryDialog> createState() => _MorningEntryDialogState();
}

class _MorningEntryDialogState extends State<MorningEntryDialog> {
  final _amount = TextEditingController();
  final _classAmount = TextEditingController();
  final _reason = TextEditingController();
  final _commission = TextEditingController(); // inside a distributor refill
  bool _commissionEdited = false;
  // Shop rule (owner, 2026-11-21): extra morning balance is distributor
  // credit, payable back by the next morning. Own money is not the default.
  UnexplainedCategory _category = UnexplainedCategory.topUpDistributorCredit;
  String? _distributorId;
  bool _showOtherCategories = false;
  bool _busy = false;
  bool _confirmed = false;
  bool _changed = false;
  String? _error;

  /// Server-confirmed morning check (after "Save morning balance").
  MorningSnapshot? _snapshot;

  RechargeOperator get _op => widget.state.operator;

  @override
  void initState() {
    super.initState();
    _snapshot = widget.state.morning;
    if (_snapshot != null) _classAmount.text = _rupeesText(_snapshot!.remainingPaise.abs());
    _autoCommission();
    final forOp = widget.distributors.where((d) => d.defaultOperator == _op).toList();
    if (forOp.length == 1) {
      _distributorId = forOp.single.id;
    } else if (widget.distributors.length == 1) {
      _distributorId = widget.distributors.single.id;
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _classAmount.dispose();
    _commission.dispose();
    _reason.dispose();
    super.dispose();
  }

  String _rupeesText(int paise) =>
      '${paise ~/ 100}.${(paise % 100).toString().padLeft(2, '0')}';

  /// 3.9% of a distributor refill is commission (1,039 = 1,000 + 39).
  void _autoCommission() {
    if (_commissionEdited || _category != UnexplainedCategory.topUpDistributorCredit) return;
    final c = topUpCommissionPaise(parseRupeesToPaise(_classAmount.text) ?? 0, kDefaultTopUpCommissionBp);
    _commission.text = _rupeesText(c);
  }

  int get _commissionPaise => _category == UnexplainedCategory.topUpDistributorCredit
      ? (parseRupeesToPaise(_commission.text) ?? 0)
      : 0;

  /// Distributor credit only, unless the owner opens "Other types". Own
  /// money stays available there (last), but is never the default.
  List<UnexplainedCategory> get _visibleCategories => _showOtherCategories
      ? [
          UnexplainedCategory.topUpDistributorCredit,
          UnexplainedCategory.excess,
          UnexplainedCategory.refund,
          UnexplainedCategory.bonus,
          UnexplainedCategory.commissionCredit,
          UnexplainedCategory.otherAdjustment,
          UnexplainedCategory.manualCorrection,
          // topUpOwn is not offered: the shop never adds its own money.
        ]
      : const [UnexplainedCategory.topUpDistributorCredit, UnexplainedCategory.excess];

  MorningCheck? get _preview {
    final p = parseRupeesToPaise(_amount.text);
    if (p == null) return null;
    return computeMorningCheck(
        operator: _op,
        previousClosing: widget.state.previousClosing,
        morningActualPaise: p,
        morningAt: DateTime.now(),
        ledger: widget.state.movements);
  }

  Future<void> _saveMorning() async {
    final p = parseRupeesToPaise(_amount.text);
    if (p == null) {
      setState(() => _error = 'Enter a valid amount (സാധുവായ തുക നൽകുക)');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await RechargeAccountingService.instance.verifyMorning(
          shopId: widget.shopId,
          actor: widget.actor,
          operator: _op,
          morningActualPaise: p,
          periodId: widget.state.periodId);
      final fresh = (await RechargeAccountingService.instance.periodState(widget.shopId))[_op];
      _changed = true;
      setState(() {
        _snapshot = fresh?.morning;
        if (_snapshot != null) _classAmount.text = _rupeesText(_snapshot!.remainingPaise.abs());
        _autoCommission();
      });
    } catch (e) {
      setState(() => _error = accountingErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _postClassification() async {
    final snap = _snapshot!;
    var p = parseRupeesToPaise(_classAmount.text);
    if (p == null || p == 0) {
      setState(() => _error = 'Enter a valid amount (സാധുവായ തുക നൽകുക)');
      return;
    }
    if (snap.remainingPaise < 0) {
      // Discrepancy: only a documented correction (negative) is allowed.
      _category = UnexplainedCategory.manualCorrection;
      p = -p;
    }
    if (_category == UnexplainedCategory.topUpDistributorCredit && _distributorId == null) {
      setState(() => _error = 'Select the distributor (ഡിസ്ട്രിബ്യൂട്ടർ തിരഞ്ഞെടുക്കുക)');
      return;
    }
    if (_reason.text.trim().isEmpty) {
      setState(() => _error = 'Reason is required (കാരണം നിർബന്ധം)');
      return;
    }
    if (!_confirmed) {
      setState(() => _error = 'Tick the owner confirmation first (സ്ഥിരീകരിക്കുക)');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_category == UnexplainedCategory.topUpDistributorCredit) {
        // Refill = payable to the distributor + commission (profit).
        await RechargeAccountingService.instance.postDistributorCreditWithCommission(
            shopId: widget.shopId,
            actor: widget.actor,
            operator: _op,
            receivedPaise: p,
            commissionPaise: _commissionPaise,
            distributorId: _distributorId!,
            reason: _reason.text.trim(),
            periodId: widget.state.periodId);
      } else {
        await RechargeAccountingService.instance.postClassified(
            shopId: widget.shopId,
            actor: widget.actor,
            operator: _op,
            category: _category,
            amountPaise: p,
            reason: _reason.text.trim(),
            transactionDate: DateTime.now(),
            periodId: widget.state.periodId);
      }
      _changed = true;
      final fresh = (await RechargeAccountingService.instance.periodState(widget.shopId))[_op];
      final left = fresh?.morning?.remainingPaise ?? 0;
      if (!mounted) return;
      _toast(context, 'Posted ${formatInrPaise(p)} as ${_category.label}');
      if (left > 0) {
        // Distributor part posted; whatever is left is Excess by default.
        setState(() {
          _snapshot = fresh!.morning;
          _category = UnexplainedCategory.excess;
          _classAmount.text = _rupeesText(left);
          _reason.text = 'Excess after distributor credit';
          _confirmed = false;
        });
      } else {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      setState(() => _error = accountingErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final prev = widget.state.previousClosing;
    final snap = _snapshot;
    final preview = snap == null ? _preview : null;
    final check = snap?.check ?? preview;

    return _PeriodDialog(
      title: 'Morning Balance – ${operatorShortName(_op)}',
      malayalam: 'രാവിലെ ബാലൻസ് & പുതിയ ടോപ്പ്-അപ്പ്',
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(_changed),
          child: const Text('Close (അടയ്ക്കുക)'),
        ),
        if (snap == null && prev != null)
          FilledButton(
            key: const ValueKey('morning-save'),
            style: _primaryButton(TekColors.electricCyan),
            onPressed: _busy ? null : _saveMorning,
            child: Text(_busy ? 'Saving…' : 'Save morning balance (സേവ്)'),
          ),
        if (snap != null && snap.remainingPaise != 0)
          FilledButton(
            key: const ValueKey('morning-classify'),
            style: _primaryButton(snap.remainingPaise > 0 ? kPeriodOrange : kPeriodRed),
            onPressed: _busy ? null : _postClassification,
            child: Text(_busy ? 'Posting…' : 'Confirm & post (സ്ഥിരീകരിക്കുക)'),
          ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (prev == null)
            const Text(
              'Previous closing missing (മുൻ ക്ലോസിംഗ് ഇല്ല). Enter a verified reference balance first from the operator card.',
              style: TextStyle(color: kPeriodRed, fontWeight: FontWeight.w700),
            )
          else ...[
            if (snap == null)
              TextField(
                key: const ValueKey('morning-amount'),
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: TekColors.textPrimary),
                decoration: _input("Actual balance in ${operatorShortName(_op)} app now",
                    hint: 'e.g. 1500', prefix: '₹ '),
                onChanged: (_) => setState(() {}),
              ),
            const SizedBox(height: 12),
            _row('Previous verified closing', formatInrPaise(prev.actualPaise)),
            if (check != null) ...[
              _row('Actual morning balance', formatInrPaise(check.morningActualPaise)),
              _row('Raw difference', formatInrPaise(check.rawDifferencePaise)),
              _row('Already recorded in ledger', formatInrPaise(check.alreadyRecordedPaise)),
              const Divider(color: TekColors.border),
              _row(
                check.unexplainedPaise >= 0
                    ? 'New Net Top-Up (to confirm)'
                    : 'Balance discrepancy (investigate)',
                formatInrPaise(check.unexplainedPaise),
                color: check.unexplainedPaise == 0
                    ? kPeriodGreen
                    : (check.unexplainedPaise > 0 ? kPeriodOrange : kPeriodRed),
                bold: true,
              ),
              if (snap == null)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    'Preview only. The server recalculates this when you save; nothing is posted until you classify it.',
                    style: TextStyle(color: TekColors.textMuted, fontSize: 11),
                  ),
                ),
            ],
          ],
          if (snap != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: PeriodStatusChip(snap.status.label, morningStatusColor(snap.status)),
            ),
            if (snap.classifiedPaise != 0)
              _row('Already classified', formatInrPaise(snap.classifiedPaise)),
            if (snap.remainingPaise != 0) ...[
              const SizedBox(height: 12),
              if (snap.remainingPaise > 0)
                DropdownButtonFormField<UnexplainedCategory>(
                  isExpanded: true,
                  key: const ValueKey('morning-category'),
                  initialValue: _category,
                  dropdownColor: TekColors.elevatedSurface,
                  style: const TextStyle(color: TekColors.textPrimary),
                  decoration: _input('Classify the amount as (ഇനം)'),
                  items: [
                    for (final c in _visibleCategories)
                      DropdownMenuItem(
                          value: c,
                          child: Text('${c.label} (${c.malayalam})', overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (c) => setState(() {
                    _category = c ?? _category;
                    _autoCommission();
                  }),
                )
              else
                const Text(
                  'A negative difference is a discrepancy. It is never posted automatically. Post a documented correction only after you find the cause.',
                  style: TextStyle(color: kPeriodRed, fontSize: 12),
                ),
              if (snap.remainingPaise > 0 && !_showOtherCategories)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const ValueKey('morning-other-categories'),
                    onPressed: () => setState(() => _showOtherCategories = true),
                    child: const Text('Other types: refund, bonus, commission… (മറ്റ് ഇനങ്ങൾ)',
                        style: TextStyle(fontSize: 11.5)),
                  ),
                ),
              if (_category == UnexplainedCategory.topUpDistributorCredit &&
                  snap.remainingPaise > 0) ...[
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  key: const ValueKey('morning-distributor'),
                  isExpanded: true,
                  initialValue: _distributorId,
                  dropdownColor: TekColors.elevatedSurface,
                  style: const TextStyle(color: TekColors.textPrimary),
                  decoration: _input('Distributor (ഡിസ്ട്രിബ്യൂട്ടർ)'),
                  items: [
                    for (final d in widget.distributors)
                      DropdownMenuItem(value: d.id, child: Text(d.name)),
                  ],
                  onChanged: (v) => setState(() => _distributorId = v),
                ),
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    'Posted as payable to this distributor: pay it back by the next morning. (ഡിസ്ട്രിബ്യൂട്ടർക്ക് നൽകാനുള്ള തുക — നാളെ രാവിലെക്കകം തിരിച്ചു നൽകണം)',
                    style: TextStyle(color: kPeriodOrange, fontSize: 11.5),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const ValueKey('morning-commission'),
                  controller: _commission,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: const TextStyle(color: TekColors.textPrimary),
                  decoration: _input('Commission included (ഇതിൽ കമ്മീഷൻ) – 3.9% auto', prefix: '₹ '),
                  onChanged: (_) => setState(() => _commissionEdited = true),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Payable to distributor (കൊടുക്കേണ്ടത്): ${formatInrPaise((parseRupeesToPaise(_classAmount.text) ?? 0) - _commissionPaise)} • Commission – profit (കമ്മീഷൻ): ${formatInrPaise(_commissionPaise)}',
                    key: const ValueKey('morning-split'),
                    style: const TextStyle(color: TekColors.electricCyan, fontSize: 11.5),
                  ),
                ),
              ],
              if (_category == UnexplainedCategory.excess && snap.remainingPaise > 0)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    'Kept in the separate Excess account: not own money, not profit. (എക്സസ് — പ്രത്യേക കണക്ക്)',
                    style: TextStyle(color: TekColors.electricCyan, fontSize: 11.5),
                  ),
                ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('morning-class-amount'),
                controller: _classAmount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: TekColors.textPrimary),
                onChanged: (_) => setState(_autoCommission),
                decoration: _input('Amount (max ${formatInrPaise(snap.remainingPaise.abs())})',
                    prefix: '₹ '),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('morning-reason'),
                controller: _reason,
                style: const TextStyle(color: TekColors.textPrimary),
                decoration: _input('Reason (കാരണം)'),
              ),
              CheckboxListTile(
                key: const ValueKey('morning-confirm'),
                contentPadding: EdgeInsets.zero,
                value: _confirmed,
                onChanged: (v) => setState(() => _confirmed = v ?? false),
                title: const Text('I confirm this entry (ഉടമ സ്ഥിരീകരണം)',
                    style: TextStyle(color: TekColors.textPrimary, fontSize: 12.5)),
              ),
            ],
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: const TextStyle(color: kPeriodRed, fontSize: 12)),
            ),
        ],
      ),
    );
  }
}

// ===========================================================================
// REFERENCE BALANCE (first period / previous closing missing)
// ===========================================================================

class ReferenceBalanceDialog extends StatefulWidget {
  final String shopId;
  final AccountingActor actor;
  final RechargeOperator operator;
  const ReferenceBalanceDialog(
      {super.key, required this.shopId, required this.actor, required this.operator});

  static Future<bool?> show(BuildContext context,
          {required String shopId,
          required AccountingActor actor,
          required RechargeOperator operator}) =>
      showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => ReferenceBalanceDialog(shopId: shopId, actor: actor, operator: operator));

  @override
  State<ReferenceBalanceDialog> createState() => _ReferenceBalanceDialogState();
}

class _ReferenceBalanceDialogState extends State<ReferenceBalanceDialog> {
  final _amount = TextEditingController();
  final _reason = TextEditingController();
  bool _confirmed = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final p = parseRupeesToPaise(_amount.text);
    if (p == null) return setState(() => _error = 'Enter a valid amount (സാധുവായ തുക നൽകുക)');
    if (_reason.text.trim().isEmpty) return setState(() => _error = 'Reason is required (കാരണം നിർബന്ധം)');
    if (!_confirmed) return setState(() => _error = 'Tick the owner confirmation first (സ്ഥിരീകരിക്കുക)');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await RechargeAccountingService.instance.postReferenceBalance(
          shopId: widget.shopId,
          actor: widget.actor,
          operator: widget.operator,
          balancePaise: p,
          reason: _reason.text.trim());
      // Seamlessly sync the POS execution wallet to the entered reference balance
      try {
        await RechargeAccountingService.instance.alignWallet(
          shopId: widget.shopId,
          actor: widget.actor,
          operator: widget.operator,
          ownPaise: p,
          creditPaise: 0,
          reason: 'Initial setup: wallet auto-aligned to verified reference balance',
        );
      } catch (e) {
        debugPrint('[ReferenceBalanceDialog] Auto-align notice: $e');
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _error = accountingErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _PeriodDialog(
        title: 'Verified reference balance – ${operatorShortName(widget.operator)}',
        malayalam: 'മുൻ ക്ലോസിംഗ് ഇല്ല: പരിശോധിച്ച ബാലൻസ് നൽകുക',
        actions: [
          TextButton(
              onPressed: _busy ? null : () => Navigator.of(context).pop(false),
              child: const Text('Cancel (വേണ്ട)')),
          FilledButton(
              style: _primaryButton(TekColors.electricCyan),
              onPressed: _busy ? null : _save,
              child: Text(_busy ? 'Saving…' : 'Save reference (സേവ്)')),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'No verified closing exists for this operator, so nothing is calculated automatically. Check the balance in the operator app and enter it here. It becomes the opening of the first period and is saved as an audited entry.',
              style: TextStyle(color: TekColors.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: TekColors.textPrimary),
                decoration: _input('Verified balance', prefix: '₹ ')),
            const SizedBox(height: 10),
            TextField(
                controller: _reason,
                style: const TextStyle(color: TekColors.textPrimary),
                decoration: _input('Reason / source (കാരണം)')),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _confirmed,
              onChanged: (v) => setState(() => _confirmed = v ?? false),
              title: const Text('I verified this in the operator app (ഉടമ സ്ഥിരീകരണം)',
                  style: TextStyle(color: TekColors.textPrimary, fontSize: 12.5)),
            ),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: kPeriodRed, fontSize: 12)),
          ],
        ),
      );
}

// ===========================================================================
// CHANGE TOP-UP SOURCE: OWN MONEY -> DISTRIBUTOR CREDIT
// ===========================================================================

class ReclassifyTopUpDialog extends StatefulWidget {
  final String shopId;
  final AccountingActor actor;
  final RechargeOperator operator;
  final List<DistributorProfile> distributors;
  const ReclassifyTopUpDialog({
    super.key,
    required this.shopId,
    required this.actor,
    required this.operator,
    required this.distributors,
  });

  static Future<bool?> show(BuildContext context,
          {required String shopId,
          required AccountingActor actor,
          required RechargeOperator operator,
          required List<DistributorProfile> distributors}) =>
      showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ReclassifyTopUpDialog(
            shopId: shopId, actor: actor, operator: operator, distributors: distributors),
      );

  @override
  State<ReclassifyTopUpDialog> createState() => _ReclassifyTopUpDialogState();
}

class _ReclassifyTopUpDialogState extends State<ReclassifyTopUpDialog> {
  final _amount = TextEditingController();
  final _reason = TextEditingController();
  String? _distributorId;
  bool _confirmed = false;
  bool _busy = false;
  bool _changed = false;
  bool _incomplete = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final own = widget.distributors.where((d) => d.defaultOperator == widget.operator).toList();
    if (own.length == 1) _distributorId = own.single.id;
  }

  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _checkIncomplete() async {
    final p = parseRupeesToPaise(_amount.text);
    final d = _distributorId;
    if (p == null || p <= 0 || d == null) return setState(() => _incomplete = false);
    final pending = await RechargeAccountingService.instance.reclassifyPending(
        shopId: widget.shopId, operator: widget.operator, amountPaise: p, distributorId: d);
    if (mounted) setState(() => _incomplete = pending);
  }

  Future<void> _post() async {
    final p = parseRupeesToPaise(_amount.text);
    if (p == null || p <= 0) return setState(() => _error = 'Enter a valid amount (സാധുവായ തുക നൽകുക)');
    if (_distributorId == null) return setState(() => _error = 'Select the distributor (ഡിസ്ട്രിബ്യൂട്ടർ)');
    if (_reason.text.trim().isEmpty) return setState(() => _error = 'Reason is required (കാരണം നിർബന്ധം)');
    if (!_confirmed) return setState(() => _error = 'Tick the owner confirmation first (സ്ഥിരീകരിക്കുക)');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await RechargeAccountingService.instance.reclassifyOwnTopUpToDistributor(
          shopId: widget.shopId,
          actor: widget.actor,
          operator: widget.operator,
          amountPaise: p,
          distributorId: _distributorId!,
          reason: _reason.text.trim());
      _changed = true;
      if (mounted) {
        _toast(context, 'Moved ${formatInrPaise(p)} from own money to distributor credit');
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      _changed = true; // step 1 may have posted: refresh the dashboard on close
      setState(() {
        _error = accountingErrorText(e);
        _incomplete = e is AccountingException && e.code == 'RECLASSIFY_INCOMPLETE';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = parseRupeesToPaise(_amount.text);
    final dist = widget.distributors.where((d) => d.id == _distributorId).firstOrNull;
    return _PeriodDialog(
      title: 'Change top-up source – ${operatorShortName(widget.operator)}',
      malayalam: 'സോഴ്സ് മാറ്റുക: സ്വന്തം പണം → ഡിസ്ട്രിബ്യൂട്ടർ ക്രെഡിറ്റ്',
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(_changed),
          child: const Text('Close (അടയ്ക്കുക)'),
        ),
        FilledButton(
          key: const ValueKey('reclass-post'),
          style: _primaryButton(_incomplete ? kPeriodRed : kPeriodOrange),
          onPressed: _busy ? null : _post,
          child: Text(_busy
              ? 'Posting…'
              : (_incomplete ? 'Finish step 2 (പൂർത്തിയാക്കുക)' : 'Confirm & post (സ്ഥിരീകരിക്കുക)')),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Use this when a top-up that came from a distributor was saved as own money. Two audited entries are posted: a correction of −amount on own money, then +amount as distributor credit. The wallet total does not change; the distributor\'s dues go up by the amount.',
            style: TextStyle(color: TekColors.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: const ValueKey('reclass-distributor'),
            isExpanded: true,
            initialValue: _distributorId,
            dropdownColor: TekColors.elevatedSurface,
            style: const TextStyle(color: TekColors.textPrimary),
            decoration: _input('Distributor (ഡിസ്ട്രിബ്യൂട്ടർ)'),
            items: [
              for (final d in widget.distributors)
                DropdownMenuItem(value: d.id, child: Text(d.name, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) {
              setState(() => _distributorId = v);
              _checkIncomplete();
            },
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('reclass-amount'),
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(color: TekColors.textPrimary),
            decoration: _input('Amount to move', hint: 'e.g. 2000', prefix: '₹ '),
            onChanged: (_) {
              setState(() {});
              _checkIncomplete();
            },
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('reclass-reason'),
            controller: _reason,
            style: const TextStyle(color: TekColors.textPrimary),
            decoration: _input('Reason (കാരണം)', hint: 'e.g. Morning entry saved as own money'),
          ),
          if (p != null && p > 0) ...[
            const SizedBox(height: 12),
            _row('Own money balance', '−${formatInrPaise(p)}', color: kPeriodRed),
            _row('Distributor credit balance', '+${formatInrPaise(p)}', color: kPeriodGreen),
            _row('Wallet total', 'unchanged (മാറ്റമില്ല)'),
            _row('Dues to ${dist?.name ?? 'distributor'}', '+${formatInrPaise(p)}',
                color: kPeriodOrange, bold: true),
          ],
          if (_incomplete)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'A previous attempt with these details did not finish. Posting again completes it; step 1 is not posted twice. (മുമ്പത്തെ ശ്രമം പൂർത്തിയായില്ല)',
                style: TextStyle(color: kPeriodRed, fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
          CheckboxListTile(
            key: const ValueKey('reclass-confirm'),
            contentPadding: EdgeInsets.zero,
            value: _confirmed,
            onChanged: (v) => setState(() => _confirmed = v ?? false),
            title: const Text('I confirm this came from the distributor (ഉടമ സ്ഥിരീകരണം)',
                style: TextStyle(color: TekColors.textPrimary, fontSize: 12.5)),
          ),
          if (_error != null)
            Text(_error!, style: const TextStyle(color: kPeriodRed, fontSize: 12)),
        ],
      ),
    );
  }
}

// ===========================================================================
// NIGHT CLOSING
// ===========================================================================

class ClosingEntryDialog extends StatefulWidget {
  final String shopId;
  final AccountingActor actor;
  final OperatorPeriodState state;
  const ClosingEntryDialog(
      {super.key, required this.shopId, required this.actor, required this.state});

  static Future<bool?> show(BuildContext context,
          {required String shopId,
          required AccountingActor actor,
          required OperatorPeriodState state}) =>
      showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => ClosingEntryDialog(shopId: shopId, actor: actor, state: state));

  @override
  State<ClosingEntryDialog> createState() => _ClosingEntryDialogState();
}

class _ClosingEntryDialogState extends State<ClosingEntryDialog> {
  final _amount = TextEditingController();
  final _reason = TextEditingController();
  bool _confirmed = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save(ClosingBreakdown b) async {
    final p = parseRupeesToPaise(_amount.text);
    if (p == null) return setState(() => _error = 'Enter a valid amount (സാധുവായ തുക നൽകുക)');
    if (b.variancePaise != 0 && _reason.text.trim().isEmpty) {
      return setState(() => _error = 'A reason is required when there is a variance (കാരണം നിർബന്ധം)');
    }
    if (!_confirmed) return setState(() => _error = 'Tick the owner confirmation first (സ്ഥിരീകരിക്കുക)');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await RechargeAccountingService.instance.verifyClosing(
          shopId: widget.shopId,
          actor: widget.actor,
          operator: widget.state.operator,
          actualPaise: p,
          periodId: widget.state.periodId,
          reason: _reason.text.trim());
      if (mounted) {
        final v = r.data['variancePaise'];
        _toast(context,
            'Closing verified and locked. Variance: ${v is int ? formatInrPaise(v) : '-'}');
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      setState(() => _error = accountingErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.state;
    final actual = parseRupeesToPaise(_amount.text);
    final b = st.closing(actualPaise: actual);
    final status = b.status;
    return _PeriodDialog(
      title: 'Night Closing – ${operatorShortName(st.operator)}',
      malayalam: 'രാത്രി ക്ലോസിംഗ് ബാലൻസ് (ഈ കാലയളവ്)',
      actions: [
        TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            child: const Text('Cancel (വേണ്ട)')),
        FilledButton(
          key: const ValueKey('closing-save'),
          style: _primaryButton(TekColors.electricCyan),
          onPressed: _busy || st.previousClosing == null ? null : () => _save(b),
          child: Text(_busy ? 'Saving…' : 'Verify & lock (ലോക്ക്)'),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (st.previousClosing == null)
            const Text('Previous closing missing (മുൻ ക്ലോസിംഗ് ഇല്ല). Enter a verified reference balance first.',
                style: TextStyle(color: kPeriodRed, fontWeight: FontWeight.w700)),
          _row('1. Opening (previous verified closing)', formatInrPaise(b.openingPaise)),
          _row('2. Wallet top-ups (incl. morning)', formatInrPaise(b.topUpsPaise), color: kPeriodGreen),
          _row('3. Recharge debits (actual)', '-${formatInrPaise(b.rechargeDebitsPaise)}', color: kPeriodOrange),
          _row('4. Refunds / commission / bonus credits', formatInrPaise(b.creditsPaise)),
          _row('5. Reversals (commission clawback)', '-${formatInrPaise(b.clawbacksPaise)}'),
          _row('6. Other verified adjustments', formatInrPaise(b.adjustmentsPaise)),
          if (b.pendingDebitsPaise != 0)
            _row('Pending recharges (already debited)', '-${formatInrPaise(b.pendingDebitsPaise)}',
                color: kPeriodOrange),
          const Divider(color: TekColors.border),
          _row('7. Expected closing', formatInrPaise(b.expectedClosingPaise), bold: true),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('closing-amount'),
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(color: TekColors.textPrimary),
            decoration: _input('8. Actual closing (from operator app)', prefix: '₹ '),
            onChanged: (_) => setState(() {}),
          ),
          if (b.variancePaise != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _row('9. Variance', formatInrPaise(b.variancePaise!), bold: true,
                    color: varianceStatusColor(status!))),
                const SizedBox(width: 8),
                PeriodStatusChip(status.label, varianceStatusColor(status)),
              ],
            ),
            if (status == VarianceStatus.excess)
              Text(
                'Excess ${formatInrPaise(b.variancePaise!)} is kept in the separate Excess account: not profit, not own money. (എക്സസ് — പ്രത്യേക കണക്ക്)',
                key: const ValueKey('closing-excess-note'),
                style: const TextStyle(color: TekColors.electricCyan, fontSize: 11.5),
              ),
            if (status == VarianceStatus.shortage)
              const Text(
                'Shortage is only shown: nothing is deducted from recharge cash. (കുറവ് — കാണിക്കുക മാത്രം)',
                key: ValueKey('closing-shortage-note'),
                style: TextStyle(color: kPeriodRed, fontSize: 11.5),
              ),
          ],
          const SizedBox(height: 10),
          TextField(
            controller: _reason,
            style: const TextStyle(color: TekColors.textPrimary),
            decoration: _input('Reason / remarks (required if variance)'),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _confirmed,
            onChanged: (v) => setState(() => _confirmed = v ?? false),
            title: const Text(
                'I verified the closing. The period will be locked; later corrections need an adjustment entry.',
                style: TextStyle(color: TekColors.textPrimary, fontSize: 12)),
          ),
          if (_error != null)
            Text(_error!, style: const TextStyle(color: kPeriodRed, fontSize: 12)),
        ],
      ),
    );
  }
}

// ===========================================================================
// OPERATOR-WISE DISTRIBUTOR PAYMENT
// ===========================================================================

const List<String> kDistributorPaymentModes = ['Cash', 'Bank Transfer', 'UPI', 'Cheque'];

class DistributorPaymentV2Dialog extends StatefulWidget {
  final String shopId;
  final AccountingActor actor;
  final List<DistributorProfile> distributors;
  final SettlementSummary? summary;
  final String? initialDistributorId;
  final RechargeOperator? initialOperator;
  const DistributorPaymentV2Dialog({
    super.key,
    required this.shopId,
    required this.actor,
    required this.distributors,
    this.summary,
    this.initialDistributorId,
    this.initialOperator,
  });

  static Future<bool?> show(BuildContext context,
          {required String shopId,
          required AccountingActor actor,
          required List<DistributorProfile> distributors,
          SettlementSummary? summary,
          String? initialDistributorId,
          RechargeOperator? initialOperator}) =>
      showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => DistributorPaymentV2Dialog(
          shopId: shopId,
          actor: actor,
          distributors: distributors,
          summary: summary,
          initialDistributorId: initialDistributorId,
          initialOperator: initialOperator,
        ),
      );

  @override
  State<DistributorPaymentV2Dialog> createState() => _DistributorPaymentV2DialogState();
}

class _DistributorPaymentV2DialogState extends State<DistributorPaymentV2Dialog> {
  final _amount = TextEditingController();
  final _ref = TextEditingController();
  final _notes = TextEditingController();
  String? _distributorId;
  RechargeOperator? _operator;
  String _mode = 'UPI';
  DateTime _date = DateTime.now();
  bool _confirmed = false;
  bool _busy = false;
  String? _error;
  int _formGen = 0; // rebuilds the dropdowns after Clear

  @override
  void initState() {
    super.initState();
    _distributorId = widget.initialDistributorId;
    _operator = widget.initialOperator;
  }

  @override
  void dispose() {
    _amount.dispose();
    _ref.dispose();
    _notes.dispose();
    super.dispose();
  }

  /// Wrong entry or starting again: everything typed goes back to empty.
  void _clearForm() {
    _amount.clear();
    _ref.clear();
    _notes.clear();
    setState(() {
      _distributorId = widget.initialDistributorId;
      _operator = widget.initialOperator;
      _mode = 'UPI';
      _date = DateTime.now();
      _confirmed = false;
      _error = null;
      _formGen++;
    });
  }

  int get _beforePaise {
    if (_distributorId == null || _operator == null) return 0;
    return widget.summary?.account(_distributorId!, _operator!)?.balancePaise ?? 0;
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(now.year - 2),
      lastDate: now, // never in the future
    );
    if (d != null) setState(() => _date = DateTime(d.year, d.month, d.day, now.hour, now.minute));
  }

  Future<void> _pay() async {
    final p = parseRupeesToPaise(_amount.text);
    if (_distributorId == null) return setState(() => _error = 'Select the distributor (ഡിസ്ട്രിബ്യൂട്ടർ)');
    if (_operator == null) return setState(() => _error = 'Select the operator (ഓപ്പറേറ്റർ)');
    if (p == null || p <= 0) return setState(() => _error = 'Enter a valid amount (സാധുവായ തുക നൽകുക)');
    if (!_confirmed) return setState(() => _error = 'Tick the owner confirmation first (സ്ഥിരീകരിക്കുക)');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await RechargeAccountingService.instance.distributorPayment(
        shopId: widget.shopId,
        actor: widget.actor,
        distributorId: _distributorId!,
        operator: _operator!,
        amountPaise: p,
        paymentMode: _mode,
        paymentDate: _date,
        referenceNo: _ref.text.trim(),
        notes: _notes.text.trim(),
      );
      if (mounted) {
        final adv = r.data['advancePaise'];
        _toast(
            context,
            r.replayed
                ? 'This payment was already recorded; nothing was posted again.'
                : (adv is int && adv > 0
                    ? 'Payment recorded. Advance with ${operatorShortName(_operator!)}: ${formatInrPaise(adv)}'
                    : 'Payment recorded.'));
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      setState(() => _error = accountingErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = parseRupeesToPaise(_amount.text) ?? 0;
    final before = _beforePaise;
    final after = before - p;
    return _PeriodDialog(
      title: 'Distributor Payment (operator-wise)',
      malayalam: 'ഷോപ്പിൽ നിന്നും ഓപ്പറേറ്ററുടെ ആൾക്ക് പേയ്മെൻ്റ് കൊടുക്കുക',
      actions: [
        TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            child: const Text('Cancel (വേണ്ട)')),
        TextButton.icon(
          key: const ValueKey('pay-clear'),
          onPressed: _busy ? null : _clearForm,
          icon: const Icon(Icons.backspace_outlined, size: 16, color: kPeriodRed),
          label: const Text('എല്ലാം മായ്ക്കുക (Clear)', style: TextStyle(color: kPeriodRed)),
        ),
        FilledButton(
          key: const ValueKey('pay-submit'),
          style: _primaryButton(kPeriodOrange),
          onPressed: _busy ? null : _pay,
          child: Text(_busy ? 'Posting…' : 'Record payment (രേഖപ്പെടുത്തുക)'),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            isExpanded: true,
            key: ValueKey('pay-distributor-$_formGen'),
            initialValue: _distributorId,
            dropdownColor: TekColors.elevatedSurface,
            style: const TextStyle(color: TekColors.textPrimary),
            decoration: _input('Distributor (ഡിസ്ട്രിബ്യൂട്ടർ)'),
            items: [
              for (final d in widget.distributors)
                DropdownMenuItem(value: d.id, child: Text(d.name)),
            ],
            onChanged: (v) => setState(() => _distributorId = v),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<RechargeOperator>(
            isExpanded: true,
            key: ValueKey('pay-operator-$_formGen'),
            initialValue: _operator,
            dropdownColor: TekColors.elevatedSurface,
            style: const TextStyle(color: TekColors.textPrimary),
            decoration: _input('Operator account (ഓപ്പറേറ്റർ)'),
            items: [
              for (final op in kPeriodOperators)
                DropdownMenuItem(value: op, child: Text(operatorShortName(op))),
            ],
            onChanged: (v) => setState(() => _operator = v),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('pay-amount'),
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(color: TekColors.textPrimary),
            decoration: _input('Payment amount', prefix: '₹ '),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: ValueKey('pay-mode-$_formGen'),
                  isExpanded: true,
                  initialValue: _mode,
                  dropdownColor: TekColors.elevatedSurface,
                  style: const TextStyle(color: TekColors.textPrimary),
                  decoration: _input('Mode'),
                  items: [
                    for (final m in kDistributorPaymentModes)
                      DropdownMenuItem(value: m, child: Text(m)),
                  ],
                  onChanged: (v) => setState(() => _mode = v ?? _mode),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: _busy ? null : _pickDate,
                icon: const Icon(Icons.event_rounded, size: 16),
                label: Text(DateFormat('dd MMM yyyy').format(_date)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
              controller: _ref,
              style: const TextStyle(color: TekColors.textPrimary),
              decoration: _input('Reference / UTR number')),
          const SizedBox(height: 10),
          TextField(
              controller: _notes,
              style: const TextStyle(color: TekColors.textPrimary),
              decoration: _input('Notes')),
          if (_distributorId != null && _operator != null) ...[
            const SizedBox(height: 12),
            Text('ഇപ്പോൾ: ${shopPaymentLineMalayalam(_operator!, before)}',
                key: const ValueKey('pay-before-ml'),
                style: TextStyle(
                    color: before > 0 ? kPeriodOrange : (before < 0 ? kPeriodBlue : kPeriodGreen),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700)),
            _row('${operatorShortName(_operator!)} account before',
                before >= 0 ? '${formatInrPaise(before)} outstanding' : '${formatInrPaise(-before)} advance',
                color: before >= 0 ? kPeriodOrange : kPeriodBlue),
            if (p > 0) ...[
              _row('After this payment',
                  after >= 0 ? '${formatInrPaise(after)} outstanding' : '${formatInrPaise(-after)} ADVANCE / EXCESS',
                  color: after > 0 ? kPeriodOrange : (after == 0 ? kPeriodGreen : kPeriodBlue),
                  bold: true),
              Text('ഈ പേയ്മെൻ്റിന് ശേഷം: ${shopPaymentLineMalayalam(_operator!, after)}',
                  key: const ValueKey('pay-after-ml'),
                  style: TextStyle(
                      color: after > 0 ? kPeriodOrange : (after == 0 ? kPeriodGreen : kPeriodBlue),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
            ],
            const Text(
              'Only this operator\'s account changes. An advance is never moved to another operator. Recharge totals and wallet balances do not change.',
              style: TextStyle(color: TekColors.textMuted, fontSize: 11),
            ),
          ],
          CheckboxListTile(
            key: const ValueKey('pay-confirm'),
            contentPadding: EdgeInsets.zero,
            value: _confirmed,
            onChanged: (v) => setState(() => _confirmed = v ?? false),
            title: const Text('I confirm this payment (ഉടമ സ്ഥിരീകരണം)',
                style: TextStyle(color: TekColors.textPrimary, fontSize: 12.5)),
          ),
          if (_error != null)
            Text(_error!, style: const TextStyle(color: kPeriodRed, fontSize: 12)),
        ],
      ),
    );
  }
}

// ===========================================================================
// SECTIONS
// ===========================================================================

class _SectionCard extends StatelessWidget {
  final String title;
  final String malayalam;
  final IconData icon;
  final Color accent;
  final Widget? trailing;
  final Widget child;
  const _SectionCard({
    required this.title,
    required this.malayalam,
    required this.icon,
    required this.accent,
    required this.child,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: TekColors.cardBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: accent.withValues(alpha: 0.35), width: 1.2),
          boxShadow: TekColors.cardShadow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: accent, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              color: TekColors.textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w800)),
                      Text(malayalam,
                          style: const TextStyle(color: TekColors.textSecondary, fontSize: 11)),
                    ],
                  ),
                ),
              ],
            ),
            if (trailing != null) ...[
              const SizedBox(height: 10),
              Align(alignment: Alignment.centerRight, child: trailing!),
            ],
            const SizedBox(height: 14),
            child,
          ],
        ),
      );
}

Widget _tableHeader(List<String> cols, List<int> flex) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: TekColors.mainBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        for (var i = 0; i < cols.length; i++)
          Expanded(
            flex: flex[i],
            child: Text(cols[i],
                textAlign: i == 0 ? TextAlign.left : TextAlign.right,
                style: const TextStyle(
                    color: TekColors.textMuted, fontSize: 10.5, fontWeight: FontWeight.w800)),
          ),
      ]),
    );

/// Operator-wise recharge breakdown with IST date filters.
class OperatorRechargeBreakdown extends StatefulWidget {
  final String shopId;
  const OperatorRechargeBreakdown({super.key, required this.shopId});

  @override
  State<OperatorRechargeBreakdown> createState() => _OperatorRechargeBreakdownState();
}

class _OperatorRechargeBreakdownState extends State<OperatorRechargeBreakdown> {
  RechargePeriodFilter _filter = RechargePeriodFilter.today;
  DateTimeRange? _custom;

  IstRange get _range => istRangeFor(_filter,
      customStart: _custom?.start, customEnd: _custom?.end);

  Future<void> _pick(RechargePeriodFilter f) async {
    if (f == RechargePeriodFilter.custom) {
      final now = DateTime.now();
      final r = await showDateRangePicker(
        context: context,
        firstDate: DateTime(now.year - 5),
        lastDate: now,
        initialDateRange: _custom,
      );
      if (r == null) return;
      setState(() {
        _custom = r;
        _filter = f;
      });
      return;
    }
    setState(() => _filter = f);
  }

  @override
  Widget build(BuildContext context) {
    final svc = RechargeAccountingService.instance;
    final sel = svc.volume(widget.shopId, _range);
    final all = svc.volume(widget.shopId, istRangeFor(RechargePeriodFilter.allTime));
    final selLabel = _filter == RechargePeriodFilter.custom && _custom != null
        ? '${DateFormat('dd MMM').format(_custom!.start)} – ${DateFormat('dd MMM').format(_custom!.end)}'
        : _filter.label;

    return _SectionCard(
      title: 'Operator Recharge Breakdown',
      malayalam: 'ഓപ്പറേറ്റർ തിരിച്ചുള്ള റീചാർജ് (IST)',
      icon: Icons.stacked_bar_chart_rounded,
      accent: TekColors.electricCyan,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final f in RechargePeriodFilter.values)
                ChoiceChip(
                  key: ValueKey('vol-filter-${f.name}'),
                  label: Text(f.label, style: const TextStyle(fontSize: 11)),
                  selected: _filter == f,
                  selectedColor: TekColors.electricCyan.withValues(alpha: 0.25),
                  backgroundColor: TekColors.mainBg,
                  labelStyle: TextStyle(
                      color: _filter == f ? TekColors.textPrimary : TekColors.textSecondary),
                  onSelected: (_) => _pick(f),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _tableHeader(['OPERATOR', selLabel.toUpperCase(), 'CUMULATIVE'], [3, 4, 4]),
          for (final op in kPeriodOperators)
            InkWell(
              key: ValueKey('vol-row-${op.name}'),
              onTap: () => showOperatorDetail(context,
                  shopId: widget.shopId, operator: op, range: _range, rangeLabel: selLabel),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                child: Row(children: [
                  Expanded(
                      flex: 3,
                      child: Row(children: [
                        Text(operatorShortName(op),
                            style: const TextStyle(
                                color: TekColors.textPrimary, fontWeight: FontWeight.w700)),
                        const Icon(Icons.chevron_right_rounded,
                            size: 16, color: TekColors.textMuted),
                      ])),
                  Expanded(
                      flex: 4,
                      child: Text(formatInrPaise(sel.of(op).grossPaise),
                          textAlign: TextAlign.right,
                          style: const TextStyle(color: TekColors.textPrimary))),
                  Expanded(
                      flex: 4,
                      child: Text(formatInrPaise(all.of(op).grossPaise),
                          textAlign: TextAlign.right,
                          style: const TextStyle(color: TekColors.textPrimary))),
                ]),
              ),
            ),
          const Divider(color: TekColors.border),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(children: [
              const Expanded(
                  flex: 3,
                  child: Text('TOTAL',
                      style: TextStyle(color: TekColors.textPrimary, fontWeight: FontWeight.w900))),
              Expanded(
                  flex: 4,
                  child: Text(formatInrPaise(sel.grossPaise),
                      key: const ValueKey('vol-total-selected'),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          color: TekColors.electricCyan, fontWeight: FontWeight.w900))),
              Expanded(
                  flex: 4,
                  child: Text(formatInrPaise(all.grossPaise),
                      key: const ValueKey('vol-total-cumulative'),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          color: TekColors.electricCyan, fontWeight: FontWeight.w900))),
            ]),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              _mini('Gross', formatInrPaise(sel.grossPaise)),
              _mini('Refunds / Reversals', formatInrPaise(sel.refundsPaise)),
              _mini('Net', formatInrPaise(sel.netPaise)),
              _mini('Successful', '${sel.successCount}'),
              _mini('Failed', '${sel.failedCount}'),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Face value of successful recharges. Failed and pending recharges are not counted. Distributor payments never change these totals. Week starts on Monday; all dates are India time (IST).',
            style: TextStyle(color: TekColors.textMuted, fontSize: 10.5),
          ),
        ],
      ),
    );
  }

  Widget _mini(String k, String v) => Text.rich(TextSpan(children: [
        TextSpan(text: '$k: ', style: const TextStyle(color: TekColors.textMuted, fontSize: 11)),
        TextSpan(
            text: v,
            style: const TextStyle(
                color: TekColors.textPrimary, fontSize: 11.5, fontWeight: FontWeight.w700)),
      ]));
}

/// Detail view for one operator: transactions in the range, gross / refunds /
/// net, counts, commission (instant vs periodic) and settlement history.
Future<void> showOperatorDetail(BuildContext context,
    {required String shopId,
    required RechargeOperator operator,
    required IstRange range,
    required String rangeLabel}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: TekColors.cardBg,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    builder: (ctx) => FractionallySizedBox(
      heightFactor: 0.85,
      child: _OperatorDetail(
          shopId: shopId, operator: operator, range: range, rangeLabel: rangeLabel),
    ),
  );
}

class _OperatorDetail extends StatefulWidget {
  final String shopId;
  final RechargeOperator operator;
  final IstRange range;
  final String rangeLabel;
  const _OperatorDetail(
      {required this.shopId,
      required this.operator,
      required this.range,
      required this.rangeLabel});

  @override
  State<_OperatorDetail> createState() => _OperatorDetailState();
}

class _OperatorDetailState extends State<_OperatorDetail> {
  int _instant = 0;
  int _periodic = 0;
  SettlementSummary? _settlement;
  String? _settlementError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final comms = await RechargeService.instance.getCommissionReport(
        shopId: widget.shopId,
        startDate: widget.range.startUtc?.toLocal(),
        endDate: widget.range.endUtc.toLocal(),
        operator: widget.operator,
      );
      var i = 0, p = 0;
      for (final c in comms) {
        if (c.commissionType == RechargeCommissionType.prepaid) {
          i += c.amountPaise;
        } else {
          p += c.amountPaise;
        }
      }
      if (mounted) {
        setState(() {
          _instant = i;
          _periodic = p;
        });
      }
    } catch (_) {}
    try {
      final s = await RechargeAccountingService.instance.settlement(widget.shopId);
      if (mounted) setState(() => _settlement = s);
    } catch (e) {
      if (mounted) setState(() => _settlementError = accountingErrorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final op = widget.operator;
    final txns = RechargeService.instance
        .getLocalRecharges(shopId: widget.shopId)
        .where((r) => r.operator == op && widget.range.contains(r.createdAt))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final v = RechargeAccountingService.instance.volume(widget.shopId, widget.range).of(op);
    final accounts = _settlement?.accounts.where((a) => a.operator == op).toList() ?? const [];
    final tf = DateFormat('dd MMM, hh:mm a');

    return Padding(
      padding: const EdgeInsets.all(18),
      child: ListView(
        children: [
          Text('${operatorShortName(op)} – ${widget.rangeLabel}',
              style: const TextStyle(
                  color: TekColors.textPrimary, fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          _row('Gross recharge', formatInrPaise(v.grossPaise)),
          _row('Refunds / reversals', formatInrPaise(v.refundsPaise)),
          _row('Net recharge', formatInrPaise(v.netPaise), bold: true),
          _row('Successful / failed / pending', '${v.successCount} / ${v.failedCount} / ${v.pendingCount}'),
          _row('Commission – instant (load margin)', formatInrPaise(_instant), color: kPeriodGreen),
          _row('Commission – periodic (postpaid)', formatInrPaise(_periodic), color: kPeriodGreen),
          const SizedBox(height: 12),
          const Text('Distributor settlement',
              style: TextStyle(color: TekColors.textPrimary, fontWeight: FontWeight.w800)),
          if (_settlementError != null)
            Text(_settlementError!, style: const TextStyle(color: kPeriodRed, fontSize: 12)),
          for (final a in accounts)
            _row(a.distributorName,
                a.advancePaise > 0
                    ? 'Advance ${formatInrPaise(a.advancePaise)}'
                    : 'Outstanding ${formatInrPaise(a.outstandingPaise)}',
                color: a.advancePaise > 0 ? kPeriodBlue : kPeriodOrange),
          if (_settlement != null && accounts.isEmpty)
            const Text('No distributor account for this operator.',
                style: TextStyle(color: TekColors.textMuted, fontSize: 12)),
          const SizedBox(height: 12),
          Text('Transactions (${txns.length})',
              style: const TextStyle(color: TekColors.textPrimary, fontWeight: FontWeight.w800)),
          for (final r in txns.take(300))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('${r.customerMobile.isEmpty ? r.rechargeId : r.customerMobile}  •  ${r.status.label}',
                  style: const TextStyle(color: TekColors.textPrimary, fontSize: 12.5)),
              subtitle: Text(tf.format(r.createdAt.toLocal()),
                  style: const TextStyle(color: TekColors.textMuted, fontSize: 11)),
              trailing: Text(formatInrPaise(r.amountPaise),
                  style: TextStyle(
                      color: r.status == RechargeStatus.success
                          ? TekColors.textPrimary
                          : TekColors.textMuted,
                      fontWeight: FontWeight.w700)),
            ),
          if (txns.length > 300)
            const Text('Showing the latest 300.',
                style: TextStyle(color: TekColors.textMuted, fontSize: 11)),
        ],
      ),
    );
  }
}

/// Operator-wise distributor settlement table.
/// "Airtel's" etc. in plain Malayalam, for the payment lines.
String operatorPersonMalayalam(RechargeOperator op) {
  switch (op) {
    case RechargeOperator.airtel:
      return 'എയർടെലിൻ്റെ';
    case RechargeOperator.jio:
      return 'ജിയോയുടെ';
    case RechargeOperator.vi:
      return 'വിഐയുടെ';
    case RechargeOperator.bsnl:
      return 'ബിഎസ്എൻഎലിൻ്റെ';
    case RechargeOperator.other:
      return 'ഡിസ്ട്രിബ്യൂട്ടറുടെ';
  }
}

/// One account's position as the owner says it, e.g.
/// "ഷോപ്പിൽ നിന്നും എയർടെലിൻ്റെ ആൾക്ക് കൊടുക്കാനുള്ള പേയ്മെൻ്റ്: ₹1,000.00".
/// [balancePaise] > 0: shop still owes; < 0: shop paid extra (advance).
String shopPaymentLineMalayalam(RechargeOperator op, int balancePaise) {
  final who = '${operatorPersonMalayalam(op)} ആൾക്ക്';
  if (balancePaise > 0) {
    return 'ഷോപ്പിൽ നിന്നും $who കൊടുക്കാനുള്ള പേയ്മെൻ്റ്: ${formatInrPaise(balancePaise)}';
  }
  if (balancePaise < 0) {
    return 'ഷോപ്പിൽ നിന്നും $who കൂടുതൽ കൊടുത്തത് (അഡ്വാൻസ്): ${formatInrPaise(-balancePaise)}';
  }
  return '$who കൊടുക്കാൻ ഒന്നും ബാക്കിയില്ല ✓';
}

class DistributorSettlementTable extends StatelessWidget {
  final SettlementSummary? summary;
  final String? error;
  final void Function(SettlementAccount? account) onPay;

  /// Fresh start: marks an account's old dues as settled outside the system.
  final void Function(SettlementAccount account)? onClearOld;

  /// Fresh start: records dues still owed from before the new start.
  final void Function(SettlementAccount account)? onOpeningDues;
  const DistributorSettlementTable(
      {super.key,
      required this.summary,
      required this.error,
      required this.onPay,
      this.onClearOld,
      this.onOpeningDues});

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final df = DateFormat('dd MMM yyyy');
    return _SectionCard(
      title: 'Distributor Settlement (operator-wise)',
      malayalam: 'ഓപ്പറേറ്റർ തിരിച്ചുള്ള ഡിസ്ട്രിബ്യൂട്ടർ ബാക്കി',
      icon: Icons.account_balance_wallet_rounded,
      accent: kPeriodOrange,
      trailing: FilledButton.icon(
        key: const ValueKey('settlement-pay'),
        style: _primaryButton(kPeriodOrange),
        onPressed: () => onPay(null),
        icon: const Icon(Icons.payments_rounded, size: 16),
        label: const Text('Pay distributor', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      child: error != null
          ? Text(error!, style: const TextStyle(color: kPeriodRed, fontSize: 12.5))
          : s == null
              ? const LinearProgressIndicator(minHeight: 2)
              : LayoutBuilder(builder: (context, c) {
                  final narrow = c.maxWidth < 700;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(spacing: 18, runSpacing: 6, children: [
                        _total('ഷോപ്പിൽ നിന്നും ആകെ കൊടുക്കാനുള്ളത് (Outstanding)', s.outstandingPaise, kPeriodOrange),
                        _total('കൂടുതൽ കൊടുത്തത് / അഡ്വാൻസ് (Advance)', s.advancePaise, kPeriodBlue),
                        _total('Net position (info)', s.netPositionPaise, TekColors.textSecondary),
                      ]),
                      const SizedBox(height: 10),
                      if (s.accounts.isEmpty)
                        const Text('No distributor accounts yet.',
                            style: TextStyle(color: TekColors.textMuted, fontSize: 12)),
                      if (s.accounts.isNotEmpty && !narrow)
                        _tableHeader(
                            ['DISTRIBUTOR', 'OPERATOR', 'PAYABLE', 'PAID', 'OUTSTANDING', 'ADVANCE', 'LAST PAID'],
                            [4, 2, 3, 3, 3, 3, 3]),
                      for (final a in s.accounts)
                        InkWell(
                          onTap: () => onPay(a),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                narrow ? _narrowRow(a, df) : _wideRow(a, df),
                                if (a.operator != RechargeOperator.other)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 3),
                                    child: Text(
                                      shopPaymentLineMalayalam(a.operator, a.balancePaise),
                                      key: ValueKey('pay-line-${a.distributorId}-${a.operator.name}'),
                                      style: TextStyle(
                                          color: a.balancePaise > 0
                                              ? kPeriodOrange
                                              : (a.balancePaise < 0 ? kPeriodBlue : kPeriodGreen),
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700),
                                    ),
                                  ),
                                if (a.operator != RechargeOperator.other &&
                                    (onOpeningDues != null ||
                                        (onClearOld != null && a.outstandingPaise > 0)))
                                  Wrap(
                                    alignment: WrapAlignment.end,
                                    spacing: 4,
                                    children: [
                                      if (onClearOld != null && a.outstandingPaise > 0)
                                        TextButton.icon(
                                          key: ValueKey('clear-old-${a.distributorId}-${a.operator.name}'),
                                          onPressed: () => onClearOld!(a),
                                          icon: const Icon(Icons.cleaning_services_rounded, size: 14),
                                          label: const Text('Clear old dues (പഴയ ബാക്കി തീർക്കുക)',
                                              style: TextStyle(fontSize: 11)),
                                        ),
                                      if (onOpeningDues != null)
                                        TextButton.icon(
                                          key: ValueKey('opening-dues-${a.distributorId}-${a.operator.name}'),
                                          onPressed: () => onOpeningDues!(a),
                                          icon: const Icon(Icons.playlist_add_rounded, size: 14),
                                          label: const Text('Opening dues (തുടക്ക ബാക്കി)',
                                              style: TextStyle(fontSize: 11)),
                                        ),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  );
                }),
    );
  }

  Widget _total(String label, int paise, Color c) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: TekColors.textMuted, fontSize: 10.5)),
          Text(formatInrPaise(paise),
              style: TextStyle(color: c, fontSize: 16, fontWeight: FontWeight.w900)),
        ],
      );

  Widget _cell(String t, int flex, {Color? c, bool left = false}) => Expanded(
        flex: flex,
        child: Text(t,
            textAlign: left ? TextAlign.left : TextAlign.right,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: c ?? TekColors.textPrimary, fontSize: 12)),
      );

  Widget _wideRow(SettlementAccount a, DateFormat df) => Row(children: [
        _cell(a.distributorName, 4, left: true),
        _cell(operatorShortName(a.operator), 2),
        _cell(formatInrPaise(a.payablePaise), 3),
        _cell(formatInrPaise(a.paidPaise), 3),
        _cell(formatInrPaise(a.outstandingPaise), 3,
            c: a.outstandingPaise > 0 ? kPeriodOrange : TekColors.textMuted),
        _cell(formatInrPaise(a.advancePaise), 3,
            c: a.advancePaise > 0 ? kPeriodBlue : TekColors.textMuted),
        _cell(a.lastPaymentAt == null ? '—' : df.format(a.lastPaymentAt!.toLocal()), 3),
      ]);

  Widget _narrowRow(SettlementAccount a, DateFormat df) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${a.distributorName} • ${operatorShortName(a.operator)}',
              style: const TextStyle(color: TekColors.textPrimary, fontWeight: FontWeight.w700)),
          Text(
              'Payable ${formatInrPaise(a.payablePaise)} • Paid ${formatInrPaise(a.paidPaise)}'
              '${a.lastPaymentAt == null ? '' : ' • ${df.format(a.lastPaymentAt!.toLocal())}'}',
              style: const TextStyle(color: TekColors.textMuted, fontSize: 11)),
          Text(
              a.advancePaise > 0
                  ? 'ADVANCE ${formatInrPaise(a.advancePaise)}'
                  : 'Outstanding ${formatInrPaise(a.outstandingPaise)}',
              style: TextStyle(
                  color: a.advancePaise > 0 ? kPeriodBlue : kPeriodOrange,
                  fontWeight: FontWeight.w800)),
        ],
      );
}
