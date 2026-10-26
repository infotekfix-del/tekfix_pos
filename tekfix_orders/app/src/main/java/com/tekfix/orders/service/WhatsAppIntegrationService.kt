package com.tekfix.orders.service

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.Toast
import com.tekfix.orders.data.model.Order
import com.tekfix.orders.data.model.WhatsAppConfig
import com.tekfix.orders.data.model.WhatsAppStatus
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL

data class DeliveryResult(
    val status: WhatsAppStatus,
    val messageId: String? = null,
    val errorMessage: String? = null
)

class WhatsAppIntegrationService(private val context: Context) {

    /**
     * Attempts automated delivery if a legitimate API endpoint is configured,
     * otherwise falls back cleanly to MANUAL_ACTION_REQUIRED.
     */
    suspend fun processOrderDelivery(
        order: Order,
        config: WhatsAppConfig
    ): DeliveryResult = withContext(Dispatchers.IO) {
        val formattedText = WhatsAppMessageFormatter.formatOrderMessage(order)

        // If direct supported API is configured
        if (config.isApiConfigured) {
            try {
                val url = URL(config.apiUrl)
                val connection = (url.openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"
                    setRequestProperty("Content-Type", "application/json")
                    setRequestProperty("Authorization", "Bearer ${config.apiToken}")
                    doOutput = true
                    connectTimeout = 8000
                    readTimeout = 8000
                }

                val jsonPayload = """
                    {
                        "recipient": "${config.phoneNumberId}",
                        "message": ${org.json.JSONObject.quote(formattedText)},
                        "orderId": "${order.orderId}"
                    }
                """.trimIndent()

                connection.outputStream.use { os ->
                    os.write(jsonPayload.toByteArray(Charsets.UTF_8))
                }

                val responseCode = connection.responseCode
                if (responseCode in 200..299) {
                    val responseBody = connection.inputStream.bufferedReader().use { it.readText() }
                    return@withContext DeliveryResult(
                        status = WhatsAppStatus.SENT_SUCCESSFULLY,
                        messageId = "API-$responseCode-${System.currentTimeMillis()}"
                    )
                } else {
                    return@withContext DeliveryResult(
                        status = WhatsAppStatus.DELIVERY_FAILED,
                        errorMessage = "HTTP $responseCode from messaging gateway"
                    )
                }
            } catch (e: Exception) {
                // Network failure or unconfigured gateway -> gracefully fall back
                return@withContext DeliveryResult(
                    status = WhatsAppStatus.MANUAL_ACTION_REQUIRED,
                    errorMessage = e.localizedMessage
                )
            }
        }

        // Default legitimate fallback: Cloud order is saved; manual group share requested
        return@withContext DeliveryResult(
            status = WhatsAppStatus.MANUAL_ACTION_REQUIRED
        )
    }

    /**
     * Copies the formatted order text to system clipboard.
     */
    fun copyOrderToClipboard(text: String) {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = ClipData.newPlainText("Tekfix Order", text)
        clipboard.setPrimaryClip(clip)
        Toast.makeText(context, "ഓർഡർ കോപ്പി ചെയ്തു (Order copied to clipboard)", Toast.LENGTH_SHORT).show()
    }

    /**
     * Opens the company's designated WhatsApp group via the official invitation link.
     */
    fun openGroupInvitation(invitationUrl: String) {
        try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(invitationUrl)).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                // Attempt to target WhatsApp directly if installed
                setPackage("com.whatsapp")
            }
            context.startActivity(intent)
        } catch (e: Exception) {
            // Fallback to standard browser chooser
            val browserIntent = Intent(Intent.ACTION_VIEW, Uri.parse(invitationUrl)).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            context.startActivity(browserIntent)
        }
    }

    /**
     * Opens Android system share sheet pre-filled with the order text, targeting WhatsApp.
     */
    fun shareOrderText(text: String) {
        val sendIntent = Intent().apply {
            action = Intent.ACTION_SEND
            putExtra(Intent.EXTRA_TEXT, text)
            type = "text/plain"
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        val shareIntent = Intent.createChooser(sendIntent, "Share Order to WhatsApp Group").apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        context.startActivity(shareIntent)
    }
}
