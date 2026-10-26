import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import '../auth/auth_controller.dart';
import '../main.dart' show Db, rs, dtFormat;
import '../ui/sync_status_icon.dart';
import 'activity_log.dart';

Map<String, dynamic> _row(dynamic v) => v is Map
    ? {for (final e in v.entries) '${e.key}': e.value}
    : <String, dynamic>{};
double _n(dynamic v) =>
    v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);
bool _today(dynamic iso) {
  final d = DateTime.tryParse('${iso ?? ''}');
  final n = DateTime.now();
  return d != null && d.year == n.year && d.month == n.month && d.day == n.day;
}

class _StaffAgg {
  int bills = 0;
  double sales = 0, cash = 0, upi = 0;
  DateTime? last;
  final counters = <String>{};
}

/// Owner-only live board. Reads the local Hive boxes, which the SyncEngine
/// keeps up to date from the cloud, so it refreshes in real time, uses no
/// extra Firestore reads and still opens when the phone is offline.
class StaffTrackingView extends StatefulWidget {
  const StaffTrackingView({super.key});
  @override
  State<StaffTrackingView> createState() => _StaffTrackingViewState();
}

class _StaffTrackingViewState extends State<StaffTrackingView> {
  String _staff = 'All';

  @override
  Widget build(BuildContext context) {
    if (!context.watch<AuthController>().isOwner) {
      return const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_rounded, size: 48),
                SizedBox(height: 12),
                Text(
                  'Owner only',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: const TekAppBar(
          title: Text(
              'Staff Tracking & Live Activity (ലൈവ് സ്റ്റാഫ് ട്രാക്കിംഗ്)')),
      body: ListenableBuilder(
        listenable:
            Listenable.merge([Db.sales.listenable(), Db.audit.listenable()]),
        builder: (context, _) {
          final agg = <String, _StaffAgg>{};
          final counters = <String, double>{};
          double total = 0, cash = 0, upi = 0;
          var bills = 0;
          for (final v in Db.sales.values) {
            final s = _row(v);
            if (!_today(s['createdAt'])) continue;
            if (s['returned'] == true ||
                '${s['status']}'.toUpperCase() == 'RETURNED') {
              continue;
            }
            final who = '${s['staffName'] ?? 'Unknown'}';
            final a = agg.putIfAbsent(who, _StaffAgg.new);
            final c = s.containsKey('cash') ? _n(s['cash']) : _n(s['total']);
            final u = _n(s['upi']);
            a.bills++;
            a.sales += _n(s['total']);
            a.cash += c;
            a.upi += u;
            final t = DateTime.tryParse('${s['createdAt']}');
            if (t != null && (a.last == null || t.isAfter(a.last!))) {
              a.last = t;
            }
            final ctr = '${s['counter'] ?? 'Counter'}';
            a.counters.add(ctr);
            counters[ctr] = (counters[ctr] ?? 0) + c;
            bills++;
            total += _n(s['total']);
            cash += c;
            upi += u;
          }

          final feed = <Map<String, dynamic>>[];
          final warns = <Map<String, dynamic>>[];
          for (var i = Db.audit.length - 1; i >= 0; i--) {
            final r = _row(Db.audit.getAt(i));
            if (!_today(r['date'])) {
              continue;
            }
            if (r['warn'] == true) {
              warns.add(r);
            }
            if (_staff == 'All' || r['staffName'] == _staff) {
              if ('${r['actionType'] ?? ActivityLog.typeOf('${r['action']}')}' !=
                      ActivityType.other ||
                  feed.length < 15) {
                feed.add(r);
              }
            }
            if (feed.length >= 60 && warns.length >= 20) {
              break;
            }
          }
          final names = ['All', ...agg.keys];

          return LayoutBuilder(builder: (context, box) {
            final wide = box.maxWidth >= 900;
            final summary =
                _Summary(total: total, bills: bills, cash: cash, upi: upi);
            final perStaff = _PerStaff(
                agg: agg,
                selected: _staff,
                onPick: (s) =>
                    setState(() => _staff = _staff == s ? 'All' : s));
            final cnt = _Counters(counters);
            final warnCard = _Warnings(warns);
            final live =
                _Feed(feed, names, _staff, (s) => setState(() => _staff = s));
            final left = [
              summary,
              const SizedBox(height: 12),
              const _Online(),
              const SizedBox(height: 12),
              perStaff,
              const SizedBox(height: 12),
              cnt,
              const SizedBox(height: 12),
              warnCard
            ];
            if (wide) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: ListView(children: left)),
                      const SizedBox(width: 16),
                      Expanded(child: live),
                    ]),
              );
            }
            return ListView(
                padding: const EdgeInsets.all(14),
                children: [...left, const SizedBox(height: 12), live]);
          });
        },
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;
  const _Panel(this.title, this.child, {this.trailing});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: cs.surfaceContainerLow,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cs.outlineVariant)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 15))),
            if (trailing != null) trailing!
          ]),
          const SizedBox(height: 10),
          child,
        ]),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  final double total, cash, upi;
  final int bills;
  const _Summary(
      {required this.total,
      required this.bills,
      required this.cash,
      required this.upi});

  Widget _tile(String label, double v, Color c, {bool money = true}) =>
      Expanded(
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: v),
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOutCubic,
          builder: (_, x, __) => Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
                color: c, borderRadius: BorderRadius.circular(14)),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(money ? rs(x) : x.round().toString(),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w800))),
              const SizedBox(height: 2),
              Text(label,
                  style: const TextStyle(color: Colors.white, fontSize: 11.5)),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => _Panel(
        "ഇന്നത്തെ വിൽപന (Today)",
        Row(children: [
          _tile('Sales', total, const Color(0xFF1E3A8A)),
          _tile('Cash', cash, const Color(0xFF166534)),
          _tile('UPI', upi, const Color(0xFF6D28D9)),
          _tile('Bills', bills.toDouble(), const Color(0xFF374151),
              money: false),
        ]),
        trailing: const _LiveDot(),
      );
}

