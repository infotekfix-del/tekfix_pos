package com.tekfix.orders.ui.admin

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Save
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.tekfix.orders.data.model.Order
import com.tekfix.orders.data.model.OrderProduct
import com.tekfix.orders.data.model.WhatsAppConfig
import com.tekfix.orders.service.WhatsAppIntegrationService
import com.tekfix.orders.service.WhatsAppMessageFormatter
import com.tekfix.orders.ui.components.TekfixTopAppBar
import com.tekfix.orders.ui.theme.TekfixDarkGreen
import com.tekfix.orders.ui.theme.TekfixGreen
import com.tekfix.orders.ui.theme.TekfixLightGreen
import com.tekfix.orders.ui.theme.WhatsAppDarkGreen

@Composable
fun WhatsAppSettingsScreen(
    adminViewModel: AdminViewModel,
    onNavigateBack: () -> Unit,
    isOffline: Boolean = false
) {
    val context = LocalContext.current
    val config by adminViewModel.whatsAppConfig.collectAsState()
    val uiState by adminViewModel.uiState.collectAsState()

    var groupUrl by remember(config.groupInvitationUrl) { mutableStateOf(config.groupInvitationUrl) }
    var apiUrl by remember(config.apiUrl) { mutableStateOf(config.apiUrl) }
    var apiToken by remember(config.apiToken) { mutableStateOf(config.apiToken) }
    var phoneId by remember(config.phoneNumberId) { mutableStateOf(config.phoneNumberId) }
    var manualFallback by remember(config.manualFallbackEnabled) { mutableStateOf(config.manualFallbackEnabled) }

    val service = remember { WhatsAppIntegrationService(context) }

    Scaffold(
        topBar = {
            TekfixTopAppBar(
                title = "വാട്സാപ്പ് സെറ്റിംഗ്സ് (WhatsApp Settings)",
                canNavigateBack = true,
                onNavigateBack = onNavigateBack,
                isOffline = isOffline
            )
        },
        containerColor = MaterialTheme.colorScheme.background
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            if (uiState.successMessage != null) {
                Surface(
                    color = TekfixLightGreen,
                    shape = RoundedCornerShape(10.dp),
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

            // Group Link Card
            Card(
                shape = RoundedCornerShape(16.dp),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.Groups, contentDescription = null, tint = WhatsAppDarkGreen)
                        Spacer(modifier = Modifier.width(8.dp))
                        Text(
                            text = "കമ്പനി വാട്സാപ്പ് ഗ്രൂപ്പ് ലിങ്ക് (Group Invitation Link)",
                            style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.Bold
                        )
                    }

                    Spacer(modifier = Modifier.height(10.dp))

                    Text(
                        text = "സ്റ്റാഫ് ഓർഡർ സമർപ്പിച്ച ശേഷം ഗ്രൂപ്പിലേക്ക് മെസ്സേജ് പങ്കിടാൻ ഈ ലിങ്ക് ഉപയോഗിക്കുന്നു.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )

                    Spacer(modifier = Modifier.height(12.dp))

                    OutlinedTextField(
                        value = groupUrl,
                        onValueChange = { groupUrl = it },
                        label = { Text("WhatsApp Group Invitation URL") },
                        singleLine = true,
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            }

            // Cloud API Gateway Card (Optional / Advanced)
            Card(
                shape = RoundedCornerShape(16.dp),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Text(
                        text = "⚡ ഓട്ടോമേറ്റഡ് API ഗേറ്റ്‌വേ (Automated Cloud API - Optional)",
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Bold,
                        color = TekfixDarkGreen
                    )

                    Spacer(modifier = Modifier.height(6.dp))

                    Text(
                        text = "നേരിട്ട് ക്ലൗഡ് വഴി മെസ്സേജ് അയക്കാൻ അംഗീകൃത WhatsApp Business API വെബ്‌ഹുക്ക് കോൺഫിഗർ ചെയ്യാം.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        lineHeight = 16.sp
                    )

                    Spacer(modifier = Modifier.height(12.dp))

                    OutlinedTextField(
                        value = apiUrl,
                        onValueChange = { apiUrl = it },
                        label = { Text("API Webhook URL (e.g. https://api.whatsapp.com/...)") },
                        singleLine = true,
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth()
                    )

                    Spacer(modifier = Modifier.height(10.dp))

                    OutlinedTextField(
                        value = apiToken,
                        onValueChange = { apiToken = it },
                        label = { Text("Bearer Access Token") },
                        singleLine = true,
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth()
                    )

                    Spacer(modifier = Modifier.height(10.dp))

                    OutlinedTextField(
                        value = phoneId,
                        onValueChange = { phoneId = it },
                        label = { Text("Phone Number ID / Group JID") },
                        singleLine = true,
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth()
                    )

                    Spacer(modifier = Modifier.height(12.dp))

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Checkbox(checked = manualFallback, onCheckedChange = { manualFallback = it })
                        Text(
                            text = "മാനുവൽ ഗ്രൂപ്പ് ഷെയർ ബാക്കപ്പ് അനുവദിക്കുക (Enable Manual Group Fallback)",
                            style = MaterialTheme.typography.bodySmall
                        )
                    }
                }
            }

            // Save Settings Button
            Button(
                onClick = {
                    adminViewModel.saveWhatsAppConfig(
                        WhatsAppConfig(
                            groupInvitationUrl = groupUrl.trim(),
                            apiUrl = apiUrl.trim(),
                            apiToken = apiToken.trim(),
                            phoneNumberId = phoneId.trim(),
                            manualFallbackEnabled = manualFallback
                        )
                    )
                },
                colors = ButtonDefaults.buttonColors(containerColor = TekfixGreen),
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .height(50.dp)
            ) {
                Icon(Icons.Default.Save, contentDescription = null)
                Spacer(modifier = Modifier.width(8.dp))
                Text("ക്രമീകരണങ്ങൾ സേവ് ചെയ്യുക (SAVE SETTINGS)", fontWeight = FontWeight.Bold)
            }

            // Test Sample Message Button
            OutlinedButton(
                onClick = {
                    val sampleOrder = Order(
                        orderId = "TF-20261026-TEST",
                        staffName = "Demo Staff",
                        createdDate = "26-10-2026",
                        createdTime = "10:30 AM",
                        products = listOf(
                            OrderProduct(name = "iPhone 15 Tempered Glass", quantity = 20, model = "iPhone 15"),
                            OrderProduct(name = "Type-C Cable", quantity = 10, model = "Fast Charging", remarks = "As requested")
                        ),
                        totalTypes = 2,
                        totalQuantity = 30,
                        generalRemarks = "Urgent test order"
                    )
                    val text = WhatsAppMessageFormatter.formatOrderMessage(sampleOrder)
                    service.copyOrderToClipboard(text)
                },
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                Text("സാമ്പിൾ ഓർഡർ മെസ്സേജ് ടെസ്റ്റ് ചെയ്യുക (Test Message Format)")
            }

            Spacer(modifier = Modifier.height(20.dp))
        }
    }
}
