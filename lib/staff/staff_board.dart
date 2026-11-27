// ============================================================================
// TEKFIX ERP - STAFF BOARD (modern staff & salary list)
// * Today's attendance in one tap per staff (Present / Half / Leave).
// * "Forgot to mark" list: every past unmarked day, filled from here.
// * Last 7 days strip, this month's earned / paid / to pay or advance.
// * Pay, calendar & details, edit, delete.
// ============================================================================

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';

import '../main.dart' show Db, rs;
import '../theme/tek_tokens.dart';
import 'staff_detail_screen.dart';
import 'staff_payroll.dart';

typedef StaffAction = void Function(dynamic key, Map<String, dynamic> staff);

const _present = 'Present';
const _half = 'Half Day';
const _absent = 'Absent';

Color _statusColor(String? s) => s == _present
    ? TekColors.success
    : s == _half
        ? TekColors.warning
        : s == _absent
            ? TekColors.error
            : TekColors.textMuted;

/// Writes one attendance mark ('' clears it) and logs it.
Future<void> markStaffDay(dynamic key, DateTime day, String status) async {
  final raw = Db.staff.get(key);
  if (raw is! Map) return;
  final s = Map<String, dynamic>.from(raw);
  final att = Map<String, dynamic>.from((s['attendance'] as Map?) ?? {});
  final k = payrollDayKey(day);
  if (status.isEmpty) {
    att.remove(k);
  } else {
    att[k] = status;
  }
  s['attendance'] = att;
  s['lastUpdated'] = DateTime.now().toIso8601String();
  await Db.staff.put(key, s);
  await Db.logAction(
      action: 'Attendance Marked',
      entity: 'Staff',
      entityId: '$key',
      newValue: {'date': k, 'status': status.isEmpty ? 'cleared' : status});
}

class StaffBoard extends StatefulWidget {
  final StaffAction onPay;
  final StaffAction onEdit;
  final StaffAction onDelete;
  const StaffBoard(
      {super.key,
      required this.onPay,
      required this.onEdit,
      required this.onDelete});

  @override
  State<StaffBoard> createState() => _StaffBoardState();
}

