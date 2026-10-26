package com.tekfix.orders.service

import com.tekfix.orders.data.model.Order

object WhatsAppMessageFormatter {

    const val COMPANY_NAME = "Tekfix Digital"
    const val DIVIDER = "━━━━━━━━━━━━━━━━━━"

    /**
     * Formats an Order into the official, professional WhatsApp message text
     * specified in Section 13.
     */
    fun formatOrderMessage(order: Order): String {
        val sb = StringBuilder()

        sb.append("📦 NEW PRODUCT ORDER\n\n")
        sb.append("🏢 Company: $COMPANY_NAME\n\n")
        sb.append("$DIVIDER\n\n")

        sb.append("📋 ORDER INFORMATION\n\n")
        sb.append("🆔 Order ID: ${order.orderId}\n")
        sb.append("📅 Date: ${order.createdDate}\n")
        sb.append("🕒 Time: ${order.createdTime}\n")
        sb.append("👤 Ordered By: ${order.staffName}\n\n")
        sb.append("$DIVIDER\n\n")

        sb.append("🛒 PRODUCT DETAILS\n\n")
        order.products.forEachIndexed { index, product ->
            sb.append("${index + 1}. ${product.name}\n")
            sb.append("   Quantity: ${product.quantity} ${product.unit}\n")
            if (product.model.isNotBlank()) {
                sb.append("   Model: ${product.model}\n")
            } else if (product.variant.isNotBlank()) {
                sb.append("   Variant: ${product.variant}\n")
            }
            if (product.remarks.isNotBlank()) {
                sb.append("   Remarks: ${product.remarks}\n")
            }
            sb.append("\n")
        }

        sb.append("$DIVIDER\n\n")

        sb.append("📊 ORDER SUMMARY\n\n")
        sb.append("Total Product Types: ${order.totalTypes}\n")
        val unitLabel = if (order.products.isNotEmpty()) order.products.first().unit else "Pcs"
        sb.append("Total Quantity: ${order.totalQuantity} $unitLabel\n\n")

        if (order.generalRemarks.isNotBlank()) {
            sb.append("📝 General Remarks:\n")
            sb.append("${order.generalRemarks}\n\n")
            sb.append("$DIVIDER\n\n")
        }

        sb.append("Submitted through Tekfix Orders App.")

        return sb.toString()
    }
}
