import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

/// Supported Telecom & Utility Operators
enum RechargeOperator {
  airtel('Bharti Airtel', 'എയർടെൽ'),
  jio('Reliance Jio', 'ജിയോ'),
  vi('Vodafone Idea (Vi)', 'വി'),
  bsnl('BSNL Mobile', 'ബി.എസ്.എൻ.എൽ'),
  other('Other / Utilities', 'മറ്റ് യൂട്ടിലിറ്റികൾ');

  final String displayName;
  final String malayalam;
  const RechargeOperator(this.displayName, this.malayalam);

  static RechargeOperator fromString(String? val) {
    if (val == null) return RechargeOperator.other;
    final lower = val.toLowerCase().trim();
    if (lower.contains('airtel')) return RechargeOperator.airtel;
    if (lower.contains('jio')) return RechargeOperator.jio;
    if (lower.contains('vi') || lower.contains('vodafone') || lower.contains('idea')) {
      return RechargeOperator.vi;
    }
    if (lower.contains('bsnl')) return RechargeOperator.bsnl;
    return RechargeOperator.other;
  }
}

/// Recharge Funding Type
enum RechargeFundingType {
  ownMoney('Own Money / Prepaid', 'സ്വന്തം ബാങ്ക് പണം'),
  distributorCredit('Distributor Credit', 'ഡിസ്ട്രിബ്യൂട്ടർ ക്രെഡിറ്റ്');

  final String label;
  final String malayalam;
  const RechargeFundingType(this.label, this.malayalam);

  static RechargeFundingType fromString(String? val) {
    if (val == null) return RechargeFundingType.distributorCredit;
    final lower = val.toLowerCase();
    if (lower.contains('own') || lower.contains('prepaid')) {
      return RechargeFundingType.ownMoney;
    }
    return RechargeFundingType.distributorCredit;
  }
}

/// Customer Payment Collection Mode
enum RechargePaymentMode {
  cash('Cash', 'ക്യാഷ്'),
  upi('UPI', 'യു.പി.ഐ'),
  card('Card', 'കാർഡ്');

  final String label;
  final String malayalam;
  const RechargePaymentMode(this.label, this.malayalam);

  static RechargePaymentMode fromString(String? val) {
    if (val == null) return RechargePaymentMode.cash;
    final lower = val.toLowerCase();
    if (lower.contains('upi')) return RechargePaymentMode.upi;
    if (lower.contains('card')) return RechargePaymentMode.card;
    return RechargePaymentMode.cash;
  }
}

/// Manual Operator Confirmation Status
enum RechargeStatus {
  pending('Pending', 'തീരുമാനമായിട്ടില്ല'),
  success('Success', 'വിജയിച്ചു'),
  failed('Failed', 'പരാജയപ്പെട്ടു'),
  refunded('Refunded', 'തിരികെ നൽകി'),
  disputed('Owner Review (Disputed)', 'ഉടമയുടെ പരിശോധന വേണം');

  final String label;
  final String malayalam;
  const RechargeStatus(this.label, this.malayalam);

  static RechargeStatus fromString(String? val) {
    if (val == null) return RechargeStatus.pending;
    final lower = val.toLowerCase();
    if (lower.contains('dispute') || lower.contains('review')) {
      return RechargeStatus.disputed;
    }
    if (lower.contains('success')) return RechargeStatus.success;
    if (lower.contains('refund')) return RechargeStatus.refunded;
    if (lower.contains('fail')) return RechargeStatus.failed;
    return RechargeStatus.pending;
  }
}

/// Short Distributor Item for Dropdown selection
class DistributorItem {
  final String id;
  final String name;
  final String defaultOperator;

  const DistributorItem({
    required this.id,
    required this.name,
    this.defaultOperator = 'All',
  });

  static const List<DistributorItem> defaultPresets = [
    DistributorItem(
      id: 'DIST_APEX_AIRTEL',
      name: 'Apex Telecom (Airtel Distributor)',
      defaultOperator: 'Airtel',
    ),
    DistributorItem(
      id: 'DIST_MURUGAN_VI',
      name: 'Sree Murugan Telelinks (Vi Distributor)',
      defaultOperator: 'Vi',
    ),
    DistributorItem(
      id: 'DIST_JIO_AGENCY',
      name: 'Kochi Jio Prime Agency',
      defaultOperator: 'Jio',
    ),
    DistributorItem(
      id: 'DIST_BSNL_CSC',
      name: 'BSNL Direct CSC Channel',
      defaultOperator: 'BSNL',
    ),
    DistributorItem(
      id: 'DIST_LOCAL_GEN',
      name: 'General Multi-Recharge Agency',
      defaultOperator: 'Other',
    ),
  ];
}

/// Master Quick Recharge Entry Model
class RechargeEntry {
  final String rechargeId;
  final String shopId;
  final RechargeOperator operator;
  final String customerMobile;
  final double amount;
  final int amountPaise;
  final RechargeFundingType fundingType;
  final String? distributorId;
  final String? distributorName;
  final RechargePaymentMode paymentMode;
  final String referenceNumber;
  final RechargeStatus status;
  final String staffId;
  final String staffName;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String dateString;
  final String notes;
  final bool walletDebited;
  final bool customerPaymentCollected;
  final bool requiresOwnerReview;
  final String? disputeNote;
  final String? refundId;
  final double? refundAmount;
  final String? refundMethod;
  final bool isOfflinePending;

  const RechargeEntry({
    required this.rechargeId,
    required this.shopId,
    required this.operator,
    this.customerMobile = '',
    required this.amount,
    required this.amountPaise,
    required this.fundingType,
    this.distributorId,
    this.distributorName,
    required this.paymentMode,
    this.referenceNumber = '',
    required this.status,
    required this.staffId,
    required this.staffName,
    required this.createdAt,
    required this.updatedAt,
    required this.dateString,
    this.notes = '',
    this.walletDebited = false,
    this.customerPaymentCollected = false,
    this.requiresOwnerReview = false,
    this.disputeNote,
    this.refundId,
    this.refundAmount,
    this.refundMethod,
    this.isOfflinePending = false,
  });

  Map<String, dynamic> toMap({bool forFirestore = true}) {
    return {
      'rechargeId': rechargeId,
      'shopId': shopId,
      'operator': operator.name,
      'operatorName': operator.displayName,
      'customerMobile': customerMobile.trim(),
      'amount': amount,
      'amountPaise': amountPaise,
      'fundingType': fundingType.name,
      'distributorId': distributorId,
      'distributorName': distributorName,
      'paymentMode': paymentMode.name,
      'referenceNumber': referenceNumber.trim(),
      'status': status.name,
      'staffId': staffId,
      'staffName': staffName,
      'dateString': dateString,
      'notes': notes.trim(),
      'walletDebited': walletDebited,
      'customerPaymentCollected': customerPaymentCollected,
      'requiresOwnerReview': requiresOwnerReview,
      'disputeNote': disputeNote,
      'refundId': refundId,
      'refundAmount': refundAmount,
      'refundMethod': refundMethod,
      'isOfflinePending': isOfflinePending,
      'createdAt': forFirestore
          ? Timestamp.fromDate(createdAt)
          : createdAt.toIso8601String(),
      'updatedAt': forFirestore
          ? Timestamp.fromDate(updatedAt)
          : updatedAt.toIso8601String(),
    };
  }

  factory RechargeEntry.fromMap(Map<String, dynamic> map, String id) {
    DateTime parseDate(dynamic val) {
      if (val is Timestamp) return val.toDate();
      if (val is DateTime) return val;
      if (val is int) return DateTime.fromMillisecondsSinceEpoch(val);
      if (val != null) {
        return DateTime.tryParse(val.toString()) ?? DateTime.now();
      }
      return DateTime.now();
    }

    final double amt = (map['amount'] as num?)?.toDouble() ?? 0.0;
    final int paise = (map['amountPaise'] as num?)?.toInt() ?? (amt * 100).round();

    return RechargeEntry(
      rechargeId: map['rechargeId']?.toString() ?? id,
      shopId: map['shopId']?.toString() ?? '',
      operator: RechargeOperator.fromString(map['operator']?.toString() ?? map['operatorName']?.toString()),
      customerMobile: map['customerMobile']?.toString() ?? '',
      amount: amt,
      amountPaise: paise,
      fundingType: RechargeFundingType.fromString(map['fundingType']?.toString()),
      distributorId: map['distributorId']?.toString(),
      distributorName: map['distributorName']?.toString(),
      paymentMode: RechargePaymentMode.fromString(map['paymentMode']?.toString()),
      referenceNumber: map['referenceNumber']?.toString() ?? '',
      status: RechargeStatus.fromString(map['status']?.toString()),
      staffId: map['staffId']?.toString() ?? 'staff',
      staffName: map['staffName']?.toString() ?? 'Staff',
      createdAt: parseDate(map['createdAt']),
      updatedAt: parseDate(map['updatedAt']),
      dateString: map['dateString']?.toString() ?? '',
      notes: map['notes']?.toString() ?? '',
      walletDebited: map['walletDebited'] as bool? ?? false,
      customerPaymentCollected:
          map['customerPaymentCollected'] as bool? ?? false,
      requiresOwnerReview: map['requiresOwnerReview'] as bool? ?? false,
      disputeNote: map['disputeNote']?.toString(),
      refundId: map['refundId']?.toString(),
      refundAmount: (map['refundAmount'] as num?)?.toDouble(),
      refundMethod: map['refundMethod']?.toString(),
      isOfflinePending: map['isOfflinePending'] as bool? ?? false,
    );
  }

  factory RechargeEntry.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    return RechargeEntry.fromMap(doc.data() ?? {}, doc.id);
  }

  RechargeEntry copyWith({
    RechargeStatus? status,
    DateTime? updatedAt,
    String? notes,
    bool? walletDebited,
    bool? customerPaymentCollected,
    bool? requiresOwnerReview,
    String? disputeNote,
    String? refundId,
    double? refundAmount,
    String? refundMethod,
    bool? isOfflinePending,
  }) {
    return RechargeEntry(
      rechargeId: rechargeId,
      shopId: shopId,
      operator: operator,
      customerMobile: customerMobile,
      amount: amount,
      amountPaise: amountPaise,
      fundingType: fundingType,
      distributorId: distributorId,
      distributorName: distributorName,
      paymentMode: paymentMode,
      referenceNumber: referenceNumber,
      status: status ?? this.status,
      staffId: staffId,
      staffName: staffName,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      dateString: dateString,
      notes: notes ?? this.notes,
      walletDebited: walletDebited ?? this.walletDebited,
      customerPaymentCollected:
          customerPaymentCollected ?? this.customerPaymentCollected,
      requiresOwnerReview: requiresOwnerReview ?? this.requiresOwnerReview,
      disputeNote: disputeNote ?? this.disputeNote,
      refundId: refundId ?? this.refundId,
      refundAmount: refundAmount ?? this.refundAmount,
      refundMethod: refundMethod ?? this.refundMethod,
      isOfflinePending: isOfflinePending ?? this.isOfflinePending,
    );
  }
}


/// Operator-wise Digital Wallet Float
class OperatorWallet {
  final String walletId;
  final String shopId;
  final RechargeOperator operator;
  final String operatorName;
  final int ownPrepaidBalancePaise;
  final int distributorCreditBalancePaise;
  final DateTime updatedAt;

  const OperatorWallet({
    required this.walletId,
    required this.shopId,
    required this.operator,
    required this.operatorName,
    this.ownPrepaidBalancePaise = 0,
    this.distributorCreditBalancePaise = 0,
    required this.updatedAt,
  });

  int get totalBalancePaise =>
      ownPrepaidBalancePaise + distributorCreditBalancePaise;
  double get ownPrepaidBalance => ownPrepaidBalancePaise / 100.0;
  double get distributorCreditBalance => distributorCreditBalancePaise / 100.0;
  double get totalBalance => totalBalancePaise / 100.0;