class _StaffBoardState extends State<StaffBoard> {
  bool _showAllMissing = false;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: Db.staff.listenable(),
      builder: (context, _, __) {
        final staff = <dynamic, Map<String, dynamic>>{
          for (final k in Db.staff.keys)
            if (Db.staff.get(k) is Map)
              k: Map<String, dynamic>.from(Db.staff.get(k) as Map),
        };
        if (staff.isEmpty) {
          return const Center(
            child: Text(
                'ജീവനക്കാരെ ചേർത്തിട്ടില്ല.\nതാഴെയുള്ള "ജീവനക്കാരൻ" ബട്ടൺ അമർത്തുക.',
                textAlign: TextAlign.center,
                style: TextStyle(color: TekColors.textSecondary)),
          );
        }
        final now = DateTime.now();
        final todayKey = payrollDayKey(now);
        final month = payrollMonthKey(now);
        var presentToday = 0, unmarkedToday = 0;
        for (final s in staff.values) {
          final st = (s['attendance'] as Map?)?[todayKey];
          if (st == null) {
            unmarkedToday++;
          } else if (st != _absent) {
            presentToday++;
          }
        }
        final missing = missingAttendance(staff, now: now);

        return LayoutBuilder(builder: (context, c) {
          final cols = c.maxWidth >= 1300 ? 3 : (c.maxWidth >= 820 ? 2 : 1);
          final cardW = (c.maxWidth - 32 - 14 * (cols - 1)) / cols - 0.5;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 120),
            children: [
              _todayHeader(now, staff.length, presentToday, unmarkedToday),
              if (missing.isNotEmpty) ...[
                const SizedBox(height: 14),
                _missingPanel(missing),
              ],
              const SizedBox(height: 14),
              Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [
                  for (final e in staff.entries)
                    SizedBox(
                        width: cardW,
                        child: _staffCard(e.key, e.value, now, month)),
                ],
              ),
            ],
          );
        });
      },
    );
  }

  // ----------------------------------------------------------------- header
  Widget _todayHeader(DateTime now, int total, int present, int unmarked) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: [Color(0xFF312E81), Color(0xFF1E1B4B)]),
        borderRadius: BorderRadius.circular(18),
        border:
            Border.all(color: TekColors.primaryLight.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.today_rounded,
              color: TekColors.primaryLight, size: 30),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(DateFormat('EEEE, dd MMMM yyyy').format(now),
                    style: const TextStyle(
                        color: TekColors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(
                    'ഇന്ന് ഹാജർ $present / $total  •  രേഖപ്പെടുത്താത്തവർ $unmarked',
                    style: const TextStyle(
                        color: TekColors.textSecondary, fontSize: 12.5)),
              ],
            ),
          ),
          if (unmarked == 0)
            const _Pill('എല്ലാം രേഖപ്പെടുത്തി ✓', TekColors.success)
          else
            _Pill('$unmarked ബാക്കി', TekColors.warning),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- missing
  Widget _missingPanel(List<MissingAttendance> missing) {
    final shown = _showAllMissing ? missing : missing.take(8).toList();
    return Container(
      key: const ValueKey('staff-missing-panel'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: TekColors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: TekColors.warning.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            const Icon(Icons.event_busy_rounded, color: TekColors.warning),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                  'ഹാജർ രേഖപ്പെടുത്താൻ മറന്ന ദിവസങ്ങൾ (${missing.length})',
                  style: const TextStyle(
                      color: TekColors.textPrimary,
                      fontWeight: FontWeight.w800,
                      fontSize: 14.5)),
            ),
          ]),
          const Padding(
            padding: EdgeInsets.only(top: 2, bottom: 8),
            child: Text(
                'ഓരോ വരിയിലും ഒറ്റ ടാപ്പിൽ രേഖപ്പെടുത്താം. (Tap to fill the days you missed.)',
                style:
                    TextStyle(color: TekColors.textSecondary, fontSize: 11.5)),
          ),
          for (final m in shown)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(
                    width: 92,
                    child: Text(DateFormat('dd MMM, EEE').format(m.day),
                        style: const TextStyle(
                            color: TekColors.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 12.5)),
                  ),
                  Expanded(
                    child: Text(m.staffName,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: TekColors.textSecondary, fontSize: 12.5)),
                  ),
                  _MarkButtons(
                    keyPrefix: 'missing-${m.staffKey}-${payrollDayKey(m.day)}',
                    selected: null,
                    compact: true,
                    onMark: (st) => markStaffDay(m.staffKey, m.day, st),
                  ),
                ],
              ),
            ),
          if (missing.length > 8)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () =>
                    setState(() => _showAllMissing = !_showAllMissing),
                child: Text(_showAllMissing
                    ? 'കുറച്ച് കാണിക്കുക'
                    : 'എല്ലാം കാണിക്കുക (${missing.length})'),
              ),
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ card
  Widget _staffCard(
      dynamic key, Map<String, dynamic> s, DateTime now, String month) {
    final p = payrollFor(s, month);
    final att = Map<String, dynamic>.from((s['attendance'] as Map?) ?? {});
    final today = att[payrollDayKey(now)] as String?;
    final name = '${s['name'] ?? ''}';
    final initials = name.trim().isEmpty
        ? '?'
        : name
            .trim()
            .split(RegExp(r'\s+'))
            .take(2)
            .map((w) => w[0].toUpperCase())
            .join();
    final due = p.net;

    return Container(
      key: ValueKey('staff-card-$key'),
      decoration: BoxDecoration(
        color: TekColors.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: TekColors.border),
        boxShadow: TekColors.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top: avatar, name, today status
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                        colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)]),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(initials,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 16)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: TekColors.textPrimary,
                              fontSize: 15.5,
                              fontWeight: FontWeight.w800)),
                      Text(
                          [
                            if ('${s['role'] ?? ''}'.isNotEmpty) '${s['role']}',
                            if ('${s['phone'] ?? ''}'.isNotEmpty)
                              '${s['phone']}',
                          ].join('  •  '),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: TekColors.textMuted, fontSize: 11.5)),
                    ],
                  ),
                ),
                _Pill(
                    today == null ? 'ഇന്ന്: ബാക്കി' : 'ഇന്ന്: ${_label(today)}',
                    _statusColor(today)),
              ],
            ),
          ),
          // Today in one tap
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _MarkButtons(
              keyPrefix: 'today-$key',
              selected: today,
              onMark: (st) => markStaffDay(key, now, st == today ? '' : st),
            ),
          ),
          const SizedBox(height: 12),
          // Last 7 days
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                for (var i = 6; i >= 0; i--)
                  Expanded(
                    child: () {
                      final d = DateTime(now.year, now.month, now.day - i);
                      final st = att[payrollDayKey(d)] as String?;
                      return InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => _pickDayStatus(key, name, d, st),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Column(children: [
                            Text(DateFormat('E').format(d).substring(0, 2),
                                style: TextStyle(
                                    color: i == 0
                                        ? TekColors.textPrimary
                                        : TekColors.textMuted,
                                    fontSize: 10.5,
                                    fontWeight: i == 0
                                        ? FontWeight.w800
                                        : FontWeight.w500)),
                            const SizedBox(height: 4),
                            Container(
                              width: 26,
                              height: 26,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: _statusColor(st).withValues(
                                    alpha: st == null ? 0.08 : 0.25),
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: _statusColor(st).withValues(
                                        alpha: st == null ? 0.3 : 0.9)),
                              ),
                              child: Text('${d.day}',
                                  style: const TextStyle(
                                      color: TekColors.textPrimary,
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700)),
                            ),
                          ]),
                        ),
                      );
                    }(),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Month money
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: TekColors.mainBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: TekColors.borderSubtle),
            ),
            child: Column(
              children: [
                Row(children: [
                  _stat('ഈ മാസം ജോലി', '${p.daysWorked} ദിവസം'),
                  _stat('നേടിയത്', rs(p.earned)),
                  _stat('നൽകിയത്', rs(p.paid)),
                ]),
                const Divider(color: TekColors.borderSubtle, height: 18),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                          due >= 0
                              ? 'ഇനി നൽകാനുള്ളത്'
                              : 'അഡ്വാൻസ് (അടുത്ത മാസം കുറയും)',
                          style: const TextStyle(
                              color: TekColors.textSecondary, fontSize: 12)),
                    ),
                    Text(rs(due.abs()),
                        style: TextStyle(
                            color:
                                due >= 0 ? TekColors.warning : TekColors.info,
                            fontSize: 20,
                            fontWeight: FontWeight.w900)),
                  ],
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                      '${rs(p.dailyRate)}/ദിവസം  •  മാസം ${rs(p.monthlySalary)}',
                      style: const TextStyle(
                          color: TekColors.textMuted, fontSize: 10.5)),
                ),
              ],
            ),
          ),
          // Actions
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 12),
            child: Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      FilledButton.icon(
                        key: ValueKey('staff-pay-$key'),
                        onPressed: () => widget.onPay(key, s),
                        icon:
                            const Icon(Icons.currency_rupee_rounded, size: 16),
                        label: const Text('ശമ്പളം നൽകുക'),
                      ),
                      OutlinedButton.icon(
                        key: ValueKey('staff-details-$key'),
                        onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) =>
                                    StaffDetailScreen(staffKey: key))),
                        icon:
                            const Icon(Icons.calendar_month_rounded, size: 16),
                        label: const Text('കലണ്ടർ'),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit_outlined,
                      color: TekColors.textSecondary, size: 20),
                  onPressed: () => widget.onEdit(key, s),
                ),
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline,
                      color: TekColors.error, size: 20),
                  onPressed: () => widget.onDelete(key, s),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stat(String k, String v) => Expanded(
        child: Column(children: [
          Text(k,
              style:
                  const TextStyle(color: TekColors.textMuted, fontSize: 10.5)),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(v,
                style: const TextStyle(
                    color: TekColors.textPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: 13.5)),
          ),
        ]),
      );

  Future<void> _pickDayStatus(
      dynamic key, String name, DateTime d, String? current) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: TekColors.cardBg,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('$name • ${DateFormat('dd MMM yyyy, EEEE').format(d)}',
                  style: const TextStyle(
                      color: TekColors.textPrimary,
                      fontWeight: FontWeight.w800,
                      fontSize: 15)),
              const SizedBox(height: 14),
              _MarkButtons(
                  keyPrefix: 'sheet',
                  selected: current,
                  onMark: (st) => Navigator.pop(ctx, st)),
              const SizedBox(height: 8),
              if (current != null)
                TextButton(
                    onPressed: () => Navigator.pop(ctx, ''),
                    child: const Text('മായ്ക്കുക (Clear)')),
            ],
          ),
        ),
      ),
    );
    if (choice != null) await markStaffDay(key, d, choice);
  }
}