class _LiveDot extends StatefulWidget {
  const _LiveDot();
  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1200))
    ..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: Tween(begin: .35, end: 1.0).animate(_c),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: 9,
              height: 9,
              decoration: const BoxDecoration(
                  color: Colors.red, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          const Text('LIVE',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
        ]),
      );
}

class _PerStaff extends StatelessWidget {
  final Map<String, _StaffAgg> agg;
  final String selected;
  final ValueChanged<String> onPick;
  const _PerStaff(
      {required this.agg, required this.selected, required this.onPick});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final list = agg.entries.toList()
      ..sort((a, b) => b.value.sales.compareTo(a.value.sales));
    return _Panel(
      'Sales by staff (സ്റ്റാഫ് തിരിച്ച്)',
      list.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(8),
              child: Text('ഇന്ന് ഇതുവരെ ബില്ലുകൾ ഇല്ല (No bills yet today)'))
          : Column(children: [
              for (final e in list)
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => onPick(e.key),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: selected == e.key
                          ? cs.primaryContainer
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: cs.outlineVariant),
                    ),
                    child: Row(children: [
                      CircleAvatar(
                          radius: 18,
                          backgroundColor: cs.primary,
                          child: Text(
                              e.key.isEmpty ? '?' : e.key[0].toUpperCase(),
                              style: TextStyle(
                                  color: cs.onPrimary,
                                  fontWeight: FontWeight.w800))),
                      const SizedBox(width: 10),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(e.key,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                            Text(
                                '${e.value.bills} bills • Cash ${rs(e.value.cash)} • UPI ${rs(e.value.upi)}${e.value.last == null ? '' : ' • ${dtFormat.format(e.value.last!).split(', ').last}'}',
                                style: const TextStyle(fontSize: 12)),
                          ])),
                      Text(rs(e.value.sales),
                          style: const TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 15)),
                    ]),
                  ),
                ),
            ]),
    );
  }
}

class _Counters extends StatelessWidget {
  final Map<String, double> m;
  const _Counters(this.m);
  @override
  Widget build(BuildContext context) => _Panel(
        'Cash collected per counter (കൗണ്ടർ ക്യാഷ്)',
        m.isEmpty
            ? const Text('—')
            : Column(children: [
                for (final e
                    in (m.entries.toList()
                      ..sort((a, b) => b.value.compareTo(a.value))))
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(e.key.contains('Windows')
                        ? Icons.desktop_windows_rounded
                        : Icons.smartphone_rounded),
                    title: Text(e.key),
                    trailing: Text(rs(e.value),
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                  ),
              ]),
      );
}

