// Owner edit of a saved recharge entry (2026-11-22).
// A saved recharge is never overwritten:
//  * mobile number / Cash <-> UPI: changed on the server with an audit event;
//  * wrong amount / operator: the entry is marked Corrected on the server (its
//    wallet debit comes back, its commission is reversed) and the correct
//    recharge is then saved through the normal New Recharge flow.
// Owner only, online only, reason required; refused after that operator's
// next closing is verified (LOCKED_PERIOD).
import 'package:flutter/material.dart';

import '../main.dart' show Db;
import '../theme/tek_tokens.dart';
import 'recharge_accounting_backend.dart';
import 'recharge_accounting_service.dart';
import 'recharge_models.dart';
import 'recharge_period_widgets.dart' show accountingErrorText;
import 'recharge_service.dart';

/// Local-copy updates that follow a confirmed server edit/correction.
/// The server decides; these only mirror its result on this device.
class RechargeEntryEditor {
  RechargeEntryEditor._();

  static Map<String, dynamic> _localMap(RechargeEntry t) {
    final raw = Db.recharges.get(t.rechargeId);
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return Map<String, dynamic>.from(t.toMap(forFirestore: false));
  }

  static String _modeOf(Map<String, dynamic> map) => map['paymentMode']?.toString() ?? 'Cash';

  /// True when the entry can only be fixed with a correction (Credit / Due).
  static bool isCreditDue(RechargeEntry t) => _modeOf(_localMap(t)) == 'Credit / Due';

  /// Mobile number and/or Cash <-> UPI. Pass null for "unchanged".
  static Future<void> editDetails({
    required String shopId,
    required AccountingActor actor,
    required RechargeEntry entry,
    String? newMobile,
    String? newPaymentMode,
    required String reason,
  }) async {
    final r = await RechargeAccountingService.instance.editRechargeDetails(
      shopId: shopId,
      actor: actor,
      rechargeId: entry.rechargeId,
      customerPhone: newMobile,
      paymentMode: newPaymentMode,
      reason: reason,
    );
    final map = _localMap(entry);
    final phone = (r.data['customerPhone'] ?? newMobile)?.toString();
    final mode = (r.data['paymentMode'] ?? newPaymentMode)?.toString();
    if (newMobile != null && phone != null) {
      map['mobile'] = phone;
      map['customerMobile'] = phone;
    }
    if (newPaymentMode != null && mode != null) map['paymentMode'] = mode;
    map['notes'] = '${map['notes'] ?? ''} [Edited: ${reason.trim()}]'.trim();
    map['updatedAt'] = DateTime.now().toIso8601String();
    await Db.recharges.put(entry.rechargeId, map);
    RechargeService.instance.registerConfirmedRecharge(map, entry.rechargeId);
  }

  /// Marks the entry Corrected (server credits the wallet back once). A
  /// Credit / Due entry also takes its amount off the customer's due, once.
  static Future<int> correct({
    required String shopId,
    required AccountingActor actor,
    required RechargeEntry entry,
    required String reason,
  }) async {
    final r = await RechargeAccountingService.instance.correctRecharge(
      shopId: shopId,
      actor: actor,
      rechargeId: entry.rechargeId,
      reason: reason,
    );
    final map = _localMap(entry);
    final alreadyLocal = RechargeStatus.fromString(map['status']?.toString()) == RechargeStatus.corrected;
    if (!alreadyLocal) {
      final partyKey = map['partyKey'];
      if (_modeOf(map) == 'Credit / Due' && partyKey != null && Db.parties.containsKey(partyKey)) {
        await Db.adjustParty(partyKey, -entry.amount);
      }
      map['status'] = 'CORRECTED';
      map['notes'] = '${map['notes'] ?? ''} [Corrected: ${reason.trim()}]'.trim();
      map['updatedAt'] = DateTime.now().toIso8601String();
      await Db.recharges.put(entry.rechargeId, map);
      RechargeService.instance.registerConfirmedRecharge(map, entry.rechargeId);
    }
    return (r.data['walletCreditPaise'] as num?)?.toInt() ?? 0;
  }

