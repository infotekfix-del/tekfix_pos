import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../main.dart' show Db;
import 'expense_models.dart';
import 'expense_service.dart';

class ExpenseDuplicateGroup {
  final String groupKey;
  final List<ExpenseItem> items;

  ExpenseDuplicateGroup({
    required this.groupKey,
    required this.items,
  });

  ExpenseItem get oldestItem => items.first;
  List<ExpenseItem> get duplicateItems => items.skip(1).toList();

  double get amount => oldestItem.amount;
  String get title => oldestItem.title;
  String get category => oldestItem.category;
  String get recordedByName => oldestItem.recordedByName;
  String get notes => oldestItem.notes;
}

class CleanupExecutionResult {
  final int groupsFound;
  final int documentsDeleted;
  final double amountCleaned;
  final ExpenseMetrics beforeMetrics;
  final ExpenseMetrics afterMetrics;

  const CleanupExecutionResult({
    required this.groupsFound,
    required this.documentsDeleted,
    required this.amountCleaned,
    required this.beforeMetrics,
    required this.afterMetrics,
  });
}

class ExpenseCleanupService {
  ExpenseCleanupService._();
  static final ExpenseCleanupService instance = ExpenseCleanupService._();

  /// Step 1: DRY RUN SCAN
  /// Scans expenses and groups duplicates by:
  /// same amount + category + staff/createdBy + same note,
  /// with createdAt within 5 seconds of each other.
  /// Never deletes anything in this step.
  Future<List<ExpenseDuplicateGroup>> scanDuplicates({
    required String shopId,
  }) async {
    final sId = shopId.isNotEmpty ? shopId : Db.setting('shop_id', 'tekfix');
    final allExpenses = await ExpenseService.instance.getAllExpenses(sId);

    final Map<String, List<ExpenseItem>> candidates = {};
    for (final exp in allExpenses) {
      if (exp.isVoided) continue;
      final key =
          '${exp.amount.toStringAsFixed(2)}|${exp.category.trim().toLowerCase()}|${exp.recordedByUid}|${exp.notes.trim().toLowerCase()}';
      candidates.putIfAbsent(key, () => []).add(exp);
    }

    final List<ExpenseDuplicateGroup> duplicateGroups = [];

    for (final entry in candidates.entries) {
      final list = entry.value;
      if (list.length < 2) continue;

      // Sort by creation timestamp
      list.sort((a, b) {
        final tA = a.createdAt ?? a.expenseDate;
        final tB = b.createdAt ?? b.expenseDate;
        return tA.compareTo(tB);
      });

      List<ExpenseItem> currentCluster = [list.first];
      for (int i = 1; i < list.length; i++) {
        final prev = currentCluster.last;
        final curr = list[i];
        final tPrev = prev.createdAt ?? prev.expenseDate;
        final tCurr = curr.createdAt ?? curr.expenseDate;

        if ((tCurr.difference(tPrev).inMilliseconds).abs() <= 5000) {
          currentCluster.add(curr);
        } else {
          if (currentCluster.length > 1) {
            duplicateGroups.add(ExpenseDuplicateGroup(
              groupKey: entry.key,
              items: List.from(currentCluster),
            ));
          }
          currentCluster = [curr];
        }
      }
      if (currentCluster.length > 1) {
        duplicateGroups.add(ExpenseDuplicateGroup(
          groupKey: entry.key,
          items: List.from(currentCluster),
        ));
      }
    }

    return duplicateGroups;
  }

