// Customer CRM core: phone-driven customer lookup, unique-phone enforcement,
// and the local indexes used for O(1) billing lookups.
//
// Pure Dart (hive + uuid only, no Flutter) so it can be unit-tested and run
// against a COPY of real shop data.
//
// Storage model
// -------------
// * Customers ARE parties (box `tek_parties`, type != Supplier). The CRM adds
//   fields to the party record: `_id` (uuid), `phone` (normalised 10 digits),
//   `createdAt`, `whatsappOptIn`, `doNotMessage`, `birthday`, `notes`, `tags`.
//   Parties already go through the SyncEngine, so these sync with no changes.
// * Sales store `customerId` (uuid) + `customerPhone` + `customerName`
//   snapshot.
// * totalSpent / billCount / first+last purchase are DERIVED: kept in the
//   local-only box `customer_stats` and recomputed from the customer's sales
//   whenever one of them changes. They are never synced, so a sync conflict can
//   never corrupt them (rebuildIndexes() recomputes everything from sales).
// * Local index boxes (never synced, always rebuildable):
//     customer_phone_index : phone        -> customer uuid
//     customer_sales_index : customer uuid -> [sale uuid, ...] (oldest first)
//     customer_stats       : customer uuid -> {k, phone, totalSpent(paise), ...}
//     customer_crm_refs    : 'p:<partyKey>' -> customer uuid
//                            's:<saleUuid>' -> sale Hive key
//                            'k:<saleKey>'  -> {c: customer uuid, s: sale uuid}
//                            'meta:*'       -> version / counters
// The indexes are kept current by Box.watch() listeners on parties and sales,
// so POS saves, edits, returns, deletes AND records arriving from other
// devices through sync all update them.

import 'dart:async';

import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

import '../core/hive_safe_open.dart' show isHiveLockError;
import 'customer_models.dart';
import 'customer_search.dart';
import 'phone_utils.dart';

const String kBoxCustomerPhoneIndex = 'customer_phone_index';
const String kBoxCustomerSalesIndex = 'customer_sales_index';
const String kBoxCustomerStats = 'customer_stats';
const String kBoxCustomerRefs = 'customer_crm_refs';
const List<String> kCrmIndexBoxes = [
  kBoxCustomerPhoneIndex,
  kBoxCustomerSalesIndex,
  kBoxCustomerStats,
  kBoxCustomerRefs,
];

/// Bump to force a one-time full index rebuild on next start.
const int kCrmIndexVersion = 1;

/// Audit hook (wired to ActivityLog in the app; no-op in tests).
typedef CrmAudit = Future<void> Function({
  required String action,
  required String entityId,
  Map<String, dynamic>? oldValue,
  Map<String, dynamic>? newValue,
});

Map<String, dynamic> _map(dynamic v) => v is Map
    ? {for (final e in v.entries) '${e.key}': e.value}
    : <String, dynamic>{};

class CrmRebuildReport {
  final int customers;
  final int indexedSales;
  final List<String> duplicatePhones;
  const CrmRebuildReport(
      this.customers, this.indexedSales, this.duplicatePhones);
  @override
  String toString() =>
      'customers=$customers sales=$indexedSales duplicates=${duplicatePhones.length}';
}

class CustomerSearchHit {
  final CrmCustomer customer;
  final Map<String, dynamic>? lastSale; // newest bill, for "last purchase"
  final int score;
  const CustomerSearchHit(this.customer, this.lastSale, this.score);

  /// "12 Nov 2026 • Redmi Note 13 • ₹15,000"-style summary parts.
  String? get lastItem {
    final items = (lastSale?['items'] as List?) ?? const [];
    if (items.isEmpty) return null;
    final first = items.first;
    return first is Map ? '${first['name'] ?? ''}' : null;
  }
}

class CustomerCrm {
  CustomerCrm({
    required this.parties,
    required this.sales,
    required this.phoneIndex,
    required this.salesIndex,
    required this.stats,
    required this.refs,
    this.audit,
  });

  final Box parties, sales;
  final Box phoneIndex, salesIndex, stats, refs;
  final CrmAudit? audit;
  static const _uuid = Uuid();

  // ------------------------------------------------------------------ setup
  static CustomerCrm? _instance;
  static CustomerCrm? get maybeInstance => _instance;
  static CustomerCrm get instance {
    final i = _instance;
    if (i == null) throw StateError('CustomerCrm.open() was not called');
    return i;
  }

