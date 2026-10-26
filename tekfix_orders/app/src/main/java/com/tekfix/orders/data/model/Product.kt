package com.tekfix.orders.data.model

import com.google.firebase.Timestamp

data class Product(
    val id: String = "",
    val name: String = "",
    val sku: String = "",
    val category: String = "Others",
    val model: String = "",
    val variant: String = "",
    val unit: String = "Pcs",
    val inStock: Boolean = true,
    val lowStock: Boolean = false,
    val active: Boolean = true,
    val createdAt: Timestamp? = null,
    val updatedAt: Timestamp? = null
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "name" to name,
        "sku" to sku,
        "category" to category,
        "model" to model,
        "variant" to variant,
        "unit" to unit,
        "inStock" to inStock,
        "lowStock" to lowStock,
        "active" to active,
        "createdAt" to (createdAt ?: Timestamp.now()),
        "updatedAt" to Timestamp.now()
    )

    companion object {
        fun fromMap(id: String, map: Map<String, Any?>): Product {
            return Product(
                id = id,
                name = map["name"] as? String ?: "",
                sku = map["sku"] as? String ?: "",
                category = map["category"] as? String ?: "Others",
                model = map["model"] as? String ?: "",
                variant = map["variant"] as? String ?: "",
                unit = map["unit"] as? String ?: "Pcs",
                inStock = map["inStock"] as? Boolean ?: true,
                lowStock = map["lowStock"] as? Boolean ?: false,
                active = map["active"] as? Boolean ?: true,
                createdAt = map["createdAt"] as? Timestamp,
                updatedAt = map["updatedAt"] as? Timestamp
            )
        }
    }
}
