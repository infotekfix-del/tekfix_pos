package com.tekfix.orders

import com.tekfix.orders.data.model.Order
import com.tekfix.orders.data.model.OrderProduct
import org.junit.Assert.assertEquals
import org.junit.Test

class OrderCalculationTest {

    @Test
    fun testOrderProductSummaryCalculations() {
        val products = listOf(
            OrderProduct(name = "Tempered Glass", quantity = 10),
            OrderProduct(name = "Cover", quantity = 5),
            OrderProduct(name = "Cable", quantity = 15)
        )

        val totalTypes = products.size
        val totalQuantity = products.sumOf { it.quantity }

        assertEquals(3, totalTypes)
        assertEquals(30, totalQuantity)

        val order = Order(
            orderId = "TF-TEST",
            products = products,
            totalTypes = totalTypes,
            totalQuantity = totalQuantity
        )

        assertEquals(3, order.totalTypes)
        assertEquals(30, order.totalQuantity)
    }
}
