// ============================================================================
// TEKFIX ERP - STAFF DETAIL: month view, attendance calendar, salary /
// advance payments (with reversal), bonus / deduction, carry-forward balance
// and salary slip (WhatsApp / copy). Owner screen; local Hive (tek_staff).
// ============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart' show Db, ModeSelector, toast, tf, formDialog, rs;
import '../ui/sync_status_icon.dart' show TekAppBar;
import 'staff_payroll.dart';

class StaffDetailScreen extends StatefulWidget {
  final dynamic staffKey;
  const StaffDetailScreen({super.key, required this.staffKey});

  @override
  State<StaffDetailScreen> createState() => _StaffDetailScreenState();
}

class _StaffDetailScreenState extends State<StaffDetailScreen> {
  String _month = payrollMonthKey(DateTime.now());

  Map<String, dynamic>? get _staff {
    final v = Db.staff.get(widget.staffKey);
    return v is Map ? Map<String, dynamic>.from(v) : null;
  }

  Future<void> _save(Map<String, dynamic> s) async {
    s['lastUpdated'] = DateTime.now().toIso8601String();
    await Db.staff.put(widget.staffKey, s);
  }

  // ------------------------------------------------------------ attendance
  Future<void> _setDay(Map<String, dynamic> s, DateTime day) async {
    final key = payrollDayKey(day);
    final current = '${(s['attendance'] as Map?)?[key] ?? ''}';
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text('${s['name']} • ${DateFormat('dd MMM yyyy').format(day)}',
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text(current.isEmpty ? 'Not marked' : 'Now: $current'),
            ),
            for (final o in const [
              ('Present', 'Present (ഹാജർ)', Colors.green),
              ('Half Day', 'Half Day (പകുതി)', Colors.orange),
              ('Absent', 'Absent (ലീവ്)', Colors.red),
            ])
              ListTile(
                leading: Icon(Icons.circle, color: o.$3),
                title: Text(o.$2),
                selected: current == o.$1,
                onTap: () => Navigator.pop(ctx, o.$1),
              ),
            ListTile(
              leading: const Icon(Icons.clear),
              title: const Text('Clear (മായ്ക്കുക)'),
              onTap: () => Navigator.pop(ctx, ''),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    final att = Map<String, dynamic>.from((s['attendance'] as Map?) ?? {});
    if (choice.isEmpty) {
      att.remove(key);
    } else {
      att[key] = choice;
    }
    s['attendance'] = att;
    await _save(s);
    await Db.logAction(
        action: 'Attendance Marked',
        entity: 'Staff',
        entityId: '${widget.staffKey}',
        newValue: {'date': key, 'status': choice.isEmpty ? 'cleared' : choice});
  }

  // -------------------------------------------------------------- payments
  Future<void> _pay(Map<String, dynamic> s, PayrollMonth p) async {
    final amt = TextEditingController(
        text: p.net > 0 ? p.net.toStringAsFixed(p.net == p.net.roundToDouble() ? 0 : 2) : '');
    final note = TextEditingController();
    String mode = 'Cash';
    String type = 'salary';
    await formDialog(
      context,
      title: 'ശമ്പളം / അഡ്വാൻസ്: ${s['name']} (${p.month})',
      body: (set) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'salary', label: Text('ശമ്പളം (Salary)')),
              ButtonSegment(value: 'advance', label: Text('അഡ്വാൻസ് (Advance)')),
            ],
            selected: {type},
            onSelectionChanged: (v) => set(() => type = v.first),
          ),
          const SizedBox(height: 12),
          tf(amt, 'നൽകുന്ന തുക ₹', number: true),
          tf(note, 'കുറിപ്പ് (Note)'),
          ModeSelector(value: mode, onChanged: (v) => set(() => mode = v)),
        ],
      ),
      onSave: () async {
        final a = ((double.tryParse(amt.text.trim()) ?? 0) * 100).round() / 100;
        if (a <= 0) return 'ശരിയായ തുക നൽകുക';
        final expenseKey = await Db.expenses.add({
          'category': 'Staff Salary',
          'title': '${type == 'advance' ? 'Advance' : 'Salary'} to ${s['name']} (${p.month})',
          'amount': a,
          'mode': mode,
          'createdAt': DateTime.now().toIso8601String(),
        });
        final pays = [
          for (final e in (s['payments'] as List?) ?? const []) Map<String, dynamic>.from(e as Map)
        ];
        pays.add({
          'id': 'PAY_${DateTime.now().microsecondsSinceEpoch}',
          'date': DateTime.now().toIso8601String(),
          'month': p.month,
          'amount': a,
          'mode': mode,
          'type': type,
          'note': note.text.trim(),
          'expenseKey': expenseKey,
        });
        s['payments'] = pays;
        await _save(s);
        await Db.moveMoney(mode, -a, '${type == 'advance' ? 'Advance' : 'Salary'}: ${s['name']}');
        await Db.logAction(
            action: type == 'advance' ? 'Staff Advance Paid' : 'Salary Paid',
            entity: 'Staff',
            entityId: '${widget.staffKey}',
            newValue: {'amount': a, 'mode': mode, 'month': p.month, 'type': type});
        return null;
      },
    );
  }

  /// Wrong payment: marked reversed (kept for audit), money and the expense
  /// are put back with a reversing entry. Nothing is deleted.
  Future<void> _reversePayment(Map<String, dynamic> s, int index) async {
    final pays = [
      for (final e in (s['payments'] as List?) ?? const []) Map<String, dynamic>.from(e as Map)
    ];
    final x = pays[index];
    if (x['reversed'] == true) return;
    final a = (x['amount'] as num?)?.toDouble() ?? 0;
    final mode = '${x['mode'] ?? 'Cash'}';
    final ok = await _confirm('ഈ പേയ്‌മെന്റ് റദ്ദാക്കണോ? (Reverse this payment?)',
        '${rs(a)} • $mode • ${x['note'] ?? ''}\nപണം $mode-ലേക്ക് തിരികെ ചേർക്കും.');
    if (!ok) return;
    x['reversed'] = true;
    x['reversedAt'] = DateTime.now().toIso8601String();
    pays[index] = x;
    s['payments'] = pays;
    await _save(s);
    await Db.expenses.add({
      'category': 'Staff Salary',
      'title': 'Reversal: ${x['type'] == 'advance' ? 'Advance' : 'Salary'} to ${s['name']} (${x['month']})',
      'amount': -a,
      'mode': mode,
      'createdAt': DateTime.now().toIso8601String(),
      'reversalOf': x['expenseKey'],
    });
    await Db.moveMoney(mode, a, 'Reversal of salary/advance: ${s['name']}');
    await Db.logAction(
        action: 'Staff Payment Reversed',
        entity: 'Staff',
        entityId: '${widget.staffKey}',
        newValue: {'amount': a, 'mode': mode, 'month': x['month']});
    if (mounted) toast(context, 'പേയ്‌മെന്റ് റദ്ദാക്കി (Payment reversed)');
  }

  // ----------------------------------------------------------- adjustments
  Future<void> _adjust(Map<String, dynamic> s, String month) async {
    final amt = TextEditingController();
    final note = TextEditingController();
    String kind = 'bonus';
    await formDialog(
      context,
      title: 'ബോണസ് / കുറവ്: ${s['name']} ($month)',
      body: (set) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'bonus', label: Text('ബോണസ് / ഓവർടൈം')),
              ButtonSegment(value: 'deduction', label: Text('കുറവ് / പിഴ')),
            ],
            selected: {kind},
            onSelectionChanged: (v) => set(() => kind = v.first),
          ),
          const SizedBox(height: 12),
          tf(amt, 'തുക ₹', number: true),
          tf(note, 'കാരണം (Reason) *'),
        ],
      ),
      onSave: () async {
        final a = ((double.tryParse(amt.text.trim()) ?? 0) * 100).round() / 100;
        if (a <= 0) return 'ശരിയായ തുക നൽകുക';
        if (note.text.trim().isEmpty) return 'കാരണം നൽകുക (Reason required)';
        final adjs = [
          for (final e in (s['adjustments'] as List?) ?? const []) Map<String, dynamic>.from(e as Map)
        ];
        adjs.add({
          'id': 'ADJ_${DateTime.now().microsecondsSinceEpoch}',
          'date': DateTime.now().toIso8601String(),
          'month': month,
          'amount': kind == 'bonus' ? a : -a,
          'note': note.text.trim(),
        });
        s['adjustments'] = adjs;
        await _save(s);
        await Db.logAction(
            action: kind == 'bonus' ? 'Staff Bonus Added' : 'Staff Deduction Added',
            entity: 'Staff',
            entityId: '${widget.staffKey}',
            newValue: {'amount': kind == 'bonus' ? a : -a, 'month': month, 'note': note.text.trim()});
        return null;
      },
    );
  }

  Future<void> _reverseAdjustment(Map<String, dynamic> s, int index) async {
    final adjs = [
      for (final e in (s['adjustments'] as List?) ?? const []) Map<String, dynamic>.from(e as Map)
    ];
    final x = adjs[index];
    if (x['reversed'] == true) return;
    if (!await _confirm('ഇത് റദ്ദാക്കണോ? (Cancel this bonus / deduction?)',
        '${rs((x['amount'] as num?) ?? 0)} • ${x['note'] ?? ''}')) {
      return;
    }
    x['reversed'] = true;
    x['reversedAt'] = DateTime.now().toIso8601String();
    adjs[index] = x;
    s['adjustments'] = adjs;
    await _save(s);
    await Db.logAction(
        action: 'Staff Adjustment Reversed',
        entity: 'Staff',
        entityId: '${widget.staffKey}',
        newValue: {'amount': x['amount'], 'month': x['month']});
  }

  // ------------------------------------------------------------------ slip
  Future<void> _shareSlip(Map<String, dynamic> s, PayrollMonth p) async {
    final text = salarySlipText(s, p);
    final digits = '${s['phone'] ?? ''}'.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 10) {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) toast(context, 'ഫോൺ നമ്പർ ഇല്ല. സ്ലിപ്പ് കോപ്പി ചെയ്തു (No phone: slip copied)');
      return;
    }
    final phone = digits.length == 10 ? '91$digits' : digits;
    final uri = Uri.https('wa.me', '/$phone', {'text': text});
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) toast(context, 'WhatsApp തുറക്കാനായില്ല', error: true);
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('വേണ്ട (No)')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ശരി (Yes)')),
          ],
        ),
      ) ==
      true;

  // ------------------------------------------------------------------ build
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: Db.staff.listenable(keys: [widget.staffKey]),
      builder: (context, _, __) {
        final s = _staff;
        if (s == null) {
          return const Scaffold(body: Center(child: Text('Staff not found')));
        }
        final p = payrollFor(s, _month);
        final current = payrollMonthKey(DateTime.now());
        return Scaffold(
          appBar: TekAppBar(
            title: Text('${s['name']}'),
            actions: [
              IconButton(
                key: const ValueKey('staff-slip-share'),
                tooltip: 'Salary slip – WhatsApp',
                icon: const Icon(Icons.share_rounded),
                onPressed: () => _shareSlip(s, p),
              ),
              IconButton(
                tooltip: 'Copy salary slip',
                icon: const Icon(Icons.copy_rounded),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: salarySlipText(s, p)));
                  if (context.mounted) toast(context, 'സ്ലിപ്പ് കോപ്പി ചെയ്തു (Slip copied)');
                },
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    key: const ValueKey('staff-month-prev'),
                    icon: const Icon(Icons.chevron_left_rounded),
                    onPressed: () => setState(() => _month = shiftMonth(_month, -1)),
                  ),
                  Text(DateFormat('MMMM yyyy').format(monthStart(_month)),
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                  IconButton(
                    key: const ValueKey('staff-month-next'),
                    icon: const Icon(Icons.chevron_right_rounded),
                    onPressed: _month.compareTo(current) >= 0
                        ? null
                        : () => setState(() => _month = shiftMonth(_month, 1)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _summary(p),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('staff-pay'),
                    onPressed: () => _pay(s, p),
                    icon: const Icon(Icons.currency_rupee_rounded, size: 18),
                    label: const Text('ശമ്പളം / അഡ്വാൻസ് നൽകുക'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('staff-adjust'),
                    onPressed: () => _adjust(s, _month),
                    icon: const Icon(Icons.exposure_rounded, size: 18),
                    label: const Text('ബോണസ് / കുറവ്'),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              const Text('ഹാജർ കലണ്ടർ (Attendance) – ദിവസത്തിൽ തൊട്ട് മാറ്റാം',
                  style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              _calendar(s),
              const SizedBox(height: 18),
              const Text('പേയ്‌മെന്റുകൾ (Payments)', style: TextStyle(fontWeight: FontWeight.w800)),
              if (p.payments.isEmpty)
                const Padding(
                    padding: EdgeInsets.all(8), child: Text('ഈ മാസം പേയ്‌മെന്റ് ഇല്ല (None this month)')),
              ..._paymentRows(s),
              const SizedBox(height: 18),
              const Text('ബോണസ് / കുറവ് (Adjustments)', style: TextStyle(fontWeight: FontWeight.w800)),
              if (p.adjustmentEntries.isEmpty)
                const Padding(padding: EdgeInsets.all(8), child: Text('ഇല്ല (None)')),
              ..._adjustmentRows(s),
              const SizedBox(height: 18),
              Text(
                'കഴിഞ്ഞ മാസത്തെ ബാക്കി / അഡ്വാൻസ് $kPayrollCarryStartMonth മുതൽ അടുത്ത മാസത്തേക്ക് തനിയെ പോകും. '
                '(Balance and advance carry forward from $kPayrollCarryStartMonth.)',
                style: TextStyle(fontSize: 11.5, color: Theme.of(context).hintColor),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _summary(PayrollMonth p) {
    Widget kv(String k, String v, {Color? c, bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(child: Text(k)),
            Text(v,
                style: TextStyle(
                    color: c, fontWeight: bold ? FontWeight.w900 : FontWeight.w700, fontSize: bold ? 16 : 14)),
          ]),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(children: [
          Row(children: [
            _chip('ഹാജർ ${p.present}', Colors.green),
            const SizedBox(width: 6),
            _chip('Half ${p.halfDays}', Colors.orange),
            const SizedBox(width: 6),
            _chip('ലീവ് ${p.absent}', Colors.red),
          ]),
          const Divider(),
          kv('പ്രതിദിന വേതനം (Daily rate)', '${rs(p.dailyRate)}/day'),
          kv('മാസ ശമ്പളം (${p.daysInMonth} days)', rs(p.monthlySalary)),
          kv('ജോലി ചെയ്ത ദിവസം', '${p.daysWorked} days'),
          kv('നേടിയത് (Earned)', rs(p.earned), c: Colors.teal),
          if (p.adjustments != 0)
            kv(p.adjustments > 0 ? 'ബോണസ് (Bonus)' : 'കുറവ് (Deduction)', rs(p.adjustments),
                c: p.adjustments > 0 ? Colors.green : Colors.red),
          if (p.carriedIn != 0)
            kv(p.carriedIn > 0 ? 'കഴിഞ്ഞ മാസത്തെ ബാക്കി' : 'കഴിഞ്ഞ മാസത്തെ അഡ്വാൻസ്',
                p.carriedIn > 0 ? rs(p.carriedIn) : '-${rs(-p.carriedIn)}',
                c: p.carriedIn > 0 ? Colors.orange : Colors.blue),
          kv('നൽകിയത് – ശമ്പളം', rs(p.paidSalary)),
          if (p.paidAdvance > 0) kv('നൽകിയത് – അഡ്വാൻസ്', rs(p.paidAdvance)),
          const Divider(),
          kv(p.net >= 0 ? 'ഇനി നൽകാനുള്ളത് (To pay)' : 'അഡ്വാൻസ് (അടുത്ത മാസം കുറയും)',
              rs(p.net.abs()),
              c: p.net >= 0 ? Colors.orange : Colors.blue, bold: true),
        ]),
      ),
    );
  }

  Widget _chip(String t, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: c.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: c.withValues(alpha: 0.6))),
        child: Text(t, style: TextStyle(color: c, fontWeight: FontWeight.w800, fontSize: 12)),
      );

  Widget _calendar(Map<String, dynamic> s) {
    final start = monthStart(_month);
    final days = DateTime(start.year, start.month + 1, 0).day;
    final att = Map<String, dynamic>.from((s['attendance'] as Map?) ?? {});
    final today = DateTime.now();
    final lead = start.weekday - 1; // Monday first
    return Column(
      children: [
        Row(children: [
          for (final d in const ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
            Expanded(child: Center(child: Text(d, style: const TextStyle(fontWeight: FontWeight.w700)))),
        ]),
        const SizedBox(height: 4),
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          childAspectRatio: 1.25,
          children: [
            for (var i = 0; i < lead; i++) const SizedBox.shrink(),
            for (var d = 1; d <= days; d++)
              () {
                final day = DateTime(start.year, start.month, d);
                final st = '${att[payrollDayKey(day)] ?? ''}';
                final future = day.isAfter(DateTime(today.year, today.month, today.day));
                final c = st == 'Present'
                    ? Colors.green
                    : st == 'Half Day'
                        ? Colors.orange
                        : st == 'Absent'
                            ? Colors.red
                            : Colors.grey;
                return InkWell(
                  key: ValueKey('staff-day-$d'),
                  onTap: future ? null : () => _setDay(s, day),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    decoration: BoxDecoration(
                      color: c.withValues(alpha: st.isEmpty ? 0.06 : 0.22),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: c.withValues(alpha: st.isEmpty ? 0.2 : 0.7)),
                    ),
                    alignment: Alignment.center,
                    child: Text('$d',
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: future ? Theme.of(context).disabledColor : null)),
                  ),
                );
              }(),
          ],
        ),
      ],
    );
  }

  List<Widget> _paymentRows(Map<String, dynamic> s) {
    final pays = (s['payments'] as List?) ?? const [];
    final out = <Widget>[];
    for (var i = 0; i < pays.length; i++) {
      final x = Map<String, dynamic>.from(pays[i] as Map);
      if ('${x['month']}' != _month) continue;
      final rev = x['reversed'] == true;
      final dt = DateTime.tryParse('${x['date']}');
      out.add(ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(x['type'] == 'advance' ? Icons.fast_forward_rounded : Icons.payments_rounded,
            color: rev ? Colors.grey : null),
        title: Text(
          '${rs((x['amount'] as num?) ?? 0)} • ${x['type'] == 'advance' ? 'അഡ്വാൻസ്' : 'ശമ്പളം'} • ${x['mode'] ?? ''}',
          style: TextStyle(decoration: rev ? TextDecoration.lineThrough : null),
        ),
        subtitle: Text(
            '${dt == null ? '' : DateFormat('dd MMM, hh:mm a').format(dt.toLocal())}'
            '${'${x['note'] ?? ''}'.isEmpty ? '' : ' • ${x['note']}'}${rev ? ' • റദ്ദാക്കി (Reversed)' : ''}'),
        trailing: rev
            ? null
            : IconButton(
                key: ValueKey('staff-pay-reverse-$i'),
                tooltip: 'Wrong payment – reverse',
                icon: const Icon(Icons.undo_rounded, color: Colors.red),
                onPressed: () => _reversePayment(s, i),
              ),
      ));
    }
    return out;
  }

  List<Widget> _adjustmentRows(Map<String, dynamic> s) {
    final adjs = (s['adjustments'] as List?) ?? const [];
    final out = <Widget>[];
    for (var i = 0; i < adjs.length; i++) {
      final x = Map<String, dynamic>.from(adjs[i] as Map);
      if ('${x['month']}' != _month) continue;
      final rev = x['reversed'] == true;
      final a = (x['amount'] as num?)?.toDouble() ?? 0;
      out.add(ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(a >= 0 ? Icons.add_circle_rounded : Icons.remove_circle_rounded,
            color: rev ? Colors.grey : (a >= 0 ? Colors.green : Colors.red)),
        title: Text('${a >= 0 ? 'ബോണസ്' : 'കുറവ്'} ${rs(a.abs())}',
            style: TextStyle(decoration: rev ? TextDecoration.lineThrough : null)),
        subtitle: Text('${x['note'] ?? ''}${rev ? ' • റദ്ദാക്കി' : ''}'),
        trailing: rev
            ? null
            : IconButton(
                tooltip: 'Cancel',
                icon: const Icon(Icons.undo_rounded, color: Colors.red),
                onPressed: () => _reverseAdjustment(s, i),
              ),
      ));
    }
    return out;
  }
}
