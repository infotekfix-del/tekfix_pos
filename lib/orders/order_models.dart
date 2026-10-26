import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

enum StaffOrderStatus {
  submitted('Submitted', 'സമർപ്പിച്ചു', Color(0xFF2563EB)),
  pending('Pending', 'തീരുമാനമായില്ല', Color(0xFFD97706)),
  confirmed('Confirmed', 'സ്ഥിരീകരിച്ചു', Color(0xFF059669)),
  processing('Processing', 'പ്രോസസ്സിംഗ്', Color(0xFF7C3AED)),
  completed('Completed', 'പൂർത്തിയായി', Color(0xFF0D9488)),
  cancelled('Cancelled', 'റദ്ദാക്കി', Color(0xFFDC2626));

  final String label;
  final String labelMl;
  final Color color;

  const StaffOrderStatus(this.label, this.labelMl, this.color);

  static StaffOrderStatus fromString(String? val) {
    if (val == null) return StaffOrderStatus.submitted;
    return StaffOrderStatus.values.firstWhere(
      (e) => e.name.toLowerCase() == val.toLowerCase(),
      orElse: () => StaffOrderStatus.submitted,
    );
  }
}

enum WhatsAppDeliveryStatus {
  orderSaved('Order Saved', 'ഡാറ്റാബേസിൽ സേവ് ചെയ്തു', Color(0xFF0F766E)),
  waitingDelivery('Waiting for Delivery', 'ഡെലിവറി കാത്തിരിക്കുന്നു', Color(0xFFD97706)),
  sentSuccessfully('Sent Successfully', 'വിജയകരമായി അയച്ചു', Color(0xFF16A34A)),
  deliveryFailed('Delivery Failed', 'പരാജയപ്പെട്ടു', Color(0xFFDC2626)),
  manualActionRequired('Manual Share Required', 'ഗ്രൂപ്പിലേക്ക് അയക്കുക', Color(0xFF25D366));

  final String label;
  final String labelMl;
  final Color color;

  const WhatsAppDeliveryStatus(this.label, this.labelMl, this.color);

  static WhatsAppDeliveryStatus fromString(String? val) {
    if (val == null) return WhatsAppDeliveryStatus.orderSaved;
    return WhatsAppDeliveryStatus.values.firstWhere(
      (e) => e.name.toLowerCase() == val.toLowerCase(),
      orElse: () => WhatsAppDeliveryStatus.orderSaved,
    );
  }
}

class StaffOrderProduct {
  final String id;
  final String productId;
  final String name;
  final String sku;
  final String category;
  final String model;
  final String variant;
  final int quantity;
  final String unit;
  final String remarks;
  final bool isCustom;

  StaffOrderProduct({
    required this.id,
    this.productId = '',
    required this.name,
    this.sku = '',
    this.category = 'Others',
    this.model = '',
    this.variant = '',
    required this.quantity,
    this.unit = 'Pcs',
    this.remarks = '',
    this.isCustom = false,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'productId': productId,
        'name': name,
        'sku': sku,
        'category': category,
        'model': model,
        'variant': variant,
        'quantity': quantity,
        'unit': unit,
        'remarks': remarks,
        'isCustom': isCustom,
      };

  factory StaffOrderProduct.fromMap(Map<String, dynamic> m) {
    return StaffOrderProduct(
      id: '${m['id'] ?? ''}',
      productId: '${m['productId'] ?? ''}',
      name: '${m['name'] ?? ''}',
      sku: '${m['sku'] ?? ''}',
      category: '${m['category'] ?? 'Others'}',
      model: '${m['model'] ?? ''}',
      variant: '${m['variant'] ?? ''}',
      quantity: (m['quantity'] as num?)?.toInt() ?? 1,
      unit: '${m['unit'] ?? 'Pcs'}',
      remarks: '${m['remarks'] ?? ''}',
      isCustom: m['isCustom'] == true,
    );
  }
}

class StaffOrder {
  final String orderId;
  final String shopId;
  final String staffId;
  final String staffName;
  final String createdDate;
  final String createdTime;
  final DateTime createdAt;
  final List<StaffOrderProduct> products;
  final int totalTypes;
  final int totalQuantity;
  final String generalRemarks;
  final StaffOrderStatus status;
  final WhatsAppDeliveryStatus whatsappDeliveryStatus;
  final String? whatsappMessageId;
  final DateTime? updatedAt;
  final String? updatedBy;

