// =============================================================================
// TEKFIX ERP — SMART INVENTORY SEARCH ENGINE
// Version 2.0 Pro: High-Performance In-Memory Index, Offline-First & Live Sync
// =============================================================================

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import '../main.dart' show Db;
import 'smart_inventory_models.dart';

class SmartInventorySearchEngine extends ChangeNotifier {
  SmartInventorySearchEngine._();
  static final SmartInventorySearchEngine instance =
      SmartInventorySearchEngine._();

  final Map<String, InventorySearchItem> _itemsById = {};
  List<InventorySearchItem> _cachedList = [];
  bool _isInitialized = false;
  bool _isLoading = false;
  bool _isRefreshing = false;
  String? _lastError;
  String? _syncErrorMessage;
  InventorySyncState _syncState = InventorySyncState.syncing;
  String _currentShopId = '';
  StreamSubscription? _hiveSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
      _firestoreSubscription;

  bool get isInitialized => _isInitialized;
  bool get isLoading => _isLoading;
  bool get isRefreshing => _isRefreshing;
  InventorySyncState get syncState => _syncState;
  bool get isConnected => _syncState == InventorySyncState.connected;
  bool get isOffline => _syncState == InventorySyncState.offline;
  bool get isSyncing => _syncState == InventorySyncState.syncing;
  bool get hasSyncError => _syncState == InventorySyncState.error;
  String? get lastError => _lastError;
  String? get syncErrorMessage => _syncErrorMessage;
  String get currentShopId => _currentShopId;
  int get itemCount => _cachedList.length;

  /// Initializes the search index from local Hive cache first, then establishes live Firestore listener.
  Future<void> initialize({String? shopId, bool forceRefresh = false}) async {
    final targetShopId = (shopId != null && shopId.isNotEmpty)
        ? shopId.trim()
        : Db.setting('shop_id', 'tekfix');

    if (_isInitialized &&
        !forceRefresh &&
        _currentShopId == targetShopId &&
        _itemsById.isNotEmpty) {
      return;
    }

    _currentShopId = targetShopId;
    _isLoading = true;
    _lastError = null;
    notifyListeners();

    try {
      // 1. FAST LOCAL LOAD: Index all items in Hive Db.items (0ms latency)
      _loadFromLocalHive();
      _isInitialized = true;

      // 2. Setup reactive Hive listener to auto-refresh index on any local stock/product mutation
      _hiveSubscription?.cancel();
      if (Db.items.isOpen) {
        _hiveSubscription = Db.items.watch().listen((_) {
          _loadFromLocalHive();
          notifyListeners();
        });
      }

      // 3. REAL-TIME CLOUD SYNC: Listen to Firestore shops/{shopId}/inventory with metadata changes
      _setupFirestoreListener(targetShopId);
    } catch (e) {
      debugPrint('[SmartInventorySearchEngine] Initialization error: $e');
      _lastError = e.toString();
      _syncState = InventorySyncState.error;
      _syncErrorMessage = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Refreshes the local in-memory index from Hive and Firestore.
  Future<void> refresh() async {
    await forceServerRefresh();
  }

  void _loadFromLocalHive() {
    if (!Db.items.isOpen) return;

    for (final key in Db.items.keys) {
      final raw = Db.items.get(key);
      if (raw is! Map) continue;

      final id = (raw['_id'] ?? key).toString();
      final item = InventorySearchItem.fromMap(
        id: id,
        key: key,
        map: raw,
      );

      // Only index active and non-deleted items
      if (item.isActive && !item.isDeleted) {
        _itemsById[id] = item;
      } else {
        _itemsById.remove(id);
      }
    }

    _cachedList = _itemsById.values.toList();
  }

  /// Establishes real-time snapshot listener on shops/{shopId}/inventory with metadata detection.
  void _setupFirestoreListener(String shopId) {
    if (Firebase.apps.isEmpty) {
      _syncState = InventorySyncState.offline;
      debugPrint(
          '[SmartInventorySearchEngine] Firebase not initialized; running in offline mode.');
      return;
    }

    // Cancel existing listener before creating a new one to prevent leaks
    _firestoreSubscription?.cancel();
    _firestoreSubscription = null;
    _syncState = InventorySyncState.syncing;
    notifyListeners();

    try {
      final fs = FirebaseFirestore.instance;
      final user = FirebaseAuth.instance.currentUser;
      debugPrint(
          '[SmartInventorySearchEngine] Starting snapshot listener for shops/$shopId/inventory (Auth User: ${user?.uid ?? "Anonymous"})');

      final collectionRef =
          fs.collection('shops').doc(shopId).collection('inventory');

      _firestoreSubscription =
          collectionRef.snapshots(includeMetadataChanges: true).listen(
        (snapshot) {
          final isFromCache = snapshot.metadata.isFromCache;
          final hasPendingWrites = snapshot.metadata.hasPendingWrites;

          debugPrint(
            '[SmartInventorySearchEngine] Snapshot received: ${snapshot.docs.length} docs, '
            'isFromCache: $isFromCache, hasPendingWrites: $hasPendingWrites',
          );

          for (final doc in snapshot.docs) {
            final data = doc.data();
            final id = doc.id;
            final item = InventorySearchItem.fromMap(
              id: id,
              key: _itemsById[id]?.itemKey,
              map: data,
            );

            if (item.isActive && !item.isDeleted) {
              _itemsById[id] = item;
            } else {
              _itemsById.remove(id);
            }
          }

          _cachedList = _itemsById.values.toList();

          if (!isFromCache) {
            // Fresh server snapshot verified!
            _syncState = InventorySyncState.connected;
            _syncErrorMessage = null;
          } else {
            // Data is served from local Firestore cache; server response is pending
            _syncState = InventorySyncState.offline;
          }

          notifyListeners();
        },
        onError: (error) {
          debugPrint(
              '[SmartInventorySearchEngine] Firestore snapshot listener error: $error');
          _syncState = InventorySyncState.error;
          _syncErrorMessage = error.toString();
          notifyListeners();
        },
      );
    } catch (e) {
      debugPrint('[SmartInventorySearchEngine] Listener setup exception: $e');
      _syncState = InventorySyncState.error;
      _syncErrorMessage = e.toString();
      notifyListeners();
    }
  }

  /// Forces a fresh server-only fetch from Cloud Firestore (`Source.server`).
  Future<bool> forceServerRefresh() async {
    if (_isRefreshing) return false;
    _isRefreshing = true;
    _syncState = InventorySyncState.syncing;
    notifyListeners();

    try {
      if (Firebase.apps.isEmpty) {
        throw Exception('Firebase is not initialized');
      }

      final fs = FirebaseFirestore.instance;
      final shopId = _currentShopId.isNotEmpty
          ? _currentShopId
          : Db.setting('shop_id', 'tekfix');
      final user = FirebaseAuth.instance.currentUser;

      debugPrint(
          '[SmartInventorySearchEngine] Force refreshing server inventory for shops/$shopId/inventory (User: ${user?.uid})');

      final snapshot = await fs
          .collection('shops')
          .doc(shopId)
          .collection('inventory')
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 10));

      debugPrint(
          '[SmartInventorySearchEngine] Server refresh success: ${snapshot.docs.length} products loaded.');

      for (final doc in snapshot.docs) {
        final data = doc.data();
        final id = doc.id;
        final item = InventorySearchItem.fromMap(
          id: id,
          key: _itemsById[id]?.itemKey,
          map: data,
        );

        if (item.isActive && !item.isDeleted) {
          _itemsById[id] = item;
        } else {
          _itemsById.remove(id);
        }
      }

      _cachedList = _itemsById.values.toList();
      _syncState = InventorySyncState.connected;
      _syncErrorMessage = null;
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[SmartInventorySearchEngine] Server refresh failed: $e');
      _syncState = InventorySyncState.error;
      _syncErrorMessage = e.toString();
      notifyListeners();
      return false;
    } finally {
      _isRefreshing = false;
      notifyListeners();
    }
  }

