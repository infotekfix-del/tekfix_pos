import 'package:intl/intl.dart';

class RepairJob {
  final dynamic key;
  final String id;
  final String customerName;
  final String phone;
  final String productType;
  final String brandModel;
  final String serial;
  final String complaint;
  final String condition;
  final String accessories;
  final String technician;
  final double estimatedCost;
  final double advance;
  final double finalAmount;
  final String expectedDelivery;
  final int warrantyDays;
  final String status;
  final String notes;
  final bool billCreated;
  final String? invoice;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final List<Map<String, dynamic>> statusHistory;
  final List<dynamic> parts;

  const RepairJob({
    this.key,
    required this.id,
    required this.customerName,
    required this.phone,
    required this.productType,
    required this.brandModel,
    required this.serial,
    required this.complaint,
    this.condition = '',
    this.accessories = '',
    this.technician = '',
    this.estimatedCost = 0.0,
    this.advance = 0.0,
    this.finalAmount = 0.0,
    this.expectedDelivery = '',
    this.warrantyDays = 0,
    this.status = 'Received',
    this.notes = '',
    this.billCreated = false,
    this.invoice,
    this.createdAt,
    this.updatedAt,
    this.statusHistory = const [],
    this.parts = const [],
  });

  /// Balance remaining after advance paid
  double get balance {
    final total = billCreated ? finalAmount : estimatedCost;
    final bal = total - advance;
    return bal < 0 ? 0.0 : bal;
  }

  bool get isActive =>
      const ['Received', 'Diagnosing', 'In Progress', 'Waiting for Parts']
          .contains(status);

  bool get isReady => status == 'Ready';
  bool get isDelivered => status == 'Delivered';
  bool get isCancelled => status == 'Cancelled';
  bool get isWaitingForParts => status == 'Waiting for Parts';

  bool get isOverdue {
    if (isDelivered || isCancelled || expectedDelivery.isEmpty) return false;
    try {
      final dt = DateTime.parse(expectedDelivery);
      final today = DateTime.now();
      final endOfTargetDay = DateTime(dt.year, dt.month, dt.day, 23, 59, 59);
      return today.isAfter(endOfTargetDay);
    } catch (_) {
      return false;
    }
  }

  bool get isDueToday {
    if (isDelivered || isCancelled || expectedDelivery.isEmpty) return false;
    try {
      final dt = DateTime.parse(expectedDelivery);
      final today = DateTime.now();
      return dt.year == today.year && dt.month == today.month && dt.day == today.day;
    } catch (_) {
      return false;
    }
  }

  String get formattedCreatedAt {
    if (createdAt == null) return '';
    return DateFormat('dd MMM yyyy, hh:mm a').format(createdAt!);
  }

  factory RepairJob.fromMap(dynamic key, Map<String, dynamic> map) {
    DateTime? parseDt(dynamic v) {
      if (v == null) return null;
      if (v is DateTime) return v;
      try {
        return DateTime.parse(v.toString());
      } catch (_) {
        return null;
      }
    }

    double parseD(dynamic v) {
      if (v is num) return v.toDouble();
      return double.tryParse('${v ?? ''}') ?? 0.0;
    }

    int parseI(dynamic v) {
      if (v is num) return v.toInt();
      return int.tryParse('${v ?? ''}') ?? 0;
    }

    List<Map<String, dynamic>> parseHistory(dynamic v) {
      if (v is List) {
        return v
            .map((e) => e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{})
            .toList();
      }
      return [];
    }

    final jobId = '${map['jobId'] ?? key ?? ''}';

    return RepairJob(
      key: key,
      id: jobId,
      customerName: '${map['customerName'] ?? ''}',
      phone: '${map['phone'] ?? ''}',
      productType: '${map['productType'] ?? 'Mobile'}',
      brandModel: '${map['brandModel'] ?? ''}',
      serial: '${map['serial'] ?? ''}',
      complaint: '${map['complaint'] ?? ''}',
      condition: '${map['condition'] ?? ''}',
      accessories: '${map['accessories'] ?? ''}',
      technician: '${map['technician'] ?? ''}',
      estimatedCost: parseD(map['estimatedCost']),
      advance: parseD(map['advance']),
      finalAmount: parseD(map['finalAmount']),
      expectedDelivery: '${map['expectedDelivery'] ?? ''}',
      warrantyDays: parseI(map['warrantyDays']),
      status: '${map['status'] ?? 'Received'}',
      notes: '${map['notes'] ?? ''}',
      billCreated: map['billCreated'] == true,
      invoice: map['invoice'] != null ? '${map['invoice']}' : null,
      createdAt: parseDt(map['createdAt']),
      updatedAt: parseDt(map['updatedAt']),
      statusHistory: parseHistory(map['statusHistory']),
      parts: (map['parts'] as List?) ?? [],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'jobId': id,
      'customerName': customerName,
      'phone': phone,
      'productType': productType,
      'brandModel': brandModel,
      'serial': serial,
      'complaint': complaint,
      'condition': condition,
      'accessories': accessories,
      'technician': technician,
      'estimatedCost': estimatedCost,
      'advance': advance,
      'finalAmount': finalAmount,
      'expectedDelivery': expectedDelivery,
      'warrantyDays': warrantyDays,
      'status': status,
      'notes': notes,
      'billCreated': billCreated,
      'invoice': invoice,
      'createdAt': createdAt?.toIso8601String() ?? DateTime.now().toIso8601String(),
      'updatedAt': updatedAt?.toIso8601String() ?? DateTime.now().toIso8601String(),
      'statusHistory': statusHistory,
      'parts': parts,
    };
  }

  RepairJob copyWith({
    dynamic key,
    String? id,
    String? customerName,
    String? phone,
    String? productType,
    String? brandModel,
    String? serial,
    String? complaint,
    String? condition,
    String? accessories,
    String? technician,
    double? estimatedCost,
    double? advance,
    double? finalAmount,
    String? expectedDelivery,
    int? warrantyDays,
    String? status,
    String? notes,
    bool? billCreated,
    String? invoice,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<Map<String, dynamic>>? statusHistory,
    List<dynamic>? parts,
  }) {
    return RepairJob(
      key: key ?? this.key,
      id: id ?? this.id,
      customerName: customerName ?? this.customerName,
      phone: phone ?? this.phone,
      productType: productType ?? this.productType,
      brandModel: brandModel ?? this.brandModel,
      serial: serial ?? this.serial,
      complaint: complaint ?? this.complaint,
      condition: condition ?? this.condition,
      accessories: accessories ?? this.accessories,
      technician: technician ?? this.technician,
      estimatedCost: estimatedCost ?? this.estimatedCost,
      advance: advance ?? this.advance,
      finalAmount: finalAmount ?? this.finalAmount,
      expectedDelivery: expectedDelivery ?? this.expectedDelivery,
      warrantyDays: warrantyDays ?? this.warrantyDays,
      status: status ?? this.status,
      notes: notes ?? this.notes,
      billCreated: billCreated ?? this.billCreated,
      invoice: invoice ?? this.invoice,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      statusHistory: statusHistory ?? this.statusHistory,
      parts: parts ?? this.parts,
    );
  }
}
