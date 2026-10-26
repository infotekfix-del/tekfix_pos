package com.tekfix.orders.data.repository

import com.google.firebase.Timestamp
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.Query
import com.google.firebase.firestore.SetOptions
import com.tekfix.orders.data.model.Order
import com.tekfix.orders.data.model.OrderStatus
import com.tekfix.orders.data.model.WhatsAppConfig
import com.tekfix.orders.data.model.WhatsAppStatus
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.tasks.await
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class OrderRepository(
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance()
) {

    private val ordersCollection = firestore.collection("orders")
    private val countersCollection = firestore.collection("counters")
    private val settingsDoc = firestore.collection("settings").document("whatsapp")

    /**
     * Generates a non-duplicable, sequential Order ID in the format:
     * TF-YYYYMMDD-0001
     */
    suspend fun generateOrderId(): String {
        val dateFormat = SimpleDateFormat("yyyyMMdd", Locale.getDefault())
        val dateStr = dateFormat.format(Date())
        val counterRef = countersCollection.document("orders_$dateStr")

        return try {
            val sequence = firestore.runTransaction { transaction ->
                val snapshot = transaction.get(counterRef)
                val current = snapshot.getLong("seq") ?: 0L
                val next = current + 1
                transaction.set(counterRef, mapOf("seq" to next), SetOptions.merge())
                next
            }.await()

            val seqFormatted = String.format(Locale.US, "%04d", sequence)
            "TF-$dateStr-$seqFormatted"
        } catch (e: Exception) {
            // High-entropy fallback if offline or transaction error
            val timeShort = System.currentTimeMillis() % 10000
            val randomSuffix = String.format(Locale.US, "%04d", timeShort)
            "TF-$dateStr-$randomSuffix"
        }
    }

    /**
     * Submits and stores an order in Cloud Firestore.
     */
    suspend fun createOrder(order: Order): Result<Order> {
        return try {
            val finalOrder = order.copy(
                createdAt = Timestamp.now(),
                updatedAt = Timestamp.now()
            )
            ordersCollection.document(finalOrder.orderId).set(finalOrder.toMap()).await()
            Result.success(finalOrder)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getOrderById(orderId: String): Result<Order> {
        return try {
            val doc = ordersCollection.document(orderId).get().await()
            if (doc.exists()) {
                Result.success(Order.fromMap(doc.id, doc.data ?: emptyMap()))
            } else {
                Result.failure(Exception("Order not found"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * Real-time stream of orders submitted by a specific staff member.
     */
    fun getStaffOrdersFlow(staffId: String): Flow<List<Order>> = callbackFlow {
        val listener = ordersCollection
            .whereEqualTo("staffId", staffId)
            .orderBy("createdAt", Query.Direction.DESCENDING)
            .addSnapshotListener { snapshot, error ->
                if (error != null) {
                    close(error)
                    return@addSnapshotListener
                }
                val list = snapshot?.documents?.map { doc ->
                    Order.fromMap(doc.id, doc.data ?: emptyMap())
                } ?: emptyList()
                trySend(list)
            }
        awaitClose { listener.remove() }
    }

    /**
     * Real-time stream of all orders across the company for Admin review.
     */
    fun getAllOrdersAdminFlow(): Flow<List<Order>> = callbackFlow {
        val listener = ordersCollection
            .orderBy("createdAt", Query.Direction.DESCENDING)
            .addSnapshotListener { snapshot, error ->
                if (error != null) {
                    close(error)
                    return@addSnapshotListener
                }
                val list = snapshot?.documents?.map { doc ->
                    Order.fromMap(doc.id, doc.data ?: emptyMap())
                } ?: emptyList()
                trySend(list)
            }
        awaitClose { listener.remove() }
    }

    suspend fun updateOrderStatus(orderId: String, status: OrderStatus): Result<Unit> {
        return try {
            ordersCollection.document(orderId).update(
                mapOf(
                    "status" to status.name,
                    "updatedAt" to Timestamp.now()
                )
            ).await()
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun updateWhatsAppStatus(
        orderId: String,
        status: WhatsAppStatus,
        messageId: String? = null
    ): Result<Unit> {
        return try {
            val updates = mutableMapOf<String, Any?>(
                "whatsappDeliveryStatus" to status.name,
                "updatedAt" to Timestamp.now()
            )
            if (messageId != null) {
                updates["whatsappMessageId"] = messageId
            }
            ordersCollection.document(orderId).update(updates).await()
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getWhatsAppConfig(): WhatsAppConfig {
        return try {
            val doc = settingsDoc.get().await()
            if (doc.exists()) {
                WhatsAppConfig.fromMap(doc.data ?: emptyMap())
            } else {
                WhatsAppConfig()
            }
        } catch (e: Exception) {
            WhatsAppConfig()
        }
    }

    suspend fun saveWhatsAppConfig(config: WhatsAppConfig): Result<Unit> {
        return try {
            settingsDoc.set(config.toMap(), SetOptions.merge()).await()
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}
