package com.tekfix.orders.ui.staff

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.tekfix.orders.data.local.OrderDraftManager
import com.tekfix.orders.data.model.*
import com.tekfix.orders.data.repository.OrderRepository
import com.tekfix.orders.data.repository.ProductRepository
import com.tekfix.orders.service.WhatsAppIntegrationService
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

data class NewOrderUiState(
    val orderId: String = "",
    val orderDate: String = "",
    val orderTime: String = "",
    val staffName: String = "",
    val staffId: String = "",
    val cartProducts: List<OrderProduct> = emptyList(),
    val generalRemarks: String = "",
    val isSubmitting: Boolean = false,
    val submitSuccessOrder: Order? = null,
    val errorMessage: String? = null,
    val hasDraft: Boolean = false
) {
    val totalTypes: Int get() = cartProducts.size
    val totalQuantity: Int get() = cartProducts.sumOf { it.quantity }
    val isValid: Boolean get() = cartProducts.isNotEmpty() && cartProducts.all { it.quantity > 0 && it.name.isNotBlank() }
}

class OrderViewModel(
    private val context: Context,
    private val orderRepository: OrderRepository = OrderRepository(),
    private val productRepository: ProductRepository = ProductRepository(),
    private val draftManager: OrderDraftManager = OrderDraftManager(context),
    private val whatsAppService: WhatsAppIntegrationService = WhatsAppIntegrationService(context)
) : ViewModel() {

    // Available Products from Catalog
    val productsFlow: StateFlow<List<Product>> = productRepository.getActiveProductsFlow()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    // Active Order Creation State
    private val _orderState = MutableStateFlow(NewOrderUiState())
    val orderState: StateFlow<NewOrderUiState> = _orderState.asStateFlow()

    // Staff Orders History Flow
    private val _staffOrders = MutableStateFlow<List<Order>>(emptyList())
    val staffOrders: StateFlow<List<Order>> = _staffOrders.asStateFlow()

    fun initNewOrder(staff: User) {
        viewModelScope.launch {
            val dateFormat = SimpleDateFormat("dd-MM-yyyy", Locale.getDefault())
            val timeFormat = SimpleDateFormat("hh:mm a", Locale.getDefault())
            val now = Date()

            // Check if draft exists
            val draft = draftManager.getDraft()
            if (draft != null) {
                _orderState.value = NewOrderUiState(
                    orderId = draft.first,
                    orderDate = dateFormat.format(now),
                    orderTime = timeFormat.format(now),
                    staffName = staff.name,
                    staffId = staff.uid,
                    cartProducts = draft.second,
                    generalRemarks = draft.third,
                    hasDraft = true
                )
            } else {
                val generatedId = orderRepository.generateOrderId()
                _orderState.value = NewOrderUiState(
                    orderId = generatedId,
                    orderDate = dateFormat.format(now),
                    orderTime = timeFormat.format(now),
                    staffName = staff.name,
                    staffId = staff.uid
                )
            }
        }
    }

    fun loadStaffOrders(staffId: String) {
        viewModelScope.launch {
            orderRepository.getStaffOrdersFlow(staffId).collect { list ->
                _staffOrders.value = list
            }
        }
    }

    fun addCatalogProduct(product: Product, quantity: Int = 1, remarks: String = "") {
        if (quantity <= 0) return

        val currentList = _orderState.value.cartProducts.toMutableList()
        val existingIndex = currentList.indexOfFirst { it.productId == product.id && it.model == product.model }

        if (existingIndex != -1) {
            val existing = currentList[existingIndex]
            currentList[existingIndex] = existing.copy(
                quantity = existing.quantity + quantity,
                remarks = if (remarks.isNotBlank()) remarks else existing.remarks
            )
        } else {
            currentList.add(
                OrderProduct(
                    productId = product.id,
                    name = product.name,
                    sku = product.sku,
                    category = product.category,
                    model = product.model,
                    variant = product.variant,
                    quantity = quantity,
                    unit = product.unit,
                    remarks = remarks,
                    isCustom = false
                )
            )
        }

        _orderState.value = _orderState.value.copy(cartProducts = currentList)
        persistDraft()
    }

    fun addCustomProduct(
        name: String,
        model: String,
        quantity: Int,
        unit: String,
        remarks: String
    ): Boolean {
        if (name.isBlank() || quantity <= 0) {
            _orderState.value = _orderState.value.copy(errorMessage = "പ്രൊഡക്റ്റ് പേരും അളവും കൃത്യമായി നൽകുക")
            return false
        }

        val currentList = _orderState.value.cartProducts.toMutableList()
        currentList.add(
            OrderProduct(
                name = name.trim(),
                model = model.trim(),
                quantity = quantity,
                unit = if (unit.isBlank()) "Pcs" else unit.trim(),
                remarks = remarks.trim(),
                isCustom = true
            )
        )

        _orderState.value = _orderState.value.copy(cartProducts = currentList, errorMessage = null)
        persistDraft()
        return true
    }

    fun updateProductQuantity(index: Int, newQuantity: Int) {
        if (index !in _orderState.value.cartProducts.indices) return
        val currentList = _orderState.value.cartProducts.toMutableList()

        if (newQuantity <= 0) {
            currentList.removeAt(index)
        } else {
            currentList[index] = currentList[index].copy(quantity = newQuantity)
        }

        _orderState.value = _orderState.value.copy(cartProducts = currentList)
        persistDraft()
    }

    fun updateProductRemarks(index: Int, newRemarks: String) {
        if (index !in _orderState.value.cartProducts.indices) return
        val currentList = _orderState.value.cartProducts.toMutableList()
        currentList[index] = currentList[index].copy(remarks = newRemarks)
        _orderState.value = _orderState.value.copy(cartProducts = currentList)
        persistDraft()
    }

    fun removeProduct(index: Int) {
        if (index !in _orderState.value.cartProducts.indices) return
        val currentList = _orderState.value.cartProducts.toMutableList()
        currentList.removeAt(index)
        _orderState.value = _orderState.value.copy(cartProducts = currentList)
        persistDraft()
    }

    fun setGeneralRemarks(remarks: String) {
        _orderState.value = _orderState.value.copy(generalRemarks = remarks)
        persistDraft()
    }

    private fun persistDraft() {
        val s = _orderState.value
        if (s.orderId.isNotBlank()) {
            draftManager.saveDraft(s.orderId, s.cartProducts, s.generalRemarks)
        }
    }

    fun clearDraftAndReset(staff: User) {
        draftManager.clearDraft()
        initNewOrder(staff)
    }

    /**
     * Submits order to Firestore atomically, then triggers WhatsApp delivery pipeline.
     */
    fun submitOrder(onSuccess: (Order) -> Unit) {
        val state = _orderState.value
        if (!state.isValid) {
            _orderState.value = state.copy(errorMessage = "കുറഞ്ഞത് ഒരു പ്രൊഡക്റ്റെങ്കിലും ഓർഡർ ചെയ്യുക (At least one valid product is required)")
            return
        }
        if (state.isSubmitting) return // Prevent duplicate taps

        viewModelScope.launch {
            _orderState.value = state.copy(isSubmitting = true, errorMessage = null)

            val order = Order(
                orderId = state.orderId,
                staffId = state.staffId,
                staffName = state.staffName,
                createdDate = state.orderDate,
                createdTime = state.orderTime,
                products = state.cartProducts,
                totalTypes = state.totalTypes,
                totalQuantity = state.totalQuantity,
                generalRemarks = state.generalRemarks,
                status = OrderStatus.SUBMITTED,
                whatsappDeliveryStatus = WhatsAppStatus.ORDER_SAVED
            )

            val createResult = orderRepository.createOrder(order)
            createResult.onSuccess { savedOrder ->
                // Clear local draft upon confirmed Firestore save
                draftManager.clearDraft()

                // Attempt automated WhatsApp delivery
                val config = orderRepository.getWhatsAppConfig()
                val deliveryResult = whatsAppService.processOrderDelivery(savedOrder, config)

                // Update final WhatsApp delivery status in Firestore
                orderRepository.updateWhatsAppStatus(
                    savedOrder.orderId,
                    deliveryResult.status,
                    deliveryResult.messageId
                )

                val updatedOrder = savedOrder.copy(
                    whatsappDeliveryStatus = deliveryResult.status,
                    whatsappMessageId = deliveryResult.messageId
                )

                _orderState.value = _orderState.value.copy(
                    isSubmitting = false,
                    submitSuccessOrder = updatedOrder
                )

                onSuccess(updatedOrder)
            }.onFailure { err ->
                _orderState.value = _orderState.value.copy(
                    isSubmitting = false,
                    errorMessage = "ഓർഡർ സമർപ്പിക്കൽ പരാജയപ്പെട്ടു: ${err.localizedMessage}"
                )
            }
        }
    }

    fun duplicateOrder(order: Order, staff: User) {
        viewModelScope.launch {
            val dateFormat = SimpleDateFormat("dd-MM-yyyy", Locale.getDefault())
            val timeFormat = SimpleDateFormat("hh:mm a", Locale.getDefault())
            val now = Date()
            val newId = orderRepository.generateOrderId()

            _orderState.value = NewOrderUiState(
                orderId = newId,
                orderDate = dateFormat.format(now),
                orderTime = timeFormat.format(now),
                staffName = staff.name,
                staffId = staff.uid,
                cartProducts = order.products.map { it.copy(id = java.util.UUID.randomUUID().toString()) },
                generalRemarks = order.generalRemarks
            )
            persistDraft()
        }
    }

    fun clearSubmissionState() {
        _orderState.value = _orderState.value.copy(submitSuccessOrder = null, errorMessage = null)
    }
}
