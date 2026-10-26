package com.tekfix.orders.ui.admin

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.tekfix.orders.data.model.User
import com.tekfix.orders.ui.components.EmptyStateView
import com.tekfix.orders.ui.components.TekfixTopAppBar
import com.tekfix.orders.ui.theme.TekfixDarkGreen
import com.tekfix.orders.ui.theme.TekfixGreen
import com.tekfix.orders.ui.theme.TekfixLightGreen
import com.tekfix.orders.ui.theme.TextSecondary

@Composable
fun StaffManagementScreen(
    adminViewModel: AdminViewModel,
    onNavigateBack: () -> Unit,
    isOffline: Boolean = false
) {
    val staffList by adminViewModel.staffFlow.collectAsState()
    val uiState by adminViewModel.uiState.collectAsState()

    var showAddStaffDialog by remember { mutableStateOf(false) }

    if (showAddStaffDialog) {
        AddStaffDialog(
            onDismiss = { showAddStaffDialog = false },
            onAdd = { name, email, pass, phone ->
                adminViewModel.createStaff(name, email, pass, phone) {
                    showAddStaffDialog = false
                }
            }
        )
    }

    Scaffold(
        topBar = {
            TekfixTopAppBar(
                title = "സ്റ്റാഫ് മാനേജ്മെന്റ് (Staff)",
                subtitle = "${staffList.size} Staff Members",
                canNavigateBack = true,
                onNavigateBack = onNavigateBack,
                isOffline = isOffline
            )
        },
        floatingActionButton = {
            FloatingActionButton(
                onClick = { showAddStaffDialog = true },
                containerColor = TekfixGreen,
                contentColor = Color.White
            ) {
                Icon(Icons.Default.PersonAdd, contentDescription = "Add Staff")
            }
        },
        containerColor = MaterialTheme.colorScheme.background
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
        ) {
            if (uiState.successMessage != null) {
                Surface(
                    color = TekfixLightGreen,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier.padding(12.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(Icons.Default.Check, contentDescription = null, tint = TekfixDarkGreen)
                        Spacer(modifier = Modifier.width(8.dp))
                        Text(
                            text = uiState.successMessage ?: "",
                            color = TekfixDarkGreen,
                            style = MaterialTheme.typography.bodySmall,
                            modifier = Modifier.weight(1f)
                        )
                        IconButton(onClick = { adminViewModel.clearMessages() }, modifier = Modifier.size(24.dp)) {
                            Icon(Icons.Default.Close, contentDescription = "Dismiss", modifier = Modifier.size(16.dp))
                        }
                    }
                }
            }

            if (uiState.errorMessage != null) {
                Surface(
                    color = MaterialTheme.colorScheme.errorContainer,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(
                        text = uiState.errorMessage ?: "",
                        color = MaterialTheme.colorScheme.onErrorContainer,
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.padding(12.dp)
                    )
                }
            }

            if (staffList.isEmpty()) {
                EmptyStateView(
                    icon = Icons.Default.PeopleOutline,
                    title = "സ്റ്റാഫ് അക്കൗണ്ടുകൾ ഇല്ല",
                    subtitle = "പുതിയ സ്റ്റാഫ് അക്കൗണ്ട് ചേർക്കാൻ താഴെയുള്ള ബട്ടൺ ക്ലിക്ക് ചെയ്യുക.",
                    actionButtonText = "+ സ്റ്റാഫിനെ ചേർക്കുക",
                    onActionClick = { showAddStaffDialog = true }
                )
            } else {
                LazyColumn(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(horizontal = 16.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                    contentPadding = PaddingValues(top = 12.dp, bottom = 80.dp)
                ) {
                    items(staffList, key = { it.uid }) { staff ->
                        Card(
                            shape = RoundedCornerShape(16.dp),
                            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                            elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(16.dp),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = staff.name,
                                        style = MaterialTheme.typography.titleMedium,
                                        fontWeight = FontWeight.Bold
                                    )
                                    Text(
                                        text = staff.email,
                                        style = MaterialTheme.typography.bodySmall,
                                        color = TextSecondary
                                    )
                                    if (staff.phone.isNotBlank()) {
                                        Text(
                                            text = "Phone: ${staff.phone}",
                                            style = MaterialTheme.typography.bodySmall,
                                            color = TextSecondary
                                        )
                                    }
                                }

                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    IconButton(onClick = { adminViewModel.sendStaffPasswordReset(staff.email) }) {
                                        Icon(
                                            imageVector = Icons.Default.LockReset,
                                            contentDescription = "Reset Password",
                                            tint = TekfixGreen
                                        )
                                    }

                                    Switch(
                                        checked = staff.active,
                                        onCheckedChange = { active ->
                                            adminViewModel.toggleStaffActive(staff.uid, active)
                                        },
                                        colors = SwitchDefaults.colors(
                                            checkedThumbColor = Color.White,
                                            checkedTrackColor = TekfixGreen
                                        )
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun AddStaffDialog(
    onDismiss: () -> Unit,
    onAdd: (name: String, email: String, pass: String, phone: String) -> Unit
) {
    var name by remember { mutableStateOf("") }
    var emailOrUser by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var phone by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("പുതിയ സ്റ്റാഫിനെ ചേർക്കുക (Add Staff)", fontWeight = FontWeight.Bold) },
        text = {
            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                if (error != null) {
                    Text(error ?: "", color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                }

                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("പേര് (Full Name) *") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )

                OutlinedTextField(
                    value = emailOrUser,
                    onValueChange = { emailOrUser = it },
                    label = { Text("യൂസർനെയിം / ഇമെയിൽ (Username or Email) *") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )

                OutlinedTextField(
                    value = password,
                    onValueChange = { password = it },
                    label = { Text("പാസ്‌വേർഡ് (Password) *") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )

                OutlinedTextField(
                    value = phone,
                    onValueChange = { phone = it },
                    label = { Text("ഫോൺ നമ്പർ (Phone)") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
            }
        },
        confirmButton = {
            Button(
                onClick = {
                    if (name.isBlank() || emailOrUser.isBlank() || password.isBlank()) {
                        error = "എല്ലാ നിർബന്ധിത വിവരങ്ങളും നൽകുക (Please fill all required fields)"
                    } else if (password.length < 6) {
                        error = "പാസ്‌വേർഡിന് കുറഞ്ഞത് 6 അക്ഷരങ്ങൾ വേണം (Password must be >= 6 characters)"
                    } else {
                        onAdd(name, emailOrUser, password, phone)
                    }
                },
                colors = ButtonDefaults.buttonColors(containerColor = TekfixGreen)
            ) {
                Text("അക്കൗണ്ട് സൃഷ്ടിക്കുക (Create)")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("റദ്ദാക്കുക (Cancel)")
            }
        }
    )
}