  /// Values to pre-fill the New Recharge form with after a correction.
  static RechargePrefill prefillFor(RechargeEntry entry) {
    final map = _localMap(entry);
    return RechargePrefill(
      operator: map['operator']?.toString() ?? entry.operator.displayName,
      mobile: entry.customerMobile,
      amount: entry.amount,
      paymentMode: _modeOf(map),
      notes: 'Correction of ${entry.rechargeId}',
    );
  }
}

/// Starting values for the New Recharge form.
class RechargePrefill {
  final String operator;
  final String mobile;
  final double amount;
  final String paymentMode;
  final String notes;
  const RechargePrefill({
    required this.operator,
    required this.mobile,
    required this.amount,
    required this.paymentMode,
    required this.notes,
  });
}

/// Result of the Edit dialog.
enum RechargeEditOutcome { none, detailsSaved, corrected }

class RechargeEditDialog extends StatefulWidget {
  final String shopId;
  final AccountingActor actor;
  final RechargeEntry entry;
  const RechargeEditDialog({super.key, required this.shopId, required this.actor, required this.entry});

  static Future<RechargeEditOutcome> show(BuildContext context,
      {required String shopId, required AccountingActor actor, required RechargeEntry entry}) async {
    final r = await showDialog<RechargeEditOutcome>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RechargeEditDialog(shopId: shopId, actor: actor, entry: entry),
    );
    return r ?? RechargeEditOutcome.none;
  }

  @override
  State<RechargeEditDialog> createState() => _RechargeEditDialogState();
}

