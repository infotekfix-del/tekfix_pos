package com.tekfix.orders

import com.tekfix.orders.data.model.Order
import com.tekfix.orders.data.model.OrderProduct
import com.tekfix.orders.service.WhatsAppMessageFormatter
import org.junit.Assert.assertTrue
import org.junit.Test

class WhatsAppMessageFormatterTest {

    @Test
    fun testFormatOrderMessage_matchesSection13Spec() {
        val order = Order(
            orderId = "TF-20261026-0001",
            staffName = "Staff Name",
            createdDate = "26-10-2026",
            createdTime = "10:30 AM",
            products = listOf(
                OrderProduct(name = "iPhone 15 Tempered Glass", quantity = 20, unit = "Pcs", model = "iPhone 15"),
                OrderProduct(name = "Type-C Cable", quantity = 10, unit = "Pcs", model = "Fast Charging"),
                OrderProduct(name = "Samsung A15 Back Cover", quantity = 15, unit = "Pcs", model = "Samsung A15"),
                OrderProduct(name = "Custom Product", quantity = 5, unit = "Pcs", model = "Custom Variant", remarks = "As requested", isCustom = true)
            ),
            totalTypes = 4,
            totalQuantity = 50,
            generalRemarks = "Urgent order"
        )

        val message = WhatsAppMessageFormatter.formatOrderMessage(order)

        // Validate Key Header Elements
        assertTrue("Header should contain company", message.contains("🏢 Company: Tekfix Digital"))
        assertTrue("Order ID must be formatted", message.contains("🆔 Order ID: TF-20261026-0001"))
        assertTrue("Date must be formatted", message.contains("📅 Date: 26-10-2026"))
        assertTrue("Time must be formatted", message.contains("🕒 Time: 10:30 AM"))
        assertTrue("Staff must be formatted", message.contains("👤 Ordered By: Staff Name"))

        // Validate Product details
        assertTrue("Item 1 present", message.contains("1. iPhone 15 Tempered Glass"))
        assertTrue("Item 1 quantity", message.contains("Quantity: 20 Pcs"))
        assertTrue("Item 1 model", message.contains("Model: iPhone 15"))

        assertTrue("Item 4 remarks", message.contains("Remarks: As requested"))

        // Validate Summary
        assertTrue("Total Types", message.contains("Total Product Types: 4"))
        assertTrue("Total Quantity", message.contains("Total Quantity: 50 Pcs"))
        assertTrue("General remarks", message.contains("Urgent order"))
        assertTrue("Footer present", message.contains("Submitted through Tekfix Orders App."))
    }
}
