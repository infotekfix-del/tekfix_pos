package com.tekfix.orders.data.model

import com.google.firebase.Timestamp

data class WhatsAppConfig(
    val groupInvitationUrl: String = "https://chat.whatsapp.com/GD5fTnnLRk9I0mPXdJ80n0?s=cl&p=a&mlu=4&ilr=4",
    val apiUrl: String = "",
    val apiToken: String = "",
    val phoneNumberId: String = "",
    val manualFallbackEnabled: Boolean = true,
    val updatedAt: Timestamp? = null
) {
    val isApiConfigured: Boolean get() = apiUrl.isNotBlank() && apiToken.isNotBlank()

    fun toMap(): Map<String, Any?> = mapOf(
        "groupInvitationUrl" to groupInvitationUrl,
        "apiUrl" to apiUrl,
        "apiToken" to apiToken,
        "phoneNumberId" to phoneNumberId,
        "manualFallbackEnabled" to manualFallbackEnabled,
        "updatedAt" to Timestamp.now()
    )

    companion object {
        fun fromMap(map: Map<String, Any?>): WhatsAppConfig {
            return WhatsAppConfig(
                groupInvitationUrl = map["groupInvitationUrl"] as? String
                    ?: "https://chat.whatsapp.com/GD5fTnnLRk9I0mPXdJ80n0?s=cl&p=a&mlu=4&ilr=4",
                apiUrl = map["apiUrl"] as? String ?: "",
                apiToken = map["apiToken"] as? String ?: "",
                phoneNumberId = map["phoneNumberId"] as? String ?: "",
                manualFallbackEnabled = map["manualFallbackEnabled"] as? Boolean ?: true,
                updatedAt = map["updatedAt"] as? Timestamp
            )
        }
    }
}
