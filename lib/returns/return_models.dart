import 'package:flutter/material.dart';

/// Customer Return Status in the return lifecycle.
class CustomerReturnStatus {
  static const String registered = 'Return Registered';
  static const String underInspection = 'Under Inspection';
  static const String warrantyVerified = 'Warranty Verified';
  static const String handedOverToVendor = 'Handed Over to Vendor';
  static const String receivedAtShop = 'Received at Shop';
  static const String readyForCustomer = 'Ready for Customer';
  static const String returnedToCustomer = 'Returned to Customer';
  static const String completed = 'Completed';
  static const String claimRejected = 'Claim Rejected';

  static const List<String> all = [
    registered,
    underInspection,
    warrantyVerified,
    handedOverToVendor,
    receivedAtShop,
    readyForCustomer,
    returnedToCustomer,
    completed,
    claimRejected,
  ];

  static Color getColor(String status) {
    switch (status) {
      case registered:
        return const Color(0xFF38BDF8); // Sky blue
      case underInspection:
        return const Color(0xFFF59E0B); // Amber
      case warrantyVerified:
        return const Color(0xFF8B5CF6); // Purple
      case handedOverToVendor:
        return const Color(0xFFEC4899); // Pink
      case receivedAtShop:
        return const Color(0xFF06B6D4); // Cyan
      case readyForCustomer:
        return const Color(0xFF10B981); // Emerald
      case returnedToCustomer:
      case completed:
        return const Color(0xFF22C55E); // Green
      case claimRejected:
        return const Color(0xFFEF4444); // Red
      default:
        return const Color(0xFF94A3B8); // Slate
    }
  }

  static IconData getIcon(String status) {
    switch (status) {
      case registered:
        return Icons.assignment_return_rounded;
      case underInspection:
        return Icons.search_rounded;
      case warrantyVerified:
        return Icons.verified_rounded;
      case handedOverToVendor:
        return Icons.local_shipping_rounded;
      case receivedAtShop:
        return Icons.store_rounded;
      case readyForCustomer:
        return Icons.task_alt_rounded;
      case returnedToCustomer:
      case completed:
        return Icons.check_circle_rounded;
      case claimRejected:
        return Icons.cancel_rounded;
      default:
        return Icons.help_outline_rounded;
    }
  }
}

/// Customer Warranty Status - kept strictly separate from Vendor terms.
class CustomerWarrantyStatus {
  static const String active = 'Active Warranty';
  static const String expired = 'Expired Warranty';
  static const String noWarranty = 'No Warranty';
  static const String verificationRequired = 'Verification Required';
  static const String underWarrantyInspection = 'Under Warranty Inspection';
  static const String claimRejected = 'Claim Rejected';

  static const List<String> all = [
    active,
    expired,
    noWarranty,
    verificationRequired,
    underWarrantyInspection,
    claimRejected,
  ];

  static Color getColor(String status) {
    switch (status) {
      case active:
        return const Color(0xFF10B981); // Emerald green
      case expired:
        return const Color(0xFFEF4444); // Red
      case noWarranty:
        return const Color(0xFF64748B); // Slate
      case verificationRequired:
        return const Color(0xFFF59E0B); // Amber
      case underWarrantyInspection:
        return const Color(0xFF8B5CF6); // Purple
      case claimRejected:
        return const Color(0xFFDC2626); // Crimson
      default:
        return const Color(0xFF94A3B8);
    }
  }

  static IconData getIcon(String status) {
    switch (status) {
      case active:
        return Icons.security_rounded;
      case expired:
        return Icons.gpp_bad_rounded;
      case noWarranty:
        return Icons.shield_outlined;
      case verificationRequired:
        return Icons.priority_high_rounded;
      case underWarrantyInspection:
        return Icons.manage_search_rounded;
      case claimRejected:
        return Icons.block_rounded;
      default:
        return Icons.help_outline_rounded;
    }
  }
}

/// 14 Specific Vendor Statuses required by workflow.
class VendorStatus {
  static const String notHandedOver = 'Not Handed Over';
  static const String handedOverToVendor = 'Handed Over to Vendor';
  static const String receivedByVendor = 'Received by Vendor';
  static const String underInspectionAtVendor = 'Under Inspection at Vendor';
  static const String waitingForVendorApproval = 'Waiting for Vendor Approval';
  static const String waitingForSpareParts = 'Waiting for Spare Parts';
  static const String underRepairAtVendor = 'Under Repair at Vendor';
  static const String repairedByVendor = 'Repaired by Vendor';
  static const String replacementApproved = 'Replacement Approved';
  static const String replacementDispatched = 'Replacement Dispatched';
  static const String replacementReceivedAtShop = 'Replacement Received at Shop';
  static const String warrantyClaimRejectedByVendor = 'Warranty Claim Rejected by Vendor';
  static const String returnedUnrepaired = 'Returned Unrepaired';
  static const String vendorFollowUpRequired = 'Vendor Follow-up Required';