class _RechargeEditDialogState extends State<RechargeEditDialog> {
  late final TextEditingController _mobile;
  final _reason = TextEditingController();
  late String _mode;
  late final String _origMode;
  late final bool _creditDue;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _mobile = TextEditingController(text: widget.entry.customerMobile);
    _creditDue = RechargeEntryEditor.isCreditDue(widget.entry);
    _origMode = _creditDue
        ? 'Credit / Due'
        : (widget.entry.paymentMode == RechargePaymentMode.upi ? 'UPI' : 'Cash');
    _mode = _origMode;
  }

  @override
  void dispose() {
    // Disposed after the exit animation (avoids the red error screen).
    final m = _mobile, r = _reason;
    Future.delayed(const Duration(milliseconds: 500), () {
      m.dispose();
      r.dispose();
    });
    super.dispose();
  }

  bool _reasonOk() {
    if (_reason.text.trim().isEmpty) {
      setState(() => _error = 'കാരണം എഴുതുക (Enter a reason)');
      return false;
    }
    return true;
  }

  Future<void> _saveDetails() async {
    if (!_reasonOk()) return;
    final phone = _mobile.text.trim();
    final phoneChanged = phone != widget.entry.customerMobile;
    final modeChanged = _mode != _origMode;
    if (!phoneChanged && !modeChanged) {
      setState(() => _error = 'മാറ്റമൊന്നുമില്ല (Nothing changed)');
      return;
    }
    if (phoneChanged && !RegExp(r'^[0-9]{10}$').hasMatch(phone)) {
      setState(() => _error = 'മൊബൈൽ നമ്പർ 10 അക്കം (Mobile number must be 10 digits)');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await RechargeEntryEditor.editDetails(
        shopId: widget.shopId,
        actor: widget.actor,
        entry: widget.entry,
        newMobile: phoneChanged ? phone : null,
        newPaymentMode: modeChanged ? _mode : null,
        reason: _reason.text,
      );
      if (mounted) Navigator.pop(context, RechargeEditOutcome.detailsSaved);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = accountingErrorText(e);
        });
      }
    }
  }

  Future<void> _correct() async {
    if (!_reasonOk()) return;
    final t = widget.entry;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TekColors.cardBg,
        title: const Text('Correct this recharge? (തിരുത്തണോ?)',
            style: TextStyle(color: TekColors.textPrimary, fontSize: 16)),
        content: Text(
          '${t.operator.displayName} • ${t.customerMobile} • ₹${t.amount.toStringAsFixed(2)}\n\n'
          'This entry will be marked CORRECTED and ₹${t.amount.toStringAsFixed(2)} goes back to the wallet. '
          'Then the New Recharge form opens: save the correct amount / operator there.\n\n'
          'ഈ എൻട്രി "തിരുത്തി" എന്നാകും, തുക വാലറ്റിലേക്ക് തിരികെ വരും. '
          'ശേഷം തുറക്കുന്ന ഫോമിൽ ശരിയായ റീചാർജ് സേവ് ചെയ്യുക.',
          style: const TextStyle(color: TekColors.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No (വേണ്ട)')),
          FilledButton(
            key: const ValueKey('correct-recharge-confirm'),
            style: FilledButton.styleFrom(backgroundColor: TekColors.warning),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Yes, correct (തിരുത്തുക)'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await RechargeEntryEditor.correct(
          shopId: widget.shopId, actor: widget.actor, entry: t, reason: _reason.text);
      if (mounted) Navigator.pop(context, RechargeEditOutcome.corrected);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = accountingErrorText(e);
        });
      }
    }
  }

  Widget _modeChip(String mode) {
    final sel = _mode == mode;
    return ChoiceChip(
      key: ValueKey('edit-mode-$mode'),
      label: Text(mode),
      selected: sel,
      onSelected: (_busy || _creditDue) ? null : (_) => setState(() => _mode = mode),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.entry;
    const label = TextStyle(color: TekColors.textSecondary, fontSize: 12);
    return AlertDialog(
      backgroundColor: TekColors.cardBg,
      title: const Text('Edit Recharge (റീചാർജ് തിരുത്തുക)',
          style: TextStyle(color: TekColors.textPrimary, fontSize: 17, fontWeight: FontWeight.bold)),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${t.operator.displayName} • ₹${t.amount.toStringAsFixed(2)} • ${t.rechargeId}',
                  style: const TextStyle(color: TekColors.textMuted, fontSize: 11.5)),
              const SizedBox(height: 14),
              const Text('1. Mobile number / payment mode (മൊബൈൽ നമ്പർ / പേയ്മെന്റ് രീതി)', style: label),
              const SizedBox(height: 6),
              TextField(
                key: const ValueKey('edit-mobile'),
                controller: _mobile,
                enabled: !_busy,
                keyboardType: TextInputType.phone,
                maxLength: 10,
                style: const TextStyle(color: TekColors.textPrimary),
                decoration: const InputDecoration(labelText: 'Mobile (മൊബൈൽ)', counterText: ''),
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [_modeChip('Cash'), _modeChip('UPI')]),
              if (_creditDue)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                      'Credit / Due entry: to change the payment mode use "Correct" below. '
                      '(ക്രെഡിറ്റ് എൻട്രിക്ക് താഴെയുള്ള "തിരുത്തുക" ഉപയോഗിക്കുക)',
                      style: TextStyle(color: TekColors.warning, fontSize: 11)),
                ),
              const SizedBox(height: 14),
              TextField(
                key: const ValueKey('edit-reason'),
                controller: _reason,
                enabled: !_busy,
                style: const TextStyle(color: TekColors.textPrimary),
                decoration: const InputDecoration(labelText: 'Reason (കാരണം) *'),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  key: const ValueKey('edit-save-details'),
                  onPressed: _busy ? null : _saveDetails,
                  child: const Text('Save details (സേവ് ചെയ്യുക)'),
                ),
              ),
              const Divider(height: 28, color: TekColors.borderSubtle),
              const Text('2. Wrong amount / operator (തുകയോ ഓപ്പറേറ്ററോ തെറ്റി)', style: label),
              const SizedBox(height: 6),
              const Text(
                  'Marks this entry CORRECTED, returns the amount to the wallet, then opens New Recharge to save the correct one.\n'
                  'ഈ എൻട്രി "തിരുത്തി" ആക്കി, ശരിയായത് പുതിയതായി സേവ് ചെയ്യാം.',
                  style: TextStyle(color: TekColors.textMuted, fontSize: 11.5)),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  key: const ValueKey('edit-correct'),
                  onPressed: _busy ? null : _correct,
                  icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                  label: const Text('Correct amount / operator (തിരുത്തുക)'),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_error!,
                      key: const ValueKey('edit-error'),
                      style: const TextStyle(color: TekColors.error, fontSize: 12)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, RechargeEditOutcome.none),
          child: const Text('Close (അടയ്ക്കുക)'),
        ),
      ],
    );
  }
}