  /// Cancels active Firestore and Hive subscriptions cleanly.
  void cancelListeners() {
    _firestoreSubscription?.cancel();
    _firestoreSubscription = null;
    _hiveSubscription?.cancel();
    _hiveSubscription = null;
    debugPrint('[SmartInventorySearchEngine] All listeners cancelled.');
  }

  /// Searches the in-memory inventory using multi-token matching and relevance scoring.
  List<InventorySearchItem> search(String query, {int limit = 25}) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      // Return top available products when query is empty
      return _cachedList.take(limit).toList();
    }

    final normQuery = InventorySearchItem.normalize(trimmed);
    final tokens = normQuery.split(' ').where((t) => t.isNotEmpty).toList();

    final matches = <_ScoredItem>[];

    for (final item in _cachedList) {
      if (item.matchesTokens(tokens)) {
        final score = item.matchScore(tokens, trimmed);
        matches.add(_ScoredItem(item: item, score: score));
      }
    }

    // Sort descending by relevance score
    matches.sort((a, b) => b.score.compareTo(a.score));

    return matches.take(limit).map((m) => m.item).toList();
  }

  /// Looks up an exact matching product by Barcode or SKU for instant scanner selection.
  InventorySearchItem? findExactBarcodeOrSku(String code) {
    final clean = code.trim().toLowerCase();
    if (clean.isEmpty) return null;

    for (final item in _cachedList) {
      if (item.barcode.trim().toLowerCase() == clean ||
          item.sku.trim().toLowerCase() == clean) {
        return item;
      }
    }
    return null;
  }

  @override
  void dispose() {
    cancelListeners();
    super.dispose();
  }
}

class _ScoredItem {
  final InventorySearchItem item;
  final int score;
  _ScoredItem({required this.item, required this.score});
}