  /// Step 2 & 3: CONFIRM & EXECUTE CLEANUP
  /// 1. Exports selected docs to `expense_cleanup_backup` with deletedAt + deletedBy
  /// 2. Deletes duplicates in atomic batches (max 500 ops per batch)
  /// 3. Recalculates today's and month's metrics, and updates cash/bank ledger
  Future<CleanupExecutionResult> executeCleanup({
    required String shopId,
    required List<String> duplicateDocIdsToDelete,
    required String deletedByUid,
    required String deletedByName,
  }) async {
    final sId = shopId.isNotEmpty ? shopId : Db.setting('shop_id', 'tekfix');
    final beforeMetrics =
        await ExpenseService.instance.computeExpenseMetrics(shopId: sId);

    if (duplicateDocIdsToDelete.isEmpty) {
      return CleanupExecutionResult(
        groupsFound: 0,
        documentsDeleted: 0,
        amountCleaned: 0.0,
        beforeMetrics: beforeMetrics,
        afterMetrics: beforeMetrics,
      );
    }

    double totalAmountCleaned = 0.0;
    final firestore =
        Firebase.apps.isNotEmpty ? FirebaseFirestore.instance : null;

    if (firestore != null) {
      final expensesCol =
          firestore.collection('shops').doc(sId).collection('expenses');
      final backupCol = firestore
          .collection('shops')
          .doc(sId)
          .collection('expense_cleanup_backup');
      final cashBankCol = firestore
          .collection('shops')
          .doc(sId)
          .collection('accounting_cash_bank');

      // Fetch documents to backup and calculate total cleaned
      final List<Map<String, dynamic>> toBackup = [];
      for (final docId in duplicateDocIdsToDelete) {
        try {
          final snap = await expensesCol.doc(docId).get();
          if (snap.exists && snap.data() != null) {
            final data = Map<String, dynamic>.from(snap.data()!);
            data['deletedAt'] = FieldValue.serverTimestamp();
            data['deletedByUid'] = deletedByUid;
            data['deletedByName'] = deletedByName;
            data['cleanupReason'] = 'Owner confirmed duplicate cleanup';
            toBackup.add({'id': docId, 'data': data});

            final amt = (data['amount'] as num?)?.toDouble() ?? 0.0;
            totalAmountCleaned += amt;
          }
        } catch (e) {
          debugPrint('[ExpenseCleanupService] Fetch doc for backup error: $e');
        }
      }

      // Execute in chunks of 250 (each doc does 1 backup + 1 expense delete = 2 ops, well under 500)
      const chunkSize = 200;
      for (int i = 0; i < toBackup.length; i += chunkSize) {
        final chunk = toBackup.skip(i).take(chunkSize).toList();
        final batch = firestore.batch();

        for (final item in chunk) {
          final docId = item['id'] as String;
          final data = item['data'] as Map<String, dynamic>;

          // 1. Export to backup collection
          batch.set(backupCol.doc(docId), data);

          // 2. Delete duplicate from expenses
          batch.delete(expensesCol.doc(docId));

          // 3. Remove orphaned ledger debit if present
          batch.delete(cashBankCol.doc('CB_EXP_$docId'));
        }

        await batch.commit();
      }
    }

    // Clean up local Hive mirror and restore ledger balance
    for (final docId in duplicateDocIdsToDelete) {
      if (Db.expenses.containsKey(docId)) {
        final raw = Db.expenses.get(docId);
        if (raw is Map) {
          final amt = (raw['amount'] as num?)?.toDouble() ?? 0.0;
          final mode = (raw['paymentMode'] ?? raw['mode'] ?? 'CASH').toString();
          // Restore money locally
          await Db.moveMoney(
            ExpensePaymentMode.toLedgerMode(mode),
            amt,
            'Duplicate Expense Cleanup Reversal (ID: $docId)',
          );
        }
        await Db.expenses.delete(docId);
      }
    }

    await Db.logAction(
      action: 'Expense Duplicates Cleaned',
      entity: 'Expense',
      reason: 'Deleted ${duplicateDocIdsToDelete.length} duplicates. Cleaned: ₹$totalAmountCleaned',
    );

    final afterMetrics =
        await ExpenseService.instance.computeExpenseMetrics(shopId: sId);

    return CleanupExecutionResult(
      groupsFound: duplicateDocIdsToDelete.length,
      documentsDeleted: duplicateDocIdsToDelete.length,
      amountCleaned: totalAmountCleaned,
      beforeMetrics: beforeMetrics,
      afterMetrics: afterMetrics,
    );
  }
}

