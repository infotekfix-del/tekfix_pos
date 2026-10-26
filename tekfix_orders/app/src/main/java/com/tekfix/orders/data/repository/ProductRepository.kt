package com.tekfix.orders.data.repository

import com.google.firebase.Timestamp
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.Query
import com.tekfix.orders.data.model.Product
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.tasks.await

class ProductRepository(
    private val firestore: FirebaseFirestore = FirebaseFirestore.getInstance()
) {

    private val productsCollection = firestore.collection("products")

    /**
     * Real-time stream of active products available for staff selection.
     */
    fun getActiveProductsFlow(): Flow<List<Product>> = callbackFlow {
        val listener = productsCollection
            .whereEqualTo("active", true)
            .orderBy("name", Query.Direction.ASCENDING)
            .addSnapshotListener { snapshot, error ->
                if (error != null) {
                    close(error)
                    return@addSnapshotListener
                }
                val list = snapshot?.documents?.map { doc ->
                    Product.fromMap(doc.id, doc.data ?: emptyMap())
                } ?: emptyList()
                trySend(list)
            }
        awaitClose { listener.remove() }
    }

    /**
     * Real-time stream of all products for Admin management.
     */
    fun getAllProductsAdminFlow(): Flow<List<Product>> = callbackFlow {
        val listener = productsCollection
            .orderBy("name", Query.Direction.ASCENDING)
            .addSnapshotListener { snapshot, error ->
                if (error != null) {
                    close(error)
                    return@addSnapshotListener
                }
                val list = snapshot?.documents?.map { doc ->
                    Product.fromMap(doc.id, doc.data ?: emptyMap())
                } ?: emptyList()
                trySend(list)
            }
        awaitClose { listener.remove() }
    }

    suspend fun addProduct(product: Product): Result<String> {
        return try {
            val docRef = productsCollection.document()
            val newProduct = product.copy(
                id = docRef.id,
                createdAt = Timestamp.now(),
                updatedAt = Timestamp.now()
            )
            docRef.set(newProduct.toMap()).await()
            Result.success(docRef.id)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun updateProduct(product: Product): Result<Unit> {
        return try {
            productsCollection.document(product.id).update(
                mapOf(
                    "name" to product.name,
                    "sku" to product.sku,
                    "category" to product.category,
                    "model" to product.model,
                    "variant" to product.variant,
                    "unit" to product.unit,
                    "inStock" to product.inStock,
                    "lowStock" to product.lowStock,
                    "active" to product.active,
                    "updatedAt" to Timestamp.now()
                )
            ).await()
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun setProductActiveStatus(productId: String, active: Boolean): Result<Unit> {
        return try {
            productsCollection.document(productId).update(
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

    suspend fun deleteProduct(productId: String): Result<Unit> {
        return try {
            productsCollection.document(productId).delete().await()
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getExistingSkus(): Set<String> {
        return try {
            val snapshot = productsCollection.get().await()
            snapshot.documents.mapNotNull { it.getString("sku") }
                .filter { it.isNotBlank() }
                .toSet()
        } catch (e: Exception) {
            emptySet()
        }
    }

    suspend fun batchImportProducts(products: List<Product>): Result<Int> {
        return try {
            var count = 0
            val chunks = products.chunked(450) // Firestore batch limit is 500 ops
            for (chunk in chunks) {
                val batch = firestore.batch()
                for (product in chunk) {
                    val ref = productsCollection.document()
                    batch.set(ref, product.copy(id = ref.id).toMap())
                    count++
                }
                batch.commit().await()
            }
            Result.success(count)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}
