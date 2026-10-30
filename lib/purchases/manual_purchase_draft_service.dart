// =============================================================================
// TEKFIX ERP — MANUAL PURCHASE DRAFT SERVICE
// Auto-saves the in-progress manual purchase draft to Hive so that a crash,
// back-press or app restart never loses a half-entered bill.
// =============================================================================

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../main.dart' show Db, boxSettings;
import 'purchase_models.dart';

/// Lightweight draft model — stores only the raw JSON of each section.
/// Full model reconstruction happens when the user resumes.
class ManualPurchaseDraft {
  static const _hiveKey = 'manual_purchase_draft_v1';

  // ---- Supplier ----
  final dynamic vendorKey;
  final String vendorName;
  final String vendorPhone;
  final String vendorGst;
  final String vendorAddress;
  final String vendorState;

  // ---- Invoice ----
  final String billNumber;
  final String vendorInvoiceNumber;
  final DateTime purchaseDate;
  final String placeOfSupply;
  final String notes;
  final bool hasAttachment;

  // ---- Items (serialized) ----
  final List<Map<String, dynamic>> itemMaps;

  // ---- Charges ----
  final double otherCharges;
  final double otherChargesGstRate;

  // ---- Payment ----
  final double paidAmount;
  final String paymentMethod;
  final String paymentRef;
  final bool applyRoundOff;

  // ---- Meta ----
  final DateTime savedAt;
  final String draftId;

  ManualPurchaseDraft({
    this.vendorKey,
    this.vendorName = '',
    this.vendorPhone = '',
    this.vendorGst = '',
    this.vendorAddress = '',
    this.vendorState = '',
    this.billNumber = '',
    this.vendorInvoiceNumber = '',
    DateTime? purchaseDate,
    this.placeOfSupply = '',
    this.notes = '',
    this.hasAttachment = false,
    this.itemMaps = const [],
    this.otherCharges = 0.0,
    this.otherChargesGstRate = 0.0,
    this.paidAmount = 0.0,
    this.paymentMethod = 'Cash',
    this.paymentRef = '',
    this.applyRoundOff = true,
    DateTime? savedAt,
    String? draftId,
  })  : purchaseDate = purchaseDate ?? DateTime.now(),
        savedAt = savedAt ?? DateTime.now(),
        draftId = draftId ?? 'DRAFT_${DateTime.now().millisecondsSinceEpoch}';

  bool get hasData =>
      vendorName.isNotEmpty ||
      vendorInvoiceNumber.isNotEmpty ||
      itemMaps.isNotEmpty;

  List<PurchaseBillItem> get items => itemMaps
      .map((m) => PurchaseBillItem.fromMap(m))
      .toList();

  Map<String, dynamic> toJson() => {
        'vendorKey': vendorKey?.toString(),
        'vendorName': vendorName,
        'vendorPhone': vendorPhone,
        'vendorGst': vendorGst,
        'vendorAddress': vendorAddress,
        'vendorState': vendorState,
        'billNumber': billNumber,
        'vendorInvoiceNumber': vendorInvoiceNumber,
        'purchaseDate': purchaseDate.toIso8601String(),
        'placeOfSupply': placeOfSupply,
        'notes': notes,
        'hasAttachment': hasAttachment,
        'itemMaps': itemMaps,
        'otherCharges': otherCharges,
        'otherChargesGstRate': otherChargesGstRate,
        'paidAmount': paidAmount,
        'paymentMethod': paymentMethod,
        'paymentRef': paymentRef,
        'applyRoundOff': applyRoundOff,
        'savedAt': savedAt.toIso8601String(),
        'draftId': draftId,
      };

  factory ManualPurchaseDraft.fromJson(Map<String, dynamic> json) {
    return ManualPurchaseDraft(
      vendorKey: json['vendorKey'],
      vendorName: json['vendorName']?.toString() ?? '',
      vendorPhone: json['vendorPhone']?.toString() ?? '',
      vendorGst: json['vendorGst']?.toString() ?? '',
      vendorAddress: json['vendorAddress']?.toString() ?? '',
      vendorState: json['vendorState']?.toString() ?? '',
      billNumber: json['billNumber']?.toString() ?? '',
      vendorInvoiceNumber: json['vendorInvoiceNumber']?.toString() ?? '',
      purchaseDate: json['purchaseDate'] != null
          ? DateTime.tryParse(json['purchaseDate'].toString()) ?? DateTime.now()
          : DateTime.now(),
      placeOfSupply: json['placeOfSupply']?.toString() ?? '',
      notes: json['notes']?.toString() ?? '',
      hasAttachment: json['hasAttachment'] == true,
      itemMaps: (json['itemMaps'] is List)
          ? (json['itemMaps'] as List).map((e) {
              if (e is Map) return Map<String, dynamic>.from(e);
              return <String, dynamic>{};
            }).toList()
          : [],
      otherCharges: (json['otherCharges'] as num?)?.toDouble() ?? 0.0,
      otherChargesGstRate:
          (json['otherChargesGstRate'] as num?)?.toDouble() ?? 0.0,
      paidAmount: (json['paidAmount'] as num?)?.toDouble() ?? 0.0,
      paymentMethod: json['paymentMethod']?.toString() ?? 'Cash',
      paymentRef: json['paymentRef']?.toString() ?? '',
      applyRoundOff: json['applyRoundOff'] != false,
      savedAt: json['savedAt'] != null
          ? DateTime.tryParse(json['savedAt'].toString()) ?? DateTime.now()
          : DateTime.now(),
      draftId: json['draftId']?.toString() ??
          'DRAFT_${DateTime.now().millisecondsSinceEpoch}',
    );
  }
}

/// Service to persist and restore a single manual purchase draft.
class ManualPurchaseDraftService {
  ManualPurchaseDraftService._();
  static final ManualPurchaseDraftService instance =
      ManualPurchaseDraftService._();

  static const _key = ManualPurchaseDraft._hiveKey;

  Box get _box {
    try {
      return Hive.box(boxSettings);
    } catch (_) {
      return Db.settings;
    }
  }

  /// Saves [draft] to local Hive settings box.
  /// Call this whenever a meaningful field changes (debounced by caller).
  Future<void> save(ManualPurchaseDraft draft) async {
    try {
      final json = jsonEncode(draft.toJson());
      await _box.put(_key, json);
    } catch (e) {
      debugPrint('[ManualPurchaseDraftService] save error: $e');
    }
  }

  /// Loads the persisted draft. Returns null if none exists or deserialization fails.
  ManualPurchaseDraft? load() {
    try {
      final raw = _box.get(_key);
      if (raw == null) return null;
      final decoded = jsonDecode(raw.toString()) as Map<String, dynamic>;
      return ManualPurchaseDraft.fromJson(decoded);
    } catch (e) {
      debugPrint('[ManualPurchaseDraftService] load error: $e');
      return null;
    }
  }

  /// Checks whether a saved draft exists and has data worth restoring.
  bool hasDraft() {
    try {
      final draft = load();
      return draft != null && draft.hasData;
    } catch (_) {
      return false;
    }
  }

  /// Deletes the persisted draft. Call after a successful save.
  Future<void> delete() async {
    try {
      await _box.delete(_key);
    } catch (e) {
      debugPrint('[ManualPurchaseDraftService] delete error: $e');
    }
  }
}

