import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import '../core/device.dart';
import '../main.dart'
    show
        Db,
        boxItems,
        boxParties,
        boxSales,
        boxPurchases,
        boxExpenses,
        boxStaff,
        boxServices,
        boxStockMoves,
        boxAudit,
        boxBank,
        boxReturns,
        boxPurchaseBills,
        boxVendorPayments;

enum SyncState { synced, syncing, offline, error }

class _Col {
  final String box, name;
  final String? counter; // merged with increments, never overwritten
  final bool ownerOnlyRead; // staff devices push but never pull these
  final bool staffOwnRowsOnly; // staff pull only rows with staffId == uid
  final int
      windowDays; // first pull on a new device fetches only this many days (0 = all)
  const _Col(this.box, this.name,
      {this.counter,
      this.ownerOnlyRead = false,
      this.staffOwnRowsOnly = false,
      this.windowDays = 0});
}

const _cols = <_Col>[
  _Col(boxItems, 'items', counter: 'stock'),
  _Col(boxParties, 'parties', counter: 'balance'),
  _Col(boxSales, 'sales', staffOwnRowsOnly: true, windowDays: 90),
  _Col(boxPurchases, 'purchases', ownerOnlyRead: true),
  _Col(boxExpenses, 'expenses', ownerOnlyRead: true),
  _Col(boxStaff, 'staff', ownerOnlyRead: true),
  _Col(boxServices, 'services'),
  _Col(boxStockMoves, 'stock_moves', ownerOnlyRead: true, windowDays: 30),
  _Col(boxAudit, 'activity_logs', ownerOnlyRead: true, windowDays: 30),
  _Col(boxReturns, 'returns'),
  _Col(boxPurchaseBills, 'purchase_bills', ownerOnlyRead: true),
  _Col(boxVendorPayments, 'vendor_payments', ownerOnlyRead: true),
];

const _uuid = Uuid();
const _metaKeys = {'_u', '_by', '_st'};

dynamic _canon(dynamic v) {
  if (v is Map) {
    final ks = v.keys.map((e) => '$e').toList()..sort();
    return {for (final k in ks) k: _canon(v[k])};
  }
  if (v is List) return [for (final e in v) _canon(e)];
  return v;
}

Map<String, dynamic> _asMap(dynamic v) => v is Map
    ? {for (final e in v.entries) '${e.key}': e.value}
    : <String, dynamic>{};

double _num(dynamic v) =>
    v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0.0);

/// Two 32-bit FNV-1a hashes -> 16 hex chars. Ignores sync metadata.
String _hash(Map<String, dynamic> rec) {
  final c = _canon({
    for (final e in rec.entries)
      if (!_metaKeys.contains(e.key)) e.key: e.value
  });
  String s;
  try {
    s = jsonEncode(c);
  } catch (_) {
    s = c.toString();
  }
  var a = 0x811c9dc5, b = 0x01000193 ^ 0x5bd1e995;
  for (final u in s.codeUnits) {
    a = ((a ^ u) * 0x01000193) & 0xffffffff;
    b = ((b ^ u) * 0x0100019b) & 0xffffffff;
  }
  return a.toRadixString(16).padLeft(8, '0') +
      b.toRadixString(16).padLeft(8, '0');
}

/// Offline-first sync:  Hive (source of truth on device)  <->  Firestore.
///
///  * every local write is detected through Box.watch(), stamped with a uuid
///    (`_id`) and put in a persistent outbox -> pushed in batches when online
///  * remote changes arrive through incremental snapshot listeners
///  * stock / party balance / cash balances are merged as DELTAS
///    (FieldValue.increment) so two devices selling the same item offline
///    never overwrite each other
class SyncEngine extends ChangeNotifier {
  SyncEngine._();
  static final SyncEngine instance = SyncEngine._();

  late Box _meta, _outbox;
  bool _boxesOpen = false;
  FirebaseFirestore get _fs => FirebaseFirestore.instance;

  String? _shop;
  String _uid = '';
  bool _owner = false, _online = true, _flushing = false, _running = false;
  SyncState _state = SyncState.offline;
  DateTime? lastSyncAt;
  String? lastError;
  bool needsSeedDecision = false;

