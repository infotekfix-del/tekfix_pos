package com.tekfix.orders.util

import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import com.tekfix.orders.data.model.Order
import com.tekfix.orders.data.model.Product
import java.io.File
import java.io.FileOutputStream

object CsvExporter {

    /**
     * Converts a list of orders into a detailed CSV string.
     */
    fun exportOrdersToCsv(orders: List<Order>): String {
        val sb = StringBuilder()
        sb.append("Order ID,Date,Time,Staff Name,Total Types,Total Quantity,Status,WhatsApp Status,Products Summary,General Remarks\n")

        for (order in orders) {
            val productsSummary = order.products.joinToString(" | ") {
                "${it.name} (${it.quantity} ${it.unit})"
            }.replace("\"", "\"\"")

            val remarks = order.generalRemarks.replace("\"", "\"\"")

            sb.append("\"${order.orderId}\",")
            sb.append("\"${order.createdDate}\",")
            sb.append("\"${order.createdTime}\",")
            sb.append("\"${order.staffName}\",")
            sb.append("${order.totalTypes},")
            sb.append("${order.totalQuantity},")
            sb.append("\"${order.status.displayName}\",")
            sb.append("\"${order.whatsappDeliveryStatus.displayName}\",")
            sb.append("\"$productsSummary\",")
            sb.append("\"$remarks\"\n")
        }

        return sb.toString()
    }

    /**
     * Converts product list into standard CSV format for export.
     */
    fun exportProductsToCsv(products: List<Product>): String {
        val sb = StringBuilder()
        sb.append("Name,SKU,Category,Model,Variant,Unit,InStock,Active\n")

        for (p in products) {
            sb.append("\"${p.name.replace("\"", "\"\"")}\",")
            sb.append("\"${p.sku.replace("\"", "\"\"")}\",")
            sb.append("\"${p.category.replace("\"", "\"\"")}\",")
            sb.append("\"${p.model.replace("\"", "\"\"")}\",")
            sb.append("\"${p.variant.replace("\"", "\"\"")}\",")
            sb.append("\"${p.unit.replace("\"", "\"\"")}\",")
            sb.append("${p.inStock},")
            sb.append("${p.active}\n")
        }

        return sb.toString()
    }

    /**
     * Writes CSV string to cache and shares via Android Intent.
     */
    fun shareCsvFile(context: Context, filename: String, csvContent: String) {
        val file = File(context.cacheDir, filename)
        FileOutputStream(file).use { it.write(csvContent.toByteArray(Charsets.UTF_8)) }

        val uri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            file
        )

        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/csv"
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_SUBJECT, filename)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }

        context.startActivity(Intent.createChooser(intent, "Share CSV Report").apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        })
    }
}
