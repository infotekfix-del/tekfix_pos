package com.tekfix.orders.data.model

import java.util.UUID

data class OrderProduct(
    val id: String = UUID.randomUUID().toString(),
    val productId: String = "",
    val name: String = "",
    val sku: String = "",
    val category: String = "Others",
    val model: String = "",
    val variant: String = "",
    val quantity: Int = 1,
    val unit: String = "Pcs",
    val remarks: String = "",
    val isCustom: Boolean = false
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "id" to id,
        "productId" to productId,
        "name" to name,
        "sku" to sku,
        "category" to category,
        "model" to model,
        "variant" to variant,
        "quantity" to quantity,
        "unit" to unit,
        "remarks" to remarks,
        "isCustom" to isCustom
    )

    companion object {
        fun fromMap(map: Map<String, Any?>): OrderProduct {
            return OrderProduct(
                id = map["id"] as? String ?: UUID.randomUUID().toString(),
                productId = map["productId"] as? String ?: "",
                name = map["name"] as? String ?: "",
                sku = map["sku"] as? String ?: "",
                category = map["category"] as? String ?: "Others",
                model = map["model"] as? String ?: "",
                variant = map["variant"] as? String ?: "",
                quantity = (map["quantity"] as? Number)?.toInt() ?: 1,
                unit = map["unit"] as? String ?: "Pcs",
                remarks = map["remarks"] as? String ?: "",
                isCustom = map["isCustom"] as? Boolean ?: false
            )
        }
    }
}