  static const List<String> all = [
    notHandedOver,
    handedOverToVendor,
    receivedByVendor,
    underInspectionAtVendor,
    waitingForVendorApproval,
    waitingForSpareParts,
    underRepairAtVendor,
    repairedByVendor,
    replacementApproved,
    replacementDispatched,
    replacementReceivedAtShop,
    warrantyClaimRejectedByVendor,
    returnedUnrepaired,
    vendorFollowUpRequired,
  ];

  static Color getColor(String status) {
    switch (status) {
      case notHandedOver:
        return const Color(0xFF64748B); // Slate
      case handedOverToVendor:
        return const Color(0xFF38BDF8); // Sky blue
      case receivedByVendor:
        return const Color(0xFF06B6D4); // Cyan
      case underInspectionAtVendor:
        return const Color(0xFF818CF8); // Indigo
      case waitingForVendorApproval:
        return const Color(0xFFA855F7); // Purple
      case waitingForSpareParts:
        return const Color(0xFFF97316); // Orange
      case underRepairAtVendor:
        return const Color(0xFFEAB308); // Yellow
      case repairedByVendor:
        return const Color(0xFF10B981); // Emerald
      case replacementApproved:
        return const Color(0xFF22C55E); // Green
      case replacementDispatched:
        return const Color(0xFF3B82F6); // Blue
      case replacementReceivedAtShop:
        return const Color(0xFF14B8A6); // Teal
      case warrantyClaimRejectedByVendor:
        return const Color(0xFFEF4444); // Red
      case returnedUnrepaired:
        return const Color(0xFFB91C1C); // Dark red
      case vendorFollowUpRequired:
        return const Color(0xFFF43F5E); // Rose/Alert
      default:
        return const Color(0xFF94A3B8);
    }
  }

  static IconData getIcon(String status) {
    switch (status) {
      case notHandedOver:
        return Icons.hourglass_empty_rounded;
      case handedOverToVendor:
        return Icons.local_shipping_rounded;
      case receivedByVendor:
        return Icons.mark_email_read_rounded;
      case underInspectionAtVendor:
        return Icons.find_in_page_rounded;
      case waitingForVendorApproval:
        return Icons.pending_actions_rounded;
      case waitingForSpareParts:
        return Icons.settings_suggest_rounded;
      case underRepairAtVendor:
        return Icons.build_circle_rounded;
      case repairedByVendor:
        return Icons.task_alt_rounded;
      case replacementApproved:
        return Icons.published_with_changes_rounded;
      case replacementDispatched:
        return Icons.flight_takeoff_rounded;
      case replacementReceivedAtShop:
        return Icons.storefront_rounded;
      case warrantyClaimRejectedByVendor:
        return Icons.highlight_off_rounded;
      case returnedUnrepaired:
        return Icons.assignment_return_rounded;
      case vendorFollowUpRequired:
        return Icons.warning_amber_rounded;
      default:
        return Icons.info_outline_rounded;
    }
  }
}

/// Vendor Resolution Types
class VendorResolutionType {
  static const String repaired = 'Repaired';
  static const String replacementApproved = 'Replacement Approved';
  static const String replacementDispatched = 'Replacement Dispatched';
  static const String replacementReceived = 'Replacement Received';
  static const String claimRejected = 'Claim Rejected';
  static const String returnedUnrepaired = 'Returned Unrepaired';

  static const List<String> all = [
    repaired,
    replacementApproved,
    replacementDispatched,
    replacementReceived,
    claimRejected,
    returnedUnrepaired,
  ];
}

/// Return Reasons
class ReturnReason {
  static const String productNotWorking = 'Product Not Working';
  static const String chargingProblem = 'Charging Problem';
  static const String batteryProblem = 'Battery Problem';
  static const String displayProblem = 'Display Problem';
  static const String soundProblem = 'Sound Problem';
  static const String other = 'Other';

  static const List<String> all = [
    productNotWorking,
    chargingProblem,
    batteryProblem,
    displayProblem,
    soundProblem,
    other,
  ];
}

/// Chronological event entry in a return case.
class ReturnTimelineEvent {
  final String id;
  final DateTime timestamp;
  final String title;
  final String description;
  final String actorId;
  final String actorName;
  final String actorRole; // 'Owner' or 'Staff'
  final String status;
  final String? notes;
  final Map<String, dynamic> metadata;