  final _subs = <StreamSubscription>[];
  StreamSubscription? _connSub;
  Timer? _kick, _retry;
  final _keyToUid = <String, String>{}; // 'box|key' -> uid
  final _uidToKey = <String, dynamic>{}; // 'box|uid' -> key
  final _hashes = <String, String>{}; // 'box|uid' -> content hash
  final _remoteDel = <String>{};

  SyncState get state => _state;
  int get pending => _boxesOpen ? _outbox.length : 0;

  /// Call in main() right after Hive.initFlutter(). Separate boxes, so the
  /// existing backup/restore (allBoxes) is untouched.
  Future<void> openBoxes() async {
    if (_boxesOpen) return;
    try {
      _meta = Hive.isBoxOpen('tek_sync_meta')
          ? Hive.box('tek_sync_meta')
          : await Hive.openBox('tek_sync_meta');
      _outbox = Hive.isBoxOpen('tek_sync_outbox')
          ? Hive.box('tek_sync_outbox')
          : await Hive.openBox('tek_sync_outbox');
      _boxesOpen = true;
    } catch (e) {
      debugPrint('[TekFix SyncEngine] openBoxes error ($e). Auto-recovering sync boxes...');
      try {
        await Hive.deleteBoxFromDisk('tek_sync_meta');
        await Hive.deleteBoxFromDisk('tek_sync_outbox');
        _meta = await Hive.openBox('tek_sync_meta');
        _outbox = await Hive.openBox('tek_sync_outbox');
        _boxesOpen = true;
      } catch (e2) {
        debugPrint('[TekFix SyncEngine] Fatal: could not recover sync boxes: $e2');
      }
    }
  }

  // ---------------------------------------------------------------- lifecycle
  Future<void> start(
      {required String shopId,
      required String uid,
      required bool isOwner}) async {
    if (_running && _shop == shopId && _uid == uid && _owner == isOwner) return;
    await stop();
    _shop = shopId;
    _uid = uid;
    _owner = isOwner;
    _running = true;
    final c = await Connectivity().checkConnectivity();
    _online = !c.contains(ConnectivityResult.none);
    _connSub = Connectivity().onConnectivityChanged.listen((r) {
      final on = !r.contains(ConnectivityResult.none);
      if (on != _online) {
        _online = on;
        if (on) {
          _begin();
          _schedule();
        }
        _refreshState();
      }
    });
    await _buildIndex();
    _watchLocal();
    _refreshState();
    await _begin();
  }

  Future<void> stop() async {
    _running = false;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _connSub?.cancel();
    _connSub = null;
    _kick?.cancel();
    _retry?.cancel();
    _keyToUid.clear();
    _uidToKey.clear();
    _hashes.clear();
    _listening = false;
    _state = SyncState.offline;
    notifyListeners();
  }

  bool _listening = false;

  /// Seed check, then pull listeners, then first push.
  Future<void> _begin() async {
    if (!_running || _shop == null) return;
    try {
      if (_online && _meta.get('seed_done') != true) await _ensureSeed();
      if (_meta.get('seed_done') == true && !_listening && _online) {
        _listening = true;
        _listenRemote();
      }
    } catch (e) {
      _fail(e);
    }
    _schedule();
  }

  /// The FIRST device that owns real data uploads it. Any other device with
  /// old, unstamped local data must choose: discard local + pull from cloud.
  Future<void> _ensureSeed() async {
    final ref = _fs.doc('shops/$_shop/meta/seed');
    final hasLegacy = _hasUnstamped();
    var created = false;
    final snap = await ref.get();
    if (!snap.exists && _owner) {
      await _fs.runTransaction((tx) async {
        final s = await tx.get(ref);
        if (!s.exists) {
          tx.set(
              ref, {'by': DeviceInfo.id, 'at': FieldValue.serverTimestamp()});
          created = true;
        }
      });
    }
    if (created) {
      _stampLegacyAndQueue();
      await _meta.put('is_seed', true);
      await _meta.put('seed_done', true);
    } else if (snap.exists || !_owner) {
      if (!snap.exists) return; // staff device waiting for the owner to seed
      if (hasLegacy) {
        needsSeedDecision = true;
        notifyListeners();
        return;
      }
      await _meta.put('seed_done', true);
    }
    needsSeedDecision = false;
  }

