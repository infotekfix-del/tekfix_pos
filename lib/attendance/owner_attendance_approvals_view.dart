import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../auth/auth_controller.dart';
import '../main.dart' show kPrimary, toast;
import '../shared/tek_pos_strings.dart';
import 'attendance_models.dart';
import 'attendance_service.dart';

class OwnerAttendanceApprovalsView extends StatefulWidget {
  final String shopId;

  const OwnerAttendanceApprovalsView({
    super.key,
    required this.shopId,
  });

  @override
  State<OwnerAttendanceApprovalsView> createState() =>
      _OwnerAttendanceApprovalsViewState();
}

class _OwnerAttendanceApprovalsViewState
    extends State<OwnerAttendanceApprovalsView> {
  final _timeFormat = DateFormat('hh:mm a');
  final _dateFormat = DateFormat('dd MMM yyyy, EEEE');

  String _filterStaff = 'All';
  DateTime? _filterDate;

  Future<void> _approveRecord(AttendanceRecord r, String ownerUid) async {
    try {
      await AttendanceService.instance.approveAttendance(
        shopId: widget.shopId,
        docId: r.id,
        ownerUid: ownerUid,
      );
      if (mounted) {
        toast(context, '${r.staffName} - അറ്റൻഡൻസ് അംഗീകരിച്ചു');
      }
    } catch (e) {
      if (mounted) toast(context, 'അംഗീകരിക്കാൻ സാധിച്ചില്ല: $e', error: true);
    }
  }

  Future<void> _bulkApprove(List<AttendanceRecord> records, String ownerUid) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(TekStrings.btnApproveAll),
        content: Text('${records.length} ജീവനക്കാരുടെ അറ്റൻഡൻസ് ഒന്നിച്ച് അംഗീകരിക്കണോ?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('വേണ്ട')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('അംഗീകരിക്കുക')),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await AttendanceService.instance.bulkApprovePending(
        shopId: widget.shopId,
        ownerUid: ownerUid,
        docIds: records.map((e) => e.id).toList(),
      );
      if (mounted) toast(context, '${records.length} അറ്റൻഡൻസുകൾ അംഗീകരിച്ചു');
    } catch (e) {
      if (mounted) toast(context, 'ബൾക്ക് അപ്രൂവൽ പരാജയപ്പെട്ടു: $e', error: true);
    }
  }

  Future<void> _showAdjustOrRejectDialog(AttendanceRecord r, String ownerUid) async {
    int activeTab = 0; // 0 = Adjust, 1 = Reject
    DateTime inTime = r.checkIn ?? DateTime.now();
    DateTime? outTime = r.checkOut;
    final reasonCtrl = TextEditingController();
    bool revokeAccess = false;
    String? err;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('${r.staffName} - ${TekStrings.btnAdjustOrReject}'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, label: Text('സമയം തിരുത്തുക (Adjust)')),
                      ButtonSegment(value: 1, label: Text('നിരസിക്കുക (Reject)')),
                    ],
                    selected: {activeTab},
                    onSelectionChanged: (val) => setD(() => activeTab = val.first),
                  ),
                  const SizedBox(height: 16),

                  if (activeTab == 0) ...[
                    // Adjust Tab
                    const Text('ചെക്ക്-ഇൻ സമയം (Check-In Time):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 6),
                    ListTile(
                      tileColor: Colors.grey.withAlpha(20),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      title: Text(_timeFormat.format(inTime)),
                      trailing: const Icon(Icons.access_time_rounded),
                      onTap: () async {
                        final picked = await showTimePicker(
                          context: ctx,
                          initialTime: TimeOfDay.fromDateTime(inTime),
                        );
                        if (picked != null) {
                          setD(() {
                            inTime = DateTime(
                              inTime.year,
                              inTime.month,
                              inTime.day,
                              picked.hour,
                              picked.minute,
                            );
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 12),

                    const Text('ചെക്ക്-ഔട്ട് സമയം (Check-Out Time):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 6),
                    ListTile(
                      tileColor: Colors.grey.withAlpha(20),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      title: Text(outTime != null ? _timeFormat.format(outTime!) : 'ഡ്യൂട്ടിയിലാണ് (Currently Active)'),
                      trailing: const Icon(Icons.access_time_filled_rounded),
                      onTap: () async {
                        final picked = await showTimePicker(
                          context: ctx,
                          initialTime: TimeOfDay.fromDateTime(outTime ?? DateTime.now()),
                        );
                        if (picked != null) {
                          setD(() {
                            final base = outTime ?? inTime;
                            outTime = DateTime(
                              base.year,
                              base.month,
                              base.day,
                              picked.hour,
                              picked.minute,
                            );
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 12),

                    TextField(
                      controller: reasonCtrl,
                      decoration: const InputDecoration(
                        labelText: TekStrings.labelAdjustReason,
                        hintText: 'ഉദാ: ട്രാഫിക് ബ്ലോക്ക്, വൈകി ഇറങ്ങി...',
                      ),
                    ),
                  ] else ...[
                    // Reject Tab
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.shade200),
                      ),
                      child: Text(
                        'അറ്റൻഡൻസ് നിരസിച്ചാൽ ഈ ദിവസത്തെ ഹാജർ പെറോൾ ശമ്പളത്തിൽ കണക്കാക്കില്ല.',
                        style: TextStyle(color: Colors.red.shade900, fontSize: 12),
                      ),
                    ),
                    const SizedBox(height: 12),

                    TextField(
                      controller: reasonCtrl,
                      decoration: const InputDecoration(
                        labelText: TekStrings.labelRejectReason,
                        hintText: 'നിരസിക്കാനുള്ള കാരണം നൽകുക...',
                      ),
                    ),
                    const SizedBox(height: 10),

                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: revokeAccess,
                      onChanged: (v) => setD(() => revokeAccess = v ?? false),
                      title: const Text(
                        TekStrings.revokeAccessPrompt,
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  ],

                  if (err != null) ...[
                    const SizedBox(height: 8),
                    Text(err!, style: const TextStyle(color: Colors.red, fontSize: 12)),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('റദ്ദാക്കുക (Cancel)')),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: activeTab == 0 ? kPrimary : Colors.red,
              ),
              onPressed: () async {
                if (reasonCtrl.text.trim().isEmpty) {
                  setD(() => err = 'കാരണം നൽകേണ്ടത് നിർബന്ധമാണ് (Reason is required)');
                  return;
                }

                try {
                  if (activeTab == 0) {
                    await AttendanceService.instance.adjustAttendance(
                      shopId: widget.shopId,
                      docId: r.id,
                      ownerUid: ownerUid,
                      adjustedCheckIn: inTime,
                      adjustedCheckOut: outTime,
                      reason: reasonCtrl.text.trim(),
                    );
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (mounted) toast(context, 'അറ്റൻഡൻസ് സമയം തിരുത്തി അപ്രൂവ് ചെയ്തു');
                  } else {
                    await AttendanceService.instance.rejectAttendance(
                      shopId: widget.shopId,
                      docId: r.id,
                      ownerUid: ownerUid,
                      reason: reasonCtrl.text.trim(),
                      revokeAccess: revokeAccess,
                    );
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (mounted) toast(context, 'അറ്റൻഡൻസ് നിരസിച്ചു');
                  }
                } catch (e) {
                  setD(() => err = '$e');
                }
              },
              child: Text(activeTab == 0 ? 'തിരുത്തുക & അപ്രൂവ് ചെയ്യുക' : 'നിരസിക്കുക (Reject)'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ownerUid = context.watch<AuthController>().uid;

    return Scaffold(
      appBar: AppBar(
        title: const Text(TekStrings.approvalsTitle),
      ),
      body: StreamBuilder<List<AttendanceRecord>>(
        stream: AttendanceService.instance.streamPendingApprovals(widget.shopId),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final allPending = snapshot.data ?? [];

          // Unique staff list for filter
          final staffNames = {'All', ...allPending.map((e) => e.staffName)};

          final filtered = allPending.where((r) {
            final matchesStaff = _filterStaff == 'All' || r.staffName == _filterStaff;
            bool matchesDate = true;
            if (_filterDate != null && r.checkIn != null) {
              matchesDate = r.checkIn!.year == _filterDate!.year &&
                  r.checkIn!.month == _filterDate!.month &&
                  r.checkIn!.day == _filterDate!.day;
            }
            return matchesStaff && matchesDate;
          }).toList();

          return Column(
            children: [
              // Header Summary & Bulk Action
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  border: Border(bottom: BorderSide(color: Colors.amber.shade200)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade100,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.pending_actions_rounded, color: Colors.amber.shade900, size: 28),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${allPending.length} അംഗീകാരം കാത്തിരിക്കുന്നു',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.amber.shade900,
                            ),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'സ്റ്റാഫിന്റെ കൃത്യമായ ജോലി സമയവും രജിസ്റ്റർ ക്യാഷും പരിശോധിച്ച് അപ്രൂവ് ചെയ്യുക.',
                            style: TextStyle(fontSize: 12, color: Colors.black54),
                          ),
                        ],
                      ),
                    ),
                    if (allPending.isNotEmpty)
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.green.shade700,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        ),
                        onPressed: () => _bulkApprove(allPending, ownerUid),
                        icon: const Icon(Icons.done_all_rounded, size: 18),
                        label: const Text('Approve All'),
                      ),
                  ],
                ),
              ),

              // Filter Bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    // Staff Dropdown
                    DropdownButton<String>(
                      value: _filterStaff,
                      underline: const SizedBox(),
                      items: staffNames
                          .map((name) => DropdownMenuItem(value: name, child: Text(name)))
                          .toList(),
                      onChanged: (val) => setState(() => _filterStaff = val ?? 'All'),
                    ),
                    const Spacer(),
                    // Date Filter
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _filterDate ?? DateTime.now(),
                          firstDate: DateTime(2025),
                          lastDate: DateTime.now().add(const Duration(days: 1)),
                        );
                        setState(() => _filterDate = picked);
                      },
                      icon: const Icon(Icons.calendar_today_rounded, size: 14),
                      label: Text(_filterDate != null ? DateFormat('dd MMM').format(_filterDate!) : 'All Dates'),
                    ),
                    if (_filterDate != null)
                      IconButton(
                        icon: const Icon(Icons.clear, size: 16),
                        onPressed: () => setState(() => _filterDate = null),
                      ),
                  ],
                ),
              ),

              const Divider(height: 1),

              // List of Pending Approvals
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.task_alt_rounded, size: 56, color: Colors.green.shade400),
                            const SizedBox(height: 12),
                            const Text(
                              'അപ്രൂവ് ചെയ്യാൻ ബാക്കിയില്ല!\n(No pending attendance approvals)',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey, fontSize: 15),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: filtered.length,
                        itemBuilder: (context, idx) {
                          final r = filtered[idx];
                          return _buildApprovalCard(r, ownerUid);
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildApprovalCard(AttendanceRecord r, String ownerUid) {
    final now = DateTime.now();
    final inTime = r.checkIn;
    final outTime = r.checkOut;
    final isPendingMoreThan24h = inTime != null && now.difference(inTime).inHours >= 24;

    final cashReg = r.cashRegister;
    final hasMismatch = cashReg != null && cashReg['mismatch'] == true;
    final diff = (cashReg?['difference'] as num?)?.toDouble() ?? 0.0;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: hasMismatch ? Colors.red.shade300 : Colors.grey.shade300,
          width: hasMismatch ? 1.5 : 1.0,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top Row: Staff Name, Date, 24h Warning
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: kPrimary.withAlpha(30),
                  child: Text(
                    r.staffName.isNotEmpty ? r.staffName[0].toUpperCase() : 'S',
                    style: const TextStyle(fontWeight: FontWeight.bold, color: kPrimary),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        r.staffName,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      Text(
                        inTime != null ? _dateFormat.format(inTime) : r.date,
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                if (isPendingMoreThan24h)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.red.shade100,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      TekStrings.pendingMoreThan24h,
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.red),
                    ),
                  ),
              ],
            ),

            const SizedBox(height: 14),

            // Time & Duty Details
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.withAlpha(20),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('ചെക്ക്-ഇൻ (Check-In)', style: TextStyle(fontSize: 11, color: Colors.grey)),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Text(
                              inTime != null ? _timeFormat.format(inTime) : '--',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                            ),
                            if (r.isLate) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                decoration: BoxDecoration(
                                  color: Colors.orange.shade100,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  TekStrings.lateArrival,
                                  style: TextStyle(fontSize: 9, color: Colors.orange.shade900, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('ചെക്ക്-ഔട്ട് (Check-Out)', style: TextStyle(fontSize: 11, color: Colors.grey)),
                        const SizedBox(height: 2),
                        Text(
                          outTime != null ? _timeFormat.format(outTime) : 'ഡ്യൂട്ടിയിലാണ് (Active)',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: outTime != null ? null : Colors.green,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('ജോലി സമയം', style: TextStyle(fontSize: 11, color: Colors.grey)),
                        const SizedBox(height: 2),
                        Text(
                          '${r.workingHours.toStringAsFixed(1)} hrs',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                        Text(
                          r.dutyStage,
                          style: const TextStyle(fontSize: 10, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Cash Register Mismatch alert (if checkout submitted register)
            if (cashReg != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: hasMismatch ? Colors.red.shade50 : Colors.green.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: hasMismatch ? Colors.red.shade200 : Colors.green.shade200,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      hasMismatch ? Icons.warning_amber_rounded : Icons.check_circle_outline,
                      size: 20,
                      color: hasMismatch ? Colors.red : Colors.green,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        hasMismatch
                            ? 'ക്യാഷ് വ്യത്യാസം: പ്രതീക്ഷിച്ചത് ₹${cashReg['expectedCash']}, എണ്ണിയത് ₹${cashReg['closingCash']} (Diff: ₹${diff.toStringAsFixed(0)})'
                            : 'ക്യാഷ് രജിസ്റ്റർ കൃത്യമാണ് (Closing Cash: ₹${cashReg['closingCash']})',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: hasMismatch ? Colors.red.shade900 : Colors.green.shade900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 14),

            // Action Buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _showAdjustOrRejectDialog(r, ownerUid),
                  icon: const Icon(Icons.edit_note_rounded, size: 18),
                  label: const Text('Adjust / Reject'),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF16A34A),
                  ),
                  onPressed: () => _approveRecord(r, ownerUid),
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: const Text(TekStrings.btnApprove),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