  const ReturnTimelineEvent({
    required this.id,
    required this.timestamp,
    required this.title,
    required this.description,
    required this.actorId,
    required this.actorName,
    required this.actorRole,
    required this.status,
    this.notes,
    this.metadata = const {},
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'timestamp': timestamp.toIso8601String(),
        'title': title,
        'description': description,
        'actorId': actorId,
        'actorName': actorName,
        'actorRole': actorRole,
        'status': status,
        'notes': notes,
        'metadata': metadata,
      };

  factory ReturnTimelineEvent.fromMap(Map<dynamic, dynamic> m) {
    return ReturnTimelineEvent(
      id: m['id']?.toString() ?? '',
      timestamp: DateTime.tryParse(m['timestamp']?.toString() ?? '') ?? DateTime.now(),
      title: m['title']?.toString() ?? '',
      description: m['description']?.toString() ?? '',
      actorId: m['actorId']?.toString() ?? '',
      actorName: m['actorName']?.toString() ?? 'Staff',
      actorRole: m['actorRole']?.toString() ?? 'Staff',
      status: m['status']?.toString() ?? '',
      notes: m['notes']?.toString(),
      metadata: (m['metadata'] is Map) ? Map<String, dynamic>.from(m['metadata']) : {},
    );
  }
}

/// Vendor Handover Record (e.g. VHO-2026-0001)
class VendorHandoverRecord {
  final String handoverReference;
  final DateTime handoverDate;
  final dynamic vendorKey;
  final String vendorName;
  final String vendorPhone;
  final String vendorReferenceNumber;
  final String vendorServiceCentre;
  final String handedOverById;
  final String handedOverByName;
  final String handoverNotes;
  final String? handoverProofUrl;
  final bool isReceivedByVendor;
  final DateTime? vendorReceivedDate;
  final String? vendorReceivedNotes;

  const VendorHandoverRecord({
    required this.handoverReference,
    required this.handoverDate,
    this.vendorKey,
    required this.vendorName,
    required this.vendorPhone,
    required this.vendorReferenceNumber,
    required this.vendorServiceCentre,
    required this.handedOverById,
    required this.handedOverByName,
    required this.handoverNotes,
    this.handoverProofUrl,
    this.isReceivedByVendor = false,
    this.vendorReceivedDate,
    this.vendorReceivedNotes,
  });

  Map<String, dynamic> toMap() => {
        'handoverReference': handoverReference,
        'handoverDate': handoverDate.toIso8601String(),
        'vendorKey': vendorKey,
        'vendorName': vendorName,
        'vendorPhone': vendorPhone,
        'vendorReferenceNumber': vendorReferenceNumber,
        'vendorServiceCentre': vendorServiceCentre,
        'handedOverById': handedOverById,
        'handedOverByName': handedOverByName,
        'handoverNotes': handoverNotes,
        'handoverProofUrl': handoverProofUrl,
        'isReceivedByVendor': isReceivedByVendor,
        'vendorReceivedDate': vendorReceivedDate?.toIso8601String(),
        'vendorReceivedNotes': vendorReceivedNotes,
      };

  factory VendorHandoverRecord.fromMap(Map<dynamic, dynamic> m) {
    return VendorHandoverRecord(
      handoverReference: m['handoverReference']?.toString() ?? '',
      handoverDate: DateTime.tryParse(m['handoverDate']?.toString() ?? '') ?? DateTime.now(),
      vendorKey: m['vendorKey'],
      vendorName: m['vendorName']?.toString() ?? '',
      vendorPhone: m['vendorPhone']?.toString() ?? '',
      vendorReferenceNumber: m['vendorReferenceNumber']?.toString() ?? '',
      vendorServiceCentre: m['vendorServiceCentre']?.toString() ?? '',
      handedOverById: m['handedOverById']?.toString() ?? '',
      handedOverByName: m['handedOverByName']?.toString() ?? '',
      handoverNotes: m['handoverNotes']?.toString() ?? '',
      handoverProofUrl: m['handoverProofUrl']?.toString(),
      isReceivedByVendor: m['isReceivedByVendor'] == true,
      vendorReceivedDate: m['vendorReceivedDate'] != null
          ? DateTime.tryParse(m['vendorReceivedDate'].toString())
          : null,
      vendorReceivedNotes: m['vendorReceivedNotes']?.toString(),
    );
  }

  VendorHandoverRecord copyWith({
    bool? isReceivedByVendor,
    DateTime? vendorReceivedDate,
    String? vendorReceivedNotes,
  }) {
    return VendorHandoverRecord(
      handoverReference: handoverReference,
      handoverDate: handoverDate,
      vendorKey: vendorKey,
      vendorName: vendorName,
      vendorPhone: vendorPhone,
      vendorReferenceNumber: vendorReferenceNumber,
      vendorServiceCentre: vendorServiceCentre,
      handedOverById: handedOverById,
      handedOverByName: handedOverByName,
      handoverNotes: handoverNotes,
      handoverProofUrl: handoverProofUrl,
      isReceivedByVendor: isReceivedByVendor ?? this.isReceivedByVendor,
      vendorReceivedDate: vendorReceivedDate ?? this.vendorReceivedDate,
      vendorReceivedNotes: vendorReceivedNotes ?? this.vendorReceivedNotes,
    );
  }
}

/// Vendor Status History Record
class VendorStatusHistoryItem {
  final String previousStatus;
  final String newStatus;
  final DateTime timestamp;
  final String updatedById;
  final String updatedByName;
  final String? vendorReferenceNumber;
  final String notes;
  final List<String> attachments;

