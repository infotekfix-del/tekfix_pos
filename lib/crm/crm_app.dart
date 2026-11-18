// App glue for the Customer CRM: startup, activity-log audit, safety backup
// and the owner-only CRM tools screen (dry run, migrate, rebuild indexes).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import '../auth/auth_controller.dart';
import '../main.dart' show Db, AppCard, askPin, boxParties, boxSales;
import 'customer_crm.dart';
import 'customer_migration.dart';
import 'crm_messaging.dart';
import 'crm_permissions.dart';

/// Current user's CRM permission (owner / admin = manager).
bool crmCan(CrmAction a) {
  final auth = AuthController.instance;
  return crmAllowed(a,
      signedIn: auth.signedIn, manager: auth.isOwner || auth.isAdmin);
}

/// Called once from main() after Hive boxes are open.
Future<void> startCustomerCrm() async {
  await CustomerCrm.open(
    parties: Db.parties,
    sales: Db.sales,
    audit: ({required action, required entityId, oldValue, newValue}) =>
        Db.logAction(
            action: action,
            entity: 'Customer',
            entityId: entityId,
            oldValue: oldValue,
            newValue: newValue),
  );
  // Phase 5: templates / campaigns / message log / automation settings
  await CrmMessaging.open(CustomerCrm.instance,
      seed: crmCan(CrmAction.editTemplates));
}

/// Full JSON export (restorable via Backup & Sync) + raw copies of the
/// parties/sales Hive files, next to the Hive data. Returns the folder.
Future<String> takeCrmSafetyBackup() async {
  final hiveDir = File(Db.parties.path!).parent.path;
  final ts = DateTime.now()
      .toIso8601String()
      .replaceAll(':', '')
      .replaceAll('-', '')
      .split('.')
      .first;
  final dir = Directory('$hiveDir${Platform.pathSeparator}tekfix_backups'
      '${Platform.pathSeparator}crm_migration_$ts');
  await dir.create(recursive: true);
  await File('${dir.path}${Platform.pathSeparator}tekfix_full_backup.json')
      .writeAsString(Db.exportAll());
  for (final b in [boxParties, boxSales]) {
    final p = Hive.box(b).path;
    if (p != null && File(p).existsSync()) {
      await File(p).copy('${dir.path}${Platform.pathSeparator}$b.hive');
    }
  }
  return dir.path;
}

class CrmToolsScreen extends StatefulWidget {
  const CrmToolsScreen({super.key});
  @override
  State<CrmToolsScreen> createState() => _CrmToolsScreenState();
}

class _CrmToolsScreenState extends State<CrmToolsScreen> {
  CrmMigrationPlan? _plan;
  bool _busy = false;
  bool _optIn = true;
  String _log = '';

  CustomerCrm? get _crm => CustomerCrm.maybeInstance;

