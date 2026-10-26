package com.tekfix.orders.data.local

import android.content.Context
import android.content.SharedPreferences
import com.tekfix.orders.data.model.OrderProduct
import org.json.JSONArray
import org.json.JSONObject

/**
 * Manages persisting active order drafts locally on the device to prevent
 * accidental data loss during network interruptions or phone restarts.
 */
class OrderDraftManager(context: Context) {

    private val prefs: SharedPreferences =
        context.getSharedPreferences("tekfix_order_drafts", Context.MODE_PRIVATE)

    fun saveDraft(
        orderId: String,
        products: List<OrderProduct>,
        generalRemarks: String
    ) {
        val jsonArray = JSONArray()
        products.forEach { p ->
            val obj = JSONObject().apply {
                put("id", p.id)
                put("productId", p.productId)
                put("name", p.name)
                put("sku", p.sku)
                put("category", p.category)
                put("model", p.model)
                put("variant", p.variant)
                put("quantity", p.quantity)
                put("unit", p.unit)
                put("remarks", p.remarks)
                put("isCustom", p.isCustom)
            }
            jsonArray.put(obj)
        }

        prefs.edit()
            .putString("draft_order_id", orderId)
            .putString("draft_products", jsonArray.toString())
            .putString("draft_remarks", generalRemarks)
            .apply()
    }

    fun getDraft(): Triple<String, List<OrderProduct>, String>? {
        val orderId = prefs.getString("draft_order_id", null) ?: return null
        val productsJson = prefs.getString("draft_products", null) ?: "[]"
        val remarks = prefs.getString("draft_remarks", "") ?: ""

        val list = mutableListOf<OrderProduct>()
        try {
            val jsonArray = JSONArray(productsJson)
            for (i in 0 until jsonArray.length()) {
                val obj = jsonArray.getJSONObject(i)
                list.add(
                    OrderProduct(
                        id = obj.optString("id"),
                        productId = obj.optString("productId"),
                        name = obj.optString("name"),
                        sku = obj.optString("sku"),
                        category = obj.optString("category", "Others"),
                        model = obj.optString("model"),
                        variant = obj.optString("variant"),
                        quantity = obj.optInt("quantity", 1),
                        unit = obj.optString("unit", "Pcs"),
                        remarks = obj.optString("remarks"),
                        isCustom = obj.optBoolean("isCustom", false)
                    )
                )
            }
        } catch (e: Exception) {
            return null
        }

        if (list.isEmpty() && remarks.isBlank()) return null
        return Triple(orderId, list, remarks)
    }

    fun clearDraft() {
        prefs.edit().clear().apply()
    }
}