  const VendorStatusHistoryItem({
    required this.previousStatus,
    required this.newStatus,
    required this.timestamp,
    required this.updatedById,
    required this.updatedByName,
    this.vendorReferenceNumber,
    required this.notes,
    this.attachments = const [],
  });

  Map<String, dynamic> toMap() => {
        'previousStatus': previousStatus,
        'newStatus': newStatus,
        'timestamp': timestamp.toIso8601String(),
        'updatedById': updatedById,
        'updatedByName': updatedByName,
        'vendorReferenceNumber': vendorReferenceNumber,
        'notes': notes,
        'attachments': attachments,
      };

  factory VendorStatusHistoryItem.fromMap(Map<dynamic, dynamic> m) {
    return VendorStatusHistoryItem(
      previousStatus: m['previousStatus']?.toString() ?? '',
      newStatus: m['newStatus']?.toString() ?? '',
      timestamp: DateTime.tryParse(m['timestamp']?.toString() ?? '') ?? DateTime.now(),
      updatedById: m['updatedById']?.toString() ?? '',
      updatedByName: m['updatedByName']?.toString() ?? '',
      vendorReferenceNumber: m['vendorReferenceNumber']?.toString(),
      notes: m['notes']?.toString() ?? '',
      attachments: (m['attachments'] is List)
          ? (m['attachments'] as List).map((e) => e.toString()).toList()
          : [],
    );
  }
}

/// Resolution recorded from the Vendor
class VendorResolution {
  final String decision; // From VendorResolutionType
  final DateTime decisionDate;
  final String? repairDetails;
  final bool isReplacement;
  final String? replacementProduct;
  final String? replacementSerialNumber; // New IMEI/Serial
  final DateTime? replacementReceivedDate;
  final double vendorCharges;
  final double vendorCreditRefund;
  final String? vendorNotes;
  final String? claimRejectionReason;
  final String? resolvedById;
  final String? resolvedByName;

  const VendorResolution({
    required this.decision,
    required this.decisionDate,
    this.repairDetails,
    this.isReplacement = false,
    this.replacementProduct,
    this.replacementSerialNumber,
    this.replacementReceivedDate,
    this.vendorCharges = 0.0,
    this.vendorCreditRefund = 0.0,
    this.vendorNotes,
    this.claimRejectionReason,
    this.resolvedById,
    this.resolvedByName,
  });

  Map<String, dynamic> toMap() => {
        'decision': decision,
        'decisionDate': decisionDate.toIso8601String(),
        'repairDetails': repairDetails,
        'isReplacement': isReplacement,
        'replacementProduct': replacementProduct,
        'replacementSerialNumber': replacementSerialNumber,
        'replacementReceivedDate': replacementReceivedDate?.toIso8601String(),
        'vendorCharges': vendorCharges,
        'vendorCreditRefund': vendorCreditRefund,
        'vendorNotes': vendorNotes,
        'claimRejectionReason': claimRejectionReason,
        'resolvedById': resolvedById,
        'resolvedByName': resolvedByName,
      };

  factory VendorResolution.fromMap(Map<dynamic, dynamic> m) {
    return VendorResolution(
      decision: m['decision']?.toString() ?? VendorResolutionType.repaired,
      decisionDate: DateTime.tryParse(m['decisionDate']?.toString() ?? '') ?? DateTime.now(),
      repairDetails: m['repairDetails']?.toString(),
      isReplacement: m['isReplacement'] == true,
      replacementProduct: m['replacementProduct']?.toString(),
      replacementSerialNumber: m['replacementSerialNumber']?.toString(),
      replacementReceivedDate: m['replacementReceivedDate'] != null
          ? DateTime.tryParse(m['replacementReceivedDate'].toString())
          : null,
      vendorCharges: (m['vendorCharges'] as num?)?.toDouble() ?? 0.0,
      vendorCreditRefund: (m['vendorCreditRefund'] as num?)?.toDouble() ?? 0.0,
      vendorNotes: m['vendorNotes']?.toString(),
      claimRejectionReason: m['claimRejectionReason']?.toString(),
      resolvedById: m['resolvedById']?.toString(),
      resolvedByName: m['resolvedByName']?.toString(),
    );
  }
}

/// Customer Delivery Confirmation Record
class CustomerDeliveryRecord {
  final DateTime deliveryDate;
  final String deliveredById;
  final String deliveredByName;
  final String customerConfirmation;
  final String? deliveryNotes;
  final String? deliveredProductDetails;