  Future<void> _run(String label, Future<String> Function() job) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await job();
      if (mounted) setState(() => _log = '$label: $r');
    } catch (e) {
      if (mounted) setState(() => _log = '$label FAILED: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _dryRun() => _run('Dry run', () async {
        final p = await CustomerMigration(_crm!).dryRun();
        setState(() => _plan = p);
        return p.nothingToDo ? 'nothing to do' : 'see counts above';
      });

  Future<void> _apply() async {
    final p = _plan;
    if (p == null || !crmCan(CrmAction.runMigration)) return;
    if (!await askPin(context)) return;
    await _run('Migration', () async {
      final dir = await takeCrmSafetyBackup();
      final r = await CustomerMigration(_crm!)
          .apply(backupDone: true, optInExisting: _optIn);
      await Db.logAction(
          action: 'Customer CRM Migration',
          entity: 'Customer',
          newValue: {...r.toMap(), 'backup': dir});
      final again = await CustomerMigration(_crm!).dryRun();
      setState(() => _plan = again);
      return 'done. Backup: $dir';
    });
  }

  Future<void> _rebuild() async {
    if (!crmCan(CrmAction.rebuildIndexes)) return;
    if (!await askPin(context)) return;
    await _run('Rebuild indexes', () async {
      final r = await _crm!.rebuildIndexes();
      await Db.logAction(
          action: 'Customer Index Rebuild',
          entity: 'Customer',
          newValue: {'result': '$r'});
      return '$r';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!crmCan(CrmAction.runMigration)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Customer CRM Tools')),
        body: const Center(child: Text(kCrmDenied)),
      );
    }
    final crm = _crm;
    final p = _plan;
    Widget row(String k, Object v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(child: Text(k)),
            Text('$v', style: const TextStyle(fontWeight: FontWeight.w800)),
          ]),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('കസ്റ്റമർ CRM ടൂളുകൾ (Customer CRM Tools)')),
      body: crm == null
          ? const Center(child: Text('CRM not started (CRM ആരംഭിച്ചിട്ടില്ല)'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                AppCard(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('ഇൻഡക്സ് (Indexes)',
                          style: TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 6),
                      row('Phones indexed', crm.phoneIndex.length),
                      row('Customers with bills', crm.salesIndex.length),
                      row('Last migration',
                          '${(crm.refs.get('mig:v1') as Map?)?['at'] ?? 'never'}'),
                      if (crm.lastError != null)
                        Text('Last error: ${crm.lastError}',
                            style: const TextStyle(color: Colors.red)),
                    ],
                  ),
                ),
                AppCard(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                          'പഴയ ബില്ലുകൾ കസ്റ്റമറുമായി ബന്ധിപ്പിക്കുക (Link old bills to customers)',
                          style: TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      const Text(
                          'ആദ്യം Dry run: ഒന്നും മാറ്റില്ല, എണ്ണം മാത്രം കാണിക്കും. '
                          'Apply ചെയ്യുന്നതിന് മുമ്പ് ബാക്കപ്പ് എടുക്കും. വീണ്ടും run ചെയ്യുന്നത് സുരക്ഷിതമാണ്.\n'
                          '(Dry run changes nothing. Apply takes a backup first and is safe to re-run.)',
                          style: TextStyle(fontSize: 12)),
                      const SizedBox(height: 10),
                      if (p != null) ...[
                        row('Bills total', p.salesTotal),
                        row('Already linked', p.salesAlreadyLinked),
                        row('Bills to link (ബന്ധിപ്പിക്കും)', p.salesToLink),
                        row('New customers to create', p.customersToCreate),
                        row('Customer records to update', p.partiesToUpdate),
                        row('Walk-in / no phone', p.salesNoCustomer),
                        row('Invalid phone numbers (skipped)', p.invalidPhones),
                        row('Duplicate phones (need merge)',
                            p.duplicatePhones.length),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _optIn,
                          onChanged: (v) => setState(() => _optIn = v ?? false),
                          title: const Text(
                              'നിലവിലെ കസ്റ്റമർമാർക്ക് WhatsApp ഓഫറുകൾ അയക്കാം (Mark existing customers as WhatsApp opt-in)',
                              style: TextStyle(fontSize: 13)),
                        ),
                      ],
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _dryRun,
                          icon: const Icon(Icons.search_rounded),
                          label: const Text('Dry run (ഡ്രൈ റൺ)'),
                        ),
                        FilledButton.icon(
                          onPressed:
                              _busy || p == null || p.nothingToDo ? null : _apply,
                          icon: const Icon(Icons.backup_rounded),
                          label: const Text('Backup & Apply (ബാക്കപ്പ് + മാറ്റുക)'),
                        ),
                      ]),
                    ],
                  ),
                ),
                AppCard(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('റിപ്പയർ (Repair)',
                          style: TextStyle(fontWeight: FontWeight.w800)),
                      const Text(
                          'ഫോൺ / ബിൽ ഇൻഡക്സ് വീണ്ടും നിർമ്മിക്കുക. ഡാറ്റ മാറ്റില്ല. (Rebuilds the lookup indexes from bills; changes no data.)',
                          style: TextStyle(fontSize: 12)),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _rebuild,
                        icon: const Icon(Icons.build_rounded),
                        label: const Text('Rebuild indexes (ഇൻഡക്സ് റീബിൽഡ്)'),
                      ),
                    ],
                  ),
                ),
                if (_busy) const LinearProgressIndicator(),
                if (_log.isNotEmpty)
                  SelectableText(_log, style: const TextStyle(fontSize: 12)),
              ],
            ),
    );
  }
}