String _label(String s) =>
    s == _present ? 'ഹാജർ' : (s == _half ? 'പകുതി' : 'ലീവ്');

class _Pill extends StatelessWidget {
  final String text;
  final Color color;
  const _Pill(this.text, this.color);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.6)),
        ),
        child: Text(text,
            style: TextStyle(
                color: color, fontSize: 11.5, fontWeight: FontWeight.w800)),
      );
}

/// Present / Half / Leave in one row. [selected] is highlighted.
class _MarkButtons extends StatelessWidget {
  final String keyPrefix;
  final String? selected;
  final bool compact;
  final ValueChanged<String> onMark;
  const _MarkButtons(
      {required this.keyPrefix,
      required this.selected,
      required this.onMark,
      this.compact = false});

  @override
  Widget build(BuildContext context) {
    Widget b(String status, String label, Color c) {
      final on = selected == status;
      return Padding(
        padding: EdgeInsets.only(left: compact ? 4 : 0, right: compact ? 0 : 6),
        child: Material(
          color: on ? c : c.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            key: ValueKey('$keyPrefix-$status'),
            borderRadius: BorderRadius.circular(10),
            onTap: () => onMark(status),
            child: Container(
              padding: EdgeInsets.symmetric(
                  horizontal: compact ? 10 : 12, vertical: compact ? 6 : 9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: c.withValues(alpha: on ? 1 : 0.5)),
              ),
              alignment: Alignment.center,
              child: Text(label,
                  style: TextStyle(
                      color: on ? Colors.black : c,
                      fontWeight: FontWeight.w800,
                      fontSize: compact ? 11.5 : 12.5)),
            ),
          ),
        ),
      );
    }

    final buttons = [
      b(_present, compact ? 'ഹാജർ' : '✓ ഹാജർ', TekColors.success),
      b(_half, compact ? '½' : '½ പകുതി', TekColors.warning),
      b(_absent, compact ? 'ലീവ്' : '✕ ലീവ്', TekColors.error),
    ];
    return compact
        ? Row(mainAxisSize: MainAxisSize.min, children: buttons)
        : Row(children: [for (final w in buttons) Expanded(child: w)]);
  }
}
