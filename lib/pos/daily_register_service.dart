import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart' show Db, tekM, toast;
import 'daily_register_models.dart';

class DailyRegisterService {
  DailyRegisterService._();
  static final DailyRegisterService instance = DailyRegisterService._();

  static String toDateString(DateTime dt) {
    return DateFormat('yyyy_MM_dd').format(dt);
  }

  static String toDisplayDate(DateTime dt) {
    return DateFormat('dd MMM yyyy').format(dt);
  }

  /// Retrieve sales for a given date from Hive (instant offline) and optionally merge Firestore
  Future<List<Map<String, dynamic>>> getSalesForDate(
    DateTime targetDate, {
    String? shopId,
  }) async {
    final startOfDay =
        DateTime(targetDate.year, targetDate.month, targetDate.day, 0, 0, 0);
    final endOfDay = DateTime(
        targetDate.year, targetDate.month, targetDate.day, 23, 59, 59, 999);

    final Map<String, Map<String, dynamic>> salesMap = {};

    bool matchesTargetDate(dynamic rawDate) {
      if (rawDate == null) return false;
      DateTime? dt;
      if (rawDate is Timestamp) {
        dt = rawDate.toDate();
      } else if (rawDate is DateTime) {
        dt = rawDate;
      } else if (rawDate is int) {
        dt = DateTime.fromMillisecondsSinceEpoch(rawDate);
      } else {
        final s = rawDate.toString();
        dt = DateTime.tryParse(s);
        if (dt == null && s.length >= 10) {
          final normalized = s.replaceAll('_', '-');
          dt = DateTime.tryParse(normalized);
        }
      }
      if (dt == null) return false;
      return dt.year == targetDate.year &&
          dt.month == targetDate.month &&
          dt.day == targetDate.day;
    }

    // 1. Load from Hive local storage
    for (final k in Db.sales.keys) {
      final s = tekM(Db.sales.get(k));
      final inv =
          s['invoice']?.toString() ?? s['invoiceId']?.toString() ?? '$k';
      if (matchesTargetDate(s['createdAt']) ||
          matchesTargetDate(s['date']) ||
          matchesTargetDate(s['_st'])) {
        final copy = Map<String, dynamic>.from(s);
        copy['_hiveKey'] = k;
        salesMap[inv] = copy;
      }
    }

    // 2. Query Firestore if shopId provided
    final resolvedShop = shopId ?? Db.setting('shop_id', '');
    if (resolvedShop.isNotEmpty) {
      try {
        final startTs = Timestamp.fromDate(startOfDay);
        final endTs = Timestamp.fromDate(endOfDay);
        final startIso = startOfDay.toIso8601String();
        final endIso = endOfDay.toIso8601String();
        final dateHyphen = DateFormat('yyyy-MM-dd').format(targetDate);
        final dateUnderscore = DateFormat('yyyy_MM_dd').format(targetDate);

        Future<void> fetchCollection(String colName) async {
          final colRef = FirebaseFirestore.instance
              .collection('shops')
              .doc(resolvedShop)
              .collection(colName);

          // A. Query by Timestamp range
          try {
            final snapTs = await colRef
                .where('createdAt', isGreaterThanOrEqualTo: startTs)
                .where('createdAt', isLessThanOrEqualTo: endTs)
                .get();
            for (final doc in snapTs.docs) {
              final data = doc.data();
              final inv = data['invoice']?.toString() ??
                  data['invoiceId']?.toString() ??
                  doc.id;
              if (!salesMap.containsKey(inv)) {
                salesMap[inv] = Map<String, dynamic>.from(data);
              }
            }
          } catch (_) {}

          // B. Query by ISO string range
          try {
            final snapIso = await colRef
                .where('createdAt', isGreaterThanOrEqualTo: startIso)
                .where('createdAt', isLessThanOrEqualTo: endIso)
                .get();
            for (final doc in snapIso.docs) {
              final data = doc.data();
              final inv = data['invoice']?.toString() ??
                  data['invoiceId']?.toString() ??
                  doc.id;
              if (!salesMap.containsKey(inv)) {
                salesMap[inv] = Map<String, dynamic>.from(data);
              }
            }
          } catch (_) {}

          // C. Query by date field ('YYYY-MM-DD' or 'YYYY_MM_DD')
          for (final dVal in [dateHyphen, dateUnderscore]) {
            try {
              final snapDate =
                  await colRef.where('date', isEqualTo: dVal).get();
              for (final doc in snapDate.docs) {
                final data = doc.data();
                final inv = data['invoice']?.toString() ??
                    data['invoiceId']?.toString() ??
                    doc.id;
                if (!salesMap.containsKey(inv)) {
                  salesMap[inv] = Map<String, dynamic>.from(data);
                }
              }
            } catch (_) {}
          }
        }

        await fetchCollection('sales');
        await fetchCollection('sales_orders');
      } catch (e) {
        debugPrint('Firestore daily sales fetch skipped/offline: $e');
      }
    }

    // Sort by createdAt descending
    final list = salesMap.values.toList();
    list.sort((a, b) {
      DateTime getDt(Map<String, dynamic> m) {
        final c = m['createdAt'];
        if (c is Timestamp) return c.toDate();
        if (c is int) return DateTime.fromMillisecondsSinceEpoch(c);
        if (c != null) return DateTime.tryParse(c.toString()) ?? DateTime(2000);
        return DateTime(2000);
      }

      return getDt(b).compareTo(getDt(a));
    });

    return list;
  }

