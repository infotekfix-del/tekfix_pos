package com.tekfix.orders.data.repository

import com.google.firebase.FirebaseApp
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.tekfix.orders.data.model.User
import com.tekfix.orders.data.model.UserRole
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.tasks.await

class StaffRepository(
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance()
) {

    private val usersCollection = firestore.collection("users")

    /**
     * Real-time stream of all staff accounts for Admin management.
     */
    fun getAllStaffFlow(): Flow<List<User>> = callbackFlow {
        val listener = usersCollection
            .whereEqualTo("role", "staff")
            .addSnapshotListener { snapshot, error ->
                if (error != null) {
                    close(error)
                    return@addSnapshotListener
                }
                val list = snapshot?.documents?.map { doc ->
                    User.fromMap(doc.id, doc.data ?: emptyMap())
                } ?: emptyList()
                trySend(list)
            }
        awaitClose { listener.remove() }
    }

    /**
     * Creates a staff member account. Uses a secondary FirebaseApp instance
     * to avoid logging out the current active Admin session.
     */
    suspend fun createStaffAccount(
        name: String,
        emailOrUsername: String,
        password: String,
        phone: String = ""
    ): Result<User> {
        return try {
            val email = if (emailOrUsername.contains("@")) {
                emailOrUsername.trim()
            } else {
                "${emailOrUsername.trim().lowercase()}@tekfix.com"
            }

            // Create secondary FirebaseApp so current Admin session stays intact
            val context = FirebaseApp.getInstance().applicationContext
            val secondaryAppName = "StaffCreationApp"
            val secondaryApp = FirebaseApp.getApps(context).firstOrNull { it.name == secondaryAppName }
                ?: FirebaseApp.initializeApp(context, FirebaseApp.getInstance().options, secondaryAppName)

            val secondaryAuth = FirebaseAuth.getInstance(secondaryApp)
            val authResult = secondaryAuth.createUserWithEmailAndPassword(email, password).await()
            val newUid = authResult.user?.uid ?: throw Exception("Failed to create user in Auth")

            val staffUser = User(
                uid = newUid,
                email = email,
                name = name.trim(),
                role = UserRole.STAFF,
                phone = phone.trim(),
                active = true,
                createdAt = Timestamp.now()
            )

            usersCollection.document(newUid).set(staffUser.toMap()).await()
            Result.success(staffUser)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun setStaffActiveStatus(uid: String, active: Boolean): Result<Unit> {
        return try {
            usersCollection.document(uid).update(
                mapOf(
                    "active" to active,
                    "updatedAt" to Timestamp.now()
                )
            ).await()
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun triggerPasswordReset(email: String): Result<Unit> {
        return try {
            FirebaseAuth.getInstance().sendPasswordResetEmail(email.trim()).await()
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}