  /// Opens the index boxes, repairs them if needed and starts watching.
  static Future<CustomerCrm> open({
    required Box parties,
    required Box sales,
    CrmAudit? audit,
  }) async {
    Future<Box> ob(String n) async {
      if (Hive.isBoxOpen(n)) return Hive.box(n);
      try {
        return await Hive.openBox(n);
      } catch (e) {
        // Locked by another TekFix: the data is fine, never delete it.
        if (isHiveLockError(e)) rethrow;
        // Unreadable: derived data only, safe to drop and rebuild.
        await Hive.deleteBoxFromDisk(n);
        return Hive.openBox(n);
      }
    }
    final crm = CustomerCrm(
      parties: parties,
      sales: sales,
      phoneIndex: await ob(kBoxCustomerPhoneIndex),
      salesIndex: await ob(kBoxCustomerSalesIndex),
      stats: await ob(kBoxCustomerStats),
      refs: await ob(kBoxCustomerRefs),
      audit: audit,
    );
    await _instance?.stopWatching();
    _instance = crm;
    await crm.ensureIndexes();
    crm.startWatching();
    return crm;
  }

  final _subs = <StreamSubscription>[];
  Future<void> _chain = Future.value();

  /// Serialise index updates so concurrent box events never interleave.
  Future<T> _enqueue<T>(Future<T> Function() job) {
    final next = _chain.then((_) => job());
    _chain = next.then((_) {}, onError: (Object e) {
      lastError = '$e';
    });
    return next;
  }

  /// Last index-update error (shown in the CRM tools screen).
  String? lastError;

  /// Completes when every queued index update has been applied.
  Future<void> get idle async {
    await Future<void>.delayed(Duration.zero);
    await _chain;
  }

  void startWatching() {
    _subs.add(parties.watch().listen((e) => _enqueue(() async {
          await indexParty(e.key, e.deleted ? null : e.value);
          await _touchCounts();
        }).ignore()));
    _subs.add(sales.watch().listen((e) => _enqueue(() async {
          await indexSale(e.key, e.deleted ? null : e.value);
          await _touchCounts();
        }).ignore()));
  }