  /// UI action for a second device that has old local data.
  Future<void> discardLocalAndPull() async {
    for (final c in _cols) {
      await Hive.box(c.box).clear();
    }
    await Db.bank.delete('cash_in_hand');
    await Db.bank.delete('bank_balance');
    await Db.bank.delete('txn_log');
    await _meta.clear();
    await _outbox.clear();
    _keyToUid.clear();
    _uidToKey.clear();
    _hashes.clear();
    await _meta.put('seed_done', true);
    needsSeedDecision = false;
    _listening = false;
    await _begin();
  }

  bool _hasUnstamped() {
    for (final c in _cols) {
      for (final k in Hive.box(c.box).keys) {
        if (_asMap(Hive.box(c.box).get(k))['_id'] == null) return true;
      }
    }
    return false;
  }

  // ------------------------------------------------------------ local -> outbox
  Future<void> _buildIndex() async {
    for (final c in _cols) {
      if (!Hive.isBoxOpen(c.box)) continue;
      final box = Hive.box(c.box);
      for (final k in box.keys) {
        final rec = _asMap(box.get(k));
        final uid = rec['_id'] as String?;
        if (uid == null) {
          continue; // legacy: stamped by _ensureSeed on the seed device
        }
        final kk = '${c.box}|$uid';
        _keyToUid['${c.box}|$k'] = uid;
        _uidToKey[kk] = k;
        final h = _hash(rec);
        _hashes[kk] = h;
        if (_meta.get('ph:$kk') != h) {
          _enqueueRaw(c.box, uid, 'upsert'); // edited while engine was off
        }
      }
      // Yield to Flutter event loop so frame rendering and touch events are processed!
      await Future.delayed(Duration.zero);
    }
    // bank counters + txn log
    if (Hive.isBoxOpen(boxBank)) {
      for (final k in const ['cash_in_hand', 'bank_balance']) {
        if (_meta.containsKey('ls:bank|$k') &&
            _num(Db.bank.get(k)) != _num(_meta.get('ls:bank|$k'))) {
          _enqueueRaw('bank', k, 'upsert');
        }
      }
      _stampTxnLog();
    }
    _schedule();
    _refreshState();
  }

  void _stampLegacyAndQueue() {
    for (final c in _cols) {
      final box = Hive.box(c.box);
      for (final k in box.keys.toList()) {
        final rec = _asMap(box.get(k));
        if (rec['_id'] != null) continue;
        final uid = _uuid.v4();
        rec['_id'] = uid;
        rec['_u'] = DateTime.now().millisecondsSinceEpoch;
        rec['_by'] = DeviceInfo.id;
        final kk = '${c.box}|$uid';
        _hashes[kk] = _hash(rec);
        _keyToUid['${c.box}|$k'] = uid;
        _uidToKey[kk] = k;
        box.put(k, rec);
        _enqueue(c.box, uid, 'upsert');
      }
    }
    for (final k in const ['cash_in_hand', 'bank_balance']) {
      if (Db.bank.containsKey(k)) _enqueue('bank', k, 'upsert');
    }
    _stampTxnLog(all: true);
  }

  void _watchLocal() {
    for (final c in _cols) {
      _subs.add(Hive.box(c.box).watch().listen((e) => _onLocal(c, e)));
    }
    _subs.add(Db.bank.watch().listen(_onBank));
  }

  Future<void> _onLocal(_Col c, BoxEvent e) async {
    if (!_running || _meta.get('seed_done') != true) return;
    final ck = '${c.box}|${e.key}';
    if (e.deleted) {
      final uid = _keyToUid.remove(ck);
      if (uid == null) return;
      final kk = '${c.box}|$uid';
      _uidToKey.remove(kk);
      _hashes.remove(kk);
      if (_remoteDel.remove(kk)) return;
      _enqueue(c.box, uid, 'delete');
      return;
    }
    final rec = _asMap(e.value);
    var uid = (rec['_id'] ?? _keyToUid[ck]) as String?;
    uid ??= _uuid.v4();
    final kk = '${c.box}|$uid';
    final h = _hash(rec);
    _keyToUid[ck] = uid;
    _uidToKey[kk] = e.key;
    if (_hashes[kk] == h && rec['_id'] == uid) {
      return; // remote-applied or our own stamp
    }
    rec['_id'] = uid;
    rec['_u'] = DateTime.now().millisecondsSinceEpoch;
    rec['_by'] = DeviceInfo.id;
    _hashes[kk] = h;
    await Hive.box(c.box).put(e.key, rec); // re-emits; filtered by hash above
    _enqueue(c.box, uid, 'upsert');
  }

