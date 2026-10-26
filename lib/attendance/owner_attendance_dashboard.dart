import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../main.dart' show Db, rs, toast, formDialog, tf, AppCard, kPrimary;
import 'attendance_models.dart';
import 'attendance_service.dart';

class OwnerAttendanceDashboard extends StatefulWidget {
  final String shopId;

  const OwnerAttendanceDashboard({super.key, required this.shopId});

  @override
  State<OwnerAttendanceDashboard> createState() =>
      _OwnerAttendanceDashboardState();
}

class _OwnerAttendanceDashboardState extends State<OwnerAttendanceDashboard>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _timeFormat = DateFormat('hh:mm a');
  final _dateFormat = DateFormat('dd MMM yyyy');
  final _monthFormat = DateFormat('yyyy-MM');
  final _monthDisplayFormat = DateFormat('MMMM yyyy');

  DateTime _selectedMonth = DateTime.now();
  String _selectedStaffFilter = 'All';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _getAllStaff() {
    return Db.staff.values
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList();
  }

  Future<void> _openMap(double? lat, double? lng) async {
    if (lat == null || lng == null) {
      toast(context, 'ലൊക്കേഷൻ വിവരങ്ങൾ ലഭ്യമല്ല (Coordinates missing)');
      return;
    }
    final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) toast(context, 'Maps തുറക്കാൻ സാധിച്ചില്ല');
    }
  }

  void _showManualEntryDialog([AttendanceRecord? existing]) {
    final staffList = _getAllStaff();
    if (staffList.isEmpty) {
      toast(context, 'ജീവനക്കാരെ ചേർത്തിട്ടില്ല (No staff found)');
      return;
    }

    String selectedStaffId = existing?.staffId ?? staffList.first['phone'] ?? '';
    String selectedStaffName = existing?.staffName ?? staffList.first['name'] ?? '';
    DateTime entryDate = existing?.date != null
        ? DateTime.tryParse(existing!.date) ?? DateTime.now()
        : DateTime.now();

    TimeOfDay inTime = existing?.checkIn != null
        ? TimeOfDay.fromDateTime(existing!.checkIn!)
        : const TimeOfDay(hour: 9, minute: 30);
    TimeOfDay? outTime = existing?.checkOut != null
        ? TimeOfDay.fromDateTime(existing!.checkOut!)
        : const TimeOfDay(hour: 18, minute: 30);
    final reasonCtrl = TextEditingController(text: existing?.manualEditNote ?? '');

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) {
          return AlertDialog(
            title: Text(existing == null ? 'ഹാജർ ചേർക്കുക (Add Missing)' : 'വിവരങ്ങൾ മാറ്റുക (Edit)'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: selectedStaffId,
                    decoration: const InputDecoration(labelText: 'ജീവനക്കാരൻ (Staff)'),
                    items: [
                      for (final s in staffList)
                        DropdownMenuItem(
                          value: '${s['phone'] ?? s['name']}',
                          child: Text('${s['name']}'),
                        ),
                    ],
                    onChanged: existing != null
                        ? null
                        : (v) {
                            final match = staffList.firstWhere(
                                (s) => '${s['phone'] ?? s['name']}' == v);
                            set(() {
                              selectedStaffId = v!;
                              selectedStaffName = '${match['name']}';
                            });
                          },
                  ),
                  const SizedBox(height: 12),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('തീയതി (Date)'),
                    subtitle: Text(_dateFormat.format(entryDate)),
                    trailing: const Icon(Icons.calendar_today_rounded),
                    onTap: () async {
                      final d = await showDatePicker(
                        context: ctx,
                        initialDate: entryDate,
                        firstDate: DateTime(2024),
                        lastDate: DateTime.now(),
                      );
                      if (d != null) set(() => entryDate = d);
                    },
                  ),
                  const Divider(),
                  Row(
                    children: [
                      Expanded(
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Check-in'),
                          subtitle: Text(inTime.format(ctx)),
                          onTap: () async {
                            final t = await showTimePicker(
                                context: ctx, initialTime: inTime);
                            if (t != null) set(() => inTime = t);
                          },
                        ),
                      ),
                      Expanded(
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Check-out'),
                          subtitle: Text(outTime != null ? outTime!.format(ctx) : 'None'),
                          onTap: () async {
                            final t = await showTimePicker(
                                context: ctx,
                                initialTime: outTime ?? const TimeOfDay(hour: 18, minute: 0));
                            if (t != null) set(() => outTime = t);
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: reasonCtrl,
                    decoration: const InputDecoration(
                      labelText: 'മാറ്റം വരുത്താനുള്ള കാരണം (Reason) *',
                      hintText: 'ഉദാ: മറന്നുപോയി, ഫീൽഡ് വർക്ക്...',
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('റദ്ദാക്കുക')),
              FilledButton(
                onPressed: () async {
                  if (reasonCtrl.text.trim().isEmpty) {
                    toast(ctx, 'ദയവായി കാരണം വ്യക്തമാക്കുക');
                    return;
                  }
                  final fullIn = DateTime(entryDate.year, entryDate.month,
                      entryDate.day, inTime.hour, inTime.minute);
                  final fullOut = outTime != null
                      ? DateTime(entryDate.year, entryDate.month, entryDate.day,
                          outTime!.hour, outTime!.minute)
                      : null;

                  try {
                    await AttendanceService.instance.ownerManualEntry(
                      shopId: widget.shopId,
                      staffId: selectedStaffId,
                      staffName: selectedStaffName,
                      date: DateFormat('yyyy-MM-dd').format(entryDate),
                      checkIn: fullIn,
                      checkOut: fullOut,
                      reason: reasonCtrl.text.trim(),
                    );
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (mounted) toast(context, 'ഹാജർ വിജയകരമായി രേഖപ്പെടുത്തി');
                  } catch (e) {
                    if (ctx.mounted) toast(ctx, 'പരാജയപ്പെട്ടു: $e', error: true);
                  }
                },
                child: const Text('സേവ് ചെയ്യുക'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _calculateAndPostSalary(
      BuildContext context, Map<String, dynamic> staff, int presentDays) {
    final double monthlySalary = (staff['monthlySalary'] as num?)?.toDouble() ?? 15000.0;
    final totalDaysInMonth =
        DateTime(_selectedMonth.year, _selectedMonth.month + 1, 0).day;
    final calculatedSalary = (monthlySalary / totalDaysInMonth) * presentDays;
    final roundedSalary = (calculatedSalary * 100).round() / 100.0;

    final amtCtrl = TextEditingController(text: roundedSalary.toStringAsFixed(0));
    final noteCtrl = TextEditingController(
        text: 'Salary (${_monthDisplayFormat.format(_selectedMonth)}): ${staff['name']} ($presentDays/$totalDaysInMonth days)');
    String mode = 'Cash';

    formDialog(
      context,
      title: 'ശമ്പളം ചെലവിലേക്ക് ചേർക്കുക',
      body: (set) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('ജീവനക്കാരൻ: ${staff['name']}',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          Text('ഹാജർ: $presentDays/$totalDaysInMonth ദിവസം (കണക്കാക്കിയ തുക: ${rs(roundedSalary)})',
              style: const TextStyle(fontSize: 13, color: Colors.teal)),
          const SizedBox(height: 12),
          tf(amtCtrl, 'നൽകുന്ന തുക ₹', number: true),
          tf(noteCtrl, 'വിവരണം (Description)'),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: mode,
            decoration: const InputDecoration(labelText: 'പേയ്മെന്റ് മോഡ്'),
            items: const [
              DropdownMenuItem(value: 'Cash', child: Text('Cash')),
              DropdownMenuItem(value: 'Bank', child: Text('Bank')),
              DropdownMenuItem(value: 'UPI', child: Text('UPI')),
            ],
            onChanged: (v) => set(() => mode = v!),
          ),
        ],
      ),
      onSave: () async {
        final a = double.tryParse(amtCtrl.text.trim()) ?? 0;
        if (a <= 0) return 'ശരിയായ തുക നൽകുക';
        final nowIso = DateTime.now().toIso8601String();

        await Db.expenses.add({
          'category': 'Staff Salary',
          'title': noteCtrl.text.trim(),
          'amount': a,
          'mode': mode,
          'createdAt': nowIso,
        });

        await Db.moveMoney(mode, -a, 'Expense (Staff Salary): ${noteCtrl.text.trim()}');

        await Db.logAction(
          action: 'Salary Posted From Attendance',
          entity: 'Expense',
          entityId: '${staff['name']}',
          newValue: {'amount': a, 'mode': mode, 'presentDays': presentDays},
        );

        if (context.mounted) {
          toast(context, 'ശമ്പളം ചെലവിലേക്ക് ചേർത്തു (${rs(a)})');
        }
        return null;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Staff Attendance Dashboard'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: "Today's Live Status", icon: Icon(Icons.flash_on_rounded)),
            Tab(text: "Monthly Report", icon: Icon(Icons.bar_chart_rounded)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Add Manual Attendance',
            icon: const Icon(Icons.add_circle_outline_rounded),
            onPressed: () => _showManualEntryDialog(),
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildTodayLiveTab(),
          _buildMonthlyReportTab(),
        ],
      ),
    );
  }

  Widget _buildTodayLiveTab() {
    final staffList = _getAllStaff();
    if (staffList.isEmpty) {
      return const Center(child: Text('ജീവനക്കാരെ ചേർത്തിട്ടില്ല (No staff found)'));
    }

    return StreamBuilder<List<AttendanceRecord>>(
      stream: AttendanceService.instance.streamAllTodayAttendance(widget.shopId),
      builder: (context, snapshot) {
        final records = snapshot.data ?? [];
        final Map<String, AttendanceRecord> recordByStaff = {
          for (final r in records) r.staffId: r
        };

        int presentCount = 0;
        int completedCount = 0;
        int absentCount = 0;

        for (final s in staffList) {
          final id = '${s['phone'] ?? s['name']}';
          final rec = recordByStaff[id];
          if (rec?.checkOut != null) {
            completedCount++;
            presentCount++;
          } else if (rec?.checkIn != null) {
            presentCount++;
          } else {
            absentCount++;
          }
        }

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                Expanded(
                  child: _summaryCard('ഹാജർ (Present)', '$presentCount', Colors.green, Icons.check_circle_outline),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _summaryCard('ഷിഫ്റ്റ് പൂർത്തിയായി', '$completedCount', Colors.indigo, Icons.done_all_rounded),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _summaryCard('വന്നിട്ടില്ല (Pending)', '$absentCount', Colors.orange, Icons.schedule_rounded),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text('ജീവനക്കാരുടെ വിവരങ്ങൾ (Live Status)',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 10),
            for (final s in staffList) ...[
              Builder(builder: (ctx) {
                final id = '${s['phone'] ?? s['name']}';
                final rec = recordByStaff[id];
                final hasIn = rec?.checkIn != null;
                final hasOut = rec?.checkOut != null;

                Color badgeColor = Colors.grey;
                String statusLabel = 'വന്നിട്ടില്ല (Not In)';
                if (hasOut) {
                  badgeColor = Colors.blueGrey;
                  statusLabel = 'Completed';
                } else if (hasIn) {
                  badgeColor = Colors.green;
                  statusLabel = 'Present';
                }

                return AppCard(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: badgeColor.withAlpha(35),
                            child: Icon(
                              hasIn ? Icons.person_rounded : Icons.person_off_rounded,
                              color: badgeColor,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${s['name']}',
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                                Text('${s['role'] ?? 'Staff'} • ${s['phone'] ?? ''}',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
                              ],
                            ),
                          ),
                          Chip(
                            label: Text(statusLabel,
                                style: TextStyle(color: badgeColor, fontWeight: FontWeight.bold, fontSize: 11)),
                            backgroundColor: badgeColor.withAlpha(25),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                      if (rec != null) ...[
                        const Divider(height: 18),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            if (rec.checkIn != null)
                              Text('In: ${_timeFormat.format(rec.checkIn!)}',
                                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                            if (rec.checkOut != null)
                              Text('Out: ${_timeFormat.format(rec.checkOut!)}',
                                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                            if (rec.checkIn != null && rec.checkOut != null)
                              Text('Hours: ${rec.workingHours.toStringAsFixed(1)}h',
                                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Colors.teal)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(Icons.location_on_rounded,
                                size: 16,
                                color: rec.checkInStatus == 'Inside shop' ? Colors.green : Colors.orange),
                            const SizedBox(width: 4),
                            Text(rec.checkInStatus,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: rec.checkInStatus == 'Inside shop' ? Colors.green : Colors.orange,
                                    fontWeight: FontWeight.w600)),
                            const Spacer(),
                            if (rec.checkInLat != null)
                              OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(horizontal: 8),
                                ),
                                icon: const Icon(Icons.map_rounded, size: 16),
                                label: const Text('Open in Maps', style: TextStyle(fontSize: 11)),
                                onPressed: () => _openMap(rec.checkInLat, rec.checkInLng),
                              ),
                            const SizedBox(width: 6),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.edit_outlined, size: 18),
                              onPressed: () => _showManualEntryDialog(rec),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                );
              }),
            ],
          ],
        );
      },
    );
  }

  Widget _buildMonthlyReportTab() {
    final staffList = _getAllStaff();
    final yearMonth = _monthFormat.format(_selectedMonth);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left_rounded),
                onPressed: () {
                  setState(() {
                    _selectedMonth = DateTime(
                        _selectedMonth.year, _selectedMonth.month - 1);
                  });
                },
              ),
              Expanded(
                child: Text(
                  _monthDisplayFormat.format(_selectedMonth),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right_rounded),
                onPressed: () {
                  setState(() {
                    _selectedMonth = DateTime(
                        _selectedMonth.year, _selectedMonth.month + 1);
                  });
                },
              ),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              ChoiceChip(
                label: const Text('All Staff'),
                selected: _selectedStaffFilter == 'All',
                onSelected: (_) => setState(() => _selectedStaffFilter = 'All'),
              ),
              for (final s in staffList) ...[
                const SizedBox(width: 8),
                ChoiceChip(
                  label: Text('${s['name']}'),
                  selected: _selectedStaffFilter == '${s['phone'] ?? s['name']}',
                  onSelected: (_) => setState(() =>
                      _selectedStaffFilter = '${s['phone'] ?? s['name']}'),
                ),
              ],
            ],
          ),
        ),
        const Divider(),
        Expanded(
          child: StreamBuilder<List<AttendanceRecord>>(
            stream: AttendanceService.instance
                .streamMonthAttendance(widget.shopId, yearMonth),
            builder: (context, snapshot) {
              final records = snapshot.data ?? [];

              final filteredStaff = _selectedStaffFilter == 'All'
                  ? staffList
                  : staffList.where((s) =>
                      '${s['phone'] ?? s['name']}' == _selectedStaffFilter).toList();

              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: filteredStaff.length,
                itemBuilder: (ctx, i) {
                  final s = filteredStaff[i];
                  final id = '${s['phone'] ?? s['name']}';
                  final staffRecs = records.where((r) => r.staffId == id).toList();

                  // Requirement 4: Payroll must count ONLY approved attendance records
                  final approvedRecs = staffRecs.where((r) => r.isApproved).toList();
                  final pendingRecs = staffRecs.where((r) => r.isPending).toList();

                  final presentDays = approvedRecs.where((r) => r.checkIn != null).length;
                  double totalHours = 0.0;
                  int lateDays = 0;
                  int fullDays = 0;
                  int halfDays = 0;

                  for (final r in approvedRecs) {
                    totalHours += r.workingHours;
                    if (r.isLate) lateDays++;
                    if (r.dutyStage.contains('Full')) {
                      fullDays++;
                    } else if (r.dutyStage.contains('Half')) {
                      halfDays++;
                    }
                  }

                  return Card(
                    margin: const EdgeInsets.only(bottom: 14),
                    child: ExpansionTile(
                      leading: CircleAvatar(
                        backgroundColor: kPrimary.withAlpha(25),
                        child: Text(
                          '${s['name']}'.substring(0, 1).toUpperCase(),
                          style: const TextStyle(fontWeight: FontWeight.bold, color: kPrimary),
                        ),
                      ),
                      title: Text('${s['name']}',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text(
                          'അംഗീകരിച്ച ഹാജർ: $presentDays ദിവസം ($fullDays Full, $halfDays Half) • $lateDays Late • ${totalHours.toStringAsFixed(1)}h'),
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (pendingRecs.isNotEmpty) ...[
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  margin: const EdgeInsets.only(bottom: 10),
                                  decoration: BoxDecoration(
                                    color: Colors.amber.shade50,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: Colors.amber.shade300),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(Icons.info_outline, size: 18, color: Colors.amber.shade900),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          'ശ്രദ്ധിക്കുക: ${pendingRecs.length} ദിവസത്തെ ഹാജർ അപ്രൂവ് ചെയ്യാൻ ബാക്കിയുണ്ട്. ഇത് ശമ്പളത്തിൽ ഉൾപ്പെടുത്തിയിട്ടില്ല.\n(Pending: ${pendingRecs.length} days, not counted in payroll yet).',
                                          style: TextStyle(fontSize: 11.5, color: Colors.amber.shade900, fontWeight: FontWeight.w600),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text('മാസ ശമ്പളം (Monthly Salary):'),
                                  Text(rs((s['monthlySalary'] as num?)?.toDouble() ?? 15000),
                                      style: const TextStyle(fontWeight: FontWeight.bold)),
                                ],
                              ),
                              const SizedBox(height: 10),
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.tonalIcon(
                                  icon: const Icon(Icons.payments_rounded),
                                  label: const Text('ശമ്പളം ചെലവിലേക്ക് ചേർക്കുക (Post Salary)'),
                                  onPressed: () => _calculateAndPostSalary(context, s, presentDays),
                                ),
                              ),
                              const SizedBox(height: 12),
                              const Text('ദിവസേനയുള്ള വിവരങ്ങൾ (Daily Logs):',
                                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                              const SizedBox(height: 6),
                              for (final r in staffRecs)
                                Container(
                                  margin: const EdgeInsets.symmetric(vertical: 4),
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.surfaceContainerHighest.withAlpha(60),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Row(
                                    children: [
                                      Text(r.date, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                      const SizedBox(width: 8),
                                      if (r.checkIn != null)
                                        Text('In: ${_timeFormat.format(r.checkIn!)}',
                                            style: const TextStyle(fontSize: 11.5)),
                                      const SizedBox(width: 6),
                                      if (r.checkOut != null)
                                        Text('Out: ${_timeFormat.format(r.checkOut!)}',
                                            style: const TextStyle(fontSize: 11.5)),
                                      const Spacer(),
                                      Text('${r.workingHours.toStringAsFixed(1)}h',
                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.teal)),
                                      if (r.checkInLat != null)
                                        IconButton(
                                          visualDensity: VisualDensity.compact,
                                          icon: const Icon(Icons.map_rounded, size: 16),
                                          onPressed: () => _openMap(r.checkInLat, r.checkInLng),
                                        ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _summaryCard(String title, String val, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const Spacer(),
              Text(val, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
            ],
          ),
          const SizedBox(height: 4),
          Text(title, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }
}