  Map<String, dynamic> toMap({bool forFirestore = true}) => {
        'walletId': walletId,
        'shopId': shopId,
        'operator': operator.name,
        'operatorName': operatorName,
        'ownPrepaidBalancePaise': ownPrepaidBalancePaise,
        'distributorCreditBalancePaise': distributorCreditBalancePaise,
        'totalBalancePaise': totalBalancePaise,
        'ownPrepaidBalance': ownPrepaidBalance,
        'distributorCreditBalance': distributorCreditBalance,
        'totalBalance': totalBalance,
        'updatedAt': forFirestore
            ? Timestamp.fromDate(updatedAt)
            : updatedAt.toIso8601String(),
      };

  factory OperatorWallet.fromMap(Map<String, dynamic> m, String id) {
    DateTime parseDt(dynamic val) {
      if (val is Timestamp) return val.toDate();
      if (val is DateTime) return val;
      if (val is int) return DateTime.fromMillisecondsSinceEpoch(val);
      if (val != null) {
        return DateTime.tryParse(val.toString()) ?? DateTime.now();
      }
      return DateTime.now();
    }

    final ownPaise = (m['ownPrepaidBalancePaise'] as num?)?.toInt() ??
        (((m['ownPrepaidBalance'] as num?)?.toDouble() ?? 0.0) * 100).round();
    final distPaise = (m['distributorCreditBalancePaise'] as num?)?.toInt() ??
        (((m['distributorCreditBalance'] as num?)?.toDouble() ?? 0.0) * 100).round();

    final op = RechargeOperator.fromString(
        m['operator']?.toString() ?? m['operatorName']?.toString());

    return OperatorWallet(
      walletId: m['walletId']?.toString() ?? id,
      shopId: m['shopId']?.toString() ?? '',
      operator: op,
      operatorName: m['operatorName']?.toString() ?? op.displayName,
      ownPrepaidBalancePaise: ownPaise,
      distributorCreditBalancePaise: distPaise,
      updatedAt: parseDt(m['updatedAt']),
    );
  }

  factory OperatorWallet.fromFirestore(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    return OperatorWallet.fromMap(doc.data() ?? {}, doc.id);
  }