  void _onBank(BoxEvent e) {
    if (!_running || _meta.get('seed_done') != true) return;
    if (e.key == 'cash_in_hand' || e.key == 'bank_balance') {
      _enqueue('bank', '${e.key}', 'upsert');
    } else if (e.key == 'txn_log') {
      _stampTxnLog();
    }
  }

  void _stampTxnLog({bool all = false}) {
    final raw = Db.bank.get('txn_log');
    if (raw is! List) return;
    var changed = false;
    final out = <dynamic>[];
    for (final e in raw) {
      final m = _asMap(e);
      if (m['_id'] == null) {
        m['_id'] = _uuid.v4();
        _enqueue('bank_txn', '${m['_id']}', 'upsert');
        changed = true;
      } else if (all && _meta.get('ph:bank_txn|${m['_id']}') == null) {
        _enqueue('bank_txn', '${m['_id']}', 'upsert');
      }
      out.add(m);
    }
    if (changed) Db.bank.put('txn_log', out);
  }

  void _enqueueRaw(String box, String id, String op) {
    final k = '$box|$id';
    final prev = _outbox.get(k);
    if (prev is Map && prev['op'] == 'delete' && op == 'upsert') return;
    _outbox.put(k, {'op': op, 't': DateTime.now().millisecondsSinceEpoch});
  }

  void _enqueue(String box, String id, String op) {
    _enqueueRaw(box, id, op);
    _schedule();
    _refreshState();
  }

  void _schedule() {
    _kick?.cancel();
    _kick = Timer(const Duration(milliseconds: 700), _flush);
  }

  // ---------------------------------------------------------------- push
  Future<void> _flush() async {
    if (!_running ||
        _flushing ||
        !_online ||
        _shop == null ||
        _meta.get('seed_done') != true) {
      _refreshState();
      return;
    }
    _flushing = true;
    _refreshState();
    try {
      while (_outbox.isNotEmpty && _running) {
        final keys = _outbox.keys.take(150).toList(); // < 500 writes per batch
        final seen = {for (final k in keys) k: _asMap(_outbox.get(k))['t']};
        final batch = _fs.batch();
        final restoreLs = <String, dynamic>{};
        final donePh = <String, String>{};
        for (final k in keys) {
          final op = _asMap(_outbox.get(k))['op'];
          final parts = '$k'.split('|');
          final box = parts[0], id = parts.sublist(1).join('|');
          if (box == 'bank') {
            final cur = _num(Db.bank.get(id));
            final lsKey = 'ls:bank|$id';
            final delta = _r(cur - _num(_meta.get(lsKey)));
            if (delta != 0) {
              restoreLs[lsKey] = _meta.get(lsKey);
              _meta.put(lsKey, cur);
              batch.set(
                  _fs.doc('shops/$_shop/bank/$id'),
                  {
                    'v': FieldValue.increment(delta),
                    '_by': DeviceInfo.id,
                    '_st': FieldValue.serverTimestamp()
                  },
                  SetOptions(merge: true));
            }
            continue;
          }
          if (box == 'bank_txn') {
            final raw = Db.bank.get('txn_log');
            final m = raw is List
                ? raw.map(_asMap).firstWhere((e) => e['_id'] == id,
                    orElse: () => <String, dynamic>{})
                : <String, dynamic>{};
            if (m.isNotEmpty) {
              final txn = Map<String, dynamic>.from(_canon(m) as Map)
                ..['_by'] = DeviceInfo.id
                ..['_st'] = FieldValue.serverTimestamp();
              batch.set(_fs.doc('shops/$_shop/bank_txns/$id'), txn,
                  SetOptions(merge: true));
              donePh['ph:bank_txn|$id'] = '1';
            }
            continue;
          }
          final col = _cols.firstWhere((c) => c.box == box);
          final kk = '$box|$id';
          final ref = _fs.doc('shops/$_shop/${col.name}/$id');
          if (op == 'delete') {
            batch.set(
                ref,
                {
                  '_del': true,
                  '_u': DateTime.now().millisecondsSinceEpoch,
                  '_by': DeviceInfo.id,
                  '_st': FieldValue.serverTimestamp()
                },
                SetOptions(merge: true));
            continue;
          }
          final key = _uidToKey[kk];
          final raw = key == null ? null : Hive.box(box).get(key);
          if (raw == null) continue;
          final rec = _asMap(raw);
          final h = _hash(rec);
          final data = Map<String, dynamic>.from(_canon(rec) as Map)
            ..remove('_st');
          var delta = 0.0;
          if (col.counter != null) {
            final cur = _num(rec[col.counter]);
            final lsKey = 'ls:$kk';
            delta = _r(cur - _num(_meta.get(lsKey)));
            data.remove(col.counter);
            if (delta != 0 || !_meta.containsKey(lsKey)) {
              data[col.counter!] = FieldValue.increment(delta);
              restoreLs[lsKey] = _meta.get(lsKey);
              _meta.put(lsKey, cur);
            }
          }
          if (delta == 0 && _meta.get('ph:$kk') == h) {
            continue; // nothing new -> saves bandwidth
          }
          data['_st'] = FieldValue.serverTimestamp();
          batch.set(ref, data, SetOptions(merge: true));
          donePh['ph:$kk'] = h;
        }
        try {
          await batch.commit();
        } catch (e) {
          // revert optimistic counter baselines so deltas are re-sent
          restoreLs
              .forEach((k, v) => v == null ? _meta.delete(k) : _meta.put(k, v));
          rethrow;
        }
        await _meta.putAll(donePh);
        for (final k in keys) {
          // keep entries that were edited again while the batch was in flight
          if (_asMap(_outbox.get(k))['t'] == seen[k]) await _outbox.delete(k);
        }
        // Yield 25ms to let Flutter process user input and render frames smoothly
        await Future.delayed(const Duration(milliseconds: 25));
      }
      lastSyncAt = DateTime.now();
      lastError = null;
    } catch (e) {
      _fail(e);
    } finally {
      _flushing = false;
      _refreshState();
    }
  }