  const CustomerDeliveryRecord({
    required this.deliveryDate,
    required this.deliveredById,
    required this.deliveredByName,
    required this.customerConfirmation,
    this.deliveryNotes,
    this.deliveredProductDetails,
  });

  Map<String, dynamic> toMap() => {
        'deliveryDate': deliveryDate.toIso8601String(),
        'deliveredById': deliveredById,
        'deliveredByName': deliveredByName,
        'customerConfirmation': customerConfirmation,
        'deliveryNotes': deliveryNotes,
        'deliveredProductDetails': deliveredProductDetails,
      };

  factory CustomerDeliveryRecord.fromMap(Map<dynamic, dynamic> m) {
    return CustomerDeliveryRecord(
      deliveryDate: DateTime.tryParse(m['deliveryDate']?.toString() ?? '') ?? DateTime.now(),
      deliveredById: m['deliveredById']?.toString() ?? '',
      deliveredByName: m['deliveredByName']?.toString() ?? '',
      customerConfirmation: m['customerConfirmation']?.toString() ?? '',
      deliveryNotes: m['deliveryNotes']?.toString(),
      deliveredProductDetails: m['deliveredProductDetails']?.toString(),
    );
  }
}

/// The main Customer Return Record
class CustomerReturn {
  final dynamic key; // Hive storage key
  final String returnId; // e.g. RET-2026-0001
  final DateTime createdAt;
  final dynamic customerKey;
  final String? customerId;
  final String customerName;
  final String customerPhone;
  final String originalInvoiceNumber;
  final dynamic originalSaleKey;
  final dynamic originalItemKey;
  final DateTime originalPurchaseDate;
  final String productName;
  final String? productBrand;
  final String? productModel;
  final String? serialNumber; // IMEI or Serial
  final double salePrice;
  final String customerWarrantyPeriod;
  final DateTime? customerWarrantyExpiryDate;
  final String customerWarrantyStatus;
  final String? warrantyInspectionNotes;
  final String? warrantyVerifiedById;
  final String? warrantyVerifiedByName;

  // Vendor Information
  final dynamic originalVendorKey;
  final String? originalVendorName;
  final String? originalVendorPhone;
  final String? originalVendorInvoice;
  final DateTime? originalVendorPurchaseDate;
  final String? originalVendorWarrantyPeriod;
  final DateTime? originalVendorWarrantyExpiry;
  final String? originalVendorReference;

  // Return Details
  final String returnReason;
  final String customerComplaint;
  final String productCondition;
  final String accessoriesReceived;
  final List<String> productPhotos;
  final String? assignedStaffId;
  final String? assignedStaffName;
  final String? internalNotes;

  // Statuses
  final String customerReturnStatus; // CustomerReturnStatus
  final String vendorStatus; // VendorStatus

  // Workflow Sub-records
  final VendorHandoverRecord? handoverRecord;
  final List<VendorStatusHistoryItem> vendorStatusHistory;
  final VendorResolution? vendorResolution;

  // Shop Receipt Details
  final DateTime? shopReceiptDate;
  final String? shopReceivedById;
  final String? shopReceivedByName;
  final String? shopInspectionNotes;
  final bool isReadyForCustomer;

  // Final Delivery to Customer
  final CustomerDeliveryRecord? customerDeliveryRecord;

  // Complete Chronological Timeline
  final List<ReturnTimelineEvent> timeline;

  final bool isCompleted;
  final DateTime updatedAt;

  const CustomerReturn({
    this.key,
    required this.returnId,
    required this.createdAt,
    this.customerKey,
    this.customerId,
    required this.customerName,
    required this.customerPhone,
    required this.originalInvoiceNumber,
    this.originalSaleKey,
    this.originalItemKey,
    required this.originalPurchaseDate,
    required this.productName,
    this.productBrand,
    this.productModel,
    this.serialNumber,
    this.salePrice = 0.0,
    required this.customerWarrantyPeriod,
    this.customerWarrantyExpiryDate,
    required this.customerWarrantyStatus,
    this.warrantyInspectionNotes,
    this.warrantyVerifiedById,
    this.warrantyVerifiedByName,
    this.originalVendorKey,
    this.originalVendorName,
    this.originalVendorPhone,
    this.originalVendorInvoice,
    this.originalVendorPurchaseDate,
    this.originalVendorWarrantyPeriod,
    this.originalVendorWarrantyExpiry,
    this.originalVendorReference,
    required this.returnReason,
    required this.customerComplaint,
    required this.productCondition,
    required this.accessoriesReceived,
    this.productPhotos = const [],
    this.assignedStaffId,
    this.assignedStaffName,
    this.internalNotes,
    required this.customerReturnStatus,
    required this.vendorStatus,
    this.handoverRecord,
    this.vendorStatusHistory = const [],
    this.vendorResolution,
    this.shopReceiptDate,
    this.shopReceivedById,
    this.shopReceivedByName,
    this.shopInspectionNotes,
    this.isReadyForCustomer = false,
    this.customerDeliveryRecord,
    this.timeline = const [],
    this.isCompleted = false,
    required this.updatedAt,
  });

