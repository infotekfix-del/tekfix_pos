import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../main.dart' show Db, tekM;
import '../expenses/expense_models.dart';
import 'rent_models.dart';

class DuplicateRentPaymentException implements Exception {
  final String message;
  final DailyRentRecord existingRecord;

  DuplicateRentPaymentException(this.message, this.existingRecord);

  @override
  String toString() => message;
}

class RentService {
  RentService._();
  static final RentService instance = RentService._();

  static String toDateKey(DateTime dt) {
    return DateFormat('yyyy-MM-dd').format(dt);
  }

  static String toDisplayDate(DateTime dt) {
    return DateFormat('dd MMM yyyy').format(dt);
  }

  /// Get rent configuration settings from Hive (offline immediate) and Firestore
  Future<DailyRentSettings> getSettings({String? shopId}) async {
    final sId = shopId ?? Db.setting('shop_id', 'tekfix');

    // 1. Hive local settings
    final rawLocal = Db.settings.get('daily_rent_config');
    DailyRentSettings settings;
    if (rawLocal != null && rawLocal is Map) {
      settings = DailyRentSettings.fromMap(Map<String, dynamic>.from(rawLocal));
    } else {
      settings = DailyRentSettings(effectiveDate: DateTime(2026, 1, 1));
    }

    // 2. Refresh from Firestore if available
    if (sId.isNotEmpty && Firebase.apps.isNotEmpty) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('shops')
            .doc(sId)
            .collection('settings')
            .doc('daily_rent')
            .get();
        if (doc.exists && doc.data() != null) {
          settings = DailyRentSettings.fromMap(doc.data()!);
          await Db.settings.put('daily_rent_config', settings.toMap());
        }
      } catch (e) {
        debugPrint('[RentService] Failed fetching remote rent settings: $e');
      }
    }

    return settings;
  }

  /// Save rent configuration settings with audit trail and rate history tracking
  Future<DailyRentSettings> saveSettings({
    required String shopId,
    required DailyRentSettings newSettings,
    required String staffId,
    required String staffName,
  }) async {
    final sId = shopId.isNotEmpty ? shopId : Db.setting('shop_id', 'tekfix');
    final current = await getSettings(shopId: sId);

    // If rent amount changed, preserve historical rate in rateHistory
    DailyRentSettings toSave = newSettings;
    if (current.dailyRentAmount != newSettings.dailyRentAmount) {
      final historyItem = RentRateHistoryItem(
        effectiveDate: current.effectiveDate,
        amount: current.dailyRentAmount,
        amountPaise: current.dailyRentAmountPaise,
        changedByUid: staffId,
        changedByName: staffName,
        changedAt: DateTime.now(),
      );
      final updatedHistory = List<RentRateHistoryItem>.from(current.rateHistory)
        ..add(historyItem);
      toSave = newSettings.copyWith(rateHistory: updatedHistory);
    }

    // Save locally to Hive
    await Db.settings.put('daily_rent_config', toSave.toMap());

    // Save to Firestore and log audit
    if (sId.isNotEmpty && Firebase.apps.isNotEmpty) {
      try {
        final firestore = FirebaseFirestore.instance;
        await firestore
            .collection('shops')
            .doc(sId)
            .collection('settings')
            .doc('daily_rent')
            .set(toSave.toMap(), SetOptions(merge: true));

        await firestore
            .collection('shops')
            .doc(sId)
            .collection('audit_logs')
            .add({
          'action': 'RENT_SETTINGS_UPDATED',
          'category': 'RENT',
          'details':
              'Updated daily rent to ₹${toSave.dailyRentAmount} (Paise: ${toSave.dailyRentAmountPaise})',
          'staffId': staffId,
          'staffName': staffName,
          'timestamp': FieldValue.serverTimestamp(),
          'createdAt': DateTime.now().toIso8601String(),
        });
      } catch (e) {
        debugPrint('[RentService] Firestore saveSettings error: $e');
      }
    }

    return toSave;
  }

  /// Fetch a single rent record for a dateKey (e.g. 2026-11-02)
  Future<DailyRentRecord?> getRentRecordForDate(
    String dateKey, {
    String? shopId,
  }) async {
    final sId = shopId ?? Db.setting('shop_id', 'tekfix');

    // 1. Hive local check (from general expenses or rent box)
    final localDoc = Db.settings.get('rent_rec_$dateKey');
    if (localDoc != null && localDoc is Map) {
      return DailyRentRecord.fromMap(
          Map<String, dynamic>.from(localDoc), dateKey);
    }

    // 2. Check general expenses box for linked rent record
    final linkedExpKey = 'EXP_RENT_$dateKey';
    if (Db.expenses.containsKey(linkedExpKey)) {
      final expMap = tekM(Db.expenses.get(linkedExpKey));
      final rec = DailyRentRecord(
        dateKey: dateKey,
        shopId: sId,
        date: DateTime.tryParse(dateKey) ?? DateTime.now(),
        expectedRent: (expMap['amount'] as num?)?.toDouble() ?? 0.0,
        expectedRentPaise: (expMap['amountPaise'] as num?)?.toInt() ?? 0,
        paidAmount: (expMap['amount'] as num?)?.toDouble() ?? 0.0,
        paidAmountPaise: (expMap['amountPaise'] as num?)?.toInt() ?? 0,
        paymentMode:
            expMap['paymentMode']?.toString() ?? ExpensePaymentMode.cash,
        status: expMap['isVoided'] == true ? 'VOIDED' : 'PAID',
        landlordName: expMap['notes']?.toString() ?? '',
        notes: expMap['notes']?.toString() ?? '',
        recordedByUid: expMap['recordedByUid']?.toString() ?? '',
        recordedByName: expMap['recordedByName']?.toString() ?? '',
        expenseId: linkedExpKey,
        isVoided: expMap['isVoided'] == true,
      );
      return rec;
    }

    // 3. Query Firestore
    if (sId.isNotEmpty && Firebase.apps.isNotEmpty) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('shops')
            .doc(sId)
            .collection('rent_records')
            .doc(dateKey)
            .get();
        if (doc.exists && doc.data() != null) {
          final rec = DailyRentRecord.fromMap(doc.data()!, doc.id);
          await Db.settings.put('rent_rec_$dateKey', rec.toMap());
          return rec;
        }
      } catch (e) {
        debugPrint('[RentService] getRentRecordForDate error: $e');
      }
    }

    return null;
  }

  /// Record rent payment atomically with duplicate protection,
  /// linked expense record creation, and ledger debit.
  Future<DailyRentRecord> recordRentPayment({
    required String shopId,
    required String dateKey,
    required double paidAmount,
    required String paymentMode,
    required String recordedByUid,
    required String recordedByName,
    String landlordName = '',
    String paymentReference = '',
    String notes = '',
    String? receiptUrl,
    bool forceAllowCorrection = false,
  }) async {
    final sId = shopId.isNotEmpty ? shopId : Db.setting('shop_id', 'tekfix');
    final dt = DateTime.tryParse(dateKey) ?? DateTime.now();
    final settings = await getSettings(shopId: sId);
    final expectedRent = settings.getRentForDate(dt);
    final expectedPaise = (expectedRent * 100).round();
    final paidPaise = (paidAmount * 100).round();

    if (paidAmount <= 0) {
      throw ArgumentError(
          'ശരിയായ വാടക തുക നൽകുക (Valid positive rent amount is required)');
    }

    // 1. DUPLICATE CHECK: verify if active payment already exists
    final existing = await getRentRecordForDate(dateKey, shopId: sId);
    if (existing != null && existing.isPaid && !forceAllowCorrection) {
      throw DuplicateRentPaymentException(
        'Daily rent has already been recorded for this date (ഈ തീയതിയിലെ വാടക ഇതിനകം രേഖപ്പെടുത്തിയിട്ടുണ്ട്).',
        existing,
      );
    }

    final expenseId = 'EXP_RENT_$dateKey';
    final ledgerTxId = 'CB_RENT_$dateKey';

    final rentRecord = DailyRentRecord(
      dateKey: dateKey,
      shopId: sId,
      date: dt,
      expectedRent: expectedRent,
      expectedRentPaise: expectedPaise,
      paidAmount: paidAmount,
      paidAmountPaise: paidPaise,
      paymentMode: paymentMode.toUpperCase() == ExpensePaymentMode.bank
          ? ExpensePaymentMode.bank
          : ExpensePaymentMode.cash,
      status: 'PAID',
      landlordName: landlordName.trim(),
      paymentReference: paymentReference.trim(),
      receiptUrl: receiptUrl,
      notes: notes.trim(),
      recordedByUid: recordedByUid,
      recordedByName: recordedByName,
      recordedAt: DateTime.now(),
      expenseId: expenseId,
      accountingTransactionId: ledgerTxId,
      isVoided: false,
    );

    // Linked General Expense object (for seamless integration with Expense module)
    final expenseMap = {
      'id': expenseId,
      '_id': expenseId,
      'status': 'ACTIVE',
      'shopId': sId,
      'title': 'Shop Daily Rent - $dateKey',
      'category': ExpenseCategory.rentAndMaintenance,
      'amount': paidAmount,
      'amountPaise': paidPaise,
      'paymentMode': rentRecord.paymentMode,
      'expenseDate': dt.toIso8601String(),
      'recordedByUid': recordedByUid,
      'recordedByName': recordedByName,
      'notes':
          landlordName.isNotEmpty ? 'Landlord: $landlordName. $notes' : notes,
      'receiptUrl': receiptUrl,
      'isVoided': false,
      'isDailyRent': true,
      'rentRecordId': dateKey,
      'createdAt': DateTime.now().toIso8601String(),
      'updatedAt': DateTime.now().toIso8601String(),
    };

    // Ledger Debit entry
    final ledgerMap = {
      'txId': ledgerTxId,
      'shopId': sId,
      'type': 'DEBIT',
      'transactionCategory': 'DAILY_RENT',
      'amount': paidAmount,
      'amountPaise': paidPaise,
      'paymentMode': rentRecord.paymentMode,
      'effectiveDate': dateKey,
      'rentRecordId': dateKey,
      'expenseId': expenseId,
      'createdByUid': recordedByUid,
      'createdByName': recordedByName,
      'createdAt': FieldValue.serverTimestamp(),
      'description': 'Shop Daily Rent for $dateKey ($paymentMode)',
    };

    // 2. ATOMIC FIRESTORE WRITE: enforce uniqueness via transaction
    if (sId.isNotEmpty && Firebase.apps.isNotEmpty) {
      final firestore = FirebaseFirestore.instance;
      final rentDocRef = firestore
          .collection('shops')
          .doc(sId)
          .collection('rent_records')
          .doc(dateKey);

      final expDocRef = firestore
          .collection('shops')
          .doc(sId)
          .collection('expenses')
          .doc(expenseId);

      final ledgerDocRef = firestore
          .collection('shops')
          .doc(sId)
          .collection('accounting_cash_bank')
          .doc(ledgerTxId);

      final auditDocRef =
          firestore.collection('shops').doc(sId).collection('audit_logs').doc();

      try {
        await firestore.runTransaction((tx) async {
          final snapshot = await tx.get(rentDocRef);
          if (snapshot.exists && !forceAllowCorrection) {
            final data = snapshot.data();
            final isAlreadyPaid =
                data?['status'] == 'PAID' && data?['isVoided'] != true;
            if (isAlreadyPaid) {
              throw DuplicateRentPaymentException(
                'Daily rent has already been recorded for today by another session.',
                DailyRentRecord.fromMap(data!, dateKey),
              );
            }
          }

          tx.set(rentDocRef, rentRecord.toMap(forFirestore: true));
          tx.set(expDocRef, {
            ...expenseMap,
            'expenseDate': Timestamp.fromDate(dt),
            'createdAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
          tx.set(ledgerDocRef, ledgerMap);
          tx.set(auditDocRef, {
            'action': 'RENT_PAYMENT_RECORDED',
            'category': 'DAILY_RENT',
            'details':
                'Recorded rent of ₹$paidAmount via $paymentMode for $dateKey',
            'dateKey': dateKey,
            'paidAmount': paidAmount,
            'paidAmountPaise': paidPaise,
            'paymentMode': paymentMode,
            'staffId': recordedByUid,
            'staffName': recordedByName,
            'timestamp': FieldValue.serverTimestamp(),
            'createdAt': DateTime.now().toIso8601String(),
          });
        });
      } catch (e) {
        if (e is DuplicateRentPaymentException) rethrow;
        debugPrint('[RentService] Firestore transaction failed or offline: $e');
      }
    }

    // 3. UPDATE LOCAL HIVE STATE & LEDGER (Instant Offline Availability)
    await Db.settings
        .put('rent_rec_$dateKey', rentRecord.toMap(forFirestore: false));
    await Db.expenses.put(expenseId, expenseMap);

    final ledgerMode = rentRecord.isCash ? 'Cash' : 'Bank';
    await Db.moveMoney(ledgerMode, -paidAmount, 'Shop Daily Rent: $dateKey');

    await Db.logAction(
      action: 'Daily Rent Paid',
      entity: 'DailyRent',
      entityId: dateKey,
      newValue: rentRecord.toMap(forFirestore: false),
    );

    return rentRecord;
  }

  /// Void an existing daily rent payment, creating a reversal debit and restoring balance
  Future<DailyRentRecord> voidRentPayment({
    required String shopId,
    required String dateKey,
    required String voidedByUid,
    required String voidedByName,
    required String voidReason,
  }) async {
    final sId = shopId.isNotEmpty ? shopId : Db.setting('shop_id', 'tekfix');
    final existing = await getRentRecordForDate(dateKey, shopId: sId);
    if (existing == null) {
      throw StateError('Rent record not found for $dateKey');
    }
    if (existing.isVoided) {
      return existing;
    }

    final voidedAt = DateTime.now();
    final updatedRecord = existing.copyWith(
      status: 'VOIDED',
      isVoided: true,
      voidedAt: voidedAt,
      voidedByUid: voidedByUid,
      voidedByName: voidedByName,
      voidReason: voidReason,
      auditHistory: [
        ...existing.auditHistory,
        {
          'action': 'VOIDED',
          'reason': voidReason,
          'byUid': voidedByUid,
          'byName': voidedByName,
          'timestamp': voidedAt.toIso8601String(),
        }
      ],
    );

    // Reversal ledger entry
    final revLedgerId = 'CB_REV_RENT_$dateKey';
    final ledgerMode = existing.isCash ? 'Cash' : 'Bank';

    // 1. Update Firestore
    if (sId.isNotEmpty && Firebase.apps.isNotEmpty) {
      try {
        final firestore = FirebaseFirestore.instance;
        final batch = firestore.batch();

        final rentRef = firestore
            .collection('shops')
            .doc(sId)
            .collection('rent_records')
            .doc(dateKey);

        final expRef = firestore
            .collection('shops')
            .doc(sId)
            .collection('expenses')
            .doc('EXP_RENT_$dateKey');

        final revLedgerRef = firestore
            .collection('shops')
            .doc(sId)
            .collection('accounting_cash_bank')
            .doc(revLedgerId);

        final auditRef = firestore
            .collection('shops')
            .doc(sId)
            .collection('audit_logs')
            .doc();

        batch.update(rentRef, {
          'status': 'VOIDED',
          'isVoided': true,
          'voidedAt': Timestamp.fromDate(voidedAt),
          'voidedByUid': voidedByUid,
          'voidedByName': voidedByName,
          'voidReason': voidReason,
        });

        batch.update(expRef, {
          'isVoided': true,
          'voidedAt': Timestamp.fromDate(voidedAt),
          'voidedByUid': voidedByUid,
          'voidReason': voidReason,
        });

        batch.set(revLedgerRef, {
          'txId': revLedgerId,
          'shopId': sId,
          'type': 'CREDIT',
          'transactionCategory': 'RENT_REVERSAL',
          'amount': existing.paidAmount,
          'amountPaise': existing.paidAmountPaise,
          'paymentMode': existing.paymentMode,
          'effectiveDate': dateKey,
          'rentRecordId': dateKey,
          'createdByUid': voidedByUid,
          'createdByName': voidedByName,
          'createdAt': FieldValue.serverTimestamp(),
          'description':
              'REVERSAL: Voided Daily Rent for $dateKey ($voidReason)',
        });

        batch.set(auditRef, {
          'action': 'RENT_PAYMENT_VOIDED',
          'category': 'DAILY_RENT',
          'details':
              'Voided rent of ₹${existing.paidAmount} for $dateKey: $voidReason',
          'staffId': voidedByUid,
          'staffName': voidedByName,
          'timestamp': FieldValue.serverTimestamp(),
          'createdAt': voidedAt.toIso8601String(),
        });

        await batch.commit();
      } catch (e) {
        debugPrint('[RentService] Firestore void error: $e');
      }
    }

    // 2. Update local Hive & restore drawer / bank balance
    await Db.settings
        .put('rent_rec_$dateKey', updatedRecord.toMap(forFirestore: false));

    if (Db.expenses.containsKey('EXP_RENT_$dateKey')) {
      final exp = tekM(Db.expenses.get('EXP_RENT_$dateKey'));
      exp['isVoided'] = true;
      exp['voidedAt'] = voidedAt.toIso8601String();
      exp['voidedByUid'] = voidedByUid;
      exp['voidReason'] = voidReason;
      await Db.expenses.put('EXP_RENT_$dateKey', exp);
    }

    await Db.moveMoney(
        ledgerMode, existing.paidAmount, 'REVERSAL: Daily Rent $dateKey');

    await Db.logAction(
      action: 'Daily Rent Voided',
      entity: 'DailyRent',
      entityId: dateKey,
      newValue: updatedRecord.toMap(forFirestore: false),
    );

    return updatedRecord;
  }

  /// Upload receipt attachment to Firebase Storage
  Future<String> uploadReceiptFile({
    required String shopId,
    required String dateKey,
    required Uint8List bytes,
    required String fileName,
    String mimeType = 'image/jpeg',
  }) async {
    final sId = shopId.isNotEmpty ? shopId : Db.setting('shop_id', 'tekfix');
    final cleanName = fileName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final ref = FirebaseStorage.instance
        .ref()
        .child('shops/$sId/rent_receipts/${dateKey}_$cleanName');

    final task =
        await ref.putData(bytes, SettableMetadata(contentType: mimeType));
    return await task.ref.getDownloadURL();
  }

  /// Compute date-by-date rent history for a given month or date range
  Future<List<DailyRentRecord>> getRentHistory({
    required String shopId,
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final sId = shopId.isNotEmpty ? shopId : Db.setting('shop_id', 'tekfix');
    final settings = await getSettings(shopId: sId);

    // Fetch existing records from Firestore if online
    final Map<String, DailyRentRecord> paidMap = {};
    if (sId.isNotEmpty && Firebase.apps.isNotEmpty) {
      try {
        final startKey = toDateKey(startDate);
        final endKey = toDateKey(endDate);
        final snap = await FirebaseFirestore.instance
            .collection('shops')
            .doc(sId)
            .collection('rent_records')
            .where(FieldPath.documentId, isGreaterThanOrEqualTo: startKey)
            .where(FieldPath.documentId, isLessThanOrEqualTo: endKey)
            .get();

        for (final doc in snap.docs) {
          paidMap[doc.id] = DailyRentRecord.fromMap(doc.data(), doc.id);
        }
      } catch (e) {
        debugPrint('[RentService] getRentHistory remote query error: $e');
      }
    }

    // Merge with Hive cached records
    for (int i = 0; i <= endDate.difference(startDate).inDays; i++) {
      final curDate = startDate.add(Duration(days: i));
      final k = toDateKey(curDate);
      if (!paidMap.containsKey(k)) {
        final local = Db.settings.get('rent_rec_$k');
        if (local != null && local is Map) {
          paidMap[k] =
              DailyRentRecord.fromMap(Map<String, dynamic>.from(local), k);
        } else if (Db.expenses.containsKey('EXP_RENT_$k')) {
          final exp = tekM(Db.expenses.get('EXP_RENT_$k'));
          paidMap[k] = DailyRentRecord(
            dateKey: k,
            shopId: sId,
            date: curDate,
            expectedRent: settings.getRentForDate(curDate),
            expectedRentPaise: (settings.getRentForDate(curDate) * 100).round(),
            paidAmount: (exp['amount'] as num?)?.toDouble() ?? 0.0,
            paidAmountPaise: (exp['amountPaise'] as num?)?.toInt() ?? 0,
            paymentMode:
                exp['paymentMode']?.toString() ?? ExpensePaymentMode.cash,
            status: exp['isVoided'] == true ? 'VOIDED' : 'PAID',
            recordedByUid: exp['recordedByUid']?.toString() ?? '',
            recordedByName: exp['recordedByName']?.toString() ?? '',
            isVoided: exp['isVoided'] == true,
          );
        }
      }
    }

    // Generate complete chronological calendar list
    final List<DailyRentRecord> results = [];
    for (int i = 0; i <= endDate.difference(startDate).inDays; i++) {
      final curDate = startDate.add(Duration(days: i));
      final k = toDateKey(curDate);
      final isScheduled = settings.isScheduledForDate(curDate);
      final expectedAmt = settings.getRentForDate(curDate);
      final expectedPaise = (expectedAmt * 100).round();

      if (paidMap.containsKey(k)) {
        results.add(paidMap[k]!);
      } else {
        // Not yet paid
        results.add(DailyRentRecord(
          dateKey: k,
          shopId: sId,
          date: curDate,
          expectedRent: expectedAmt,
          expectedRentPaise: expectedPaise,
          paidAmount: 0.0,
          paidAmountPaise: 0,
          paymentMode: settings.defaultPaymentMode,
          status: isScheduled ? 'PENDING' : 'NOT_SCHEDULED',
          recordedByUid: '',
          recordedByName: '',
          isVoided: false,
        ));
      }
    }

    // Sort descending (newest date first)
    results.sort((a, b) => b.date.compareTo(a.date));
    return results;
  }

  /// Compute high-level metrics for Today and This Month
  Future<DailyRentMetrics> computeRentMetrics({
    required String shopId,
    DateTime? forDate,
  }) async {
    final target = forDate ?? DateTime.now();
    final todayKey = toDateKey(target);
    final settings = await getSettings(shopId: shopId);

    final todayExpected = settings.getRentForDate(target);
    final todayRecord = await getRentRecordForDate(todayKey, shopId: shopId);

    final double todayPaid = (todayRecord != null && todayRecord.isPaid)
        ? todayRecord.paidAmount
        : 0.0;
    final String todayStatus = (todayRecord != null && todayRecord.isPaid)
        ? 'PAID'
        : (settings.isScheduledForDate(target) ? 'PENDING' : 'NOT_SCHEDULED');
    final String todayMode =
        todayRecord?.paymentMode ?? settings.defaultPaymentMode;

    // Month metrics: from 1st of month to today (or end of month)
    final startOfMonth = DateTime(target.year, target.month, 1);
    final daysInMonth = DateTime(target.year, target.month + 1, 0).day;
    final endOfMonth = DateTime(target.year, target.month, daysInMonth);

    final history = await getRentHistory(
      shopId: shopId,
      startDate: startOfMonth,
      endDate: target.isBefore(endOfMonth) ? target : endOfMonth,
    );

    double monthTotalPaid = 0.0;
    int monthPaidDays = 0;
    int monthUnpaidDays = 0;
    double monthTotalOutstanding = 0.0;

    for (final rec in history) {
      if (rec.isPaid) {
        monthTotalPaid += rec.paidAmount;
        monthPaidDays++;
      } else if (rec.status == 'PENDING') {
        monthUnpaidDays++;
        monthTotalOutstanding += rec.expectedRent;
      }
    }

    return DailyRentMetrics(
      todayExpected: todayExpected,
      todayPaid: todayPaid,
      todayStatus: todayStatus,
      todayPaymentMode: todayMode,
      monthTotalPaid: monthTotalPaid,
      monthPaidDays: monthPaidDays,
      monthUnpaidDays: monthUnpaidDays,
      monthTotalOutstanding: monthTotalOutstanding,
    );
  }
}