  double _r(double v) => (v * 100).round() / 100;

  // ---------------------------------------------------------------- pull
  void _listenRemote() {
    for (final c in _cols) {
      if (c.ownerOnlyRead && !_owner) continue;
      Query<Map<String, dynamic>> q = _fs.collection('shops/$_shop/${c.name}');
      if (c.staffOwnRowsOnly && !_owner) {
        q = q.where('staffId', isEqualTo: _uid);
      }
      final curKey = 'cur:${c.name}';
      var cursor = (_meta.get(curKey) as int?) ??
          (c.windowDays > 0 && _meta.get('is_seed') != true
              ? DateTime.now()
                  .subtract(Duration(days: c.windowDays))
                  .millisecondsSinceEpoch
              : 0);
      q = q
          .where('_st',
              isGreaterThan: Timestamp.fromMillisecondsSinceEpoch(cursor))
          .orderBy('_st');
      _subs.add(q.snapshots().listen((snap) async {
        var maxMs = cursor;
        for (final ch in snap.docChanges) {
          final d = ch.doc;
          if (d.metadata.hasPendingWrites) continue; // our own unsent write
          final data = d.data();
          if (data == null) continue;
          await _apply(c, d.id, data);
          final st = data['_st'];
          if (st is Timestamp && st.millisecondsSinceEpoch > maxMs) {
            maxMs = st.millisecondsSinceEpoch;
          }
        }
        if (maxMs > cursor) {
          // small overlap protects against listener restarts; _apply is idempotent
          cursor = maxMs;
          await _meta.put(curKey, maxMs - 2000);
        }
        if (!snap.metadata.isFromCache) {
          lastSyncAt = DateTime.now();
          _refreshState();
        }
      }, onError: (e) => _fail('${c.name}: $e')));
    }
    if (_owner) _listenBank();
  }