  /// Calculates days pending with vendor
  int get daysPendingWithVendor {
    if (handoverRecord == null) return 0;
    final end = shopReceiptDate ?? DateTime.now();
    return end.difference(handoverRecord!.handoverDate).inDays;
  }

  /// Whether product is currently with vendor
  bool get isPendingWithVendor {
    if (handoverRecord == null) return false;
    if (shopReceiptDate != null) return false;
    return vendorStatus != VendorStatus.notHandedOver &&
        vendorStatus != VendorStatus.replacementReceivedAtShop &&
        vendorStatus != VendorStatus.returnedUnrepaired;
  }

  /// Checks if follow-up is overdue given threshold days
  bool isFollowUpOverdue(int thresholdDays) {
    if (!isPendingWithVendor) return false;
    return daysPendingWithVendor >= thresholdDays;
  }

  Map<String, dynamic> toMap() => {
        'returnId': returnId,
        'createdAt': createdAt.toIso8601String(),
        'customerKey': customerKey,
        'customerId': customerId,
        'customerName': customerName,
        'customerPhone': customerPhone,
        'originalInvoiceNumber': originalInvoiceNumber,
        'originalSaleKey': originalSaleKey,
        'originalItemKey': originalItemKey,
        'originalPurchaseDate': originalPurchaseDate.toIso8601String(),
        'productName': productName,
        'productBrand': productBrand,
        'productModel': productModel,
        'serialNumber': serialNumber,
        'salePrice': salePrice,
        'customerWarrantyPeriod': customerWarrantyPeriod,
        'customerWarrantyExpiryDate': customerWarrantyExpiryDate?.toIso8601String(),
        'customerWarrantyStatus': customerWarrantyStatus,
        'warrantyInspectionNotes': warrantyInspectionNotes,
        'warrantyVerifiedById': warrantyVerifiedById,
        'warrantyVerifiedByName': warrantyVerifiedByName,
        'originalVendorKey': originalVendorKey,
        'originalVendorName': originalVendorName,
        'originalVendorPhone': originalVendorPhone,
        'originalVendorInvoice': originalVendorInvoice,
        'originalVendorPurchaseDate': originalVendorPurchaseDate?.toIso8601String(),
        'originalVendorWarrantyPeriod': originalVendorWarrantyPeriod,
        'originalVendorWarrantyExpiry': originalVendorWarrantyExpiry?.toIso8601String(),
        'originalVendorReference': originalVendorReference,
        'returnReason': returnReason,
        'customerComplaint': customerComplaint,
        'productCondition': productCondition,
        'accessoriesReceived': accessoriesReceived,
        'productPhotos': productPhotos,
        'assignedStaffId': assignedStaffId,
        'assignedStaffName': assignedStaffName,
        'internalNotes': internalNotes,
        'customerReturnStatus': customerReturnStatus,
        'vendorStatus': vendorStatus,
        'handoverRecord': handoverRecord?.toMap(),
        'vendorStatusHistory': vendorStatusHistory.map((e) => e.toMap()).toList(),
        'vendorResolution': vendorResolution?.toMap(),
        'shopReceiptDate': shopReceiptDate?.toIso8601String(),
        'shopReceivedById': shopReceivedById,
        'shopReceivedByName': shopReceivedByName,
        'shopInspectionNotes': shopInspectionNotes,
        'isReadyForCustomer': isReadyForCustomer,
        'customerDeliveryRecord': customerDeliveryRecord?.toMap(),
        'timeline': timeline.map((e) => e.toMap()).toList(),
        'isCompleted': isCompleted,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory CustomerReturn.fromMap(Map<dynamic, dynamic> m, [dynamic key]) {
    return CustomerReturn(
      key: key ?? m['key'],
      returnId: m['returnId']?.toString() ?? '',
      createdAt: DateTime.tryParse(m['createdAt']?.toString() ?? '') ?? DateTime.now(),
      customerKey: m['customerKey'],
      customerId: m['customerId']?.toString(),
      customerName: m['customerName']?.toString() ?? '',
      customerPhone: m['customerPhone']?.toString() ?? '',
      originalInvoiceNumber: m['originalInvoiceNumber']?.toString() ?? '',
      originalSaleKey: m['originalSaleKey'],
      originalItemKey: m['originalItemKey'],
      originalPurchaseDate: DateTime.tryParse(m['originalPurchaseDate']?.toString() ?? '') ?? DateTime.now(),
      productName: m['productName']?.toString() ?? '',
      productBrand: m['productBrand']?.toString(),
      productModel: m['productModel']?.toString(),
      serialNumber: m['serialNumber']?.toString(),
      salePrice: (m['salePrice'] as num?)?.toDouble() ?? 0.0,
      customerWarrantyPeriod: m['customerWarrantyPeriod']?.toString() ?? 'No Warranty',
      customerWarrantyExpiryDate: m['customerWarrantyExpiryDate'] != null
          ? DateTime.tryParse(m['customerWarrantyExpiryDate'].toString())
          : null,
      customerWarrantyStatus: m['customerWarrantyStatus']?.toString() ?? CustomerWarrantyStatus.noWarranty,
      warrantyInspectionNotes: m['warrantyInspectionNotes']?.toString(),
      warrantyVerifiedById: m['warrantyVerifiedById']?.toString(),
      warrantyVerifiedByName: m['warrantyVerifiedByName']?.toString(),
      originalVendorKey: m['originalVendorKey'],
      originalVendorName: m['originalVendorName']?.toString(),
      originalVendorPhone: m['originalVendorPhone']?.toString(),
      originalVendorInvoice: m['originalVendorInvoice']?.toString(),
      originalVendorPurchaseDate: m['originalVendorPurchaseDate'] != null
          ? DateTime.tryParse(m['originalVendorPurchaseDate'].toString())
          : null,
      originalVendorWarrantyPeriod: m['originalVendorWarrantyPeriod']?.toString(),
      originalVendorWarrantyExpiry: m['originalVendorWarrantyExpiry'] != null
          ? DateTime.tryParse(m['originalVendorWarrantyExpiry'].toString())
          : null,
      originalVendorReference: m['originalVendorReference']?.toString(),
      returnReason: m['returnReason']?.toString() ?? ReturnReason.other,
      customerComplaint: m['customerComplaint']?.toString() ?? '',
      productCondition: m['productCondition']?.toString() ?? '',
      accessoriesReceived: m['accessoriesReceived']?.toString() ?? '',
      productPhotos: (m['productPhotos'] is List)
          ? (m['productPhotos'] as List).map((e) => e.toString()).toList()
          : [],
      assignedStaffId: m['assignedStaffId']?.toString(),
      assignedStaffName: m['assignedStaffName']?.toString(),
      internalNotes: m['internalNotes']?.toString(),
      customerReturnStatus: m['customerReturnStatus']?.toString() ?? CustomerReturnStatus.registered,
      vendorStatus: m['vendorStatus']?.toString() ?? VendorStatus.notHandedOver,
      handoverRecord: (m['handoverRecord'] is Map)
          ? VendorHandoverRecord.fromMap(m['handoverRecord'])
          : null,
      vendorStatusHistory: (m['vendorStatusHistory'] is List)
          ? (m['vendorStatusHistory'] as List)
              .map((e) => VendorStatusHistoryItem.fromMap(e as Map))
              .toList()
          : [],
      vendorResolution: (m['vendorResolution'] is Map)
          ? VendorResolution.fromMap(m['vendorResolution'])
          : null,
      shopReceiptDate: m['shopReceiptDate'] != null
          ? DateTime.tryParse(m['shopReceiptDate'].toString())
          : null,
      shopReceivedById: m['shopReceivedById']?.toString(),
      shopReceivedByName: m['shopReceivedByName']?.toString(),
      shopInspectionNotes: m['shopInspectionNotes']?.toString(),
      isReadyForCustomer: m['isReadyForCustomer'] == true,
      customerDeliveryRecord: (m['customerDeliveryRecord'] is Map)
          ? CustomerDeliveryRecord.fromMap(m['customerDeliveryRecord'])
          : null,
      timeline: (m['timeline'] is List)
          ? (m['timeline'] as List)
              .map((e) => ReturnTimelineEvent.fromMap(e as Map))
              .toList()
          : [],
      isCompleted: m['isCompleted'] == true,
      updatedAt: DateTime.tryParse(m['updatedAt']?.toString() ?? '') ?? DateTime.now(),
    );
  }

  CustomerReturn copyWith({
    dynamic key,
    String? customerReturnStatus,
    String? vendorStatus,
    String? customerWarrantyStatus,
    String? warrantyInspectionNotes,
    String? warrantyVerifiedById,
    String? warrantyVerifiedByName,
    dynamic originalVendorKey,
    String? originalVendorName,
    String? originalVendorPhone,
    String? originalVendorInvoice,
    DateTime? originalVendorPurchaseDate,
    String? originalVendorWarrantyPeriod,
    DateTime? originalVendorWarrantyExpiry,
    String? originalVendorReference,
    VendorHandoverRecord? handoverRecord,
    List<VendorStatusHistoryItem>? vendorStatusHistory,
    VendorResolution? vendorResolution,
    DateTime? shopReceiptDate,
    String? shopReceivedById,
    String? shopReceivedByName,
    String? shopInspectionNotes,
    bool? isReadyForCustomer,
    CustomerDeliveryRecord? customerDeliveryRecord,
    List<ReturnTimelineEvent>? timeline,
    bool? isCompleted,
    DateTime? updatedAt,
  }) {
    return CustomerReturn(
      key: key ?? this.key,
      returnId: returnId,
      createdAt: createdAt,
      customerKey: customerKey,
      customerId: customerId,
      customerName: customerName,
      customerPhone: customerPhone,
      originalInvoiceNumber: originalInvoiceNumber,
      originalSaleKey: originalSaleKey,
      originalItemKey: originalItemKey,
      originalPurchaseDate: originalPurchaseDate,
      productName: productName,
      productBrand: productBrand,
      productModel: productModel,
      serialNumber: serialNumber,
      salePrice: salePrice,
      customerWarrantyPeriod: customerWarrantyPeriod,
      customerWarrantyExpiryDate: customerWarrantyExpiryDate,
      customerWarrantyStatus: customerWarrantyStatus ?? this.customerWarrantyStatus,
      warrantyInspectionNotes: warrantyInspectionNotes ?? this.warrantyInspectionNotes,
      warrantyVerifiedById: warrantyVerifiedById ?? this.warrantyVerifiedById,
      warrantyVerifiedByName: warrantyVerifiedByName ?? this.warrantyVerifiedByName,
      originalVendorKey: originalVendorKey ?? this.originalVendorKey,
      originalVendorName: originalVendorName ?? this.originalVendorName,
      originalVendorPhone: originalVendorPhone ?? this.originalVendorPhone,
      originalVendorInvoice: originalVendorInvoice ?? this.originalVendorInvoice,
      originalVendorPurchaseDate: originalVendorPurchaseDate ?? this.originalVendorPurchaseDate,
      originalVendorWarrantyPeriod: originalVendorWarrantyPeriod ?? this.originalVendorWarrantyPeriod,
      originalVendorWarrantyExpiry: originalVendorWarrantyExpiry ?? this.originalVendorWarrantyExpiry,
      originalVendorReference: originalVendorReference ?? this.originalVendorReference,
      returnReason: returnReason,
      customerComplaint: customerComplaint,
      productCondition: productCondition,
      accessoriesReceived: accessoriesReceived,
      productPhotos: productPhotos,
      assignedStaffId: assignedStaffId,
      assignedStaffName: assignedStaffName,
      internalNotes: internalNotes,
      customerReturnStatus: customerReturnStatus ?? this.customerReturnStatus,
      vendorStatus: vendorStatus ?? this.vendorStatus,
      handoverRecord: handoverRecord ?? this.handoverRecord,
      vendorStatusHistory: vendorStatusHistory ?? this.vendorStatusHistory,
      vendorResolution: vendorResolution ?? this.vendorResolution,
      shopReceiptDate: shopReceiptDate ?? this.shopReceiptDate,
      shopReceivedById: shopReceivedById ?? this.shopReceivedById,
      shopReceivedByName: shopReceivedByName ?? this.shopReceivedByName,
      shopInspectionNotes: shopInspectionNotes ?? this.shopInspectionNotes,
      isReadyForCustomer: isReadyForCustomer ?? this.isReadyForCustomer,
      customerDeliveryRecord: customerDeliveryRecord ?? this.customerDeliveryRecord,
      timeline: timeline ?? this.timeline,
      isCompleted: isCompleted ?? this.isCompleted,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }
}

/// Helper data structure representing an item found in existing sales
class PurchasedProductItem {
  final dynamic saleKey;
  final String invoiceNumber;
  final DateTime purchaseDate;
  final String customerName;
  final String customerPhone;
  final dynamic customerKey;
  final dynamic itemKey;
  final String itemId;
  final String productName;
  final String brand;
  final String model;
  final String serialNumber; // IMEI / Serial
  final double price;
  final double cost;
  final int quantity;
  final String warrantyPeriod;
  final DateTime? warrantyExpiryDate;
  final String calculatedWarrantyStatus;
  final String? originalVendorName;
  final dynamic originalVendorKey;
  final String? originalVendorPhone;
  final int previousReturnCount;

  const PurchasedProductItem({
    required this.saleKey,
    required this.invoiceNumber,
    required this.purchaseDate,
    required this.customerName,
    required this.customerPhone,
    this.customerKey,
    this.itemKey,
    required this.itemId,
    required this.productName,
    required this.brand,
    required this.model,
    required this.serialNumber,
    required this.price,
    this.cost = 0.0,
    required this.quantity,
    required this.warrantyPeriod,
    this.warrantyExpiryDate,
    required this.calculatedWarrantyStatus,
    this.originalVendorName,
    this.originalVendorKey,
    this.originalVendorPhone,
    this.previousReturnCount = 0,
  });
}
