// =============================================================================
// TEKFIX ERP — SMART INVENTORY SEARCH ENGINE
// Version 2.0 Pro: High-Performance In-Memory Index, Offline-First & Live Sync
// =============================================================================

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import '../main.dart' show Db;
import 'smart_inventory_models.dart';

class SmartInventorySearchEngine extends ChangeNotifier {
  SmartInventorySearchEngine._();
  static final SmartInventorySearchEngine instance = SmartInventorySearchEngine._();

  final Map<String, InventorySearchItem> _itemsById = {};
  List<InventorySearchItem> _cachedList = [];
  bool _isInitialized = false;
  bool _isLoading = false;
  bool _isOffline = false;
  String? _lastError;
  String _currentShopId = '';
  StreamSubscription? _hiveSubscription;

  bool get isInitialized => _isInitialized;
  bool get isLoading => _isLoading;
  bool get isOffline => _isOffline;
  String? get lastError => _lastError;
  int get itemCount => _cachedList.length;

  /// Initializes the search index from local Hive cache first, then syncs with Cloud Firestore.
  Future<void> initialize({String? shopId, bool forceRefresh = false}) async {
    final targetShopId = (shopId != null && shopId.isNotEmpty)
        ? shopId.trim()
        : Db.setting('shop_id', 'tekfix');

    if (_isInitialized && !forceRefresh && _currentShopId == targetShopId && _itemsById.isNotEmpty) {
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

      // 3. CLOUD SYNC: Query Cloud Firestore shops/{shopId}/inventory in background
      await _syncWithFirestore(targetShopId);
    } catch (e) {
      debugPrint('[SmartInventorySearchEngine] Initialization error: $e');
      _lastError = e.toString();
      _isOffline = true;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Refreshes the local in-memory index from Hive and Firestore.
  Future<void> refresh() async {
    await initialize(shopId: _currentShopId, forceRefresh: true);
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

  Future<void> _syncWithFirestore(String shopId) async {
    if (Firebase.apps.isEmpty) {
      _isOffline = true;
      return;
    }

    try {
      final fs = FirebaseFirestore.instance;
      // Fetch products from shops/{shopId}/inventory with a 6-second timeout
      final snapshot = await fs
          .collection('shops')
          .doc(shopId)
          .collection('inventory')
          .get(const GetOptions(source: Source.serverAndCache))
          .timeout(const Duration(seconds: 6));

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

      _isOffline = true;
      _cachedList = _itemsById.values.toList();
    } catch (e) {
      debugPrint('[SmartInventorySearchEngine] Firestore sync warning (running offline): $e');
      _isOffline = true;
      // Do not clear _cachedList because Hive cache is already loaded!
    }
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
    _hiveSubscription?.cancel();
    super.dispose();
  }
}

class _ScoredItem {
  final InventorySearchItem item;
  final int score;
  _ScoredItem({required this.item, required this.score});
}