  void _listenBank() {
    for (final id in const ['cash_in_hand', 'bank_balance']) {
      _subs.add(_fs.doc('shops/$_shop/bank/$id').snapshots().listen((d) async {
        if (d.metadata.hasPendingWrites || !d.exists) return;
        final remote = _num(d.data()!['v']);
        final lsKey = 'ls:bank|$id';
        final local = _num(Db.bank.get(id));
        await Db.bank.put(id, _r(remote + (local - _num(_meta.get(lsKey)))));
        await _meta.put(lsKey, remote);
      }, onError: _fail));
    }
    _subs.add(_fs
        .collection('shops/$_shop/bank_txns')
        .where('_st',
            isGreaterThan: Timestamp.fromMillisecondsSinceEpoch(
                (_meta.get('cur:bank_txns') as int?) ?? 0))
        .orderBy('_st')
        .snapshots()
        .listen((snap) async {
      final raw = Db.bank.get('txn_log');
      final log =
          (raw is List ? raw.map(_asMap).toList() : <Map<String, dynamic>>[]);
      final have = {for (final e in log) e['_id']};
      var changed = false;
      var maxMs = 0;
      for (final ch in snap.docChanges) {
        final data = ch.doc.data();
        if (data == null || ch.doc.metadata.hasPendingWrites) continue;
        final st = data['_st'];
        if (st is Timestamp && st.millisecondsSinceEpoch > maxMs) {
          maxMs = st.millisecondsSinceEpoch;
        }
        if (have.contains(data['_id'])) continue;
        data.remove('_st');
        log.add(data);
        changed = true;
      }
      if (changed) {
        log.sort((a, b) => '${a['date']}'.compareTo('${b['date']}'));
        if (log.length > 500) log.removeRange(0, log.length - 500);
        await Db.bank.put('txn_log', log);
      }
      if (maxMs > 0) await _meta.put('cur:bank_txns', maxMs - 2000);
    }, onError: _fail));
  }

  Future<void> _apply(_Col c, String uid, Map<String, dynamic> data) async {
    final box = Hive.box(c.box);
    final kk = '${c.box}|$uid';
    final key = _uidToKey[kk];
    if (data['_del'] == true) {
      if (key != null) {
        _remoteDel.add(kk);
        await box.delete(key);
      }
      return;
    }
    final rec = Map<String, dynamic>.from(data)..remove('_st');
    final local = key == null ? null : _asMap(box.get(key));
    if (local != null &&
        _outbox.containsKey(kk) &&
        _num(local['_u']) >= _num(rec['_u'])) {
      // we have a newer unsent edit: keep our field values (last-writer-wins)
      for (final e in local.entries) {
        if (e.key != c.counter) rec[e.key] = e.value;
      }
    }
    if (c.counter != null) {
      final remote = _num(data[c.counter]);
      final lsKey = 'ls:$kk';
      final merged = local == null
          ? remote
          : _r(remote + (_num(local[c.counter]) - _num(_meta.get(lsKey))));
      rec[c.counter!] = c.counter == 'stock' ? merged.round() : merged;
      await _meta.put(lsKey, remote);
    }
    rec['_id'] = uid;
    final h = _hash(rec);
    if (local != null && _hash(local) == h) {
      _hashes[kk] = h;
      return; // idempotent re-delivery
    }
    _hashes[kk] = h; // set BEFORE write so the watcher treats it as remote
    await _meta.put('ph:$kk', h);
    if (key != null) {
      await box.put(key, rec);
    } else {
      final nk = await box.add(rec);
      _uidToKey[kk] = nk;
      _keyToUid['${c.box}|$nk'] = uid;
    }
  }

  // ---------------------------------------------------------------- status
  void _fail(Object e) {
    final s = '$e';
    final transient = s.contains('unavailable') ||
        s.contains('network') ||
        s.contains('timeout') ||
        s.contains('deadline');
    if (transient) {
      _online =
          false; // connectivity_plus only knows "has network", not "has internet"
      _retry?.cancel();
      _retry = Timer(const Duration(seconds: 20), () {
        _online = true;
        _begin();
      });
    } else {
      lastError = s;
    }
    _refreshState(error: !transient);
  }

  void _refreshState({bool error = false}) {
    if (!_running) return;
    final next = error || lastError != null
        ? SyncState.error
        : !_online
            ? SyncState.offline
            : (_flushing || (_boxesOpen && _outbox.isNotEmpty))
                ? SyncState.syncing
                : SyncState.synced;
    if (next != _state) {
      _state = next;
      notifyListeners();
    }
  }

  Future<void> syncNow() async {
    lastError = null;
    _online = true;
    await _begin();
    await _flush();
  }
}
