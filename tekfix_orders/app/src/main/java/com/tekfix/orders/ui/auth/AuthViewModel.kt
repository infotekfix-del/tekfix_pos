package com.tekfix.orders.ui.auth

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.tekfix.orders.data.model.User
import com.tekfix.orders.data.repository.AuthRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class AuthUiState(
    val isLoading: Boolean = false,
    val currentUser: User? = null,
    val errorMessage: String? = null,
    val passwordResetSent: Boolean = false
)

class AuthViewModel(
    private val authRepository: AuthRepository = AuthRepository()
) : ViewModel() {

    private val _uiState = MutableStateFlow(AuthUiState())
    val uiState: StateFlow<AuthUiState> = _uiState.asStateFlow()

    fun checkAuthStatus(onResolved: (User?) -> Unit) {
        val firebaseUser = authRepository.currentUser
        if (firebaseUser == null) {
            _uiState.value = _uiState.value.copy(currentUser = null)
            onResolved(null)
            return
        }

        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true)
            val result = authRepository.getUserProfile(firebaseUser.uid)
            result.onSuccess { user ->
                if (!user.active) {
                    authRepository.logout()
                    _uiState.value = _uiState.value.copy(
                        isLoading = false,
                        currentUser = null,
                        errorMessage = "നിങ്ങളുടെ അക്കൗണ്ട് താൽക്കാലികമായി റദ്ദാക്കിയിരിക്കുന്നു (Account deactivated)."
                    )
                    onResolved(null)
                    return@launch
                }
                _uiState.value = _uiState.value.copy(isLoading = false, currentUser = user)
                onResolved(user)
            }.onFailure {
                _uiState.value = _uiState.value.copy(isLoading = false, currentUser = null)
                onResolved(null)
            }
        }
    }

    fun login(emailOrUsername: String, pass: String, onSuccess: (User) -> Unit) {
        if (emailOrUsername.isBlank() || pass.isBlank()) {
            _uiState.value = _uiState.value.copy(errorMessage = "യൂസർനെയിമും പാസ്‌വേർഡും നൽകുക (Please enter username and password)")
            return
        }

        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true, errorMessage = null)
            val result = authRepository.login(emailOrUsername, pass)
            result.onSuccess { user ->
                _uiState.value = _uiState.value.copy(isLoading = false, currentUser = user)
                onSuccess(user)
            }.onFailure { err ->
                _uiState.value = _uiState.value.copy(
                    isLoading = false,
                    errorMessage = err.localizedMessage ?: "ലോഗിൻ പരാജയപ്പെട്ടു (Login failed)"
                )
            }
        }
    }

    fun sendPasswordReset(email: String) {
        if (email.isBlank()) {
            _uiState.value = _uiState.value.copy(errorMessage = "ദയവായി ഇമെയിൽ നൽകുക (Please enter your email)")
            return
        }

        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true, errorMessage = null, passwordResetSent = false)
            val result = authRepository.sendPasswordReset(email)
            result.onSuccess {
                _uiState.value = _uiState.value.copy(isLoading = false, passwordResetSent = true)
            }.onFailure { err ->
                _uiState.value = _uiState.value.copy(
                    isLoading = false,
                    errorMessage = err.localizedMessage ?: "പാസ്‌വേർഡ് റീസെറ്റ് പരാജയപ്പെട്ടു"
                )
            }
        }
    }

    fun clearError() {
        _uiState.value = _uiState.value.copy(errorMessage = null, passwordResetSent = false)
    }

    fun logout(onLoggedOut: () -> Unit) {
        authRepository.logout()
        _uiState.value = AuthUiState()
        onLoggedOut()
    }
}
