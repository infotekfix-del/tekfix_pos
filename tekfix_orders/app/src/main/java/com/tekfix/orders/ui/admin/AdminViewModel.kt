package com.tekfix.orders.ui.admin

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.tekfix.orders.data.model.*
import com.tekfix.orders.data.repository.OrderRepository
import com.tekfix.orders.data.repository.ProductRepository
import com.tekfix.orders.data.repository.StaffRepository
import com.tekfix.orders.util.CsvImportResult
import com.tekfix.orders.util.CsvProductImporter
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch

data class AdminUiState(
    val isLoading: Boolean = false,
    val successMessage: String? = null,
    val errorMessage: String? = null,
    val importResult: CsvImportResult? = null
)

class AdminViewModel(
    private val productRepository: ProductRepository = ProductRepository(),
    private val orderRepository: OrderRepository = OrderRepository(),
    private val staffRepository: StaffRepository = StaffRepository()
) : ViewModel() {

    private val _uiState = MutableStateFlow(AdminUiState())
    val uiState: StateFlow<AdminUiState> = _uiState.asStateFlow()

    // Real-time Streams
    val productsFlow: StateFlow<List<Product>> = productRepository.getAllProductsAdminFlow()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val ordersFlow: StateFlow<List<Order>> = orderRepository.getAllOrdersAdminFlow()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val staffFlow: StateFlow<List<User>> = staffRepository.getAllStaffFlow()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    private val _whatsAppConfig = MutableStateFlow(WhatsAppConfig())
    val whatsAppConfig: StateFlow<WhatsAppConfig> = _whatsAppConfig.asStateFlow()

    init {
        loadWhatsAppConfig()
    }

    fun loadWhatsAppConfig() {
        viewModelScope.launch {
            _whatsAppConfig.value = orderRepository.getWhatsAppConfig()
        }
    }

    fun saveWhatsAppConfig(config: WhatsAppConfig) {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true, errorMessage = null)
            val res = orderRepository.saveWhatsAppConfig(config)
            res.onSuccess {
                _whatsAppConfig.value = config
                _uiState.value = _uiState.value.copy(
                    isLoading = false,
                    successMessage = "വാട്സാപ്പ് ക്രമീകരണങ്ങൾ സേവ് ചെയ്തു (Settings saved)"
                )
            }.onFailure { err ->
                _uiState.value = _uiState.value.copy(
                    isLoading = false,
                    errorMessage = err.localizedMessage
                )
            }
        }
    }

    // --- Product Management ---
    fun addProduct(product: Product, onComplete: () -> Unit) {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true, errorMessage = null)
            val res = productRepository.addProduct(product)
            res.onSuccess {
                _uiState.value = _uiState.value.copy(
                    isLoading = false,
                    successMessage = "പ്രൊഡക്റ്റ് വിജയകരമായി ചേർത്തു (Product added)"
                )
                onComplete()
            }.onFailure { err ->
                _uiState.value = _uiState.value.copy(isLoading = false, errorMessage = err.localizedMessage)
            }
        }
    }

    fun updateProduct(product: Product, onComplete: () -> Unit) {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true, errorMessage = null)
            val res = productRepository.updateProduct(product)
            res.onSuccess {
                _uiState.value = _uiState.value.copy(
                    isLoading = false,
                    successMessage = "പ്രൊഡക്റ്റ് അപ്ഡേറ്റ് ചെയ്തു (Product updated)"
                )
                onComplete()
            }.onFailure { err ->
                _uiState.value = _uiState.value.copy(isLoading = false, errorMessage = err.localizedMessage)
            }
        }
    }

    fun toggleProductActive(productId: String, active: Boolean) {
        viewModelScope.launch {
            productRepository.setProductActiveStatus(productId, active)
        }
    }

    fun deleteProduct(productId: String) {
        viewModelScope.launch {
            productRepository.deleteProduct(productId)
        }
    }

    fun importProductsCsv(csvText: String, onParsed: (CsvImportResult) -> Unit) {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true, errorMessage = null)
            val existingSkus = productRepository.getExistingSkus()
            val parsedResult = CsvProductImporter.parseCsv(csvText, existingSkus)

            _uiState.value = _uiState.value.copy(
                isLoading = false,
                importResult = parsedResult
            )
            onParsed(parsedResult)
        }
    }

    fun commitBatchImport(products: List<Product>, onComplete: () -> Unit) {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true, errorMessage = null)
            val res = productRepository.batchImportProducts(products)
            res.onSuccess { count ->
                _uiState.value = _uiState.value.copy(
                    isLoading = false,
                    successMessage = "$count പ്രൊഡക്റ്റുകൾ ഇമ്പോർട്ട് ചെയ്തു (Imported successfully)",
                    importResult = null
                )
                onComplete()
            }.onFailure { err ->
                _uiState.value = _uiState.value.copy(isLoading = false, errorMessage = err.localizedMessage)
            }
        }
    }

    // --- Staff Management ---
    fun createStaff(
        name: String,
        emailOrUsername: String,
        pass: String,
        phone: String,
        onComplete: () -> Unit
    ) {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true, errorMessage = null)
            val res = staffRepository.createStaffAccount(name, emailOrUsername, pass, phone)
            res.onSuccess {
                _uiState.value = _uiState.value.copy(
                    isLoading = false,
                    successMessage = "സ്റ്റാഫ് അക്കൗണ്ട് വിജയകരമായി സൃഷ്ടിച്ചു (Staff account created)"
                )
                onComplete()
            }.onFailure { err ->
                _uiState.value = _uiState.value.copy(isLoading = false, errorMessage = err.localizedMessage)
            }
        }
    }

    fun toggleStaffActive(uid: String, active: Boolean) {
        viewModelScope.launch {
            staffRepository.setStaffActiveStatus(uid, active)
        }
    }

    fun sendStaffPasswordReset(email: String) {
        viewModelScope.launch {
            val res = staffRepository.triggerPasswordReset(email)
            res.onSuccess {
                _uiState.value = _uiState.value.copy(
                    successMessage = "പാസ്‌വേർഡ് റീസെറ്റ് ഇമെയിൽ അയച്ചു (Reset link sent to $email)"
                )
            }.onFailure { err ->
                _uiState.value = _uiState.value.copy(errorMessage = err.localizedMessage)
            }
        }
    }

    // --- Order Status Management ---
    fun updateOrderStatus(orderId: String, newStatus: OrderStatus) {
        viewModelScope.launch {
            orderRepository.updateOrderStatus(orderId, newStatus)
        }
    }

    fun clearMessages() {
        _uiState.value = _uiState.value.copy(successMessage = null, errorMessage = null)
    }
}