  Future<void> stopWatching() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }

  Future<void> _touchCounts() async {
    await refs.put('meta:pc', parties.length);
    await refs.put('meta:sc', sales.length);
  }

  /// Rebuilds when the index is missing, from an older version, or the box
  /// sizes no longer match what was indexed (e.g. app killed mid-update).
  Future<bool> ensureIndexes() async {
    final ok = refs.get('meta:version') == kCrmIndexVersion &&
        refs.get('meta:pc') == parties.length &&
        refs.get('meta:sc') == sales.length;
    if (ok) return false;
    await _rebuild();
    return true;
  }

  /// Owner-only repair: wipes and rebuilds every CRM index from parties and
  /// sales. Never modifies parties or sales.
  Future<CrmRebuildReport> rebuildIndexes() async {
    await Future<void>.delayed(Duration.zero); // let pending box events queue
    return _enqueue(_rebuild);
  }

  Future<CrmRebuildReport> _rebuild() async {
    final keep = {
      for (final k in refs.keys)
        if ('$k'.startsWith('mig:')) k: refs.get(k)
    };
    await phoneIndex.clear();
    await salesIndex.clear();
    await stats.clear();
    await refs.clear();
    await refs.putAll(keep);
    var customers = 0;
    for (final k in parties.keys.toList()) {
      final p = parties.get(k);
      if (p is Map && isCustomerParty(p) && p['_id'] != null) customers++;
      await indexParty(k, p, recompute: false);
    }
    var n = 0;
    for (final k in sales.keys.toList()) {
      if (await indexSale(k, sales.get(k), recompute: false)) n++;
    }
    for (final uid in salesIndex.keys.toList()) {
      await _recompute('$uid');
    }
    await refs.put('meta:version', kCrmIndexVersion);
    await _touchCounts();
    return CrmRebuildReport(customers, n, duplicatePhones());
  }

  /// Phones that more than one customer party uses (data needing a merge).
  /// Full scan — only for reports, never on keystrokes.
  List<String> duplicatePhones() {
    final seen = <String, int>{};
    for (final v in parties.values) {
      if (v is! Map || !isCustomerParty(v)) continue;
      final ph = normalizePhone('${v['phone'] ?? ''}');
      if (ph == null) continue;
      seen[ph] = (seen[ph] ?? 0) + 1;
    }
    return [
      for (final e in seen.entries)
        if (e.value > 1) e.key
    ];
  }

  // --------------------------------------------------------- party indexing
  String _createdOf(String uid) {
    final k = _map(stats.get(uid))['k'];
    final p = k == null ? null : parties.get(k);
    return p is Map ? '${p['createdAt'] ?? ''}' : '';
  }

  /// Deterministic winner when two devices created the same phone offline:
  /// earliest createdAt (legacy records without one win), then smaller uuid.
  bool _beats(String a, String aCreated, String b) {
    final bCreated = _createdOf(b);
    final c = aCreated.compareTo(bCreated);
    if (c != 0) return c < 0;
    return a.compareTo(b) < 0;
  }

  Future<void> indexParty(dynamic key, dynamic value,
      {bool recompute = true}) async {
    final ck = 'p:$key';
    final oldUid = refs.get(ck) as String?;
    final p = value is Map ? value : null;
    final uid = p == null ? null : p['_id'] as String?;
    final valid = p != null && isCustomerParty(p) && uid != null;

    if (oldUid != null && (!valid || oldUid != uid)) {
      final st = _map(stats.get(oldUid));
      final ph = st['phone'] as String?;
      if (ph != null && phoneIndex.get(ph) == oldUid) {
        await phoneIndex.delete(ph);
      }
      st.remove('k');
      st.remove('phone');
      await stats.put(oldUid, st);
      await refs.delete(ck);
    }
    if (!valid) return;

    await refs.put(ck, uid);
    final st = _map(stats.get(uid));
    final oldPhone = st['phone'] as String?;
    final newPhone = normalizePhone('${p['phone'] ?? ''}');
    if (oldPhone != null &&
        oldPhone != newPhone &&
        phoneIndex.get(oldPhone) == uid) {
      await phoneIndex.delete(oldPhone);
    }
    st['k'] = key;
    st['phone'] = newPhone;
    await stats.put(uid, st);
    if (newPhone != null) {
      final cur = phoneIndex.get(newPhone) as String?;
      if (cur == null ||
          cur == uid ||
          !stats.containsKey(cur) ||
          _map(stats.get(cur))['phone'] != newPhone ||
          _beats(uid, '${p['createdAt'] ?? ''}', cur)) {
        await phoneIndex.put(newPhone, uid);
      }
    }
    if (recompute && !salesIndex.containsKey(uid)) {
      // first time we see this customer: make sure stats exist
      await _recompute(uid);
    }
  }

  // ---------------------------------------------------------- sale indexing
  /// Which customer a sale belongs to: explicit customerId, else a credit
  /// party that is a customer, else the phone index.
  String? customerIdForSale(Map s) {
    final cid = s['customerId'];
    if (cid is String && cid.isNotEmpty) return cid;
    final pid = s['partyId'];
    if (pid is String && stats.containsKey(pid)) return pid;
    final ph = normalizePhone('${s['customerPhone'] ?? ''}');
    if (ph != null) return phoneIndex.get(ph) as String?;
    return null;
  }

  /// Returns true when the sale is now linked to a customer.
  Future<bool> indexSale(dynamic key, dynamic value,
      {bool recompute = true}) async {
    final kRef = 'k:$key';
    final old = _map(refs.get(kRef));
    final s = value is Map ? value : null;
    final saleRef = s == null ? null : '${s['_id'] ?? 'local:$key'}';
    final cid = s == null ? null : customerIdForSale(s);

    final oldC = old['c'] as String?, oldS = old['s'] as String?;
    if (oldC != null && (oldC != cid || oldS != saleRef)) {
      final list = [...((salesIndex.get(oldC) as List?) ?? const [])]
        ..remove(oldS);
      await salesIndex.put(oldC, list);
      if (oldS != null && refs.get('s:$oldS') == key) {
        await refs.delete('s:$oldS');
      }
      await refs.delete(kRef);
      if (recompute) await _recompute(oldC);
    }
    if (cid == null || saleRef == null) return false;

    await refs.put('s:$saleRef', key);
    await refs.put(kRef, {'c': cid, 's': saleRef});
    final list = [...((salesIndex.get(cid) as List?) ?? const [])];
    if (!list.contains(saleRef)) {
      list.add(saleRef);
      await salesIndex.put(cid, list);
    }
    if (recompute) await _recompute(cid);
    return true;
  }

  /// Recompute derived stats for one customer from its sales (O(bills)).
  Future<void> _recompute(String uid) async {
    final refsList = (salesIndex.get(uid) as List?) ?? const [];
    final rows = <MapEntry<String, Map>>[];
    for (final r in refsList) {
      final k = refs.get('s:$r');
      final s = k == null ? null : sales.get(k);
      if (s is Map) rows.add(MapEntry('$r', s));
    }
    rows.sort((a, b) => saleWhen(a.value).compareTo(saleWhen(b.value)));
    var total = 0, count = 0;
    String? first, last;
    for (final r in rows) {
      final s = r.value;
      if (s['returned'] == true ||
          '${s['status'] ?? ''}'.toUpperCase() == 'RETURNED') {
        continue;
      }
      final net = toPaise(s['total']) - toPaise(s['returnedAmount']);
      total += net < 0 ? 0 : net;
      count++;
      final w = saleWhen(s);
      if (w.isNotEmpty) {
        first ??= w;
        last = w;
      }
    }
    await salesIndex.put(uid, [for (final r in rows) r.key]);
    final st = _map(stats.get(uid));
    st['totalSpent'] = total;
    st['billCount'] = count;
    st['firstPurchaseAt'] = first;
    st['lastPurchaseAt'] = last;
    await stats.put(uid, st);
  }

  /// New uuid for a record `_id` (sales are stamped before they are saved so
  /// the index can reference them at once; the SyncEngine keeps an `_id`).
  static String newId() => _uuid.v4();

  /// Index a sale right after it was written (the box watcher does the same
  /// thing again, idempotently) so the next lookup already sees it.
  Future<void> indexSaleNow(dynamic key, Map sale) =>
      _enqueue(() async {
        await indexSale(key, sale);
        await _touchCounts();
      });

  // ---------------------------------------------------------------- lookups
  /// O(1): phone index -> uuid -> party key. Never scans a box.
  CrmCustomer? lookupByPhone(String? raw) {
    final ph = normalizePhone(raw);
    if (ph == null) return null;
    final uid = phoneIndex.get(ph) as String?;
    return uid == null ? null : byId(uid);
  }

  CrmCustomer? byId(String uid) {
    final st = stats.get(uid);
    final k = st is Map ? st['k'] : null;
    if (k == null) return null;
    final p = parties.get(k);
    if (p is! Map || p['_id'] != uid) return null; // stale -> repair needed
    return CrmCustomer.from(k, p, st);
  }

  /// Customer's sales, newest first. [limit] null = all.
  List<MapEntry<dynamic, Map<String, dynamic>>> salesOf(String uid,
      {int? limit}) {
    final list = (salesIndex.get(uid) as List?) ?? const [];
    final out = <MapEntry<dynamic, Map<String, dynamic>>>[];
    for (var i = list.length - 1; i >= 0; i--) {
      final k = refs.get('s:${list[i]}');
      final s = k == null ? null : sales.get(k);
      if (s is Map) out.add(MapEntry(k, _map(s)));
      if (limit != null && out.length >= limit) break;
    }
    return out;
  }

  /// Phase 4 search: name, full phone or partial phone (last 4 digits),
  /// case-insensitive, Malayalam-safe. A full valid number is an O(1) index
  /// hit; anything else is one pass over parties (call it debounced).
  /// Ranked by match quality, then most recent purchase.
  List<CustomerSearchHit> searchCustomers(String query, {int limit = 20}) {
    final q = query.trim();
    if (q.isEmpty) return const [];
    if (isPhoneQuery(q)) {
      final exact = lookupByPhone(q);
      if (exact != null) return [CustomerSearchHit(exact, _lastSale(exact.id), 100)];
    }
    final scored = <MapEntry<int, MapEntry<dynamic, Map>>>[];
    for (final k in parties.keys) {
      final p = parties.get(k);
      if (p is! Map || !isCustomerParty(p) || p['_id'] == null) continue;
      final sc = partyMatchScore(p, q);
      if (sc > 0) scored.add(MapEntry(sc, MapEntry(k, p)));
    }
    String last(Map p) => '${_map(stats.get(p['_id']))['lastPurchaseAt'] ?? ''}';
    scored.sort((a, b) {
      final c = b.key.compareTo(a.key);
      return c != 0 ? c : last(b.value.value).compareTo(last(a.value.value));
    });
    final out = <CustomerSearchHit>[];
    for (final e in scored) {
      final uid = '${e.value.value['_id']}';
      final c = CrmCustomer.from(e.value.key, e.value.value, stats.get(uid) as Map?);
      out.add(CustomerSearchHit(c, _lastSale(uid), e.key));
      if (out.length >= limit) break;
    }
    return out;
  }

  Map<String, dynamic>? _lastSale(String uid) {
    final l = salesOf(uid, limit: 1);
    return l.isEmpty ? null : l.first.value;
  }

  /// Another customer already using this phone (for duplicate blocking).
  CrmCustomer? duplicateOf(String? rawPhone, {String? exceptId}) {
    final c = lookupByPhone(rawPhone);
    if (c == null || c.id == exceptId) return null;
    return c;
  }

  // ----------------------------------------------------------------- writes
  /// Creates a customer party. Throws [DuplicatePhoneException] when the
  /// phone already belongs to a customer, [FormatException] when invalid.
  Future<CrmCustomer> createCustomer({
    required String name,
    required String phone,
    bool whatsappOptIn = true,
    String? birthday,
    String notes = '',
    List<String> tags = const [],
  }) async {
    final ph = normalizePhone(phone);
    if (ph == null) throw FormatException(phoneError(phone) ?? 'Invalid phone');
    final dup = lookupByPhone(ph);
    if (dup != null) throw DuplicatePhoneException(dup);
    final uid = _uuid.v4();
    final rec = <String, dynamic>{
      '_id': uid,
      'name': isPlaceholderName(name) ? 'Customer $ph' : name.trim(),
      'phone': ph,
      'type': 'Customer',
      'balance': 0.0,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'whatsappOptIn': whatsappOptIn,
      'doNotMessage': false,
      'birthday': birthday,
      'notes': notes,
      'tags': tags,
      'remindersDisabled': false,
      'reminderCount': 0,
    };
    final k = await parties.add(rec);
    await _enqueue(() => indexParty(k, rec)); // available immediately
    await audit?.call(
        action: 'Customer Created', entityId: uid, newValue: rec);
    return byId(uid)!;
  }

  /// Applies CRM fields to a party map being saved by a form: normalises the
  /// phone, stamps uuid/createdAt and blocks duplicates. Returns the updated
  /// map. Throws [DuplicatePhoneException] / [FormatException].
  Map<String, dynamic> prepareCustomerParty(Map<String, dynamic> payload,
      {Map? existing}) {
    final out = Map<String, dynamic>.from(payload);
    if (!isCustomerParty(out)) return out;
    final raw = '${out['phone'] ?? ''}';
    if (phoneDigits(raw).isNotEmpty) {
      final ph = normalizePhone(raw);
      if (ph == null) throw FormatException(phoneError(raw)!);
      final dup = duplicateOf(ph, exceptId: existing?['_id'] as String?);
      if (dup != null) throw DuplicatePhoneException(dup);
      out['phone'] = ph;
    }
    out['_id'] ??= existing?['_id'] ?? _uuid.v4();
    out['createdAt'] ??=
        existing?['createdAt'] ?? DateTime.now().toUtc().toIso8601String();
    for (final f in const ['whatsappOptIn', 'doNotMessage', 'birthday',
      'notes', 'tags']) {
      if (!out.containsKey(f) && existing != null && existing.containsKey(f)) {
        out[f] = existing[f];
      }
    }
    out['whatsappOptIn'] ??= true;
    out['doNotMessage'] ??= false;
    return out;
  }

  /// Billing: resolves the phone typed at the POS to a customer, creating one
  /// when the number is new. Returns null for a walk-in (no phone).
  Future<CrmCustomer?> resolveForBill({
    required String phoneRaw,
    required String name,
    bool whatsappOptIn = true,
  }) async {
    if (phoneDigits(phoneRaw).isEmpty) return null;
    final ph = normalizePhone(phoneRaw);
    if (ph == null) throw FormatException(phoneError(phoneRaw)!);
    final found = lookupByPhone(ph);
    if (found != null) {
      final n = name.trim();
      if (!isPlaceholderName(n) && n != found.name) {
        await renameCustomer(found.id, n);
        return byId(found.id);
      }
      return found;
    }
    return createCustomer(name: name, phone: ph, whatsappOptIn: whatsappOptIn);
  }

  Future<void> renameCustomer(String uid, String name) async {
    final c = byId(uid);
    if (c == null) return;
    final p = _map(parties.get(c.key));
    final old = p['name'];
    p['name'] = name.trim();
    await parties.put(c.key, p);
    await audit?.call(
        action: 'Customer Edited',
        entityId: uid,
        oldValue: {'name': old},
        newValue: {'name': p['name']});
  }

  /// Fields to stamp on a sale for [c] (null = walk-in).
  static Map<String, dynamic> saleFields(CrmCustomer? c, {String name = ''}) {
    if (c == null) {
      return {
        'customerId': null,
        'customerName': isPlaceholderName(name) ? 'Walk-in Customer' : name,
      };
    }
    return {
      'customerId': c.id,
      'customerPhone': c.phone,
      'customerName': c.name,
    };
  }
}
