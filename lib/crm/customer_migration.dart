// One-time (but safely re-runnable) migration that links old sales to
// customers by phone, creating customers that are missing.
//
// * dryRun() only counts — it writes nothing.
// * apply() is idempotent: a second run finds nothing to do.
// * Never deletes or overwrites user data: an original phone that had to be
//   normalised is kept in `phoneRaw` / `customerPhoneRaw`.
// * The caller MUST take a backup first (apply() refuses without it).
//
// Pure Dart (no Flutter) so it can be run against a copy of real data.

import 'package:uuid/uuid.dart';

import 'customer_crm.dart';
import 'customer_models.dart';
import 'phone_utils.dart';

class CrmMigrationPlan {
  int salesTotal = 0;
  int salesAlreadyLinked = 0;
  int salesToLink = 0;
  int salesNoCustomer = 0; // walk-in, no phone
  int invalidPhones = 0; // phone typed but not a valid mobile
  int customersToCreate = 0;
  int partiesToUpdate = 0; // customer parties needing uuid / phone fix
  List<String> duplicatePhones = const [];
  bool applied = false;

  Map<String, dynamic> toMap() => {
        'salesTotal': salesTotal,
        'salesAlreadyLinked': salesAlreadyLinked,
        'salesToLink': salesToLink,
        'salesNoCustomer': salesNoCustomer,
        'invalidPhones': invalidPhones,
        'customersToCreate': customersToCreate,
        'partiesToUpdate': partiesToUpdate,
        'duplicatePhones': duplicatePhones,
        'applied': applied,
      };

  bool get nothingToDo =>
      salesToLink == 0 && customersToCreate == 0 && partiesToUpdate == 0;

  @override
  String toString() => toMap().toString();
}

class CustomerMigration {
  CustomerMigration(this.crm);
  final CustomerCrm crm;
  static const _uuid = Uuid();

  /// Counts only. Safe to call any time.
  Future<CrmMigrationPlan> dryRun() => _run(apply: false);

  /// Applies the plan. [backupDone] must be true (backup taken by caller).
  Future<CrmMigrationPlan> apply(
      {required bool backupDone, bool optInExisting = true}) {
    if (!backupDone) {
      throw StateError('Backup required before migration');
    }
    return _run(apply: true, optInExisting: optInExisting);
  }