  OperatorWallet copyWith({
    int? ownPrepaidBalancePaise,
    int? distributorCreditBalancePaise,
    DateTime? updatedAt,
  }) {
    return OperatorWallet(
      walletId: walletId,
      shopId: shopId,
      operator: operator,
      operatorName: operatorName,
      ownPrepaidBalancePaise:
          ownPrepaidBalancePaise ?? this.ownPrepaidBalancePaise,
      distributorCreditBalancePaise:
          distributorCreditBalancePaise ?? this.distributorCreditBalancePaise,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// Immutable Double-Entry Wallet Ledger Entry
class WalletLedgerEntry {
  final String txnId;
  final String shopId;
  final String walletId;
  final RechargeOperator operator;
  final RechargeFundingType fundingType;
  final String entryType; // TOPUP, CREDIT_LOAD, RECHARGE_DEBIT, COMMISSION_CREDIT, ADJUSTMENT
  final double amount;
  final int amountPaise;
  final int balanceBeforePaise;
  final int balanceAfterPaise;
  final String referenceId;
  final String description;
  final String staffId;
  final String staffName;
  final DateTime timestamp;

  const WalletLedgerEntry({
    required this.txnId,
    required this.shopId,
    required this.walletId,
    required this.operator,
    required this.fundingType,
    required this.entryType,
    required this.amount,
    required this.amountPaise,
    required this.balanceBeforePaise,
    required this.balanceAfterPaise,
    required this.referenceId,
    required this.description,
    required this.staffId,
    required this.staffName,
    required this.timestamp,
  });

  Map<String, dynamic> toMap({bool forFirestore = true}) => {
        'txnId': txnId,
        'shopId': shopId,
        'walletId': walletId,
        'operator': operator.name,
        'fundingType': fundingType.name,
        'entryType': entryType,
        'amount': amount,
        'amountPaise': amountPaise,
        'balanceBeforePaise': balanceBeforePaise,
        'balanceAfterPaise': balanceAfterPaise,
        'referenceId': referenceId,
        'description': description,
        'staffId': staffId,
        'staffName': staffName,
        'timestamp': forFirestore
            ? Timestamp.fromDate(timestamp)
            : timestamp.toIso8601String(),
      };

  factory WalletLedgerEntry.fromMap(Map<String, dynamic> m, String id) {
    DateTime parseDt(dynamic val) {
      if (val is Timestamp) return val.toDate();
      if (val is DateTime) return val;
      if (val != null) {
        return DateTime.tryParse(val.toString()) ?? DateTime.now();
      }
      return DateTime.now();
    }

    final amt = (m['amount'] as num?)?.toDouble() ?? 0.0;
    final paise = (m['amountPaise'] as num?)?.toInt() ?? (amt * 100).round();

    return WalletLedgerEntry(
      txnId: m['txnId']?.toString() ?? id,
      shopId: m['shopId']?.toString() ?? '',
      walletId: m['walletId']?.toString() ?? '',
      operator: RechargeOperator.fromString(m['operator']?.toString()),
      fundingType:
          RechargeFundingType.fromString(m['fundingType']?.toString()),
      entryType: m['entryType']?.toString() ?? 'ADJUSTMENT',
      amount: amt,
      amountPaise: paise,
      balanceBeforePaise:
          (m['balanceBeforePaise'] as num?)?.toInt() ?? 0,
      balanceAfterPaise:
          (m['balanceAfterPaise'] as num?)?.toInt() ?? 0,
      referenceId: m['referenceId']?.toString() ?? '',
      description: m['description']?.toString() ?? '',
      staffId: m['staffId']?.toString() ?? 'staff',
      staffName: m['staffName']?.toString() ?? 'Staff',
      timestamp: parseDt(m['timestamp']),
    );
  }

  factory WalletLedgerEntry.fromFirestore(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    return WalletLedgerEntry.fromMap(doc.data() ?? {}, doc.id);
  }

  WalletLedgerEntry copyWith({
    String? txnId,
    String? shopId,
    String? walletId,
    RechargeOperator? operator,
    RechargeFundingType? fundingType,
    String? entryType,
    double? amount,
    int? amountPaise,
    int? balanceBeforePaise,
    int? balanceAfterPaise,
    String? referenceId,
    String? description,
    String? staffId,
    String? staffName,
    DateTime? timestamp,
  }) {
    return WalletLedgerEntry(
      txnId: txnId ?? this.txnId,
      shopId: shopId ?? this.shopId,
      walletId: walletId ?? this.walletId,
      operator: operator ?? this.operator,
      fundingType: fundingType ?? this.fundingType,
      entryType: entryType ?? this.entryType,
      amount: amount ?? this.amount,
      amountPaise: amountPaise ?? this.amountPaise,
      balanceBeforePaise: balanceBeforePaise ?? this.balanceBeforePaise,
      balanceAfterPaise: balanceAfterPaise ?? this.balanceAfterPaise,
      referenceId: referenceId ?? this.referenceId,
      description: description ?? this.description,
      staffId: staffId ?? this.staffId,
      staffName: staffName ?? this.staffName,
      timestamp: timestamp ?? this.timestamp,
    );
  }
}

/// Telecom Distributor Profile with Live Trade Payable Liability
class DistributorProfile {
  final String id;
  final String shopId;
  final String name;
  final String phone;
  final String contactPerson;
  final RechargeOperator defaultOperator;
  final int openingPayablePaise;
  final int totalCreditReceivedPaise;
  final int totalPaymentsMadePaise;
  final int totalAdjustmentsPaise;
  final DateTime? lastPaymentDate;
  final DateTime updatedAt;

  const DistributorProfile({
    required this.id,
    required this.shopId,
    required this.name,
    this.phone = '',
    this.contactPerson = '',
    this.defaultOperator = RechargeOperator.other,
    this.openingPayablePaise = 0,
    this.totalCreditReceivedPaise = 0,
    this.totalPaymentsMadePaise = 0,
    this.totalAdjustmentsPaise = 0,
    this.lastPaymentDate,
    required this.updatedAt,
  });

  int get currentOutstandingPaise =>
      openingPayablePaise +
      totalCreditReceivedPaise -
      totalPaymentsMadePaise -
      totalAdjustmentsPaise;

  double get currentOutstanding => currentOutstandingPaise / 100.0;
  double get totalCreditReceived => totalCreditReceivedPaise / 100.0;
  double get totalPaymentsMade => totalPaymentsMadePaise / 100.0;

  Map<String, dynamic> toMap({bool forFirestore = true}) => {
        'id': id,
        'shopId': shopId,
        'name': name,
        'phone': phone,
        'contactPerson': contactPerson,
        'defaultOperator': defaultOperator.name,
        'openingPayablePaise': openingPayablePaise,
        'totalCreditReceivedPaise': totalCreditReceivedPaise,
        'totalPaymentsMadePaise': totalPaymentsMadePaise,
        'totalAdjustmentsPaise': totalAdjustmentsPaise,
        'currentOutstandingPaise': currentOutstandingPaise,
        'currentOutstanding': currentOutstanding,
        'lastPaymentDate': lastPaymentDate != null
            ? (forFirestore
                ? Timestamp.fromDate(lastPaymentDate!)
                : lastPaymentDate!.toIso8601String())
            : null,
        'updatedAt': forFirestore
            ? Timestamp.fromDate(updatedAt)
            : updatedAt.toIso8601String(),
      };

  factory DistributorProfile.fromMap(Map<String, dynamic> m, String id) {
    DateTime? parseDt(dynamic val) {
      if (val == null) return null;
      if (val is Timestamp) return val.toDate();
      if (val is DateTime) return val;
      return DateTime.tryParse(val.toString());
    }

    return DistributorProfile(
      id: m['id']?.toString() ?? id,
      shopId: m['shopId']?.toString() ?? '',
      name: m['name']?.toString() ?? 'Distributor',
      phone: m['phone']?.toString() ?? '',
      contactPerson: m['contactPerson']?.toString() ?? '',
      defaultOperator:
          RechargeOperator.fromString(m['defaultOperator']?.toString()),
      openingPayablePaise:
          (m['openingPayablePaise'] as num?)?.toInt() ?? 0,
      totalCreditReceivedPaise:
          (m['totalCreditReceivedPaise'] as num?)?.toInt() ?? 0,
      totalPaymentsMadePaise:
          (m['totalPaymentsMadePaise'] as num?)?.toInt() ?? 0,
      totalAdjustmentsPaise:
          (m['totalAdjustmentsPaise'] as num?)?.toInt() ?? 0,
      lastPaymentDate: parseDt(m['lastPaymentDate']),
      updatedAt: parseDt(m['updatedAt']) ?? DateTime.now(),
    );
  }

  factory DistributorProfile.fromFirestore(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    return DistributorProfile.fromMap(doc.data() ?? {}, doc.id);
  }

  DistributorProfile copyWith({
    String? name,
    String? phone,
    String? contactPerson,
    RechargeOperator? defaultOperator,
    int? openingPayablePaise,
    int? totalCreditReceivedPaise,
    int? totalPaymentsMadePaise,
    int? totalAdjustmentsPaise,
    DateTime? lastPaymentDate,
    DateTime? updatedAt,
  }) {
    return DistributorProfile(
      id: id,
      shopId: shopId,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      contactPerson: contactPerson ?? this.contactPerson,
      defaultOperator: defaultOperator ?? this.defaultOperator,
      openingPayablePaise: openingPayablePaise ?? this.openingPayablePaise,
      totalCreditReceivedPaise:
          totalCreditReceivedPaise ?? this.totalCreditReceivedPaise,
      totalPaymentsMadePaise:
          totalPaymentsMadePaise ?? this.totalPaymentsMadePaise,
      totalAdjustmentsPaise:
          totalAdjustmentsPaise ?? this.totalAdjustmentsPaise,
      lastPaymentDate: lastPaymentDate ?? this.lastPaymentDate,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// Immutable Distributor Ledger Transaction Entry
class DistributorLedgerEntry {
  final String entryId;
  final String shopId;
  final String distributorId;
  final String distributorName;
  final String entryType; // OPENING, CREDIT_RECEIVED, PAYMENT_MADE, COMMISSION_ADJUSTMENT
  final double amount;
  final int amountPaise;
  final String? paymentMode; // CASH, BANK, UPI
  final int outstandingBeforePaise;
  final int outstandingAfterPaise;
  final String referenceNumber;
  final String description;
  final String staffId;
  final String staffName;
  final DateTime timestamp;

  const DistributorLedgerEntry({
    required this.entryId,
    required this.shopId,
    required this.distributorId,
    required this.distributorName,
    required this.entryType,
    required this.amount,
    required this.amountPaise,
    this.paymentMode,
    required this.outstandingBeforePaise,
    required this.outstandingAfterPaise,
    this.referenceNumber = '',
    this.description = '',
    required this.staffId,
    required this.staffName,
    required this.timestamp,
  });

  Map<String, dynamic> toMap({bool forFirestore = true}) => {
        'entryId': entryId,
        'shopId': shopId,
        'distributorId': distributorId,
        'distributorName': distributorName,
        'entryType': entryType,
        'amount': amount,
        'amountPaise': amountPaise,
        'paymentMode': paymentMode,
        'outstandingBeforePaise': outstandingBeforePaise,
        'outstandingAfterPaise': outstandingAfterPaise,
        'referenceNumber': referenceNumber,
        'description': description,
        'staffId': staffId,
        'staffName': staffName,
        'timestamp': forFirestore
            ? Timestamp.fromDate(timestamp)
            : timestamp.toIso8601String(),
      };

  factory DistributorLedgerEntry.fromMap(Map<String, dynamic> m, String id) {
    DateTime parseDt(dynamic val) {
      if (val is Timestamp) return val.toDate();
      if (val is DateTime) return val;
      return DateTime.tryParse(val.toString()) ?? DateTime.now();
    }

    final amt = (m['amount'] as num?)?.toDouble() ?? 0.0;
    final paise = (m['amountPaise'] as num?)?.toInt() ?? (amt * 100).round();

    return DistributorLedgerEntry(
      entryId: m['entryId']?.toString() ?? id,
      shopId: m['shopId']?.toString() ?? '',
      distributorId: m['distributorId']?.toString() ?? '',
      distributorName: m['distributorName']?.toString() ?? '',
      entryType: m['entryType']?.toString() ?? 'CREDIT_RECEIVED',
      amount: amt,
      amountPaise: paise,
      paymentMode: m['paymentMode']?.toString(),
      outstandingBeforePaise:
          (m['outstandingBeforePaise'] as num?)?.toInt() ?? 0,
      outstandingAfterPaise:
          (m['outstandingAfterPaise'] as num?)?.toInt() ?? 0,
      referenceNumber: m['referenceNumber']?.toString() ?? '',
      description: m['description']?.toString() ?? '',
      staffId: m['staffId']?.toString() ?? 'staff',
      staffName: m['staffName']?.toString() ?? 'Staff',
      timestamp: parseDt(m['timestamp']),
    );
  }

  factory DistributorLedgerEntry.fromFirestore(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    return DistributorLedgerEntry.fromMap(doc.data() ?? {}, doc.id);
  }
}


/// Daily Summary of Recharge Collections Separated by Payment Mode & Operator
class DailyRechargeCollectionSummary {
  final String dateString;
  final String shopId;
  final int totalCollectionPaise;
  final int cashCollectionPaise;
  final int upiCollectionPaise;
  final int cardCollectionPaise;
  final Map<RechargeOperator, int> operatorCollectionsPaise;
  final int successfulCount;
  final int pendingCount;
  final int failedCount;
  final int refundedCount;

  const DailyRechargeCollectionSummary({
    required this.dateString,
    required this.shopId,
    this.totalCollectionPaise = 0,
    this.cashCollectionPaise = 0,
    this.upiCollectionPaise = 0,
    this.cardCollectionPaise = 0,
    this.operatorCollectionsPaise = const {},
    this.successfulCount = 0,
    this.pendingCount = 0,
    this.failedCount = 0,
    this.refundedCount = 0,
  });

  double get totalCollection => totalCollectionPaise / 100.0;
  double get cashCollection => cashCollectionPaise / 100.0;
  double get upiCollection => upiCollectionPaise / 100.0;
  double get cardCollection => cardCollectionPaise / 100.0;

  double getOperatorCollection(RechargeOperator op) =>
      (operatorCollectionsPaise[op] ?? 0) / 100.0;

  DailyRechargeCollectionSummary copyWith({
    String? dateString,
    String? shopId,
    int? totalCollectionPaise,
    int? cashCollectionPaise,
    int? upiCollectionPaise,
    int? cardCollectionPaise,
    Map<RechargeOperator, int>? operatorCollectionsPaise,
    int? successfulCount,
    int? pendingCount,
    int? failedCount,
    int? refundedCount,
  }) {
    return DailyRechargeCollectionSummary(
      dateString: dateString ?? this.dateString,
      shopId: shopId ?? this.shopId,
      totalCollectionPaise: totalCollectionPaise ?? this.totalCollectionPaise,
      cashCollectionPaise: cashCollectionPaise ?? this.cashCollectionPaise,
      upiCollectionPaise: upiCollectionPaise ?? this.upiCollectionPaise,
      cardCollectionPaise: cardCollectionPaise ?? this.cardCollectionPaise,
      operatorCollectionsPaise:
          operatorCollectionsPaise ?? this.operatorCollectionsPaise,
      successfulCount: successfulCount ?? this.successfulCount,
      pendingCount: pendingCount ?? this.pendingCount,
      failedCount: failedCount ?? this.failedCount,
      refundedCount: refundedCount ?? this.refundedCount,
    );
  }

  Map<String, dynamic> toMap() => {
        'dateString': dateString,
        'shopId': shopId,
        'totalCollectionPaise': totalCollectionPaise,
        'cashCollectionPaise': cashCollectionPaise,
        'upiCollectionPaise': upiCollectionPaise,
        'cardCollectionPaise': cardCollectionPaise,
        'totalCollection': totalCollection,
        'cashCollection': cashCollection,
        'upiCollection': upiCollection,
        'cardCollection': cardCollection,
        'operatorCollectionsPaise': operatorCollectionsPaise.map(
          (k, v) => MapEntry(k.name, v),
        ),
        'successfulCount': successfulCount,
        'pendingCount': pendingCount,
        'failedCount': failedCount,
        'refundedCount': refundedCount,
      };

  factory DailyRechargeCollectionSummary.fromMap(
      Map<String, dynamic> m, String dateStr, String sId) {
    final rawOpMap = (m['operatorCollectionsPaise'] as Map?) ?? {};
    final Map<RechargeOperator, int> opMap = {};
    for (final op in RechargeOperator.values) {
      if (rawOpMap.containsKey(op.name)) {
        opMap[op] = (rawOpMap[op.name] as num?)?.toInt() ?? 0;
      }
    }

    return DailyRechargeCollectionSummary(
      dateString: m['dateString']?.toString() ?? dateStr,
      shopId: m['shopId']?.toString() ?? sId,
      totalCollectionPaise:
          (m['totalCollectionPaise'] as num?)?.toInt() ?? 0,
      cashCollectionPaise:
          (m['cashCollectionPaise'] as num?)?.toInt() ?? 0,
      upiCollectionPaise:
          (m['upiCollectionPaise'] as num?)?.toInt() ?? 0,
      cardCollectionPaise:
          (m['cardCollectionPaise'] as num?)?.toInt() ?? 0,
      operatorCollectionsPaise: opMap,
      successfulCount: (m['successfulCount'] as num?)?.toInt() ?? 0,
      pendingCount: (m['pendingCount'] as num?)?.toInt() ?? 0,
      failedCount: (m['failedCount'] as num?)?.toInt() ?? 0,
      refundedCount: (m['refundedCount'] as num?)?.toInt() ?? 0,
    );
  }

  factory DailyRechargeCollectionSummary.empty(
          String dateStr, String sId) =>
      DailyRechargeCollectionSummary(
        dateString: dateStr,
        shopId: sId,
        operatorCollectionsPaise: {
          for (final op in RechargeOperator.values) op: 0,
        },
      );
}

/// Type of Recharge Float Recovery Deposit
enum FloatDepositType {
  cashDeposit('Cash Deposit to Bank', 'ബാങ്ക് ക്യാഷ് ഡെപ്പോസിറ്റ്'),
  upiSettlement('UPI Settlement Transfer', 'യു.പി.ഐ സെറ്റിൽമെന്റ് ട്രാൻസ്ഫർ');

  final String label;
  final String malayalam;
  const FloatDepositType(this.label, this.malayalam);

  static FloatDepositType fromString(String? val) {
    if (val == null) return FloatDepositType.cashDeposit;
    final lower = val.toLowerCase();
    if (lower.contains('upi') || lower.contains('settlement')) {
      return FloatDepositType.upiSettlement;
    }
    return FloatDepositType.cashDeposit;
  }
}

/// Immutable Record of Recharge Float Recovery Deposit
class FloatDepositRecord {
  final String depositId;
  final String shopId;
  final FloatDepositType depositType;
  final double amount;
  final int amountPaise;
  final String bankAccountId;
  final String bankAccountName;
  final String dateString;
  final String referenceNumber;
  final String notes;
  final String staffId;
  final String staffName;
  final bool isConfirmed;
  final DateTime createdAt;

  const FloatDepositRecord({
    required this.depositId,
    required this.shopId,
    required this.depositType,
    required this.amount,
    required this.amountPaise,
    required this.bankAccountId,
    required this.bankAccountName,
    required this.dateString,
    this.referenceNumber = '',
    this.notes = '',
    required this.staffId,
    required this.staffName,
    this.isConfirmed = true,
    required this.createdAt,
  });

  Map<String, dynamic> toMap({bool forFirestore = true}) => {
        'depositId': depositId,
        'shopId': shopId,
        'depositType': depositType.name,
        'amount': amount,
        'amountPaise': amountPaise,
        'bankAccountId': bankAccountId,
        'bankAccountName': bankAccountName,
        'dateString': dateString,
        'referenceNumber': referenceNumber,
        'notes': notes,
        'staffId': staffId,
        'staffName': staffName,
        'isConfirmed': isConfirmed,
        'createdAt': forFirestore
            ? Timestamp.fromDate(createdAt)
            : createdAt.toIso8601String(),
      };

  factory FloatDepositRecord.fromMap(Map<String, dynamic> m, String id) {
    DateTime parseDt(dynamic val) {
      if (val is Timestamp) return val.toDate();
      if (val is DateTime) return val;
      return DateTime.tryParse(val.toString()) ?? DateTime.now();
    }

    final amt = (m['amount'] as num?)?.toDouble() ?? 0.0;
    final paise = (m['amountPaise'] as num?)?.toInt() ?? (amt * 100).round();

    return FloatDepositRecord(
      depositId: m['depositId']?.toString() ?? id,
      shopId: m['shopId']?.toString() ?? '',
      depositType: FloatDepositType.fromString(m['depositType']?.toString()),
      amount: amt,
      amountPaise: paise,
      bankAccountId: m['bankAccountId']?.toString() ?? 'PRIMARY_BANK',
      bankAccountName:
          m['bankAccountName']?.toString() ?? 'Primary Store Bank',
      dateString: m['dateString']?.toString() ?? '',
      referenceNumber: m['referenceNumber']?.toString() ?? '',
      notes: m['notes']?.toString() ?? '',
      staffId: m['staffId']?.toString() ?? 'staff',
      staffName: m['staffName']?.toString() ?? 'Staff',
      isConfirmed: m['isConfirmed'] as bool? ?? true,
      createdAt: parseDt(m['createdAt']),
    );
  }

  factory FloatDepositRecord.fromFirestore(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    return FloatDepositRecord.fromMap(doc.data() ?? {}, doc.id);
  }
}

/// Comprehensive Dashboard Summary for Distributor Liabilities & Float Recovery
class RechargeFloatSummary {
  final String dateString;
  final String shopId;
  final int totalDistributorOutstandingPaise;
  final int paidTodayPaise;
  final int pendingPayablePaise;
  final int rechargeCashAvailablePaise;
  final int rechargeCashDepositedPaise;
  final int rechargeCashRemainingPaise;

  const RechargeFloatSummary({
    required this.dateString,
    required this.shopId,
    this.totalDistributorOutstandingPaise = 0,
    this.paidTodayPaise = 0,
    this.pendingPayablePaise = 0,
    this.rechargeCashAvailablePaise = 0,
    this.rechargeCashDepositedPaise = 0,
    this.rechargeCashRemainingPaise = 0,
  });

  double get totalDistributorOutstanding =>
      totalDistributorOutstandingPaise / 100.0;
  double get paidToday => paidTodayPaise / 100.0;
  double get pendingPayable => pendingPayablePaise / 100.0;
  double get rechargeCashAvailable => rechargeCashAvailablePaise / 100.0;
  double get rechargeCashDeposited => rechargeCashDepositedPaise / 100.0;
  double get rechargeCashRemaining => rechargeCashRemainingPaise / 100.0;

  Map<String, dynamic> toMap() => {
        'dateString': dateString,
        'shopId': shopId,
        'totalDistributorOutstandingPaise': totalDistributorOutstandingPaise,
        'paidTodayPaise': paidTodayPaise,
        'pendingPayablePaise': pendingPayablePaise,
        'rechargeCashAvailablePaise': rechargeCashAvailablePaise,
        'rechargeCashDepositedPaise': rechargeCashDepositedPaise,
        'rechargeCashRemainingPaise': rechargeCashRemainingPaise,
        'totalDistributorOutstanding': totalDistributorOutstanding,
        'paidToday': paidToday,
        'pendingPayable': pendingPayable,
        'rechargeCashAvailable': rechargeCashAvailable,
        'rechargeCashDeposited': rechargeCashDeposited,
        'rechargeCashRemaining': rechargeCashRemaining,
      };

  factory RechargeFloatSummary.fromMap(
      Map<String, dynamic> m, String dateStr, String sId) {
    return RechargeFloatSummary(
      dateString: m['dateString']?.toString() ?? dateStr,
      shopId: m['shopId']?.toString() ?? sId,
      totalDistributorOutstandingPaise:
          (m['totalDistributorOutstandingPaise'] as num?)?.toInt() ?? 0,
      paidTodayPaise: (m['paidTodayPaise'] as num?)?.toInt() ?? 0,
      pendingPayablePaise:
          (m['pendingPayablePaise'] as num?)?.toInt() ?? 0,
      rechargeCashAvailablePaise:
          (m['rechargeCashAvailablePaise'] as num?)?.toInt() ?? 0,
      rechargeCashDepositedPaise:
          (m['rechargeCashDepositedPaise'] as num?)?.toInt() ?? 0,
      rechargeCashRemainingPaise:
          (m['rechargeCashRemainingPaise'] as num?)?.toInt() ?? 0,
    );
  }

  factory RechargeFloatSummary.empty(String dateStr, String sId) =>
      RechargeFloatSummary(dateString: dateStr, shopId: sId);
}

/// Printable Distributor Payment Receipt Data
class DistributorPaymentReceipt {
  final String receiptNo;
  final String distributorId;
  final String distributorName;
  final String operatorName;
  final DateTime paymentDate;
  final double amount;
  final int amountPaise;
  final String paymentMode;
  final double previousOutstanding;
  final double remainingOutstanding;
  final String referenceNumber;
  final String staffName;
  final String notes;

  const DistributorPaymentReceipt({
    required this.receiptNo,
    required this.distributorId,
    required this.distributorName,
    required this.operatorName,
    required this.paymentDate,
    required this.amount,
    required this.amountPaise,
    required this.paymentMode,
    required this.previousOutstanding,
    required this.remainingOutstanding,
    this.referenceNumber = '',
    required this.staffName,
    this.notes = '',
  });
}

/// Commission Structure: Prepaid Load Margin vs Postpaid Backend Accrual
enum RechargeCommissionType {
  prepaid('Prepaid Load Margin', 'പ്രീപെയ്ഡ് ലോഡ് കമ്മീഷൻ'),
  postpaid('Postpaid Accrual', 'പോസ്റ്റ്പെയ്ഡ് കമ്മീഷൻ');

  final String label;
  final String malayalam;
  const RechargeCommissionType(this.label, this.malayalam);

  static RechargeCommissionType fromString(String? val) {
    if (val == null) return RechargeCommissionType.prepaid;
    final lower = val.toLowerCase();
    if (lower.contains('post')) return RechargeCommissionType.postpaid;
    return RechargeCommissionType.prepaid;
  }
}

/// Status of Commission Recognition
enum CommissionStatus {
  pending('Pending Confirmation', 'തീരുമാനമായിട്ടില്ല'),
  confirmed('Confirmed Income', 'സ്ഥിരീകരിച്ചു'),
  received('Received & Realized', 'ലഭിച്ചു');

  final String label;
  final String malayalam;
  const CommissionStatus(this.label, this.malayalam);

  static CommissionStatus fromString(String? val) {
    if (val == null) return CommissionStatus.pending;
    final lower = val.toLowerCase();
    if (lower.contains('received')) return CommissionStatus.received;
    if (lower.contains('confirm')) return CommissionStatus.confirmed;
    return CommissionStatus.pending;
  }
}

/// Settlement / Realization Channel for Commission
enum CommissionSettlementMethod {
  walletCredit('Wallet Credit Addition', 'വാലറ്റ് ക്രെഡിറ്റ്'),
  distributorDiscount('Distributor Bill Discount', 'ഡിസ്ട്രിബ്യൂട്ടർ ഇളവ്'),
  bankTransfer('Direct Bank Deposit', 'ബാങ്ക് ട്രാൻസ്ഫർ'),
  cashPayout('Physical Cash Received', 'ക്യാഷ് ലഭിച്ചത്');

  final String label;
  final String malayalam;
  const CommissionSettlementMethod(this.label, this.malayalam);

  static CommissionSettlementMethod fromString(String? val) {
    if (val == null) return CommissionSettlementMethod.walletCredit;
    final lower = val.toLowerCase();
    if (lower.contains('cash')) return CommissionSettlementMethod.cashPayout;
    if (lower.contains('bank')) return CommissionSettlementMethod.bankTransfer;
    if (lower.contains('discount') || lower.contains('distributor')) {
      return CommissionSettlementMethod.distributorDiscount;
    }
    return CommissionSettlementMethod.walletCredit;
  }
}

/// Immutable Record of an Earned Recharge Commission
class RechargeCommissionEntry {
  final String commissionId;
  final String shopId;
  final RechargeOperator operator;
  final String? distributorId;
  final String? distributorName;
  final String? rechargeId;
  final double amount;
  final int amountPaise;
  final RechargeCommissionType commissionType;
  final CommissionStatus status;
  final CommissionSettlementMethod settlementMethod;
  final DateTime receivedDate;
  final String dateString;
  final String referenceNumber;
  final String notes;
  final String staffId;
  final String staffName;
  final DateTime createdAt;

  const RechargeCommissionEntry({
    required this.commissionId,
    required this.shopId,
    required this.operator,
    this.distributorId,
    this.distributorName,
    this.rechargeId,
    required this.amount,
    required this.amountPaise,
    required this.commissionType,
    required this.status,
    required this.settlementMethod,
    required this.receivedDate,
    required this.dateString,
    this.referenceNumber = '',
    this.notes = '',
    required this.staffId,
    required this.staffName,
    required this.createdAt,
  });

  Map<String, dynamic> toMap({bool forFirestore = true}) => {
        'commissionId': commissionId,
        'shopId': shopId,
        'operator': operator.name,
        'distributorId': distributorId,
        'distributorName': distributorName,
        'rechargeId': rechargeId,
        'amount': amount,
        'amountPaise': amountPaise,
        'commissionType': commissionType.name,
        'status': status.name,
        'settlementMethod': settlementMethod.name,
        'dateString': dateString,
        'referenceNumber': referenceNumber,
        'notes': notes,
        'staffId': staffId,
        'staffName': staffName,
        'receivedDate': forFirestore
            ? Timestamp.fromDate(receivedDate)
            : receivedDate.toIso8601String(),
        'createdAt': forFirestore
            ? Timestamp.fromDate(createdAt)
            : createdAt.toIso8601String(),
      };

  factory RechargeCommissionEntry.fromMap(
      Map<String, dynamic> m, String id) {
    DateTime parseDt(dynamic val) {
      if (val is Timestamp) return val.toDate();
      if (val is DateTime) return val;
      return DateTime.tryParse(val.toString()) ?? DateTime.now();
    }

    final amt = (m['amount'] as num?)?.toDouble() ?? 0.0;
    final paise = (m['amountPaise'] as num?)?.toInt() ?? (amt * 100).round();

    return RechargeCommissionEntry(
      commissionId: m['commissionId']?.toString() ?? id,
      shopId: m['shopId']?.toString() ?? '',
      operator: RechargeOperator.fromString(m['operator']?.toString()),
      distributorId: m['distributorId']?.toString(),
      distributorName: m['distributorName']?.toString(),
      rechargeId: m['rechargeId']?.toString(),
      amount: amt,
      amountPaise: paise,
      commissionType:
          RechargeCommissionType.fromString(m['commissionType']?.toString()),
      status: CommissionStatus.fromString(m['status']?.toString()),
      settlementMethod: CommissionSettlementMethod.fromString(
          m['settlementMethod']?.toString()),
      receivedDate: parseDt(m['receivedDate']),
      dateString: m['dateString']?.toString() ?? '',
      referenceNumber: m['referenceNumber']?.toString() ?? '',
      notes: m['notes']?.toString() ?? '',
      staffId: m['staffId']?.toString() ?? 'staff',
      staffName: m['staffName']?.toString() ?? 'Staff',
      createdAt: parseDt(m['createdAt']),
    );
  }

  factory RechargeCommissionEntry.fromFirestore(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    return RechargeCommissionEntry.fromMap(doc.data() ?? {}, doc.id);
  }

  RechargeCommissionEntry copyWith({
    CommissionStatus? status,
    CommissionSettlementMethod? settlementMethod,
    String? referenceNumber,
    String? notes,
  }) {
    return RechargeCommissionEntry(
      commissionId: commissionId,
      shopId: shopId,
      operator: operator,
      distributorId: distributorId,
      distributorName: distributorName,
      rechargeId: rechargeId,
      amount: amount,
      amountPaise: amountPaise,
      commissionType: commissionType,
      status: status ?? this.status,
      settlementMethod: settlementMethod ?? this.settlementMethod,
      receivedDate: receivedDate,
      dateString: dateString,
      referenceNumber: referenceNumber ?? this.referenceNumber,
      notes: notes ?? this.notes,
      staffId: staffId,
      staffName: staffName,
      createdAt: createdAt,
    );
  }
}

/// Comprehensive Dashboard Summary for Recharge Commission Income
class CommissionDashboardSummary {
  final String dateString;
  final String monthString;
  final String shopId;
  final int todayConfirmedPaise;
  final int monthlyConfirmedPaise;
  final Map<RechargeOperator, int> operatorConfirmedPaise;
  final int pendingCommissionPaise;
  final int confirmedCommissionPaise;

  const CommissionDashboardSummary({
    required this.dateString,
    required this.monthString,
    required this.shopId,
    this.todayConfirmedPaise = 0,
    this.monthlyConfirmedPaise = 0,
    this.operatorConfirmedPaise = const {},
    this.pendingCommissionPaise = 0,
    this.confirmedCommissionPaise = 0,
  });

  double get todayConfirmed => todayConfirmedPaise / 100.0;
  double get monthlyConfirmed => monthlyConfirmedPaise / 100.0;
  double get pendingCommission => pendingCommissionPaise / 100.0;
  double get confirmedCommission => confirmedCommissionPaise / 100.0;

  double getOperatorCommission(RechargeOperator op) =>
      (operatorConfirmedPaise[op] ?? 0) / 100.0;

  double get airtelCommission =>
      getOperatorCommission(RechargeOperator.airtel);
  double get jioCommission =>
      getOperatorCommission(RechargeOperator.jio);
  double get viCommission =>
      getOperatorCommission(RechargeOperator.vi);
  double get bsnlCommission =>
      getOperatorCommission(RechargeOperator.bsnl);
  double get otherCommission =>
      getOperatorCommission(RechargeOperator.other);

  Map<String, dynamic> toMap() => {
        'dateString': dateString,
        'monthString': monthString,
        'shopId': shopId,
        'todayConfirmedPaise': todayConfirmedPaise,
        'monthlyConfirmedPaise': monthlyConfirmedPaise,
        'pendingCommissionPaise': pendingCommissionPaise,
        'confirmedCommissionPaise': confirmedCommissionPaise,
        'operatorConfirmedPaise': operatorConfirmedPaise.map(
          (k, v) => MapEntry(k.name, v),
        ),
      };

  factory CommissionDashboardSummary.fromMap(
      Map<String, dynamic> m, String dateStr, String mStr, String sId) {
    final rawOpMap = (m['operatorConfirmedPaise'] as Map?) ?? {};
    final Map<RechargeOperator, int> opMap = {};
    for (final op in RechargeOperator.values) {
      if (rawOpMap.containsKey(op.name)) {
        opMap[op] = (rawOpMap[op.name] as num?)?.toInt() ?? 0;
      }
    }

    return CommissionDashboardSummary(
      dateString: m['dateString']?.toString() ?? dateStr,
      monthString: m['monthString']?.toString() ?? mStr,
      shopId: m['shopId']?.toString() ?? sId,
      todayConfirmedPaise: (m['todayConfirmedPaise'] as num?)?.toInt() ?? 0,
      monthlyConfirmedPaise:
          (m['monthlyConfirmedPaise'] as num?)?.toInt() ?? 0,
      pendingCommissionPaise:
          (m['pendingCommissionPaise'] as num?)?.toInt() ?? 0,
      confirmedCommissionPaise:
          (m['confirmedCommissionPaise'] as num?)?.toInt() ?? 0,
      operatorConfirmedPaise: opMap,
    );
  }

  factory CommissionDashboardSummary.empty(
          String dateStr, String mStr, String sId) =>
      CommissionDashboardSummary(
        dateString: dateStr,
        monthString: mStr,
        shopId: sId,
        operatorConfirmedPaise: {
          for (final op in RechargeOperator.values) op: 0,
        },
      );
}

/// Phase 8: Reversal Type
enum ReversalType {
  walletReversal,
  customerRefund,
  commissionReversal,
  distributorReversal;

  String get displayName {
    switch (this) {
      case ReversalType.walletReversal:
        return 'Wallet Reversal';
      case ReversalType.customerRefund:
        return 'Customer Refund';
      case ReversalType.commissionReversal:
        return 'Commission Reversal';
      case ReversalType.distributorReversal:
        return 'Distributor Reversal';
    }
  }

  static ReversalType fromString(dynamic val) {
    if (val == null) return ReversalType.walletReversal;
    final s = val.toString().toLowerCase();
    if (s.contains('wallet')) return ReversalType.walletReversal;
    if (s.contains('refund') || s.contains('customer')) return ReversalType.customerRefund;
    if (s.contains('commission')) return ReversalType.commissionReversal;
    if (s.contains('distributor')) return ReversalType.distributorReversal;
    return ReversalType.walletReversal;
  }
}

/// Phase 8: Customer Refund Record
class CustomerRefundRecord {
  final String refundId;
  final String rechargeId;
  final String shopId;
  final double amount;
  final int amountPaise;
  final RechargePaymentMode refundMethod;
  final DateTime refundDate;
  final String dateString;
  final String staffId;
  final String staffName;
  final String reason;
  final String idempotencyKey;
  final String voucherId;
  final DateTime createdAt;

  const CustomerRefundRecord({
    required this.refundId,
    required this.rechargeId,
    required this.shopId,
    required this.amount,
    required this.amountPaise,
    required this.refundMethod,
    required this.refundDate,
    required this.dateString,
    required this.staffId,
    required this.staffName,
    required this.reason,
    required this.idempotencyKey,
    required this.voucherId,
    required this.createdAt,
  });

  Map<String, dynamic> toMap({bool forFirestore = true}) => {
        'refundId': refundId,
        'rechargeId': rechargeId,
        'shopId': shopId,
        'amount': amount,
        'amountPaise': amountPaise,
        'refundMethod': refundMethod.name,
        'refundDate': forFirestore ? Timestamp.fromDate(refundDate) : refundDate.toIso8601String(),
        'dateString': dateString,
        'staffId': staffId,
        'staffName': staffName,
        'reason': reason,
        'idempotencyKey': idempotencyKey,
        'voucherId': voucherId,
        'createdAt': forFirestore ? Timestamp.fromDate(createdAt) : createdAt.toIso8601String(),
      };

  factory CustomerRefundRecord.fromMap(Map<String, dynamic> m, String id) {
    DateTime parseDate(dynamic v) {
      if (v is Timestamp) return v.toDate();
      if (v is DateTime) return v;
      if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
      if (v != null) return DateTime.tryParse(v.toString()) ?? DateTime.now();
      return DateTime.now();
    }

    final double amt = (m['amount'] as num?)?.toDouble() ?? 0.0;
    final int paise = (m['amountPaise'] as num?)?.toInt() ?? (amt * 100).round();

    return CustomerRefundRecord(
      refundId: m['refundId']?.toString() ?? id,
      rechargeId: m['rechargeId']?.toString() ?? '',
      shopId: m['shopId']?.toString() ?? '',
      amount: amt,
      amountPaise: paise,
      refundMethod: RechargePaymentMode.fromString(m['refundMethod']),
      refundDate: parseDate(m['refundDate']),
      dateString: m['dateString']?.toString() ?? '',
      staffId: m['staffId']?.toString() ?? 'staff',
      staffName: m['staffName']?.toString() ?? 'Staff',
      reason: m['reason']?.toString() ?? '',
      idempotencyKey: m['idempotencyKey']?.toString() ?? '',
      voucherId: m['voucherId']?.toString() ?? '',
      createdAt: parseDate(m['createdAt']),
    );
  }
}

/// Phase 8: Reversal Ledger Entry (linked immutable record)
class ReversalLedgerEntry {
  final String reversalId;
  final String originalTxnId;
  final String shopId;
  final ReversalType reversalType;
  final double amount;
  final int amountPaise;
  final String affectedEntity;
  final String? entityReferenceId;
  final DateTime timestamp;
  final String dateString;
  final String staffId;
  final String staffName;
  final String reason;
  final String idempotencyKey;
  final String notes;

  const ReversalLedgerEntry({
    required this.reversalId,
    required this.originalTxnId,
    required this.shopId,
    required this.reversalType,
    required this.amount,
    required this.amountPaise,
    required this.affectedEntity,
    this.entityReferenceId,
    required this.timestamp,
    required this.dateString,
    required this.staffId,
    required this.staffName,
    required this.reason,
    required this.idempotencyKey,
    this.notes = '',
  });

  Map<String, dynamic> toMap({bool forFirestore = true}) => {
        'reversalId': reversalId,
        'originalTxnId': originalTxnId,
        'shopId': shopId,
        'reversalType': reversalType.name,
        'amount': amount,
        'amountPaise': amountPaise,
        'affectedEntity': affectedEntity,
        'entityReferenceId': entityReferenceId,
        'timestamp': forFirestore ? Timestamp.fromDate(timestamp) : timestamp.toIso8601String(),
        'dateString': dateString,
        'staffId': staffId,
        'staffName': staffName,
        'reason': reason,
        'idempotencyKey': idempotencyKey,
        'notes': notes,
      };

  factory ReversalLedgerEntry.fromMap(Map<String, dynamic> m, String id) {
    DateTime parseDate(dynamic v) {
      if (v is Timestamp) return v.toDate();
      if (v is DateTime) return v;
      if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
      if (v != null) return DateTime.tryParse(v.toString()) ?? DateTime.now();
      return DateTime.now();
    }

    final double amt = (m['amount'] as num?)?.toDouble() ?? 0.0;
    final int paise = (m['amountPaise'] as num?)?.toInt() ?? (amt * 100).round();

    return ReversalLedgerEntry(
      reversalId: m['reversalId']?.toString() ?? id,
      originalTxnId: m['originalTxnId']?.toString() ?? '',
      shopId: m['shopId']?.toString() ?? '',
      reversalType: ReversalType.fromString(m['reversalType']),
      amount: amt,
      amountPaise: paise,
      affectedEntity: m['affectedEntity']?.toString() ?? '',
      entityReferenceId: m['entityReferenceId']?.toString(),
      timestamp: parseDate(m['timestamp']),
      dateString: m['dateString']?.toString() ?? '',
      staffId: m['staffId']?.toString() ?? 'staff',
      staffName: m['staffName']?.toString() ?? 'Staff',
      reason: m['reason']?.toString() ?? '',
      idempotencyKey: m['idempotencyKey']?.toString() ?? '',
      notes: m['notes']?.toString() ?? '',
    );
  }
}

/// Phase 8: Dashboard & Reporting Summary for Statuses & Reversals
class RechargeReversalSummary {
  final String shopId;
  final String dateString;
  final int successfulCount;
  final int successfulPaise;
  final int pendingCount;
  final int pendingPaise;
  final int failedCount;
  final int failedPaise;
  final int refundedCount;
  final int refundedPaise;
  final int walletReversalsCount;
  final int walletReversalsPaise;
  final int commissionReversalsCount;
  final int commissionReversalsPaise;

  const RechargeReversalSummary({
    required this.shopId,
    required this.dateString,
    this.successfulCount = 0,
    this.successfulPaise = 0,
    this.pendingCount = 0,
    this.pendingPaise = 0,
    this.failedCount = 0,
    this.failedPaise = 0,
    this.refundedCount = 0,
    this.refundedPaise = 0,
    this.walletReversalsCount = 0,
    this.walletReversalsPaise = 0,
    this.commissionReversalsCount = 0,
    this.commissionReversalsPaise = 0,
  });

  double get successfulAmount => successfulPaise / 100.0;
  double get pendingAmount => pendingPaise / 100.0;
  double get failedAmount => failedPaise / 100.0;
  double get refundedAmount => refundedPaise / 100.0;
  double get walletReversalsAmount => walletReversalsPaise / 100.0;
  double get commissionReversalsAmount => commissionReversalsPaise / 100.0;

  Map<String, dynamic> toMap() => {
        'shopId': shopId,
        'dateString': dateString,
        'successfulCount': successfulCount,
        'successfulPaise': successfulPaise,
        'pendingCount': pendingCount,
        'pendingPaise': pendingPaise,
        'failedCount': failedCount,
        'failedPaise': failedPaise,
        'refundedCount': refundedCount,
        'refundedPaise': refundedPaise,
        'walletReversalsCount': walletReversalsCount,
        'walletReversalsPaise': walletReversalsPaise,
        'commissionReversalsCount': commissionReversalsCount,
        'commissionReversalsPaise': commissionReversalsPaise,
      };

  factory RechargeReversalSummary.fromMap(Map<String, dynamic> m, String sId, String dStr) {
    return RechargeReversalSummary(
      shopId: m['shopId']?.toString() ?? sId,
      dateString: m['dateString']?.toString() ?? dStr,
      successfulCount: (m['successfulCount'] as num?)?.toInt() ?? 0,
      successfulPaise: (m['successfulPaise'] as num?)?.toInt() ?? 0,
      pendingCount: (m['pendingCount'] as num?)?.toInt() ?? 0,
      pendingPaise: (m['pendingPaise'] as num?)?.toInt() ?? 0,
      failedCount: (m['failedCount'] as num?)?.toInt() ?? 0,
      failedPaise: (m['failedPaise'] as num?)?.toInt() ?? 0,
      refundedCount: (m['refundedCount'] as num?)?.toInt() ?? 0,
      refundedPaise: (m['refundedPaise'] as num?)?.toInt() ?? 0,
      walletReversalsCount: (m['walletReversalsCount'] as num?)?.toInt() ?? 0,
      walletReversalsPaise: (m['walletReversalsPaise'] as num?)?.toInt() ?? 0,
      commissionReversalsCount: (m['commissionReversalsCount'] as num?)?.toInt() ?? 0,
      commissionReversalsPaise: (m['commissionReversalsPaise'] as num?)?.toInt() ?? 0,
    );
  }
}

// -----------------------------------------------------------------------------
// PHASE 9: RECHARGE REPORTS, PROFIT & FINANCIAL RECONCILIATION MODELS
// -----------------------------------------------------------------------------

enum DateRangeFilterType {
  today('Today', 'ഇന്ന്'),
  yesterday('Yesterday', 'ഇന്നലെ'),
  thisWeek('This Week', 'ഈ ആഴ്ച'),
  thisMonth('This Month', 'ഈ മാസം'),
  custom('Custom Range', 'തിരഞ്ഞെടുത്ത തീയതി');

  final String label;
  final String malayalam;
  const DateRangeFilterType(this.label, this.malayalam);

  (DateTime start, DateTime end) getRange([DateTime? customStart, DateTime? customEnd]) {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final todayEnd = DateTime(now.year, now.month, now.day, 23, 59, 59, 999);

    switch (this) {
      case DateRangeFilterType.today:
        return (todayStart, todayEnd);
      case DateRangeFilterType.yesterday:
        final yStart = todayStart.subtract(const Duration(days: 1));
        final yEnd = DateTime(yStart.year, yStart.month, yStart.day, 23, 59, 59, 999);
        return (yStart, yEnd);
      case DateRangeFilterType.thisWeek:
        final weekDay = now.weekday; // 1 = Mon, 7 = Sun
        final wStart = todayStart.subtract(Duration(days: weekDay - 1));
        return (wStart, todayEnd);
      case DateRangeFilterType.thisMonth:
        final mStart = DateTime(now.year, now.month, 1);
        return (mStart, todayEnd);
      case DateRangeFilterType.custom:
        final s = customStart != null ? DateTime(customStart.year, customStart.month, customStart.day) : todayStart;
        final e = customEnd != null ? DateTime(customEnd.year, customEnd.month, customEnd.day, 23, 59, 59, 999) : todayEnd;
        return (s, e);
    }
  }
}

class RechargeReportFilter {
  final DateRangeFilterType filterType;
  final DateTime startDate;
  final DateTime endDate;
  final RechargeOperator? operator;
  final String? distributorId;
  final RechargePaymentMode? paymentMode;

  const RechargeReportFilter({
    required this.filterType,
    required this.startDate,
    required this.endDate,
    this.operator,
    this.distributorId,
    this.paymentMode,
  });

  factory RechargeReportFilter.today() {
    final (start, end) = DateRangeFilterType.today.getRange();
    return RechargeReportFilter(
      filterType: DateRangeFilterType.today,
      startDate: start,
      endDate: end,
    );
  }

  factory RechargeReportFilter.forType(DateRangeFilterType type, [DateTime? customStart, DateTime? customEnd]) {
    final (start, end) = type.getRange(customStart, customEnd);
    return RechargeReportFilter(
      filterType: type,
      startDate: start,
      endDate: end,
    );
  }

  String get dateRangeDisplay {
    final fmt = DateFormat('dd MMM yyyy');
    if (filterType == DateRangeFilterType.today) {
      return 'Today (${fmt.format(startDate)})';
    }
    if (filterType == DateRangeFilterType.yesterday) {
      return 'Yesterday (${fmt.format(startDate)})';
    }
    return '${fmt.format(startDate)} – ${fmt.format(endDate)}';
  }
}

class OperatorReportItem {
  final RechargeOperator operator;
  final int successfulCount;
  final int successfulPaise;
  final int failedCount;
  final int failedPaise;
  final int refundedCount;
  final int refundedPaise;
  final int cashCollectionPaise;
  final int upiCollectionPaise;
  final int cardCollectionPaise;
  final int actualCommissionEarnedPaise;

  const OperatorReportItem({
    required this.operator,
    this.successfulCount = 0,
    this.successfulPaise = 0,
    this.failedCount = 0,
    this.failedPaise = 0,
    this.refundedCount = 0,
    this.refundedPaise = 0,
    this.cashCollectionPaise = 0,
    this.upiCollectionPaise = 0,
    this.cardCollectionPaise = 0,
    this.actualCommissionEarnedPaise = 0,
  });

  double get successfulAmount => successfulPaise / 100.0;
  double get failedAmount => failedPaise / 100.0;
  double get refundedAmount => refundedPaise / 100.0;
  double get cashCollection => cashCollectionPaise / 100.0;
  double get upiCollection => upiCollectionPaise / 100.0;
  double get cardCollection => cardCollectionPaise / 100.0;
  double get actualCommissionEarned => actualCommissionEarnedPaise / 100.0;
  int get totalCollectionPaise => cashCollectionPaise + upiCollectionPaise + cardCollectionPaise;
  double get totalCollection => totalCollectionPaise / 100.0;
}

class WalletBalanceReportItem {
  final RechargeOperator operator;
  final int openingBalancePaise;
  final int openingOwnPaise;
  final int openingCreditPaise;
  final int ownTopUpPaise;
  final int distributorCreditPaise;
  final int rechargeDebitsPaise;
  final int reversalsPaise;
  final int commissionCreditsPaise;
  final int closingBalancePaise;
  final int closingOwnPaise;
  final int closingCreditPaise;

  const WalletBalanceReportItem({
    required this.operator,
    this.openingBalancePaise = 0,
    this.openingOwnPaise = 0,
    this.openingCreditPaise = 0,
    this.ownTopUpPaise = 0,
    this.distributorCreditPaise = 0,
    this.rechargeDebitsPaise = 0,
    this.reversalsPaise = 0,
    this.commissionCreditsPaise = 0,
    this.closingBalancePaise = 0,
    this.closingOwnPaise = 0,
    this.closingCreditPaise = 0,
  });

  double get openingBalance => openingBalancePaise / 100.0;
  double get openingOwn => openingOwnPaise / 100.0;
  double get openingCredit => openingCreditPaise / 100.0;
  double get ownTopUp => ownTopUpPaise / 100.0;
  double get distributorCredit => distributorCreditPaise / 100.0;
  double get rechargeDebits => rechargeDebitsPaise / 100.0;
  double get reversals => reversalsPaise / 100.0;
  double get commissionCredits => commissionCreditsPaise / 100.0;
  double get closingBalance => closingBalancePaise / 100.0;
  double get closingOwn => closingOwnPaise / 100.0;
  double get closingCredit => closingCreditPaise / 100.0;
}

class DistributorOutstandingReportItem {
  final String distributorId;
  final String distributorName;
  final RechargeOperator defaultOperator;
  final int openingPayablePaise;
  final int creditReceivedPaise;
  final int paymentsMadePaise;
  final int adjustmentsPaise;
  final int closingOutstandingPaise;
  final int cashPaymentsPaise;
  final int upiPaymentsPaise;
  final int bankPaymentsPaise;

  const DistributorOutstandingReportItem({
    required this.distributorId,
    required this.distributorName,
    required this.defaultOperator,
    this.openingPayablePaise = 0,
    this.creditReceivedPaise = 0,
    this.paymentsMadePaise = 0,
    this.adjustmentsPaise = 0,
    this.closingOutstandingPaise = 0,
    this.cashPaymentsPaise = 0,
    this.upiPaymentsPaise = 0,
    this.bankPaymentsPaise = 0,
  });

  double get openingPayable => openingPayablePaise / 100.0;
  double get creditReceived => creditReceivedPaise / 100.0;
  double get paymentsMade => paymentsMadePaise / 100.0;
  double get adjustments => adjustmentsPaise / 100.0;
  double get closingOutstanding => closingOutstandingPaise / 100.0;
  double get cashPayments => cashPaymentsPaise / 100.0;
  double get upiPayments => upiPaymentsPaise / 100.0;
  double get bankPayments => bankPaymentsPaise / 100.0;
}

class CashBankReconciliationReport {
  final int rechargeCashCollectedPaise;
  final int rechargeUpiCollectedPaise;
  final int rechargeCardCollectedPaise;
  final int customerCashRefundsPaise;
  final int customerUpiRefundsPaise;
  final int customerCardRefundsPaise;
  final int distributorCashPaymentsPaise;
  final int distributorUpiPaymentsPaise;
  final int distributorBankPaymentsPaise;
  final int actualCashDepositedToBankPaise;
  final int ownFloatBankDebitsPaise;

  const CashBankReconciliationReport({
    this.rechargeCashCollectedPaise = 0,
    this.rechargeUpiCollectedPaise = 0,
    this.rechargeCardCollectedPaise = 0,
    this.customerCashRefundsPaise = 0,
    this.customerUpiRefundsPaise = 0,
    this.customerCardRefundsPaise = 0,
    this.distributorCashPaymentsPaise = 0,
    this.distributorUpiPaymentsPaise = 0,
    this.distributorBankPaymentsPaise = 0,
    this.actualCashDepositedToBankPaise = 0,
    this.ownFloatBankDebitsPaise = 0,
  });

  double get rechargeCashCollected => rechargeCashCollectedPaise / 100.0;
  double get rechargeUpiCollected => rechargeUpiCollectedPaise / 100.0;
  double get rechargeCardCollected => rechargeCardCollectedPaise / 100.0;
  double get customerCashRefunds => customerCashRefundsPaise / 100.0;
  double get customerUpiRefunds => customerUpiRefundsPaise / 100.0;
  double get customerCardRefunds => customerCardRefundsPaise / 100.0;
  double get distributorCashPayments => distributorCashPaymentsPaise / 100.0;
  double get distributorUpiPayments => distributorUpiPaymentsPaise / 100.0;
  double get distributorBankPayments => distributorBankPaymentsPaise / 100.0;
  double get actualCashDepositedToBank => actualCashDepositedToBankPaise / 100.0;
  double get ownFloatBankDebits => ownFloatBankDebitsPaise / 100.0;

  int get netPhysicalCashFlowPaise =>
      rechargeCashCollectedPaise -
      customerCashRefundsPaise -
      distributorCashPaymentsPaise -
      actualCashDepositedToBankPaise;

  double get netPhysicalCashFlow => netPhysicalCashFlowPaise / 100.0;
}

class RechargeFinancialReport {
  final String shopId;
  final RechargeReportFilter filter;
  final DateTime generatedAt;
  final int totalRechargePaise;
  final int successfulCount;
  final int pendingCount;
  final int pendingPaise;
  final int failedCount;
  final int failedPaise;
  final int refundedCount;
  final int refundedPaise;
  final int totalCustomerCollectionPaise;
  final int cashCollectionPaise;
  final int upiCollectionPaise;
  final int cardCollectionPaise;
  final int confirmedCommissionEarnedPaise;
  final int confirmedCommissionReversedPaise;
  final int netCommissionIncomePaise;
  final Map<RechargeOperator, OperatorReportItem> operatorReports;
  final Map<RechargeOperator, WalletBalanceReportItem> walletReports;
  final List<DistributorOutstandingReportItem> distributorReports;
  final CashBankReconciliationReport reconciliation;
  final List<RechargeEntry> transactions;

  const RechargeFinancialReport({
    required this.shopId,
    required this.filter,
    required this.generatedAt,
    this.totalRechargePaise = 0,
    this.successfulCount = 0,
    this.pendingCount = 0,
    this.pendingPaise = 0,
    this.failedCount = 0,
    this.failedPaise = 0,
    this.refundedCount = 0,
    this.refundedPaise = 0,
    this.totalCustomerCollectionPaise = 0,
    this.cashCollectionPaise = 0,
    this.upiCollectionPaise = 0,
    this.cardCollectionPaise = 0,
    this.confirmedCommissionEarnedPaise = 0,
    this.confirmedCommissionReversedPaise = 0,
    this.netCommissionIncomePaise = 0,
    required this.operatorReports,
    required this.walletReports,
    required this.distributorReports,
    required this.reconciliation,
    required this.transactions,
  });

  double get totalRechargeAmount => totalRechargePaise / 100.0;
  double get pendingAmount => pendingPaise / 100.0;
  double get failedAmount => failedPaise / 100.0;
  double get refundedAmount => refundedPaise / 100.0;
  double get totalCustomerCollection => totalCustomerCollectionPaise / 100.0;
  double get cashCollection => cashCollectionPaise / 100.0;
  double get upiCollection => upiCollectionPaise / 100.0;
  double get cardCollection => cardCollectionPaise / 100.0;
  double get confirmedCommissionEarned => confirmedCommissionEarnedPaise / 100.0;
  double get confirmedCommissionReversed => confirmedCommissionReversedPaise / 100.0;
  double get netCommissionIncome => netCommissionIncomePaise / 100.0;
}

/// ============================================================================
/// PHASE 12: DAILY OPERATOR OPENING & CLOSING BALANCE RECONCILIATION MODELS
/// ============================================================================

class DailyOperatorBalanceEntry {
  final RechargeOperator operator;
  final int openingBalancePaise;
  final DateTime? openingEnteredAt;
  final String openingEnteredBy;
  final bool isOpeningCompleted;

  final int actualClosingBalancePaise;
  final DateTime? closingEnteredAt;
  final String closingEnteredBy;
  final bool isClosingCompleted;

  // Automated Financial Ledger Reconciliation
  final int totalTopupsPaise;
  final int totalCreditsPaise;
  final int totalDebitsPaise;
  final int totalDebitReversalsPaise;
  final int totalCreditReversalsPaise;
  final int expectedClosingBalancePaise;
  final int differencePaise; // actualClosingBalancePaise - expectedClosingBalancePaise

  final String? mismatchReason;
  final String? remarks;
  final bool isMismatch;
  final bool isReviewedByOwner;
  final String? reviewedBy;
  final DateTime? reviewedAt;
  final int totalCommissionPaise;

  const DailyOperatorBalanceEntry({
    required this.operator,
    this.openingBalancePaise = 0,
    this.openingEnteredAt,
    this.openingEnteredBy = '',
    this.isOpeningCompleted = false,
    this.actualClosingBalancePaise = 0,
    this.closingEnteredAt,
    this.closingEnteredBy = '',
    this.isClosingCompleted = false,
    this.totalTopupsPaise = 0,
    this.totalCreditsPaise = 0,
    this.totalDebitsPaise = 0,
    this.totalDebitReversalsPaise = 0,
    this.totalCreditReversalsPaise = 0,
    this.expectedClosingBalancePaise = 0,
    this.differencePaise = 0,
    this.mismatchReason,
    this.remarks,
    this.isMismatch = false,
    this.isReviewedByOwner = false,
    this.reviewedBy,
    this.reviewedAt,
    this.totalCommissionPaise = 0,
  });

  double get openingBalance => openingBalancePaise / 100.0;
  double get actualClosingBalance => actualClosingBalancePaise / 100.0;
  double get totalTopups => totalTopupsPaise / 100.0;
  double get totalCredits => totalCreditsPaise / 100.0;
  double get totalDebits => totalDebitsPaise / 100.0;
  double get rechargeAmount => totalDebits;
  int get rechargeAmountPaise => totalDebitsPaise;
  double get totalCommission => totalCommissionPaise / 100.0;
  double get totalDebitReversals => totalDebitReversalsPaise / 100.0;
  double get totalCreditReversals => totalCreditReversalsPaise / 100.0;
  double get expectedClosingBalance => expectedClosingBalancePaise / 100.0;
  double get difference => differencePaise / 100.0;

  Map<String, dynamic> toMap({bool forFirestore = false}) {
    return {
      'operator': operator.name,
      'openingBalancePaise': openingBalancePaise,
      'openingEnteredAt': forFirestore
          ? (openingEnteredAt != null ? Timestamp.fromDate(openingEnteredAt!) : null)
          : openingEnteredAt?.toIso8601String(),
      'openingEnteredBy': openingEnteredBy,
      'isOpeningCompleted': isOpeningCompleted,
      'actualClosingBalancePaise': actualClosingBalancePaise,
      'closingEnteredAt': forFirestore
          ? (closingEnteredAt != null ? Timestamp.fromDate(closingEnteredAt!) : null)
          : closingEnteredAt?.toIso8601String(),
      'closingEnteredBy': closingEnteredBy,
      'isClosingCompleted': isClosingCompleted,
      'totalTopupsPaise': totalTopupsPaise,
      'totalCreditsPaise': totalCreditsPaise,
      'totalDebitsPaise': totalDebitsPaise,
      'totalCommissionPaise': totalCommissionPaise,
      'totalDebitReversalsPaise': totalDebitReversalsPaise,
      'totalCreditReversalsPaise': totalCreditReversalsPaise,
      'expectedClosingBalancePaise': expectedClosingBalancePaise,
      'differencePaise': differencePaise,
      'mismatchReason': mismatchReason,
      'remarks': remarks,
      'isMismatch': isMismatch,
      'isReviewedByOwner': isReviewedByOwner,
      'reviewedBy': reviewedBy,
      'reviewedAt': forFirestore
          ? (reviewedAt != null ? Timestamp.fromDate(reviewedAt!) : null)
          : reviewedAt?.toIso8601String(),
    };
  }

  factory DailyOperatorBalanceEntry.fromMap(Map<String, dynamic> map) {
    DateTime? parseDate(dynamic val) {
      if (val is Timestamp) return val.toDate();
      if (val is String && val.isNotEmpty) return DateTime.tryParse(val);
      return null;
    }

    return DailyOperatorBalanceEntry(
      operator: RechargeOperator.fromString(map['operator']?.toString()),
      openingBalancePaise: (map['openingBalancePaise'] as num?)?.toInt() ?? 0,
      openingEnteredAt: parseDate(map['openingEnteredAt']),
      openingEnteredBy: map['openingEnteredBy']?.toString() ?? '',
      isOpeningCompleted: map['isOpeningCompleted'] == true,
      actualClosingBalancePaise: (map['actualClosingBalancePaise'] as num?)?.toInt() ?? 0,
      closingEnteredAt: parseDate(map['closingEnteredAt']),
      closingEnteredBy: map['closingEnteredBy']?.toString() ?? '',
      isClosingCompleted: map['isClosingCompleted'] == true,
      totalTopupsPaise: (map['totalTopupsPaise'] as num?)?.toInt() ?? 0,
      totalCreditsPaise: (map['totalCreditsPaise'] as num?)?.toInt() ?? 0,
      totalDebitsPaise: (map['totalDebitsPaise'] as num?)?.toInt() ?? 0,
      totalCommissionPaise: (map['totalCommissionPaise'] as num?)?.toInt() ?? 0,
      totalDebitReversalsPaise: (map['totalDebitReversalsPaise'] as num?)?.toInt() ?? 0,
      totalCreditReversalsPaise: (map['totalCreditReversalsPaise'] as num?)?.toInt() ?? 0,
      expectedClosingBalancePaise: (map['expectedClosingBalancePaise'] as num?)?.toInt() ?? 0,
      differencePaise: (map['differencePaise'] as num?)?.toInt() ?? 0,
      mismatchReason: map['mismatchReason']?.toString(),
      remarks: map['remarks']?.toString(),
      isMismatch: map['isMismatch'] == true,
      isReviewedByOwner: map['isReviewedByOwner'] == true,
      reviewedBy: map['reviewedBy']?.toString(),
      reviewedAt: parseDate(map['reviewedAt']),
    );
  }

  DailyOperatorBalanceEntry copyWith({
    RechargeOperator? operator,
    int? openingBalancePaise,
    DateTime? openingEnteredAt,
    String? openingEnteredBy,
    bool? isOpeningCompleted,
    int? actualClosingBalancePaise,
    DateTime? closingEnteredAt,
    String? closingEnteredBy,
    bool? isClosingCompleted,
    int? totalTopupsPaise,
    int? totalCreditsPaise,
    int? totalDebitsPaise,
    int? totalCommissionPaise,
    int? totalDebitReversalsPaise,
    int? totalCreditReversalsPaise,
    int? expectedClosingBalancePaise,
    int? differencePaise,
    String? mismatchReason,
    String? remarks,
    bool? isMismatch,
    bool? isReviewedByOwner,
    String? reviewedBy,
    DateTime? reviewedAt,
  }) {
    return DailyOperatorBalanceEntry(
      operator: operator ?? this.operator,
      openingBalancePaise: openingBalancePaise ?? this.openingBalancePaise,
      openingEnteredAt: openingEnteredAt ?? this.openingEnteredAt,
      openingEnteredBy: openingEnteredBy ?? this.openingEnteredBy,
      isOpeningCompleted: isOpeningCompleted ?? this.isOpeningCompleted,
      actualClosingBalancePaise: actualClosingBalancePaise ?? this.actualClosingBalancePaise,
      closingEnteredAt: closingEnteredAt ?? this.closingEnteredAt,
      closingEnteredBy: closingEnteredBy ?? this.closingEnteredBy,
      isClosingCompleted: isClosingCompleted ?? this.isClosingCompleted,
      totalTopupsPaise: totalTopupsPaise ?? this.totalTopupsPaise,
      totalCreditsPaise: totalCreditsPaise ?? this.totalCreditsPaise,
      totalDebitsPaise: totalDebitsPaise ?? this.totalDebitsPaise,
      totalCommissionPaise: totalCommissionPaise ?? this.totalCommissionPaise,
      totalDebitReversalsPaise: totalDebitReversalsPaise ?? this.totalDebitReversalsPaise,
      totalCreditReversalsPaise: totalCreditReversalsPaise ?? this.totalCreditReversalsPaise,
      expectedClosingBalancePaise: expectedClosingBalancePaise ?? this.expectedClosingBalancePaise,
      differencePaise: differencePaise ?? this.differencePaise,
      mismatchReason: mismatchReason ?? this.mismatchReason,
      remarks: remarks ?? this.remarks,
      isMismatch: isMismatch ?? this.isMismatch,
      isReviewedByOwner: isReviewedByOwner ?? this.isReviewedByOwner,
      reviewedBy: reviewedBy ?? this.reviewedBy,
      reviewedAt: reviewedAt ?? this.reviewedAt,
    );
  }
}

/// Audited correction record for daily operator opening/closing balances
class ReconciliationCorrectionEntry {
  final String correctionId;
  final RechargeOperator operator;
  final String balanceType; // 'opening' or 'closing'
  final int originalValuePaise;
  final int correctedValuePaise;
  final String reason;
  final String requestedBy;
  final String approvedBy;
  final DateTime timestamp;
  final String status; // 'pending', 'approved', 'rejected'

  const ReconciliationCorrectionEntry({
    required this.correctionId,
    required this.operator,
    required this.balanceType,
    required this.originalValuePaise,
    required this.correctedValuePaise,
    required this.reason,
    required this.requestedBy,
    required this.approvedBy,
    required this.timestamp,
    this.status = 'approved',
  });

  double get originalValue => originalValuePaise / 100.0;
  double get correctedValue => correctedValuePaise / 100.0;
  int get differencePaise => correctedValuePaise - originalValuePaise;
  double get difference => differencePaise / 100.0;

  Map<String, dynamic> toMap({bool forFirestore = false}) => {
        'correctionId': correctionId,
        'operator': operator.name,
        'balanceType': balanceType,
        'originalValuePaise': originalValuePaise,
        'correctedValuePaise': correctedValuePaise,
        'reason': reason,
        'requestedBy': requestedBy,
        'approvedBy': approvedBy,
        'status': status,
        'timestamp': forFirestore ? Timestamp.fromDate(timestamp) : timestamp.toIso8601String(),
      };

  factory ReconciliationCorrectionEntry.fromMap(Map<String, dynamic> map) {
    DateTime parseDate(dynamic val, DateTime fallback) {
      if (val is Timestamp) return val.toDate();
      if (val is String && val.isNotEmpty) return DateTime.tryParse(val) ?? fallback;
      return fallback;
    }

    final opStr = map['operator']?.toString() ?? 'other';
    final op = RechargeOperator.values.firstWhere(
      (e) => e.name == opStr,
      orElse: () => RechargeOperator.other,
    );

    return ReconciliationCorrectionEntry(
      correctionId: map['correctionId']?.toString() ?? '',
      operator: op,
      balanceType: map['balanceType']?.toString() ?? 'closing',
      originalValuePaise: (map['originalValuePaise'] as num?)?.toInt() ?? 0,
      correctedValuePaise: (map['correctedValuePaise'] as num?)?.toInt() ?? 0,
      reason: map['reason']?.toString() ?? '',
      requestedBy: map['requestedBy']?.toString() ?? '',
      approvedBy: map['approvedBy']?.toString() ?? '',
      status: map['status']?.toString() ?? 'approved',
      timestamp: parseDate(map['timestamp'], DateTime.now()),
    );
  }
}

class DailyReconciliationRecord {
  final String businessDate; // YYYY-MM-DD
  final String shopId;
  final Map<String, DailyOperatorBalanceEntry> operators;
  final String openingStatus; // 'pending', 'partial', 'completed'
  final String closingStatus; // 'pending', 'partial', 'completed'
  final String reconciliationStatus; // 'pending', 'balanced', 'mismatch', 'reviewed', 'incomplete'
  final DateTime createdAt;
  final DateTime updatedAt;
  final String createdBy;
  final DateTime? closedAt;
  final String? closedBy;
  final bool isImmutable;
  final List<String> auditNotes;
  final List<ReconciliationCorrectionEntry> corrections;
  final bool hasIncompleteLedger;

  const DailyReconciliationRecord({
    required this.businessDate,
    required this.shopId,
    required this.operators,
    this.openingStatus = 'pending',
    this.closingStatus = 'pending',
    this.reconciliationStatus = 'pending',
    required this.createdAt,
    required this.updatedAt,
    this.createdBy = '',
    this.closedAt,
    this.closedBy,
    this.isImmutable = false,
    this.auditNotes = const [],
    this.corrections = const [],
    this.hasIncompleteLedger = false,
  });

  bool get isOpeningComplete => openingStatus == 'completed';
  bool get isClosingComplete => closingStatus == 'completed';
  bool get hasMismatch => operators.values.any((op) => op.isMismatch);

  // Operator-wise recharge amounts (completely isolated from normal ERP Cash & Bank)
  double get airtelRechargeAmount => (operators['airtel']?.totalDebits ?? 0.0);
  double get jioRechargeAmount => (operators['jio']?.totalDebits ?? 0.0);
  double get viRechargeAmount => (operators['vi']?.totalDebits ?? 0.0);
  double get bsnlRechargeAmount => (operators['bsnl']?.totalDebits ?? 0.0);

  // Total Recharge Amount across all 4 operators
  double get totalRechargeAmount =>
      airtelRechargeAmount + jioRechargeAmount + viRechargeAmount + bsnlRechargeAmount;

  // Total Recharge Wallet Balance across all 4 operators
  double get totalRechargeWalletBalance => operators.values.fold(
      0.0,
      (acc, op) =>
          acc +
          (op.isClosingCompleted
              ? op.actualClosingBalance
              : op.expectedClosingBalance));

  // Total Recharge Commission (actual recognized income only)
  double get totalRechargeCommission =>
      operators.values.fold(0.0, (acc, op) => acc + op.totalCommission);

  Map<String, dynamic> toMap({bool forFirestore = false}) {
    return {
      'businessDate': businessDate,
      'shopId': shopId,
      'operators': operators.map((k, v) => MapEntry(k, v.toMap(forFirestore: forFirestore))),
      'openingStatus': openingStatus,
      'closingStatus': closingStatus,
      'reconciliationStatus': reconciliationStatus,
      'createdAt': forFirestore ? Timestamp.fromDate(createdAt) : createdAt.toIso8601String(),
      'updatedAt': forFirestore ? Timestamp.fromDate(updatedAt) : updatedAt.toIso8601String(),
      'createdBy': createdBy,
      'closedAt': forFirestore ? (closedAt != null ? Timestamp.fromDate(closedAt!) : null) : closedAt?.toIso8601String(),
      'closedBy': closedBy,
      'isImmutable': isImmutable,
      'auditNotes': auditNotes,
      'corrections': corrections.map((c) => c.toMap(forFirestore: forFirestore)).toList(),
      'hasIncompleteLedger': hasIncompleteLedger,
    };
  }

  factory DailyReconciliationRecord.fromMap(Map<String, dynamic> map) {
    DateTime parseDate(dynamic val, DateTime fallback) {
      if (val is Timestamp) return val.toDate();
      if (val is String && val.isNotEmpty) return DateTime.tryParse(val) ?? fallback;
      return fallback;
    }
    DateTime? parseNullableDate(dynamic val) {
      if (val is Timestamp) return val.toDate();
      if (val is String && val.isNotEmpty) return DateTime.tryParse(val);
      return null;
    }

    final now = DateTime.now();
    final rawOps = map['operators'] as Map<dynamic, dynamic>? ?? {};
    final ops = <String, DailyOperatorBalanceEntry>{};
    for (final entry in rawOps.entries) {
      if (entry.value is Map) {
        ops[entry.key.toString()] = DailyOperatorBalanceEntry.fromMap(
          Map<String, dynamic>.from(entry.value as Map),
        );
      }
    }

    final rawNotes = map['auditNotes'] as List<dynamic>? ?? [];
    final rawCorrections = map['corrections'] as List<dynamic>? ?? [];
    final correctionsList = rawCorrections
        .whereType<Map>()
        .map((c) => ReconciliationCorrectionEntry.fromMap(Map<String, dynamic>.from(c)))
        .toList();

    return DailyReconciliationRecord(
      businessDate: map['businessDate']?.toString() ?? DateFormat('yyyy-MM-dd').format(now),
      shopId: map['shopId']?.toString() ?? '',
      operators: ops,
      openingStatus: map['openingStatus']?.toString() ?? 'pending',
      closingStatus: map['closingStatus']?.toString() ?? 'pending',
      reconciliationStatus: map['reconciliationStatus']?.toString() ?? 'pending',
      createdAt: parseDate(map['createdAt'], now),
      updatedAt: parseDate(map['updatedAt'], now),
      createdBy: map['createdBy']?.toString() ?? '',
      closedAt: parseNullableDate(map['closedAt']),
      closedBy: map['closedBy']?.toString(),
      isImmutable: map['isImmutable'] == true,
      auditNotes: rawNotes.map((n) => n.toString()).toList(),
      corrections: correctionsList,
      hasIncompleteLedger: map['hasIncompleteLedger'] == true,
    );
  }

  DailyReconciliationRecord copyWith({
    String? businessDate,
    String? shopId,
    Map<String, DailyOperatorBalanceEntry>? operators,
    String? openingStatus,
    String? closingStatus,
    String? reconciliationStatus,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? createdBy,
    DateTime? closedAt,
    String? closedBy,
    bool? isImmutable,
    List<String>? auditNotes,
    List<ReconciliationCorrectionEntry>? corrections,
    bool? hasIncompleteLedger,
  }) {
    return DailyReconciliationRecord(
      businessDate: businessDate ?? this.businessDate,
      shopId: shopId ?? this.shopId,
      operators: operators ?? this.operators,
      openingStatus: openingStatus ?? this.openingStatus,
      closingStatus: closingStatus ?? this.closingStatus,
      reconciliationStatus: reconciliationStatus ?? this.reconciliationStatus,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      createdBy: createdBy ?? this.createdBy,
      closedAt: closedAt ?? this.closedAt,
      closedBy: closedBy ?? this.closedBy,
      isImmutable: isImmutable ?? this.isImmutable,
      auditNotes: auditNotes ?? this.auditNotes,
      corrections: corrections ?? this.corrections,
      hasIncompleteLedger: hasIncompleteLedger ?? this.hasIncompleteLedger,
    );
  }
}

/// ============================================================================
/// TEKFIX ERP - PHASE 17.1: OPERATOR COMMISSION CONTROL MODEL
/// Server-Authoritative Owner-Controlled Commission ON/OFF & Margin Settings
/// ============================================================================
class OperatorCommissionControl {
  final String shopId;
  final String operator; // AIRTEL, JIO, VI, BSNL, OTHER
  final bool isEnabled;
  final int marginBasisPoints; // e.g. 300 = 3.00%
  final DateTime updatedAt;
  final String updatedByUid;

  const OperatorCommissionControl({
    required this.shopId,
    required this.operator,
    required this.isEnabled,
    required this.marginBasisPoints,
    required this.updatedAt,
    required this.updatedByUid,
  });

  /// Commission percentage as decimal for calculations (e.g. 3.0% -> 0.03)
  double get marginMultiplier => marginBasisPoints / 10000.0;

  /// Commission percentage display (e.g. 3.00)
  double get marginPercent => marginBasisPoints / 100.0;

  factory OperatorCommissionControl.fromMap(Map<String, dynamic> map) {
    int parseBps(dynamic val) {
      if (val is int) return val;
      if (val is num) return val.round();
      if (val is String) return int.tryParse(val) ?? 300;
      return 300;
    }

    final rawOp = (map['operator']?.toString() ?? 'OTHER').toUpperCase().trim();
    return OperatorCommissionControl(
      shopId: map['shopId']?.toString() ?? map['shop_id']?.toString() ?? '',
      operator: rawOp,
      isEnabled: map['isEnabled'] == true || map['is_enabled'] == true,
      marginBasisPoints: parseBps(map['marginBasisPoints'] ?? map['margin_basis_points']),
      updatedAt: DateTime.tryParse(map['updatedAt']?.toString() ?? map['updated_at']?.toString() ?? '') ?? DateTime.now(),
      updatedByUid: map['updatedByUid']?.toString() ?? map['updated_by_uid']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'shopId': shopId,
      'operator': operator,
      'isEnabled': isEnabled,
      'marginBasisPoints': marginBasisPoints,
      'marginPercent': marginPercent,
      'updatedAt': updatedAt.toIso8601String(),
      'updatedByUid': updatedByUid,
    };
  }

  OperatorCommissionControl copyWith({
    String? shopId,
    String? operator,
    bool? isEnabled,
    int? marginBasisPoints,
    DateTime? updatedAt,
    String? updatedByUid,
  }) {
    return OperatorCommissionControl(
      shopId: shopId ?? this.shopId,
      operator: operator ?? this.operator,
      isEnabled: isEnabled ?? this.isEnabled,
      marginBasisPoints: marginBasisPoints ?? this.marginBasisPoints,
      updatedAt: updatedAt ?? this.updatedAt,
      updatedByUid: updatedByUid ?? this.updatedByUid,
    );
  }
}




