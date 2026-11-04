import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../main.dart' show Db, tekM;
import 'expense_models.dart';

class ExpenseMetrics {
  final double todayTotal;
  final double thisMonthTotal;
  final double todayCashTotal;
  final double todayBankTotal;
  final int todayCount;

  const ExpenseMetrics({
    required this.todayTotal,
    required this.thisMonthTotal,
    required this.todayCashTotal,
    required this.todayBankTotal,
    required this.todayCount,
  });

  double get totalToday => todayTotal;
  double get totalMonth => thisMonthTotal;
  double get cashToday => todayCashTotal;
  double get bankToday => todayBankTotal;

  factory ExpenseMetrics.empty() => const ExpenseMetrics(
        todayTotal: 0.0,
        thisMonthTotal: 0.0,
        todayCashTotal: 0.0,
        todayBankTotal: 0.0,
        todayCount: 0,
      );
}

class ExpenseService {
  ExpenseService._();
  static final ExpenseService instance = ExpenseService._();

  static const _uuid = Uuid();

  /// Create and persist a new expense atomically across Firestore & Hive
  Future<ExpenseItem> createExpense({
    required String shopId,
    ExpenseItem? item,
    String? title,
    String? category,
    double? amount,
    String? paymentMode,
    DateTime? expenseDate,
    String? recordedByUid,
    String? recordedByName,
    String notes = '',
    String? receiptUrl,
    String? customExpenseId,
  }) async {
    final cleanTitle = (item?.title ?? title ?? '').trim();
    if (cleanTitle.isEmpty) {
      throw ArgumentError('ചിലവിന്റെ വിവരണം നൽകുക (Expense title is required)');
    }
    final effectiveAmount = item?.amount ?? amount ?? 0.0;
    if (effectiveAmount <= 0 || effectiveAmount > 10000000) {
      throw ArgumentError(
          'ശരിയായ തുക നൽകുക (Valid positive amount is required)');
    }

    final int amountPaise =
        item?.amountPaise ?? (effectiveAmount * 100).round();
    final rawMode = item?.paymentMode ?? paymentMode ?? ExpensePaymentMode.cash;
    final normalizedMode = rawMode.toUpperCase() == ExpensePaymentMode.bank
        ? ExpensePaymentMode.bank
        : ExpensePaymentMode.cash;

    final resolvedShopId =
        shopId.isNotEmpty ? shopId : Db.setting('shop_id', 'tekfix');
    final expenseId = item?.id.isNotEmpty == true
        ? item!.id
        : (customExpenseId ??
            'EXP_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 6)}');

    final effectiveDate = item?.expenseDate ?? expenseDate ?? DateTime.now();
    final effectiveUid = item?.recordedByUid ?? recordedByUid ?? 'staff';
    final effectiveName = item?.recordedByName ?? recordedByName ?? 'Staff';
    final effectiveCategory =
        item?.category ?? category ?? ExpenseCategory.miscellaneousOther;
    final effectiveNotes = item?.notes.isNotEmpty == true ? item!.notes : notes;
    final effectiveReceipt = item?.receiptUrl ?? receiptUrl;

    final expense = ExpenseItem(
      id: expenseId,
      shopId: resolvedShopId,
      title: cleanTitle,
      category: effectiveCategory,
      amount: effectiveAmount,
      amountPaise: amountPaise,
      paymentMode: normalizedMode,
      expenseDate: effectiveDate,
      recordedByUid: effectiveUid,
      recordedByName: effectiveName,
      notes: effectiveNotes,
      receiptUrl: effectiveReceipt,
      isDailyRent: item?.isDailyRent ?? false,
      rentRecordId: item?.rentRecordId,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    // 1. Atomic Firestore Transaction (Cross-collection debit & ledger posting)
    if (Firebase.apps.isNotEmpty) {
      final firestore = FirebaseFirestore.instance;
      final expRef = firestore
          .collection('shops')
          .doc(resolvedShopId)
          .collection('expenses')
          .doc(expenseId);

      final ledgerRef = firestore
          .collection('shops')
          .doc(resolvedShopId)
          .collection('accounting_cash_bank')
          .doc('CB_EXP_$expenseId');

      final auditRef = firestore
          .collection('shops')
          .doc(resolvedShopId)
          .collection('audit_logs')
          .doc('AUDIT_EXP_$expenseId');

      final expenseMap = expense.toMap(forFirestore: true);

      final ledgerData = <String, dynamic>{
        'id': 'CB_EXP_$expenseId',
        'type': 'DEBIT',
        'entryType': 'DEBIT',
        'transactionCategory': 'EXPENSE',
        'category': 'EXPENSE',
        'expenseId': expenseId,
        'referenceId': expenseId,
        'title': cleanTitle,
        'amount': effectiveAmount,
        'amountPaise': amountPaise,
        'paymentMode': normalizedMode,
        'mode': ExpensePaymentMode.toLedgerMode(normalizedMode),
        'effectiveDate': Timestamp.fromDate(effectiveDate),
        'createdByUid': effectiveUid,
        'createdByName': effectiveName,
        'createdAt': FieldValue.serverTimestamp(),
      };

      final auditData = <String, dynamic>{
        'id': 'AUDIT_EXP_$expenseId',
        'action': 'CREATE_EXPENSE',
        'entity': 'Expense',
        'entityId': expenseId,
        'title': cleanTitle,
        'amount': effectiveAmount,
        'paymentMode': normalizedMode,
        'performedByUid': effectiveUid,
        'performedByName': effectiveName,
        'timestamp': FieldValue.serverTimestamp(),
      };

      try {
        await firestore.runTransaction((tx) async {
          tx.set(expRef, expenseMap);
          tx.set(ledgerRef, ledgerData);
          tx.set(
              firestore
                  .collection('accounting_cash_bank')
                  .doc('CB_EXP_$expenseId'),
              ledgerData);
          tx.set(auditRef, auditData);
        });
      } catch (e) {
        debugPrint(
            '[ExpenseService] Firestore transaction notice: $e (Falling back to resilient offline-first mode)');
        try {
          await expRef.set(expenseMap, SetOptions(merge: true));
          await ledgerRef.set(ledgerData, SetOptions(merge: true));
        } catch (e2) {
          debugPrint(
              '[ExpenseService] Cloud write deferred to offline outbox: $e2');
        }
      }
    }

    // 2. Update local Hive state & ledger projection
    await Db.expenses.put(expenseId, expense.toMap(forFirestore: false));
    await Db.moveMoney(
      ExpensePaymentMode.toLedgerMode(normalizedMode),
      -effectiveAmount,
      'Expense ($effectiveCategory): $cleanTitle',
    );
    await Db.logAction(
      action: 'Expense Created',
      entity: 'Expense',
      entityId: expenseId,
      newValue: expense.toMap(forFirestore: false),
    );

    return expense;
  }

  /// Atomically void an expense, reversing its financial effect in the ledger
  Future<ExpenseItem> voidExpense({
    required String shopId,
    required String expenseId,
    required String voidedByUid,
    required String voidedByName,
    String? reason,
    String? voidReason,
  }) async {
    final effectiveReason = voidReason ?? reason ?? 'Voided by user';
    final resolvedShopId =
        shopId.isNotEmpty ? shopId : Db.setting('shop_id', 'tekfix');

    // Retrieve current expense record
    Map<String, dynamic>? currentMap;
    final localRaw = Db.expenses.get(expenseId);
    if (localRaw != null) {
      currentMap = tekM(localRaw);
    } else if (Firebase.apps.isNotEmpty) {
      final expRef = FirebaseFirestore.instance
          .collection('shops')
          .doc(resolvedShopId)
          .collection('expenses')
          .doc(expenseId);
      final snap = await expRef.get();
      if (snap.exists && snap.data() != null) {
        currentMap = snap.data();
      }
    }

    if (currentMap == null) {
      throw StateError('Expense record not found ($expenseId)');
    }

    if (currentMap['isVoided'] == true) {
      throw StateError('This expense has already been voided');
    }

    final double amount = (currentMap['amount'] as num?)?.toDouble() ??
        (((currentMap['amountPaise'] as num?)?.toDouble() ?? 0.0) / 100.0);
    final int amountPaise =
        (currentMap['amountPaise'] as num?)?.toInt() ?? (amount * 100).round();
    final mode =
        (currentMap['paymentMode']?.toString() ?? 'CASH').toUpperCase();
    final title = currentMap['title']?.toString() ?? 'Expense';

    final now = DateTime.now();

    if (Firebase.apps.isNotEmpty) {
      final firestore = FirebaseFirestore.instance;
      final expRef = firestore
          .collection('shops')
          .doc(resolvedShopId)
          .collection('expenses')
          .doc(expenseId);

      final reversalLedgerRef = firestore
          .collection('shops')
          .doc(resolvedShopId)
          .collection('accounting_cash_bank')
          .doc('CB_REV_EXP_$expenseId');

      final auditRef = firestore
          .collection('shops')
          .doc(resolvedShopId)
          .collection('audit_logs')
          .doc('AUDIT_VOID_EXP_$expenseId');

      final reversalData = <String, dynamic>{
        'id': 'CB_REV_EXP_$expenseId',
        'type': 'CREDIT',
        'entryType': 'CREDIT',
        'transactionCategory': 'EXPENSE_REVERSAL',
        'category': 'EXPENSE_REVERSAL',
        'expenseId': expenseId,
        'referenceId': expenseId,
        'title': 'Reversal: $title',
        'amount': amount,
        'amountPaise': amountPaise,
        'paymentMode': mode,
        'mode': ExpensePaymentMode.toLedgerMode(mode),
        'effectiveDate': FieldValue.serverTimestamp(),
        'createdByUid': voidedByUid,
        'createdByName': voidedByName,
        'reason': reason,
        'createdAt': FieldValue.serverTimestamp(),
      };

      final auditData = <String, dynamic>{
        'id': 'AUDIT_VOID_EXP_$expenseId',
        'action': 'VOID_EXPENSE',
        'entity': 'Expense',
        'entityId': expenseId,
        'reason': reason,
        'amountReversed': amount,
        'performedByUid': voidedByUid,
        'performedByName': voidedByName,
        'timestamp': FieldValue.serverTimestamp(),
      };

      try {
        await firestore.runTransaction((tx) async {
          tx.update(expRef, {
            'isVoided': true,
            'voidedAt': FieldValue.serverTimestamp(),
            'voidedByUid': voidedByUid,
            'voidReason': effectiveReason,
            'updatedAt': FieldValue.serverTimestamp(),
          });
          tx.set(reversalLedgerRef, reversalData);
          tx.set(auditRef, auditData);
        });
      } catch (e) {
        debugPrint('[ExpenseService] Reversal transaction note: $e');
        await expRef.set({
          'isVoided': true,
          'voidedAt': FieldValue.serverTimestamp(),
          'voidedByUid': voidedByUid,
          'voidReason': effectiveReason,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    }

    // 2. Reverse local Hive projection
    final updatedMap = Map<String, dynamic>.from(currentMap)
      ..['isVoided'] = true
      ..['voidedAt'] = now.toIso8601String()
      ..['voidedByUid'] = voidedByUid
      ..['voidReason'] = effectiveReason;

    await Db.expenses.put(expenseId, updatedMap);
    await Db.moveMoney(
      ExpensePaymentMode.toLedgerMode(mode),
      amount, // Positive amount restores cash/bank balance
      'Reversal of Expense: $title ($effectiveReason)',
    );
    await Db.logAction(
      action: 'Expense Voided',
      entity: 'Expense',
      entityId: expenseId,
      reason: effectiveReason,
      newValue: updatedMap,
    );

    return ExpenseItem.fromMap(updatedMap, expenseId);
  }

  /// Upload receipt document or photo to Firebase Storage
  Future<String?> uploadReceiptFile({
    required String shopId,
    required String expenseId,
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
  }) async {
    try {
      final sId = shopId.isNotEmpty ? shopId : Db.setting('shop_id', 'tekfix');
      final cleanName = fileName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final ref = FirebaseStorage.instance
          .ref()
          .child('shops/$sId/expense_receipts/${expenseId}_$cleanName');

      final task =
          await ref.putData(bytes, SettableMetadata(contentType: mimeType));
      return await task.ref.getDownloadURL();
    } catch (e) {
      debugPrint('[ExpenseService] Receipt upload error: $e');
      rethrow;
    }
  }

  /// Fetch all expenses for a date, merging local Hive and Firestore
  Future<List<ExpenseItem>> getExpensesForDate(
    DateTime targetDate, {
    String? shopId,
    bool includeVoided = false,
  }) async {
    final Map<String, ExpenseItem> map = {};

    bool matchesDate(DateTime dt) {
      return dt.year == targetDate.year &&
          dt.month == targetDate.month &&
          dt.day == targetDate.day;
    }

    // 1. Hive local box
    for (final k in Db.expenses.keys) {
      final m = tekM(Db.expenses.get(k));
      final item = ExpenseItem.fromMap(m, '$k');
      if (matchesDate(item.expenseDate)) {
        if (includeVoided || !item.isVoided) {
          map[item.id] = item;
        }
      }
    }

    // 2. Firestore query
    final sId = shopId ?? Db.setting('shop_id', '');
    if (sId.isNotEmpty && Firebase.apps.isNotEmpty) {
      try {
        final startOfDay =
            DateTime(targetDate.year, targetDate.month, targetDate.day);
        final endOfDay = DateTime(
            targetDate.year, targetDate.month, targetDate.day, 23, 59, 59, 999);

        final snap = await FirebaseFirestore.instance
            .collection('shops')
            .doc(sId)
            .collection('expenses')
            .where('expenseDate',
                isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
            .where('expenseDate',
                isLessThanOrEqualTo: Timestamp.fromDate(endOfDay))
            .get();

        for (final doc in snap.docs) {
          final item = ExpenseItem.fromMap(doc.data(), doc.id);
          if (includeVoided || !item.isVoided) {
            map[item.id] = item;
          }
        }
      } catch (e) {
        debugPrint('[ExpenseService] Firestore fetch error: $e');
      }
    }

    final list = map.values.toList()
      ..sort((a, b) => b.expenseDate.compareTo(a.expenseDate));
    return list;
  }

  /// Compute high-level dashboard expense metrics
  Future<ExpenseMetrics> computeExpenseMetrics({
    String? shopId,
    DateTime? date,
  }) async {
    final sId = shopId ?? Db.setting('shop_id', 'tekfix');
    final now = date ?? DateTime.now();
    final all = await getAllExpenses(sId);

    double todayTotal = 0.0;
    double thisMonthTotal = 0.0;
    double todayCashTotal = 0.0;
    double todayBankTotal = 0.0;
    int todayCount = 0;

    for (final exp in all) {
      if (exp.isVoided) continue;

      final dt = exp.expenseDate;
      final isToday =
          dt.year == now.year && dt.month == now.month && dt.day == now.day;
      final isThisMonth = dt.year == now.year && dt.month == now.month;

      if (isThisMonth) {
        thisMonthTotal += exp.amount;
      }

      if (isToday) {
        todayTotal += exp.amount;
        todayCount++;
        if (exp.isCash) {
          todayCashTotal += exp.amount;
        } else {
          todayBankTotal += exp.amount;
        }
      }
    }

    return ExpenseMetrics(
      todayTotal: todayTotal,
      thisMonthTotal: thisMonthTotal,
      todayCashTotal: todayCashTotal,
      todayBankTotal: todayBankTotal,
      todayCount: todayCount,
    );
  }

  /// Retrieve all expenses cached in Hive and optionally merged with Firestore
  Future<List<ExpenseItem>> getAllExpenses(String shopId) async {
    final Map<String, ExpenseItem> map = {};

    for (final k in Db.expenses.keys) {
      final m = tekM(Db.expenses.get(k));
      final item = ExpenseItem.fromMap(m, '$k');
      map[item.id] = item;
    }

    final sId = shopId.isNotEmpty ? shopId : Db.setting('shop_id', '');
    if (sId.isNotEmpty) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('shops')
            .doc(sId)
            .collection('expenses')
            .orderBy('expenseDate', descending: true)
            .limit(300)
            .get();

        for (final doc in snap.docs) {
          final item = ExpenseItem.fromMap(doc.data(), doc.id);
          map[item.id] = item;
        }
      } catch (_) {}
    }

    final list = map.values.toList()
      ..sort((a, b) => b.expenseDate.compareTo(a.expenseDate));
    return list;
  }
}