  Future<CrmMigrationPlan> _run(
      {required bool apply, bool optInExisting = true}) async {
    final plan = CrmMigrationPlan();
    final parties = crm.parties, sales = crm.sales;

    // ---- 1. customer parties: uuid + normalised phone + CRM defaults
    final phoneToUid = <String, String>{};
    final phoneCreated = <String, String>{};
    for (final k in parties.keys.toList()) {
      final raw = parties.get(k);
      if (raw is! Map || !isCustomerParty(raw)) continue;
      final p = {for (final e in raw.entries) '${e.key}': e.value};
      var changed = false;
      if (p['_id'] == null) {
        p['_id'] = _uuid.v4();
        changed = true;
      }
      final rawPhone = '${p['phone'] ?? ''}';
      final ph = normalizePhone(rawPhone);
      if (ph != null && ph != rawPhone) {
        p['phoneRaw'] = rawPhone;
        p['phone'] = ph;
        changed = true;
      }
      if (!p.containsKey('whatsappOptIn')) {
        p['whatsappOptIn'] = optInExisting;
        p['doNotMessage'] = p['doNotMessage'] ?? false;
        changed = true;
      }
      if (changed) {
        plan.partiesToUpdate++;
        if (apply) await parties.put(k, p);
      }
      if (ph != null) {
        final uid = '${p['_id']}';
        final created = '${p['createdAt'] ?? ''}';
        final cur = phoneToUid[ph];
        // same deterministic winner rule as the phone index
        if (cur == null ||
            created.compareTo(phoneCreated[ph]!) < 0 ||
            (created == phoneCreated[ph] && uid.compareTo(cur) < 0)) {
          phoneToUid[ph] = uid;
          phoneCreated[ph] = created;
        }
      }
    }
    plan.duplicatePhones = crm.duplicatePhones();
    if (apply) {
      await crm.idle;
      await crm.rebuildIndexes();
    }

    // ---- 2. sales -> customers
    final customerIds = {
      for (final v in parties.values)
        if (v is Map && isCustomerParty(v) && v['_id'] != null) '${v['_id']}'
    };
    final newPhones = <String, Map<String, String>>{}; // phone -> name/first
    final toLink = <dynamic>[];
    for (final k in sales.keys.toList()) {
      final s = sales.get(k);
      if (s is! Map) continue;
      plan.salesTotal++;
      final cid = s['customerId'];
      if (cid is String && cid.isNotEmpty) {
        plan.salesAlreadyLinked++;
        continue;
      }
      final pid = s['partyId'];
      final rawPhone = '${s['customerPhone'] ?? ''}';
      final ph = normalizePhone(rawPhone);
      if (ph == null && pid is String && customerIds.contains(pid)) {
        plan.salesToLink++;
        toLink.add(k);
        continue;
      }
      if (ph == null) {
        if (phoneDigits(rawPhone).isNotEmpty) plan.invalidPhones++;
        plan.salesNoCustomer++;
        continue;
      }
      plan.salesToLink++;
      toLink.add(k);
      if (!phoneToUid.containsKey(ph)) {
        final when = saleWhen(s);
        final n = '${s['customerName'] ?? ''}';
        final cur = newPhones[ph];
        if (cur == null) {
          newPhones[ph] = {'name': n, 'first': when, 'last': when};
        } else {
          if (when.compareTo(cur['first']!) < 0) cur['first'] = when;
          // newest real name wins (people fix typos on later bills)
          if (!isPlaceholderName(n) && when.compareTo(cur['last']!) >= 0) {
            cur['name'] = n;
            cur['last'] = when;
          } else if (isPlaceholderName(cur['name'])) {
            cur['name'] = n;
          }
        }
      }
    }
    plan.customersToCreate = newPhones.length;
    if (!apply) return plan;

    // ---- 3. create missing customers
    for (final e in newPhones.entries) {
      if (crm.lookupByPhone(e.key) != null) continue; // re-run safety
      final uid = _uuid.v4();
      final first = e.value['first']!;
      final rec = <String, dynamic>{
        '_id': uid,
        'name': isPlaceholderName(e.value['name'])
            ? 'Customer ${e.key}'
            : e.value['name']!.trim(),
        'phone': e.key,
        'type': 'Customer',
        'balance': 0.0,
        'createdAt':
            first.isEmpty ? DateTime.now().toUtc().toIso8601String() : first,
        'whatsappOptIn': optInExisting,
        'doNotMessage': false,
        'notes': '',
        'tags': const <String>[],
        'createdBy': 'crm_migration_v1',
      };
      await parties.add(rec);
    }
    await crm.idle;
    await crm.rebuildIndexes();

    // ---- 4. stamp customerId on linked sales
    for (final k in toLink) {
      final raw = sales.get(k);
      if (raw is! Map) continue;
      final s = {for (final e in raw.entries) '${e.key}': e.value};
      if (s['customerId'] is String && '${s['customerId']}'.isNotEmpty) continue;
      final rawPhone = '${s['customerPhone'] ?? ''}';
      final ph = normalizePhone(rawPhone);
      String? cid;
      if (ph != null) {
        cid = crm.phoneIndex.get(ph) as String?;
      } else if (s['partyId'] is String) {
        cid = '${s['partyId']}';
      }
      if (cid == null) continue;
      s['customerId'] = cid;
      if (ph != null && ph != rawPhone) {
        s['customerPhoneRaw'] = rawPhone;
        s['customerPhone'] = ph;
      }
      if (ph == null) {
        final c = crm.byId(cid);
        if (c != null && c.phone.isNotEmpty) s['customerPhone'] = c.phone;
      }
      await sales.put(k, s);
    }
    await crm.idle;
    await crm.rebuildIndexes();
    plan.applied = true;
    await crm.refs.put('mig:v1', {
      ...plan.toMap(),
      'at': DateTime.now().toUtc().toIso8601String(),
    });
    return plan;
  }
}