  /// Computes the complete shift summary and metrics from the day's sales list
  DailyRegisterSummary computeDailySummary({
    required List<Map<String, dynamic>> sales,
    required DateTime date,
    String openingTime = '08:30 AM',
    String closingTime = '10:00 PM',
    double openingCash = 0.0,
    double refunds = 0.0,
    double totalCashExpenses = 0.0,
    double totalBankExpenses = 0.0,
    double cashRentPaid = 0.0,
    double bankRentPaid = 0.0,
    bool rentPendingWarning = false,
    double ownerSalaryDrawnToday = 0.0,
    double ownerExcessDrawingsToday = 0.0,
    double ownerCashSalaryDrawn = 0.0,
    double ownerCashDrawingsDrawn = 0.0,
    double ownerBankSalaryDrawn = 0.0,
    double ownerBankDrawingsDrawn = 0.0,
    double physicalCashCount = 0.0,
    double retainedCashFloat = 1000.0,
    CashDenominations denominations = const CashDenominations(),
    CashHandoverSplit handoverSplit = const CashHandoverSplit(),
    bool isBackdated = false,
    String closingStatus = '',
    String closedByStaffId = '',
    String closedByStaffName = '',
    bool isClosed = false,
  }) {
    final dStr = toDateString(date);

    double grossSales = 0.0;
    double totalDiscounts = 0.0;
    double netRevenue = 0.0;
    double totalCash = 0.0;
    double totalUpi = 0.0;
    double totalCard = 0.0;
    double totalDue = 0.0;
    double calculatedRefunds = refunds;
    int totalOrdersCount = 0;

    final Map<String, _CatAccumulator> categoryMap = {};
    final Map<String, _ItemAccumulator> productMap = {};

    for (final s in sales) {
      final isRet = s['status'] == 'RETURNED';
      if (isRet) {
        calculatedRefunds += (s['total'] as num?)?.toDouble() ?? 0.0;
        continue;
      }
      if (s['refundAmount'] != null) {
        calculatedRefunds += (s['refundAmount'] as num?)?.toDouble() ?? 0.0;
      }

      totalOrdersCount++;

      final subtotal = (s['subtotal'] as num?)?.toDouble() ??
          (s['total'] as num?)?.toDouble() ??
          0.0;
      final discount = (s['discount'] as num?)?.toDouble() ?? 0.0;
      final total = (s['total'] as num?)?.toDouble() ?? 0.0;

      final cash = (s['cash'] as num?)?.toDouble() ?? 0.0;
      final upi = (s['upi'] as num?)?.toDouble() ?? 0.0;
      final card = (s['card'] as num?)?.toDouble() ?? 0.0;
      final due = (s['due'] as num?)?.toDouble() ?? 0.0;

      grossSales += (subtotal > 0 ? subtotal : (total + discount));
      totalDiscounts += discount;
      netRevenue += total;

      totalCash += cash;
      totalUpi += upi;
      totalCard += card;
      totalDue += due;

      // Item level categorization
      final items = (s['items'] as List?) ?? [];
      for (final rawItem in items) {
        if (rawItem is! Map) continue;
        final it = Map<String, dynamic>.from(rawItem);
        final name =
            it['name']?.toString() ?? it['itemName']?.toString() ?? 'Item';
        final qty = (it['qty'] as num?)?.toInt() ?? 1;
        final price = (it['price'] as num?)?.toDouble() ??
            (it['unitPrice'] as num?)?.toDouble() ??
            0.0;
        final lineTotal =
            (it['lineTotal'] as num?)?.toDouble() ?? (price * qty);

        // Normalize Category
        final rawCat = it['category']?.toString() ?? '';
        final isPhotostat = rawCat.toLowerCase().contains('photostat') ||
            rawCat.toLowerCase().contains('print') ||
            name.toLowerCase().contains('photostat') ||
            name.toLowerCase().contains('xerox');
        final isService = it['id']?.toString().startsWith('service_') == true ||
            rawCat.toLowerCase().contains('service') ||
            rawCat.toLowerCase().contains('repair') ||
            name.toLowerCase().contains('replacement') ||
            name.toLowerCase().contains('repair');

        String resolvedCat;
        if (isPhotostat) {
          resolvedCat = 'Photostat / Printing';
        } else if (isService) {
          resolvedCat = 'Phone / Hardware Service';
        } else if (rawCat.isNotEmpty) {
          resolvedCat = rawCat;
        } else {
          resolvedCat = 'Gadgets & Accessories';
        }

        categoryMap.putIfAbsent(
            resolvedCat, () => _CatAccumulator(resolvedCat));
        categoryMap[resolvedCat]!.units += qty;
        categoryMap[resolvedCat]!.total += lineTotal;

        productMap.putIfAbsent(name, () => _ItemAccumulator(name));
        productMap[name]!.qty += qty;
        productMap[name]!.total += lineTotal;
      }
    }

    final topProducts = productMap.values.map((a) {
      return TopProductSummary(
        name: a.name,
        qty: a.qty,
        totalAmount: a.total,
      );
    }).toList()
      ..sort((a, b) => b.qty.compareTo(a.qty));

    final categoryBreakdown = categoryMap.map((k, v) {
      return MapEntry(
        k,
        CategorySalesSummary(
          category: v.category,
          units: v.units,
          totalAmount: v.total,
        ),
      );
    });

    final expectedClosingCash = (openingCash +
            totalCash -
            calculatedRefunds -
            totalCashExpenses -
            ownerCashDrawingsDrawn)
        .clamp(0.0, double.infinity);
    final discrepancy = physicalCashCount - expectedClosingCash;

    return DailyRegisterSummary(
      dateString: dStr,
      date: date,
      openingTime: openingTime,
      closingTime: closingTime,
      totalOrdersCount: totalOrdersCount,
      grossSales: grossSales,
      totalDiscounts: totalDiscounts,
      netRevenue: netRevenue,
      totalCash: totalCash,
      totalUpi: totalUpi,
      totalCard: totalCard,
      totalDue: totalDue,
      openingCash: openingCash,
      refunds: calculatedRefunds,
      totalCashExpenses: totalCashExpenses,
      totalBankExpenses: totalBankExpenses,
      cashRentPaid: cashRentPaid,
      bankRentPaid: bankRentPaid,
      rentPendingWarning: rentPendingWarning,
      ownerSalaryDrawnToday: ownerSalaryDrawnToday,
      ownerExcessDrawingsToday: ownerExcessDrawingsToday,
      ownerCashSalaryDrawn: ownerCashSalaryDrawn,
      ownerCashDrawingsDrawn: ownerCashDrawingsDrawn,
      ownerBankSalaryDrawn: ownerBankSalaryDrawn,
      ownerBankDrawingsDrawn: ownerBankDrawingsDrawn,
      physicalCashCount: physicalCashCount,
      cashDiscrepancy: discrepancy,
      retainedCashFloat: retainedCashFloat,
      denominations: denominations,
      handoverSplit: handoverSplit,
      isBackdated: isBackdated,
      closingStatus: closingStatus,
      categoryBreakdown: categoryBreakdown,
      topSellingProducts: topProducts,
      closedByStaffId: closedByStaffId,
      closedByStaffName: closedByStaffName,
      isClosed: isClosed,
    );
  }

