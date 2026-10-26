package com.tekfix.orders.data.model

import com.google.firebase.Timestamp

enum class OrderStatus(val displayName: String) {
    DRAFT("Draft"),
    SUBMITTED("Submitted"),
    PENDING("Pending"),
    CONFIRMED("Confirmed"),
    PROCESSING("Processing"),
    COMPLETED("Completed"),
    CANCELLED("Cancelled");

    companion object {
        fun fromString(value: String?): OrderStatus {
            return entries.firstOrNull { it.name.equals(value, ignoreCase = true) } ?: SUBMITTED
        }
    }
}

enum class WhatsAppStatus(val displayName: String) {
    ORDER_SAVED("Order Saved"),
    WAITING_DELIVERY("Waiting for Delivery"),
    SENT_SUCCESSFULLY("Sent Successfully"),
    DELIVERY_FAILED("Delivery Failed"),
    MANUAL_ACTION_REQUIRED("Manual Action Required");

    companion object {
        fun fromString(value: String?): WhatsAppStatus {
            return entries.firstOrNull { it.name.equals(value, ignoreCase = true) } ?: ORDER_SAVED
        }
    }
}

data class Order(
    val orderId: String = "",
    val staffId: String = "",
    val staffName: String = "",
    val createdDate: String = "", // e.g. 26-10-2026
    val createdTime: String = "", // e.g. 10:30 AM
    val createdAt: Timestamp? = null,
    val products: List<OrderProduct> = emptyList(),
    val totalTypes: Int = 0,
    val totalQuantity: Int = 0,
    val generalRemarks: String = "",
    val status: OrderStatus = OrderStatus.SUBMITTED,
    val whatsappDeliveryStatus: WhatsAppStatus = WhatsAppStatus.ORDER_SAVED,
    val whatsappMessageId: String? = null,
    val updatedAt: Timestamp? = null
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "orderId" to orderId,
        "staffId" to staffId,
        "staffName" to staffName,
        "createdDate" to createdDate,
        "createdTime" to createdTime,
        "createdAt" to (createdAt ?: Timestamp.now()),
        "products" to products.map { it.toMap() },
        "totalTypes" to totalTypes,
        "totalQuantity" to totalQuantity,
        "generalRemarks" to generalRemarks,
        "status" to status.name,
        "whatsappDeliveryStatus" to whatsappDeliveryStatus.name,
        "whatsappMessageId" to whatsappMessageId,
        "updatedAt" to Timestamp.now()
    )

    companion object {
        @Suppress("UNCHECKED_CAST")
        fun fromMap(id: String, map: Map<String, Any?>): Order {
            val rawProducts = map["products"] as? List<Map<String, Any?>> ?: emptyList()
            val parsedProducts = rawProducts.map { OrderProduct.fromMap(it) }

            val totalTypes = (map["totalTypes"] as? Number)?.toInt() ?: parsedProducts.size
            val totalQuantity = (map["totalQuantity"] as? Number)?.toInt()
                ?: parsedProducts.sumOf { it.quantity }

            return Order(
                orderId = id,
                staffId = map["staffId"] as? String ?: "",
                staffName = map["staffName"] as? String ?: "",
                createdDate = map["createdDate"] as? String ?: "",
                createdTime = map["createdTime"] as? String ?: "",
                createdAt = map["createdAt"] as? Timestamp,
                products = parsedProducts,
                totalTypes = totalTypes,
                totalQuantity = totalQuantity,
                generalRemarks = map["generalRemarks"] as? String ?: "",
                status = OrderStatus.fromString(map["status"] as? String),
                whatsappDeliveryStatus = WhatsAppStatus.fromString(map["whatsappDeliveryStatus"] as? String),
                whatsappMessageId = map["whatsappMessageId"] as? String,
                updatedAt = map["updatedAt"] as? Timestamp
            )
        }
    }
}