class _Warnings extends StatelessWidget {
  final List<Map<String, dynamic>> w;
  const _Warnings(this.w);
  @override
  Widget build(BuildContext context) => _Panel(
        'Audit warnings (voided / deleted)',
        w.isEmpty
            ? const Row(children: [
                Icon(Icons.verified_rounded, color: Colors.green),
                SizedBox(width: 8),
                Text('ഇന്ന് മുന്നറിയിപ്പുകൾ ഇല്ല (No warnings today)')
              ])
            : Column(children: [
                for (final r in w.take(20))
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                        color: const Color(0xFFFEE2E2),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFB91C1C))),
                    child: Row(children: [
                      const Icon(Icons.warning_amber_rounded,
                          color: Color(0xFFB91C1C)),
                      const SizedBox(width: 10),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text('${r['action']} • ${r['entityId']}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF7F1D1D))),
                            Text(
                                '${r['staffName']} (${r['device'] ?? '-'}) • ${dtFormat.format(DateTime.parse('${r['date']}')).split(', ').last}${r['amount'] == null ? '' : ' • ${rs(_n(r['amount']))}'}',
                                style: const TextStyle(
                                    fontSize: 12, color: Color(0xFF7F1D1D))),
                          ])),
                    ]),
                  ),
              ]),
      );
}

class _Feed extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  final List<String> names;
  final String selected;
  final ValueChanged<String> onPick;
  const _Feed(this.rows, this.names, this.selected, this.onPick);
  @override
  Widget build(BuildContext context) => _Panel(
        'Live activity feed (ലൈവ് ഫീഡ്)',
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            height: 38,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              for (final n in names)
                Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                        label: Text(n),
                        selected: selected == n,
                        onSelected: (_) => onPick(n))),
            ]),
          ),
          const SizedBox(height: 8),
          if (rows.isEmpty)
            const Padding(
                padding: EdgeInsets.all(12),
                child: Text('No activity yet today')),
          for (final r in rows.take(60))
            _FeedTile(r, key: ValueKey('${r['_id'] ?? r['date']}')),
        ]),
      );
}

class _FeedTile extends StatelessWidget {
  final Map<String, dynamic> r;
  const _FeedTile(this.r, {super.key});
  @override
  Widget build(BuildContext context) {
    final type = '${r['actionType'] ?? ActivityLog.typeOf('${r['action']}')}';
    final color = ActivityType.color(type);
    final t = DateTime.tryParse('${r['date']}');
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 350),
      builder: (_, v, child) => Opacity(
          opacity: v,
          child: Transform.translate(
              offset: Offset(0, 8 * (1 - v)), child: child)),
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: CircleAvatar(
            radius: 17,
            backgroundColor: color,
            child:
                Icon(ActivityType.icon(type), size: 17, color: Colors.white)),
        title: Text('${r['details'] ?? r['action']}',
            maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Row(children: [
          _Badge(type, color),
          const SizedBox(width: 6),
          Flexible(
              child: Text(
                  '${r['staffName'] ?? r['user']} • ${r['device'] ?? ''}${t == null ? '' : ' • ${dtFormat.format(t).split(', ').last}'}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5))),
        ]),
        trailing: r['amount'] == null
            ? null
            : Text(rs(_n(r['amount'])),
                style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  const _Badge(this.text, this.color);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
            color: color, borderRadius: BorderRadius.circular(20)),
        child: Text(text,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 10.5,
                fontWeight: FontWeight.w700)),
      );
}

/// Small role pill for headers / drawers (high contrast in both themes).
class RoleBadge extends StatelessWidget {
  final bool owner;
  const RoleBadge({super.key, required this.owner});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
            color: owner ? const Color(0xFF5B21B6) : const Color(0xFF0F766E),
            borderRadius: BorderRadius.circular(20)),
        child: Text(owner ? 'OWNER' : 'STAFF',
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 11)),
      );
}

class _Online extends StatelessWidget {
  const _Online();
  @override
  Widget build(BuildContext context) {
    final shop = context.read<AuthController>().shopId;
    return _Panel(
      'Online staff (ഓൺലൈൻ)',
      StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('shops/$shop/presence')
            .snapshots(),
        builder: (context, snap) {
          final docs = snap.data?.docs ?? [];
          if (docs.isEmpty) {
            return const Text('ഡാറ്റ ഇല്ല (No data yet)');
          }
          return Column(children: [
            for (final d in docs)
              Builder(builder: (_) {
                final m = d.data();
                final ts = (m['lastSeen'] as Timestamp?)?.toDate();
                final fresh =
                    ts != null && DateTime.now().difference(ts).inMinutes < 5;
                final on = m['online'] == true && fresh;
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.circle,
                      size: 12, color: on ? Colors.green : Colors.grey),
                  title: Text('${m['name'] ?? d.id} (${m['role'] ?? ''})'),
                  subtitle: Text(
                      ts == null ? '-' : 'Last seen ${dtFormat.format(ts)}'),
                  trailing: Text(on ? 'ONLINE' : 'OFFLINE',
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: on ? Colors.green : Colors.grey)),
                );
              }),
          ]);
        },
      ),
    );
  }
}
