package com.tekfix.orders.data.repository

import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseUser
import com.google.firebase.firestore.FirebaseFirestore
import com.tekfix.orders.data.model.User
import com.tekfix.orders.data.model.UserRole
import kotlinx.coroutines.tasks.await

class AuthRepository(
    private val auth: FirebaseAuth = FirebaseAuth.getInstance(),
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance()
) {

    val currentUser: FirebaseUser? get() = auth.currentUser

    suspend fun login(emailOrUsername: String, pass: String): Result<User> {
        return try {
            val email = if (emailOrUsername.contains("@")) {
                emailOrUsername.trim()
            } else {
                "${emailOrUsername.trim().lowercase()}@tekfix.com"
            }

            val authResult = auth.signInWithEmailAndPassword(email, pass).await()
            val firebaseUser = authResult.user ?: throw Exception("Authentication returned null user")

            val doc = firestore.collection("users").document(firebaseUser.uid).get().await()

            val user: User
            if (doc.exists()) {
                val data = doc.data ?: emptyMap()
                user = User.fromMap(doc.id, data)

                if (!user.active) {
                    auth.signOut()
                    return Result.failure(Exception("നിങ്ങളുടെ അക്കൗണ്ട് താൽക്കാലികമായി റദ്ദാക്കിയിരിക്കുന്നു. അഡ്മിനുമായി ബന്ധപ്പെടുക. (Account deactivated. Please contact administrator)."))
                }

                // Update last login timestamp
                firestore.collection("users").document(user.uid).update("lastLoginAt", Timestamp.now())
            } else {
                // If profile doc doesn't exist yet (e.g. initial setup)
                val isFirstUser = email.startsWith("admin") || email.contains("owner")
                user = User(
                    uid = firebaseUser.uid,
                    email = firebaseUser.email ?: email,
                    name = firebaseUser.displayName ?: email.substringBefore("@").replaceFirstChar { it.uppercase() },
                    role = if (isFirstUser) UserRole.ADMIN else UserRole.STAFF,
                    active = true,
                    createdAt = Timestamp.now(),
                    lastLoginAt = Timestamp.now()
                )
                firestore.collection("users").document(user.uid).set(user.toMap()).await()
            }

            Result.success(user)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getUserProfile(uid: String): Result<User> {
        return try {
            val doc = firestore.collection("users").document(uid).get().await()
            if (doc.exists()) {
                Result.success(User.fromMap(doc.id, doc.data ?: emptyMap()))
            } else {
                Result.failure(Exception("User profile not found"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun sendPasswordReset(email: String): Result<Unit> {
        return try {
            auth.sendPasswordResetEmail(email.trim()).await()
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    fun logout() {
        auth.signOut()
    }
}
