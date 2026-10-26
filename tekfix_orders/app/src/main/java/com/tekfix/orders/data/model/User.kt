package com.tekfix.orders.data.model

import com.google.firebase.Timestamp

enum class UserRole {
    ADMIN,
    STAFF;

    companion object {
        fun fromString(value: String?): UserRole {
            return when (value?.uppercase()) {
                "ADMIN" -> ADMIN
                else -> STAFF
            }
        }
    }
}

data class User(
    val uid: String = "",
    val email: String = "",
    val name: String = "",
    val role: UserRole = UserRole.STAFF,
    val phone: String = "",
    val active: Boolean = true,
    val createdAt: Timestamp? = null,
    val lastLoginAt: Timestamp? = null
) {
    val isAdmin: Boolean get() = role == UserRole.ADMIN

    fun toMap(): Map<String, Any?> = mapOf(
        "uid" to uid,
        "email" to email,
        "name" to name,
        "role" to role.name.lowercase(),
        "phone" to phone,
        "active" to active,
        "createdAt" to (createdAt ?: Timestamp.now()),
        "lastLoginAt" to lastLoginAt
    )

    companion object {
        fun fromMap(id: String, map: Map<String, Any?>): User {
            return User(
                uid = id,
                email = map["email"] as? String ?: "",
                name = map["name"] as? String ?: "",
                role = UserRole.fromString(map["role"] as? String),
                phone = map["phone"] as? String ?: "",
                active = map["active"] as? Boolean ?: true,
                createdAt = map["createdAt"] as? Timestamp,
                lastLoginAt = map["lastLoginAt"] as? Timestamp
            )
        }
    }
}