  StaffOrder({
    required this.orderId,
    required this.shopId,
    required this.staffId,
    required this.staffName,
    required this.createdDate,
    required this.createdTime,
    required this.createdAt,
    required this.products,
    required this.totalTypes,
    required this.totalQuantity,
    this.generalRemarks = '',
    this.status = StaffOrderStatus.submitted,
    this.whatsappDeliveryStatus = WhatsAppDeliveryStatus.orderSaved,
    this.whatsappMessageId,
    this.updatedAt,
    this.updatedBy,
  });

  Map<String, dynamic> toMap({bool useServerTimestamp = true}) => {
        'orderId': orderId,
        'shopId': shopId,
        'staffId': staffId,
        'staffName': staffName,
        'createdDate': createdDate,
        'createdTime': createdTime,
        'createdAt': useServerTimestamp ? FieldValue.serverTimestamp() : Timestamp.fromDate(createdAt),
        'products': products.map((p) => p.toMap()).toList(),
        'totalTypes': totalTypes,
        'totalQuantity': totalQuantity,
        'generalRemarks': generalRemarks,
        'status': status.name,
        'whatsappDeliveryStatus': whatsappDeliveryStatus.name,
        'whatsappMessageId': whatsappMessageId,
        'updatedAt': useServerTimestamp ? FieldValue.serverTimestamp() : Timestamp.fromDate(updatedAt ?? createdAt),
        'updatedBy': updatedBy,
      };

  factory StaffOrder.fromMap(String id, Map<String, dynamic> m) {
    final rawProducts = (m['products'] as List?) ?? [];
    final parsedProducts = rawProducts.map((p) => StaffOrderProduct.fromMap(Map<String, dynamic>.from(p as Map))).toList();

    DateTime parseTime(dynamic val) {
      if (val is Timestamp) return val.toDate();
      if (val is String) return DateTime.tryParse(val) ?? DateTime.now();
      return DateTime.now();
    }

    final totalTypes = (m['totalTypes'] as num?)?.toInt() ?? parsedProducts.length;
    final totalQuantity = (m['totalQuantity'] as num?)?.toInt() ?? parsedProducts.fold<int>(0, (acc, item) => acc + item.quantity);

    return StaffOrder(
      orderId: id,
      shopId: '${m['shopId'] ?? ''}',
      staffId: '${m['staffId'] ?? ''}',
      staffName: '${m['staffName'] ?? ''}',
      createdDate: '${m['createdDate'] ?? ''}',
      createdTime: '${m['createdTime'] ?? ''}',
      createdAt: parseTime(m['createdAt']),
      products: parsedProducts,
      totalTypes: totalTypes,
      totalQuantity: totalQuantity,
      generalRemarks: '${m['generalRemarks'] ?? ''}',
      status: StaffOrderStatus.fromString(m['status'] as String?),
      whatsappDeliveryStatus: WhatsAppDeliveryStatus.fromString(m['whatsappDeliveryStatus'] as String?),
      whatsappMessageId: m['whatsappMessageId'] as String?,
      updatedAt: m['updatedAt'] != null ? parseTime(m['updatedAt']) : null,
      updatedBy: m['updatedBy'] as String?,
    );
  }
}

class WhatsAppGroupConfig {
  final String groupInvitationUrl;
  final String apiUrl;
  final String apiToken;
  final String phoneNumberId;
  final bool manualFallbackEnabled;

  const WhatsAppGroupConfig({
    this.groupInvitationUrl = 'https://chat.whatsapp.com/GD5fTnnLRk9I0mPXdJ80n0?s=cl&p=a&mlu=4&ilr=4',
    this.apiUrl = '',
    this.apiToken = '',
    this.phoneNumberId = '',
    this.manualFallbackEnabled = true,
  });

  bool get isApiConfigured => apiUrl.trim().isNotEmpty && apiToken.trim().isNotEmpty;

  Map<String, dynamic> toMap() => {
        'groupInvitationUrl': groupInvitationUrl,
        'apiUrl': apiUrl,
        'apiToken': apiToken,
        'phoneNumberId': phoneNumberId,
        'manualFallbackEnabled': manualFallbackEnabled,
        'updatedAt': FieldValue.serverTimestamp(),
      };

  factory WhatsAppGroupConfig.fromMap(Map<String, dynamic> m) {
    return WhatsAppGroupConfig(
      groupInvitationUrl: '${m['groupInvitationUrl'] ?? 'https://chat.whatsapp.com/GD5fTnnLRk9I0mPXdJ80n0?s=cl&p=a&mlu=4&ilr=4'}',
      apiUrl: '${m['apiUrl'] ?? ''}',
      apiToken: '${m['apiToken'] ?? ''}',
      phoneNumberId: '${m['phoneNumberId'] ?? ''}',
      manualFallbackEnabled: m['manualFallbackEnabled'] != false,
    );
  }
}