  /// Retrieve opening cash for a date:
  /// 1. If already closed, use that day's saved opening cash (Firestore first).
  /// 2. Check Firestore `shops/{shopId}/register_openings/{dateStr}`.
  /// 3. Check local Hive key for `opening_cash_$dateStr` (offline cache).
  /// 4. Look up previous business day's closed register retained cash float.
  /// 5. Default to ₹1,000.0.
  Future<double> getOpeningCashForDate(
    DateTime targetDate, {
    String? shopId,
  }) async {
    final dateStr = toDateString(targetDate);
    final resolvedShop = shopId ?? Db.setting('shop_id', '');

    // 1. If register is already closed, use closed summary's openingCash
    final closed = await getClosedRegister(dateStr, shopId: resolvedShop);
    if (closed != null) {
      return closed.openingCash;
    }

    // 2. Check Firestore register_openings for this date (authoritative source of truth)
    if (resolvedShop.isNotEmpty) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('shops')
            .doc(resolvedShop)
            .collection('register_openings')
            .doc(dateStr)
            .get();
        if (doc.exists && doc.data() != null) {
          final data = doc.data()!;
          final openVal = (data['openingCash'] as num?)?.toDouble() ??
              (((data['openingCashPaise'] as num?)?.toDouble() ?? 0.0) / 100.0);
          await Db.settings.put('opening_cash_$dateStr', openVal);
          return openVal;
        }
      } catch (e) {
        debugPrint('Firestore register opening fetch error: $e');
      }
    }

    // 3. Check local Hive key for this date's opening cash (offline fallback)
    final localVal = Db.settings.get('opening_cash_$dateStr');
    if (localVal != null) {
      if (localVal is num) return localVal.toDouble();
      final parsed = double.tryParse(localVal.toString());
      if (parsed != null) return parsed;
    }

    // 4. Look up previous business day's closed register
    final prevDate = targetDate.subtract(const Duration(days: 1));
    final prevDateStr = toDateString(prevDate);
    final prevClosed =
        await getClosedRegister(prevDateStr, shopId: resolvedShop);
    if (prevClosed != null) {
      final prevFloat = prevClosed.retainedCashFloat;
      await Db.settings.put('opening_cash_$dateStr', prevFloat);
      return prevFloat;
    }

    // 5. Default opening float = ₹1,000.0
    return 1000.0;
  }

  /// Close daily register atomically and write immutable record to Firestore,
  /// and automatically carry forward retained cash float as next business day's opening cash.
  Future<void> closeDailyRegister({
    required DailyRegisterSummary summary,
    required String shopId,
    required String staffId,
    required String staffName,
    String? notes,
    bool isBackdated = false,
    bool forceOverrideNextDay = false,
  }) async {
    final now = DateTime.now();
    final closedSummary = summary.copyWith(
      closedByStaffId: staffId,
      closedByStaffName: staffName,
      closedAt: now,
      isClosed: true,
      isBackdated: isBackdated,
      closingStatus: isBackdated
          ? 'BACKDATED'
          : (summary.cashDiscrepancy.abs() > 0.5 ? 'DISCREPANCY' : 'CLOSED'),
      notes: notes,
    );

    final payload = closedSummary.toMap();
    final docId = summary.dateString;
    final resolvedShop = shopId.isNotEmpty ? shopId : Db.setting('shop_id', '');

    // 1. Cache to Hive local settings/registers for immediate responsive UI
    await Db.settings.put('daily_register_$docId', payload);

    // 2. Atomic Firestore transaction: write closed register + carry forward next-day opening cash
    final nextDay = summary.date.add(const Duration(days: 1));
    final nextDayStr = toDateString(nextDay);
    bool shouldCarryForward = true;

    if (resolvedShop.isNotEmpty) {
      try {
        final shopDoc =
            FirebaseFirestore.instance.collection('shops').doc(resolvedShop);
        final registerRef = shopDoc.collection('daily_registers').doc(docId);
        final nextDayRegisterRef =
            shopDoc.collection('daily_registers').doc(nextDayStr);
        final nextDayOpeningRef =
            shopDoc.collection('register_openings').doc(nextDayStr);

        await FirebaseFirestore.instance.runTransaction((transaction) async {
          final registerSnap = await transaction.get(registerRef);
          final nextDayRegisterSnap =
              await transaction.get(nextDayRegisterRef);

          final nextDayIsClosed = nextDayRegisterSnap.exists &&
              (nextDayRegisterSnap.data()?['isClosed'] == true);

          if (isBackdated && nextDayIsClosed && !forceOverrideNextDay) {
            shouldCarryForward = false;
            debugPrint(
              '[DailyRegisterService] Backdated closing for $docId: $nextDayStr is already finalized. Not overwriting next day opening cash.',
            );
          }

          transaction.set(
            registerRef,
            {
              ...payload,
              'createdAt': registerSnap.exists
                  ? (registerSnap.data()?['createdAt'] ??
                      FieldValue.serverTimestamp())
                  : FieldValue.serverTimestamp(),
              'updatedAt': FieldValue.serverTimestamp(),
              'finalized': true,
            },
            SetOptions(merge: true),
          );

          if (shouldCarryForward) {
            transaction.set(
              nextDayOpeningRef,
              {
                'businessDate': nextDayStr,
                'openingCash': summary.retainedCashFloat,
                'openingCashPaise': summary.retainedCashFloatPaise,
                'carriedFromDate': docId,
                'isBackdatedCarry': isBackdated,
                'updatedByStaffId': staffId,
                'updatedByStaffName': staffName,
                'updatedAt': FieldValue.serverTimestamp(),
              },
              SetOptions(merge: true),
            );
          }
        });
      } catch (e) {
        debugPrint('Firestore register close atomic transaction error: $e');
        // Fallback write if transaction failed (e.g. offline device)
        try {
          await FirebaseFirestore.instance
              .collection('shops')
              .doc(resolvedShop)
              .collection('daily_registers')
              .doc(docId)
              .set({
            ...payload,
            'createdAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
            'finalized': true,
          }, SetOptions(merge: true));

          if (shouldCarryForward) {
            await FirebaseFirestore.instance
                .collection('shops')
                .doc(resolvedShop)
                .collection('register_openings')
                .doc(nextDayStr)
                .set({
              'businessDate': nextDayStr,
              'openingCash': summary.retainedCashFloat,
              'openingCashPaise': summary.retainedCashFloatPaise,
              'carriedFromDate': docId,
              'isBackdatedCarry': isBackdated,
              'updatedByStaffId': staffId,
              'updatedByStaffName': staffName,
              'updatedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
          }
        } catch (e2) {
          debugPrint('Firestore register close fallback error: $e2');
        }
      }
    }

    if (shouldCarryForward) {
      await Db.settings
          .put('opening_cash_$nextDayStr', summary.retainedCashFloat);
    }

    // 3. Audit Log
    await Db.logAction(
      action:
          isBackdated ? 'Backdated EOD Register Closed' : 'EOD Register Closed',
      entity: 'DailyRegister',
      entityId: docId,
      reason:
          'Actual Cash: ₹${summary.physicalCashCount.toStringAsFixed(2)}, Retained Float: ₹${summary.retainedCashFloat.toStringAsFixed(2)}, Net Handover: ₹${summary.netCashHandover.toStringAsFixed(2)}, Status: ${closedSummary.resolvedClosingStatus}',
      newValue: {
        'businessDate': docId,
        'actualCash': summary.physicalCashCount,
        'retainedFloat': summary.retainedCashFloat,
        'netHandover': summary.netCashHandover,
        'discrepancy': summary.cashDiscrepancy,
        'isBackdated': isBackdated,
        'closedBy': staffName,
      },
    );
  }

  /// Get status of past N days for EOD status dashboard & backdated closing
  Future<List<DailyRegisterSummary>> getPastDaysRegisterStatus({
    required String shopId,
    int days = 7,
  }) async {
    final now = DateTime.now();
    final List<DailyRegisterSummary> list = [];

    for (int i = 0; i < days; i++) {
      final targetDate = now.subtract(Duration(days: i));
      final dateStr = toDateString(targetDate);
      final closed = await getClosedRegister(dateStr, shopId: shopId);

      if (closed != null) {
        list.add(closed);
      } else {
        // Fetch day's sales and compute pending summary
        final s = await getSalesForDate(targetDate, shopId: shopId);
        final openCash =
            await getOpeningCashForDate(targetDate, shopId: shopId);
        final pending = computeDailySummary(
          sales: s,
          date: targetDate,
          openingCash: openCash,
        );
        list.add(pending);
      }
    }
    return list;
  }

  /// Check if register was already closed for a date
  Future<DailyRegisterSummary?> getClosedRegister(
    String dateString, {
    String? shopId,
  }) async {
    final resolvedShop = shopId ?? Db.setting('shop_id', '');

    // 1. Check Firestore (authoritative source of truth)
    if (resolvedShop.isNotEmpty) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('shops')
            .doc(resolvedShop)
            .collection('daily_registers')
            .doc(dateString)
            .get();
        if (doc.exists && doc.data() != null) {
          final data = doc.data()!;
          final res = DailyRegisterSummary.fromMap(data);
          await Db.settings.put('daily_register_$dateString', data);
          return res;
        }
      } catch (e) {
        debugPrint('Error getting closed register from Firestore: $e');
      }
    }

    // 2. Fallback to local Hive cache if offline or uninitialized
    final local = Db.settings.get('daily_register_$dateString');
    if (local != null && local is Map) {
      return DailyRegisterSummary.fromMap(Map<String, dynamic>.from(local));
    }

    return null;
  }

  /// Thermal EOD Settlement Slip Printing (ATM-style 80mm roll)
  Future<void> printThermalEodSlip(
    BuildContext context,
    DailyRegisterSummary summary,
  ) async {
    try {
      final shopName = Db.setting('shop_name', 'TEKFIX ERP');
      final shopAddress = Db.setting('shop_address', 'Kerala, India');
      final shopPhone = Db.setting('shop_phone', '');

      final doc = pw.Document();

      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.roll80,
          margin: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          build: (pw.Context ctx) {
            return pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                // Header
                pw.Center(
                  child: pw.Text(
                    shopName.toUpperCase(),
                    style: const pw.TextStyle(
                        fontWeight: pw.FontWeight.bold, fontSize: 14),
                  ),
                ),
                if (shopAddress.isNotEmpty)
                  pw.Center(
                    child: pw.Text(
                      shopAddress,
                      style: const pw.TextStyle(fontSize: 9),
                      textAlign: pw.TextAlign.center,
                    ),
                  ),
                if (shopPhone.isNotEmpty)
                  pw.Center(
                    child: pw.Text('Tel: $shopPhone',
                        style: const pw.TextStyle(fontSize: 9)),
                  ),
                pw.SizedBox(height: 6),
                pw.Center(
                  child: pw.Text(
                    '================================',
                    style: const pw.TextStyle(fontSize: 10),
                  ),
                ),
                pw.Center(
                  child: pw.Text(
                    'DAILY REGISTER CLOSING REPORT',
                    style: const pw.TextStyle(
                        fontWeight: pw.FontWeight.bold, fontSize: 11),
                  ),
                ),
                pw.Center(
                  child: pw.Text(
                    'SHIFT SETTLEMENT SLIP',
                    style: const pw.TextStyle(fontSize: 9),
                  ),
                ),
                pw.Center(
                  child: pw.Text(
                    '================================',
                    style: const pw.TextStyle(fontSize: 10),
                  ),
                ),
                pw.SizedBox(height: 6),

                // Timing & Staff Info
                _pwLine('Date:', toDisplayDate(summary.date)),
                _pwLine('Hours:',
                    '${summary.openingTime} - ${summary.closingTime}'),
                _pwLine(
                    'Closed At:',
                    DateFormat('hh:mm a, dd/MM/yy')
                        .format(summary.closedAt ?? DateTime.now())),
                if (summary.closedByStaffName.isNotEmpty)
                  _pwLine('Closed By:', summary.closedByStaffName),
                _pwLine('Total Invoices:', '${summary.totalOrdersCount}'),
                pw.SizedBox(height: 4),
                pw.Text('--------------------------------',
                    style: const pw.TextStyle(fontSize: 10)),

                // Gross Sales & Net
                pw.SizedBox(height: 4),
                pw.Text('REVENUE OVERVIEW',
                    style: const pw.TextStyle(
                        fontWeight: pw.FontWeight.bold, fontSize: 10)),
                pw.SizedBox(height: 2),
                _pwLine('Gross Sales:',
                    'Rs. ${summary.grossSales.toStringAsFixed(2)}'),
                _pwLine('Total Discounts:',
                    '-Rs. ${summary.totalDiscounts.toStringAsFixed(2)}'),
                pw.Divider(thickness: 0.8),
                _pwLine('NET DAY SALES:',
                    'Rs. ${summary.netRevenue.toStringAsFixed(2)}',
                    isBold: true),
                pw.Divider(thickness: 0.8),

                // Payment Mode Reconciliation
                pw.SizedBox(height: 4),
                pw.Text('PAYMENT RECONCILIATION',
                    style: const pw.TextStyle(
                        fontWeight: pw.FontWeight.bold, fontSize: 10)),
                pw.SizedBox(height: 2),
                _pwLine('Opening Cash:',
                    'Rs. ${summary.openingCash.toStringAsFixed(2)}'),
                _pwLine('Cash Collections:',
                    'Rs. ${summary.totalCash.toStringAsFixed(2)}'),
                if (summary.cashRentPaid > 0)
                  _pwLine('Daily Rent Paid (Cash):',
                      '-Rs. ${summary.cashRentPaid.toStringAsFixed(2)}'),
                if (summary.ownerSalaryDrawnToday > 0)
                  _pwLine('Owner Salary Drawn Today:',
                      '-Rs. ${summary.ownerSalaryDrawnToday.toStringAsFixed(2)}'),
                if (summary.ownerExcessDrawingsToday > 0)
                  _pwLine('Owner Excess Drawings Today:',
                      '-Rs. ${summary.ownerExcessDrawingsToday.toStringAsFixed(2)}'),
                if (summary.otherCashExpenses > 0)
                  _pwLine('Other Cash Expenses:',
                      '-Rs. ${summary.otherCashExpenses.toStringAsFixed(2)}'),
                if (summary.refunds > 0)
                  _pwLine('Refunds / Returns:',
                      '-Rs. ${summary.refunds.toStringAsFixed(2)}'),
                _pwLine('Expected Closing Cash:',
                    'Rs. ${summary.expectedClosingCash.toStringAsFixed(2)}',
                    isBold: true),
                _pwLine('Physical Cash Count:',
                    'Rs. ${summary.physicalCashCount.toStringAsFixed(2)}'),
                _pwLine(
                  'Cash Discrepancy:',
                  summary.cashDiscrepancy == 0
                      ? 'Rs. 0.00 (MATCHED)'
                      : (summary.cashDiscrepancy > 0
                          ? '+Rs. ${summary.cashDiscrepancy.toStringAsFixed(2)} (OVER)'
                          : '-Rs. ${summary.cashDiscrepancy.abs().toStringAsFixed(2)} (SHORT)'),
                  isBold: summary.cashDiscrepancy != 0,
                ),
                _pwLine('UPI / GPay Total:',
                    'Rs. ${summary.totalUpi.toStringAsFixed(2)}'),
                _pwLine('Card Total:',
                    'Rs. ${summary.totalCard.toStringAsFixed(2)}'),
                if (summary.totalBankExpenses > 0)
                  _pwLine('Bank Expenses Paid:',
                      '-Rs. ${summary.totalBankExpenses.toStringAsFixed(2)}'),
                if (summary.totalDue > 0)
                  _pwLine('Credit / Due Added:',
                      'Rs. ${summary.totalDue.toStringAsFixed(2)}'),
                pw.SizedBox(height: 4),
                pw.Text('--------------------------------',
                    style: const pw.TextStyle(fontSize: 10)),

                // Denominations Breakdown
                if (!summary.denominations.isEmpty) ...[
                  pw.SizedBox(height: 4),
                  pw.Text('CASH DENOMINATIONS',
                      style: const pw.TextStyle(
                          fontWeight: pw.FontWeight.bold, fontSize: 10)),
                  pw.SizedBox(height: 2),
                  if (summary.denominations.count500 > 0)
                    _pwLine(
                        'Rs. 500 x ${summary.denominations.count500}:',
                        'Rs. ${summary.denominations.subtotal500.toStringAsFixed(0)}'),
                  if (summary.denominations.count200 > 0)
                    _pwLine(
                        'Rs. 200 x ${summary.denominations.count200}:',
                        'Rs. ${summary.denominations.subtotal200.toStringAsFixed(0)}'),
                  if (summary.denominations.count100 > 0)
                    _pwLine(
                        'Rs. 100 x ${summary.denominations.count100}:',
                        'Rs. ${summary.denominations.subtotal100.toStringAsFixed(0)}'),
                  if (summary.denominations.count50 > 0)
                    _pwLine(
                        'Rs. 50 x ${summary.denominations.count50}:',
                        'Rs. ${summary.denominations.subtotal50.toStringAsFixed(0)}'),
                  if (summary.denominations.count20 > 0)
                    _pwLine(
                        'Rs. 20 x ${summary.denominations.count20}:',
                        'Rs. ${summary.denominations.subtotal20.toStringAsFixed(0)}'),
                  if (summary.denominations.count10 > 0)
                    _pwLine(
                        'Rs. 10 x ${summary.denominations.count10}:',
                        'Rs. ${summary.denominations.subtotal10.toStringAsFixed(0)}'),
                  if (summary.denominations.count5 > 0)
                    _pwLine(
                        'Rs. 5 x ${summary.denominations.count5}:',
                        'Rs. ${summary.denominations.subtotal5.toStringAsFixed(0)}'),
                  if (summary.denominations.coinsValue > 0)
                    _pwLine('Coins Total:',
                        'Rs. ${summary.denominations.coinsValue.toStringAsFixed(2)}'),
                  pw.Divider(thickness: 0.5),
                  _pwLine('TOTAL PHYSICAL CASH:',
                      'Rs. ${summary.physicalCashCount.toStringAsFixed(2)}',
                      isBold: true),
                  pw.Text('--------------------------------',
                      style: const pw.TextStyle(fontSize: 10)),
                ],

                // EOD Final Cash Settlement & Float
                pw.SizedBox(height: 4),
                pw.Text('EOD CASH SETTLEMENT',
                    style: const pw.TextStyle(
                        fontWeight: pw.FontWeight.bold, fontSize: 10)),
                pw.SizedBox(height: 2),
                _pwLine('Actual Cash Count:',
                    'Rs. ${summary.physicalCashCount.toStringAsFixed(2)}'),
                _pwLine('Retained Cash Float:',
                    'Rs. ${summary.retainedCashFloat.toStringAsFixed(2)}'),
                pw.Divider(thickness: 0.8),
                _pwLine('NET CASH TO HANDOVER:',
                    'Rs. ${summary.netCashHandover.toStringAsFixed(2)}',
                    isBold: true),
                pw.Divider(thickness: 0.8),
                _pwLine('Next Day Opening Cash:',
                    'Rs. ${summary.nextDayOpeningCash.toStringAsFixed(2)}'),
                if (summary.handoverSplit.ownerCash > 0)
                  _pwLine('  - Owner Cash:',
                      'Rs. ${summary.handoverSplit.ownerCash.toStringAsFixed(2)}'),
                if (summary.handoverSplit.bankDeposit > 0)
                  _pwLine('  - Bank Deposit:',
                      'Rs. ${summary.handoverSplit.bankDeposit.toStringAsFixed(2)}'),
                if (summary.handoverSplit.otherHandover > 0)
                  _pwLine(
                      '  - Other (${summary.handoverSplit.otherRecipientName}):',
                      'Rs. ${summary.handoverSplit.otherHandover.toStringAsFixed(2)}'),
                _pwLine('Register Status:', summary.resolvedClosingStatus,
                    isBold: true),
                pw.Text('--------------------------------',
                    style: const pw.TextStyle(fontSize: 10)),

                // Category Breakdown
                if (summary.categoryBreakdown.isNotEmpty) ...[
                  pw.SizedBox(height: 4),
                  pw.Text('CATEGORY BREAKDOWN',
                      style: const pw.TextStyle(
                          fontWeight: pw.FontWeight.bold, fontSize: 10)),
                  pw.SizedBox(height: 2),
                  ...summary.categoryBreakdown.values.map((c) {
                    return _pwLine(
                      '${c.category} (${c.units}):',
                      'Rs. ${c.totalAmount.toStringAsFixed(2)}',
                    );
                  }),
                  pw.SizedBox(height: 4),
                  pw.Text('--------------------------------',
                      style: const pw.TextStyle(fontSize: 10)),
                ],

                // Top Products
                if (summary.topSellingProducts.isNotEmpty) ...[
                  pw.SizedBox(height: 4),
                  pw.Text('TOP PRODUCTS SOLD',
                      style: const pw.TextStyle(
                          fontWeight: pw.FontWeight.bold, fontSize: 10)),
                  pw.SizedBox(height: 2),
                  ...summary.topSellingProducts.take(5).map((p) {
                    return _pwLine(
                      '${p.name.length > 18 ? "${p.name.substring(0, 16)}.." : p.name} (x${p.qty})',
                      'Rs. ${p.totalAmount.toStringAsFixed(0)}',
                    );
                  }),
                  pw.SizedBox(height: 4),
                  pw.Text('--------------------------------',
                      style: const pw.TextStyle(fontSize: 10)),
                ],

                // Signatures
                pw.SizedBox(height: 20),
                pw.Text('Staff Signature:  ___________________',
                    style: const pw.TextStyle(fontSize: 9)),
                pw.SizedBox(height: 14),
                pw.Text('Owner Signature:  ___________________',
                    style: const pw.TextStyle(fontSize: 9)),
                pw.SizedBox(height: 10),
                pw.Center(
                  child: pw.Text('*** REGISTER CLOSED & AUDITED ***',
                      style: const pw.TextStyle(fontSize: 8)),
                ),
                pw.SizedBox(height: 10),
              ],
            );
          },
        ),
      );

      await Printing.layoutPdf(
        name: 'EOD_Slip_${summary.dateString}',
        onLayout: (PdfPageFormat format) async => doc.save(),
      );
    } catch (e) {
      if (context.mounted) {
        toast(context, 'Thermal slip print failed: $e', error: true);
      }
    }
  }

  /// Share daily summary report to WhatsApp
  Future<void> shareEodWhatsApp(
    BuildContext context,
    DailyRegisterSummary summary, {
    String? targetPhone,
  }) async {
    final dateDisplay = toDisplayDate(summary.date);
    final discText = summary.cashDiscrepancy == 0
        ? '✅ Exact Match (₹0)'
        : (summary.cashDiscrepancy > 0
            ? '⚠️ Cash Over: +₹${summary.cashDiscrepancy.toStringAsFixed(2)}'
            : '🚨 Cash Shortage: -₹${summary.cashDiscrepancy.abs().toStringAsFixed(2)}');

    final text = '''
📊 *TEKFIX ERP — END-OF-DAY (EOD) CLOSING REPORT*
📅 *Date:* $dateDisplay
⏰ *Store Hours:* ${summary.openingTime} - ${summary.closingTime}
👤 *Closed By:* ${summary.closedByStaffName.isNotEmpty ? summary.closedByStaffName : 'Staff'}
🧾 *Total Invoices:* ${summary.totalOrdersCount}

💰 *REVENUE & COLLECTIONS:*
• Gross Sales: ₹${summary.grossSales.toStringAsFixed(2)}
• Total Discounts: ₹${summary.totalDiscounts.toStringAsFixed(2)}
• *Net Day Revenue:* *₹${summary.netRevenue.toStringAsFixed(2)}*

💵 *PAYMENT DRAWER RECONCILIATION:*
• Opening Cash: ₹${summary.openingCash.toStringAsFixed(2)}
• Cash Collections: ₹${summary.totalCash.toStringAsFixed(2)}
${summary.cashRentPaid > 0 ? "• Daily Rent Paid (Cash): -₹${summary.cashRentPaid.toStringAsFixed(2)}\n" : ""}${summary.ownerSalaryDrawnToday > 0 ? "• Owner Salary Drawn Today: -₹${summary.ownerSalaryDrawnToday.toStringAsFixed(2)}\n" : ""}${summary.ownerExcessDrawingsToday > 0 ? "• Owner Excess Drawings Today: -₹${summary.ownerExcessDrawingsToday.toStringAsFixed(2)}\n" : ""}${summary.otherCashExpenses > 0 ? "• Other Cash Expenses: -₹${summary.otherCashExpenses.toStringAsFixed(2)}\n" : ""}${summary.refunds > 0 ? "• Refunds/Returns: -₹${summary.refunds.toStringAsFixed(2)}\n" : ""}• Expected Closing Cash: ₹${summary.expectedClosingCash.toStringAsFixed(2)}
• Physical Cash Counted: ₹${summary.physicalCashCount.toStringAsFixed(2)}
• Cash Status: $discText
• UPI / GPay: ₹${summary.totalUpi.toStringAsFixed(2)}
• Card Payments: ₹${summary.totalCard.toStringAsFixed(2)}
${summary.totalBankExpenses > 0 ? "• Bank Expenses Paid: -₹${summary.totalBankExpenses.toStringAsFixed(2)}\n" : ""}${summary.totalDue > 0 ? "• Customer Credit/Due: ₹${summary.totalDue.toStringAsFixed(2)}\n" : ""}
🤝 *EOD CASH SETTLEMENT:*
• Actual Cash Count: ₹${summary.physicalCashCount.toStringAsFixed(2)}
• Retained Cash Float: ₹${summary.retainedCashFloat.toStringAsFixed(2)}
• *NET CASH HANDOVER: ₹${summary.netCashHandover.toStringAsFixed(2)}*
• Next Day Opening Cash: ₹${summary.nextDayOpeningCash.toStringAsFixed(2)}
• Register Status: ${summary.resolvedClosingStatus}
${summary.handoverSplit.ownerCash > 0 ? "  - Owner Cash: ₹${summary.handoverSplit.ownerCash.toStringAsFixed(2)}\n" : ""}${summary.handoverSplit.bankDeposit > 0 ? "  - Bank Deposit: ₹${summary.handoverSplit.bankDeposit.toStringAsFixed(2)}\n" : ""}${summary.handoverSplit.otherHandover > 0 ? "  - Other (${summary.handoverSplit.otherRecipientName}): ₹${summary.handoverSplit.otherHandover.toStringAsFixed(2)}\n" : ""}
📦 *CATEGORY BREAKDOWN:*
${summary.categoryBreakdown.values.map((c) => "• ${c.category}: ${c.units} units (₹${c.totalAmount.toStringAsFixed(0)})").join("\n")}

🏆 *TOP SELLING PRODUCTS:*
${summary.topSellingProducts.take(5).map((p) => "• ${p.name} (x${p.qty}) - ₹${p.totalAmount.toStringAsFixed(0)}").join("\n")}

_Generated automatically by TekFix POS & Register System_
''';

    final clean = (targetPhone ?? Db.setting('owner_phone', ''))
        .replaceAll(RegExp(r'[^0-9]'), '');
    final phone =
        clean.isEmpty ? '' : (clean.startsWith('91') ? clean : '91$clean');
    final uri = Uri.parse(phone.isNotEmpty
        ? 'https://wa.me/$phone?text=${Uri.encodeComponent(text)}'
        : 'https://wa.me/?text=${Uri.encodeComponent(text)}');

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (context.mounted) {
        toast(context, 'WhatsApp could not be opened', error: true);
      }
    }
  }

  static pw.Widget _pwLine(String k, String v, {bool isBold = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            k,
            style: pw.TextStyle(
              fontSize: 9,
              fontWeight: isBold ? pw.FontWeight.bold : pw.FontWeight.normal,
            ),
          ),
          pw.Text(
            v,
            style: pw.TextStyle(
              fontSize: 9,
              fontWeight: isBold ? pw.FontWeight.bold : pw.FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}

class _CatAccumulator {
  final String category;
  int units = 0;
  double total = 0.0;
  _CatAccumulator(this.category);
}

class _ItemAccumulator {
  final String name;
  int qty = 0;
  double total = 0.0;
  _ItemAccumulator(this.name);
}
