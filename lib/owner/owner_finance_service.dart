import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../main.dart' show Db, tekM;
import 'owner_finance_models.dart';

class OwnerFinanceService {
  OwnerFinanceService._();
  static final OwnerFinanceService instance = OwnerFinanceService._();
  final _uuid = const Uuid();

  static String toDateKey(DateTime dt) {
    return DateFormat('yyyy-MM-dd').format(dt);
  }

  static String toDisplayDate(DateTime dt) {
    return DateFormat('dd MMM yyyy').format(dt);
  }

  /// Retrieve Owner Salary Configuration from Hive (local offline) and Firestore
  Future<OwnerSalarySettings> getSettings({String? shopId}) async {
    final sId = shopId ?? Db.setting('shop_id', 'tekfix');

    // 1. Hive local box
    final raw = Db.settings.get('owner_salary_settings');
    OwnerSalarySettings settings;
    if (raw != null && raw is Map) {
      settings = OwnerSalarySettings.fromMap(Map<String, dynamic>.from(raw));
    } else {
      settings = OwnerSalarySettings(effectiveDate: DateTime(2026, 1, 1));
    }

    // 2. Fetch from Firestore if available
    if (sId.isNotEmpty && Firebase.apps.isNotEmpty) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('shops')
            .doc(sId)
            .collection('settings')
            .doc('owner_salary')
            .get();
        if (doc.exists && doc.data() != null) {
          settings = OwnerSalarySettings.fromMap(doc.data()!);
          await Db.settings.put('owner_salary_settings', settings.toMap());
        }
      } catch (e) {
        debugPrint('[OwnerFinanceService] Failed fetching remote owner salary settings: $e');
      }
    }

    return settings;
  }

  /// Save Owner Salary Configuration with audit tracking
  Future<OwnerSalarySettings> saveSettings({
    required String shopId,
    required OwnerSalarySettings newSettings,
    required String staffId,
    required String staffName,
  }) async {
    final sId = shopId.isNotEmpty ? shopId : Db.setting('shop_id', 'tekfix');
    final current = await getSettings(shopId: sId);

    OwnerSalarySettings toSave = newSettings;
    if (current.monthlySalaryLimit != newSettings.monthlySalaryLimit) {
      final historyItem = OwnerSalaryRateHistoryItem(
        effectiveDate: current.effectiveDate,
        limitAmount: current.monthlySalaryLimit,
        limitAmountPaise: current.monthlySalaryLimitPaise,
        changedByUid: staffId,
        changedByName: staffName,
        changedAt: DateTime.now(),
      );
      final updatedHistory = List<OwnerSalaryRateHistoryItem>.from(current.rateHistory)
        ..add(historyItem);
      toSave = newSettings.copyWith(rateHistory: updatedHistory);
    }

    await Db.settings.put('owner_salary_settings', toSave.toMap());

    if (sId.isNotEmpty && Firebase.apps.isNotEmpty) {
      try {
        final firestore = FirebaseFirestore.instance;
        await firestore
            .collection('shops')
            .doc(sId)
            .collection('settings')
            .doc('owner_salary')
            .set(toSave.toMap(), SetOptions(merge: true));

        await firestore
            .collection('shops')
            .doc(sId)
            .collection('audit_logs')
            .add({
          'action': 'OWNER_SALARY_SETTINGS_UPDATED',
          'category': 'OWNER_SALARY',
          'details': 'Updated monthly owner salary limit to ₹${toSave.monthlySalaryLimit}',
          'staffId': staffId,
          'staffName': staffName,
          'timestamp': FieldValue.serverTimestamp(),
          'createdAt': DateTime.now().toIso8601String(),
        });
      } catch (e) {
        debugPrint('[OwnerFinanceService] Save settings firestore error: $e');
      }
    }

    return toSave;
  }

  /// Retrieve all owner withdrawal items for a month across Hive & Firestore
  Future<List<OwnerWithdrawalItem>> getWithdrawalsForMonth(
    DateTime targetMonth, {
    String? shopId,
    bool includeVoided = false,
  }) async {
    final sId = shopId ?? Db.setting('shop_id', 'tekfix');
    final startOfMonth = DateTime(targetMonth.year, targetMonth.month, 1, 0, 0, 0);
    final daysInMonth = DateTime(targetMonth.year, targetMonth.month + 1, 0).day;
    final endOfMonth = DateTime(targetMonth.year, targetMonth.month, daysInMonth, 23, 59, 59, 999);

    final Map<String, OwnerWithdrawalItem> map = {};

    // 1. Hive local storage scan
    for (final k in Db.settings.keys) {
      final keyStr = k.toString();
      if (keyStr.startsWith('owner_wth_')) {
        final raw = Db.settings.get(keyStr);
        if (raw is Map) {
          final item = OwnerWithdrawalItem.fromMap(Map<String, dynamic>.from(raw), keyStr);
          if (!item.date.isBefore(startOfMonth) && !item.date.isAfter(endOfMonth)) {
            if (includeVoided || !item.isVoided) {
              map[item.id] = item;
            }
          }
        }
      }
    }

    // 2. Remote Firestore query if online
    if (sId.isNotEmpty && Firebase.apps.isNotEmpty) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('shops')
            .doc(sId)
            .collection('owner_withdrawals')
            .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfMonth))
            .where('date', isLessThanOrEqualTo: Timestamp.fromDate(endOfMonth))
            .get();

        for (final doc in snap.docs) {
          final item = OwnerWithdrawalItem.fromMap(doc.data(), doc.id);
          if (includeVoided || !item.isVoided) {
            map[item.id] = item;
          }
        }
      } catch (e) {
        debugPrint('[OwnerFinanceService] getWithdrawalsForMonth error: $e');
      }
    }

    final list = map.values.toList()..sort((a, b) => b.date.compareTo(a.date));
    return list;
  }

  /// Retrieve owner withdrawals for a specific single business date
  Future<List<OwnerWithdrawalItem>> getWithdrawalsForDate(
    DateTime date, {
    String? shopId,
    bool includeVoided = false,
  }) async {
    final dKey = toDateKey(date);
    final monthList = await getWithdrawalsForMonth(date, shopId: shopId, includeVoided: includeVoided);
    return monthList.where((w) => w.dateKey == dKey).toList();
  }

  /// Calculate live month-to-date (MTD) quota metrics
  Future<OwnerMonthlyQuotaMetrics> getQuotaMetrics({
    String? shopId,
    DateTime? forDate,
  }) async {
    final sId = shopId ?? Db.setting('shop_id', 'tekfix');
    final target = forDate ?? DateTime.now();
    final settings = await getSettings(shopId: sId);
    final withdrawals = await getWithdrawalsForMonth(target, shopId: sId, includeVoided: false);

    double usedSalary = 0.0;
    double excessDrawings = 0.0;
    int count = 0;

    for (final w in withdrawals) {
      usedSalary += w.salaryPortion;
      excessDrawings += w.drawingsPortion;
      count++;
    }

    final limit = settings.monthlySalaryLimit;
    final remainingSalary = (limit - usedSalary).clamp(0.0, limit);
    final totalWithdrawn = usedSalary + excessDrawings;

    return OwnerMonthlyQuotaMetrics(
      month: target,
      monthlyLimit: limit,
      usedSalaryThisMonth: usedSalary,
      remainingSalaryThisMonth: remainingSalary,
      excessDrawingsThisMonth: excessDrawings,
      totalWithdrawnThisMonth: totalWithdrawn,
      totalWithdrawalsCount: count,
    );
  }

  /// Record an owner cash or bank withdrawal with automatic salary vs drawings split
  Future<OwnerWithdrawalItem> recordWithdrawal({
    required String shopId,
    required double amount,
    required String paymentMode, // CASH or BANK
    required String recordedByUid,
    required String recordedByName,
    DateTime? date,
    String notes = '',
  }) async {
    if (amount <= 0) {
      throw ArgumentError('ശരിയായ തുക നൽകുക (Valid positive withdrawal amount is required)');
    }

    final sId = shopId.isNotEmpty ? shopId : Db.setting('shop_id', 'tekfix');
    final txDate = date ?? DateTime.now();
    final dateKey = toDateKey(txDate);
    final normalizedMode = paymentMode.toUpperCase() == 'BANK' ? 'BANK' : 'CASH';

    // 1. DYNAMIC AUTO-CLASSIFICATION & AUTO-SPLIT LOGIC
    final metrics = await getQuotaMetrics(shopId: sId, forDate: txDate);
    final remainingSalaryQuota = metrics.remainingSalaryThisMonth;

    double salaryPortion = 0.0;
    double drawingsPortion = 0.0;

    if (remainingSalaryQuota <= 0) {
      // Quota already exhausted: 100% Owner Drawings (Equity deduction)
      salaryPortion = 0.0;
      drawingsPortion = amount;
    } else if (amount <= remainingSalaryQuota) {
      // Full amount fits within remaining quota: 100% Owner Salary (OPEX)
      salaryPortion = amount;
      drawingsPortion = 0.0;
    } else {
      // Crosses threshold midway: split transaction
      salaryPortion = remainingSalaryQuota;
      drawingsPortion = amount - remainingSalaryQuota;
    }

    final int totalPaise = (amount * 100).round();
    final int salaryPaise = (salaryPortion * 100).round();
    final int drawingsPaise = (drawingsPortion * 100).round();

    final withdrawalId = 'OWN_WTH_${txDate.millisecondsSinceEpoch}_${_uuid.v4().substring(0, 5)}';
    final expenseId = salaryPortion > 0 ? 'EXP_OWN_SAL_$withdrawalId' : null;
    final ledgerTxId = 'CB_OWN_WTH_$withdrawalId';

    final withdrawalItem = OwnerWithdrawalItem(
      id: withdrawalId,
      shopId: sId,
      date: txDate,
      dateKey: dateKey,
      totalAmount: amount,
      totalAmountPaise: totalPaise,
      salaryPortion: salaryPortion,
      salaryPortionPaise: salaryPaise,
      drawingsPortion: drawingsPortion,
      drawingsPortionPaise: drawingsPaise,
      paymentMode: normalizedMode,
      recordedByUid: recordedByUid,
      recordedByName: recordedByName,
      notes: notes.trim(),
      isVoided: false,
      expenseId: expenseId,
      ledgerTxId: ledgerTxId,
      createdAt: DateTime.now(),
    );

    // 2. PREPARE FIRESTORE DATA
    final withdrawalMap = withdrawalItem.toMap(forFirestore: true);

    // Linked General Expense object (for P&L OPEX reporting)
    Map<String, dynamic>? expenseMap;
    if (salaryPortion > 0 && expenseId != null) {
      expenseMap = {
        'id': expenseId,
        'shopId': sId,
        'title': 'Shop Owner Salary - $dateKey',
        'category': 'Shop Owner Salary',
        'amount': salaryPortion,
        'amountPaise': salaryPaise,
        'paymentMode': normalizedMode,
        'expenseDate': Timestamp.fromDate(txDate),
        'recordedByUid': recordedByUid,
        'recordedByName': recordedByName,
        'notes': notes.isNotEmpty
            ? 'Owner Salary ($dateKey): $notes'
            : 'Owner Monthly Salary allocation ($dateKey)',
        'isVoided': false,
        'isOwnerWithdrawal': true,
        'withdrawalId': withdrawalId,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };
    }

    // Ledger Debit entry
    final ledgerMap = {
      'txId': ledgerTxId,
      'shopId': sId,
      'type': 'DEBIT',
      'transactionCategory': 'OWNER_WITHDRAWAL',
      'amount': amount,
      'amountPaise': totalPaise,
      'salaryPortion': salaryPortion,
      'drawingsPortion': drawingsPortion,
      'paymentMode': normalizedMode,
      'effectiveDate': dateKey,
      'withdrawalId': withdrawalId,
      'createdByUid': recordedByUid,
      'createdByName': recordedByName,
      'createdAt': FieldValue.serverTimestamp(),
      'description': salaryPortion > 0 && drawingsPortion > 0
          ? 'Owner Withdrawal: ₹${salaryPortion.toStringAsFixed(0)} Salary + ₹${drawingsPortion.toStringAsFixed(0)} Drawings'
          : (salaryPortion > 0
              ? 'Owner Salary Withdrawal: ₹${salaryPortion.toStringAsFixed(0)}'
              : 'Owner Excess Drawings: ₹${drawingsPortion.toStringAsFixed(0)}'),
    };

    // 3. PERSIST TO FIRESTORE (ATOMIC WRITE)
    if (sId.isNotEmpty && Firebase.apps.isNotEmpty) {
      try {
        final firestore = FirebaseFirestore.instance;
        final batch = firestore.batch();

        final wthRef = firestore
            .collection('shops')
            .doc(sId)
            .collection('owner_withdrawals')
            .doc(withdrawalId);
        batch.set(wthRef, withdrawalMap);

        if (expenseMap != null && expenseId != null) {
          final expRef = firestore
              .collection('shops')
              .doc(sId)
              .collection('expenses')
              .doc(expenseId);
          batch.set(expRef, expenseMap);
        }

        final ledgerRef = firestore
            .collection('shops')
            .doc(sId)
            .collection('accounting_cash_bank')
            .doc(ledgerTxId);
        batch.set(ledgerRef, ledgerMap);

        final auditRef = firestore
            .collection('shops')
            .doc(sId)
            .collection('audit_logs')
            .doc();
        batch.set(auditRef, {
          'action': 'OWNER_WITHDRAWAL_RECORDED',
          'category': 'OWNER_WITHDRAWAL',
          'details': 'Withdrew ₹$amount ($normalizedMode): ₹$salaryPortion Salary + ₹$drawingsPortion Drawings',
          'withdrawalId': withdrawalId,
          'totalAmount': amount,
          'salaryPortion': salaryPortion,
          'drawingsPortion': drawingsPortion,
          'paymentMode': normalizedMode,
          'staffId': recordedByUid,
          'staffName': recordedByName,
          'timestamp': FieldValue.serverTimestamp(),
          'createdAt': DateTime.now().toIso8601String(),
        });

        await batch.commit();
      } catch (e) {
        debugPrint('[OwnerFinanceService] Firestore batch commit error: $e');
      }
    }

    // 4. UPDATE LOCAL HIVE STATE & SINGLE LEDGER DEBIT
    await Db.settings.put('owner_wth_$withdrawalId', withdrawalItem.toMap(forFirestore: false));

    if (expenseMap != null && expenseId != null) {
      await Db.expenses.put(expenseId, {
        ...expenseMap,
        'expenseDate': txDate.toIso8601String(),
        'createdAt': DateTime.now().toIso8601String(),
        'updatedAt': DateTime.now().toIso8601String(),
      });
    }

    // Single unified financial debit to Cash in Hand or Bank Balance
    final ledgerMode = withdrawalItem.isCash ? 'Cash' : 'Bank';
    final desc = salaryPortion > 0 && drawingsPortion > 0
        ? 'Owner Withdrawal: ₹${salaryPortion.toStringAsFixed(0)} Salary + ₹${drawingsPortion.toStringAsFixed(0)} Drawings'
        : (salaryPortion > 0
            ? 'Owner Salary Withdrawal: ₹${salaryPortion.toStringAsFixed(0)}'
            : 'Owner Excess Drawings: ₹${drawingsPortion.toStringAsFixed(0)}');

    await Db.moveMoney(ledgerMode, -amount, desc);

    await Db.logAction(
      action: 'Owner Withdrawal Recorded',
      entity: 'OwnerWithdrawal',
      entityId: withdrawalId,
      newValue: withdrawalItem.toMap(forFirestore: false),
    );

    return withdrawalItem;
  }

  /// Void an owner withdrawal and reverse financial debits atomically
  Future<OwnerWithdrawalItem> voidWithdrawal({
    required String shopId,
    required String withdrawalId,
    required String voidedByUid,
    required String voidedByName,
    String voidReason = 'Voided by user',
  }) async {
    final sId = shopId.isNotEmpty ? shopId : Db.setting('shop_id', 'tekfix');

    // Retrieve existing withdrawal
    OwnerWithdrawalItem? existing;
    final local = Db.settings.get('owner_wth_$withdrawalId');
    if (local is Map) {
      existing = OwnerWithdrawalItem.fromMap(Map<String, dynamic>.from(local), withdrawalId);
    } else if (sId.isNotEmpty && Firebase.apps.isNotEmpty) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('shops')
            .doc(sId)
            .collection('owner_withdrawals')
            .doc(withdrawalId)
            .get();
        if (doc.exists && doc.data() != null) {
          existing = OwnerWithdrawalItem.fromMap(doc.data()!, doc.id);
        }
      } catch (e) {
        debugPrint('[OwnerFinanceService] voidWithdrawal fetch error: $e');
      }
    }

    if (existing == null) {
      throw StateError('Withdrawal record not found: $withdrawalId');
    }
    if (existing.isVoided) {
      return existing;
    }

    final voidedAt = DateTime.now();
    final updated = existing.copyWith(
      isVoided: true,
      voidedAt: voidedAt,
      voidedByUid: voidedByUid,
      voidedByName: voidedByName,
      voidReason: voidReason,
    );

    // 1. Update Firestore
    if (sId.isNotEmpty && Firebase.apps.isNotEmpty) {
      try {
        final firestore = FirebaseFirestore.instance;
        final batch = firestore.batch();

        final wthRef = firestore
            .collection('shops')
            .doc(sId)
            .collection('owner_withdrawals')
            .doc(withdrawalId);
        batch.update(wthRef, {
          'isVoided': true,
          'voidedAt': Timestamp.fromDate(voidedAt),
          'voidedByUid': voidedByUid,
          'voidedByName': voidedByName,
          'voidReason': voidReason,
        });

        if (existing.expenseId != null) {
          final expRef = firestore
              .collection('shops')
              .doc(sId)
              .collection('expenses')
              .doc(existing.expenseId);
          batch.update(expRef, {
            'isVoided': true,
            'voidedAt': Timestamp.fromDate(voidedAt),
            'voidedByUid': voidedByUid,
            'voidReason': voidReason,
          });
        }

        final revLedgerRef = firestore
            .collection('shops')
            .doc(sId)
            .collection('accounting_cash_bank')
            .doc('CB_REV_OWN_WTH_$withdrawalId');
        batch.set(revLedgerRef, {
          'txId': 'CB_REV_OWN_WTH_$withdrawalId',
          'shopId': sId,
          'type': 'CREDIT',
          'transactionCategory': 'OWNER_WITHDRAWAL_REVERSAL',
          'amount': existing.totalAmount,
          'amountPaise': existing.totalAmountPaise,
          'paymentMode': existing.paymentMode,
          'effectiveDate': toDateKey(voidedAt),
          'withdrawalId': withdrawalId,
          'createdByUid': voidedByUid,
          'createdByName': voidedByName,
          'createdAt': FieldValue.serverTimestamp(),
          'description': 'Reversal: Owner Withdrawal $withdrawalId ($voidReason)',
        });

        await batch.commit();
      } catch (e) {
        debugPrint('[OwnerFinanceService] Firestore void batch error: $e');
      }
    }

    // 2. Update Local Hive & Restore Cash/Bank Balance
    await Db.settings.put('owner_wth_$withdrawalId', updated.toMap(forFirestore: false));

    if (existing.expenseId != null && Db.expenses.containsKey(existing.expenseId)) {
      final exp = tekM(Db.expenses.get(existing.expenseId));
      exp['isVoided'] = true;
      exp['voidedAt'] = voidedAt.toIso8601String();
      exp['voidedByUid'] = voidedByUid;
      exp['voidReason'] = voidReason;
      await Db.expenses.put(existing.expenseId, exp);
    }

    final ledgerMode = existing.isCash ? 'Cash' : 'Bank';
    await Db.moveMoney(
      ledgerMode,
      existing.totalAmount, // Positive amount restores cash/bank balance
      'REVERSAL: Owner Withdrawal $withdrawalId ($voidReason)',
    );

    await Db.logAction(
      action: 'Owner Withdrawal Voided',
      entity: 'OwnerWithdrawal',
      entityId: withdrawalId,
      newValue: updated.toMap(forFirestore: false),
    );

    return updated;
  }

  /// Breakdown daily owner withdrawals for EOD Closing reports
  Future<DailyOwnerWithdrawalBreakdown> computeDailyOwnerWithdrawals(
    DateTime targetDate, {
    String? shopId,
  }) async {
    final list = await getWithdrawalsForDate(targetDate, shopId: shopId, includeVoided: false);

    double cashSal = 0.0;
    double bankSal = 0.0;
    double cashDraw = 0.0;
    double bankDraw = 0.0;

    for (final w in list) {
      if (w.isCash) {
        cashSal += w.salaryPortion;
        cashDraw += w.drawingsPortion;
      } else {
        bankSal += w.salaryPortion;
        bankDraw += w.drawingsPortion;
      }
    }

    return DailyOwnerWithdrawalBreakdown(
      cashSalary: cashSal,
      bankSalary: bankSal,
      cashDrawings: cashDraw,
      bankDrawings: bankDraw,
    );
  }
}

