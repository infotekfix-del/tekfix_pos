package com.tekfix.orders.ui.staff

import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
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
import com.tekfix.orders.ui.components.TekfixTopAppBar
import com.tekfix.orders.ui.components.WhatsAppActionDialog
import com.tekfix.orders.ui.theme.CardBorder
import com.tekfix.orders.ui.theme.TekfixDarkGreen
import com.tekfix.orders.ui.theme.TekfixGreen
import com.tekfix.orders.ui.theme.TextSecondary

@Composable
fun OrderPreviewScreen(
    orderViewModel: OrderViewModel,
    onNavigateBack: () -> Unit,
    onNavigateToDashboard: () -> Unit,
    isOffline: Boolean = false
) {
    val context = LocalContext.current
    val orderState by orderViewModel.orderState.collectAsState()

    var showConfirmDialog by remember { mutableStateOf(false) }
    var submittedOrderForWhatsApp by remember { mutableStateOf<Order?>(null) }

    if (showConfirmDialog) {
        AlertDialog(
            onDismissRequest = { showConfirmDialog = false },
            title = {
                Text(
                    text = "ഓർഡർ സ്ഥിരീകരിക്കുക (Confirm Order)",
                    fontWeight = FontWeight.Bold
                )
            },
            text = {
                Text(
                    text = "ഈ ഓർഡർ സബ്മിറ്റ് ചെയ്യണമെന്ന് ഉറപ്പാണോ?\n(Are you sure you want to submit this order?)",
                    style = MaterialTheme.typography.bodyMedium
                )
            },
            confirmButton = {
                Button(
                    onClick = {
                        showConfirmDialog = false
                        orderViewModel.submitOrder { completedOrder ->
                            submittedOrderForWhatsApp = completedOrder
                        }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = TekfixGreen)
                ) {
                    Text("സ്ഥിരീകരിക്കുക (CONFIRM ORDER)", fontWeight = FontWeight.Bold)
                }
            },
            dismissButton = {
                TextButton(onClick = { showConfirmDialog = false }) {
                    Text("റദ്ദാക്കുക (CANCEL)")
                }
            }
        )
    }

    // Modal WhatsApp Action Dialog after successful submission
    if (submittedOrderForWhatsApp != null) {
        WhatsAppActionDialog(
            order = submittedOrderForWhatsApp!!,
            onDismiss = {
                submittedOrderForWhatsApp = null
                orderViewModel.clearSubmissionState()
                onNavigateToDashboard()
            }
        )
    }

    Scaffold(
        topBar = {
            TekfixTopAppBar(
                title = "ഓർഡർ പ്രിവ്യൂ (Order Preview)",
                subtitle = orderState.orderId,
                canNavigateBack = true,
                onNavigateBack = onNavigateBack,
                isOffline = isOffline
            )
        },
        bottomBar = {
            Surface(
                color = MaterialTheme.colorScheme.surface,
                shadowElevation = 8.dp,
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(16.dp)
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        OutlinedButton(
                            onClick = onNavigateBack,
                            shape = RoundedCornerShape(12.dp),
                            modifier = Modifier
                                .weight(1f)
                                .height(50.dp)
                        ) {
                            Icon(Icons.Default.Edit, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(modifier = Modifier.width(6.dp))
                            Text("തിരുത്തുക (Edit)")
                        }

                        Button(
                            onClick = {
                                Toast.makeText(context, "ഡ്രാഫ്റ്റ് സേവ് ചെയ്തു (Draft saved)", Toast.LENGTH_SHORT).show()
                                onNavigateToDashboard()
                            },
                            shape = RoundedCornerShape(12.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
                            modifier = Modifier
                                .weight(1f)
                                .height(50.dp)
                        ) {
                            Icon(Icons.Default.Save, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(16.dp))
                            Spacer(modifier = Modifier.width(6.dp))
                            Text("ഡ്രാഫ്റ്റ് (Draft)", color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }

                    Spacer(modifier = Modifier.height(10.dp))

                    Button(
                        onClick = { showConfirmDialog = true },
                        enabled = orderState.isValid && !orderState.isSubmitting,
                        shape = RoundedCornerShape(12.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = TekfixGreen),
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(52.dp)
                    ) {
                        if (orderState.isSubmitting) {
                            CircularProgressIndicator(color = Color.White, modifier = Modifier.size(22.dp), strokeWidth = 2.dp)
                            Spacer(modifier = Modifier.width(10.dp))
                            Text("സമർപ്പിക്കുന്നു (Submitting...)", fontWeight = FontWeight.Bold)
                        } else {
                            Icon(Icons.Default.Send, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(modifier = Modifier.width(8.dp))
                            Text("ഓർഡർ സമർപ്പിക്കുക (SUBMIT ORDER)", fontWeight = FontWeight.Bold, fontSize = 16.sp)
                        }
                    }
                }
            }
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
            // Error banner if any
            if (orderState.errorMessage != null) {
                Surface(
                    color = MaterialTheme.colorScheme.errorContainer,
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(
                        text = orderState.errorMessage ?: "",
                        color = MaterialTheme.colorScheme.onErrorContainer,
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.padding(12.dp)
                    )
                }
            }

            // Order Header Information Card
            Card(
                shape = RoundedCornerShape(16.dp),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            text = "📋 ORDER INFORMATION",
                            style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.Bold,
                            color = TekfixDarkGreen
                        )
                        Surface(
                            color = TekfixGreen.copy(alpha = 0.12f),
                            shape = RoundedCornerShape(8.dp)
                        ) {
                            Text(
                                text = "TEKFIX DIGITAL",
                                style = MaterialTheme.typography.labelSmall,
                                fontWeight = FontWeight.Bold,
                                color = TekfixGreen,
                                modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp)
                            )
                        }
                    }

                    HorizontalDivider(modifier = Modifier.padding(vertical = 12.dp), color = CardBorder)

                    InfoRow("Order ID", orderState.orderId, isBold = true)
                    InfoRow("Date", orderState.orderDate)
                    InfoRow("Time", orderState.orderTime)
                    InfoRow("Staff Name", orderState.staffName, isBold = true)
                }
            }

            // Product Itemization Card
            Card(
                shape = RoundedCornerShape(16.dp),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Text(
                        text = "🛒 PRODUCT DETAILS (${orderState.totalTypes} Types)",
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Bold,
                        color = TekfixDarkGreen
                    )

                    HorizontalDivider(modifier = Modifier.padding(vertical = 12.dp), color = CardBorder)

                    orderState.cartProducts.forEachIndexed { index, p ->
                        Column(modifier = Modifier.padding(vertical = 6.dp)) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween
                            ) {
                                Text(
                                    text = "${index + 1}. ${p.name}",
                                    style = MaterialTheme.typography.bodyMedium,
                                    fontWeight = FontWeight.Bold,
                                    modifier = Modifier.weight(1f)
                                )
                                Text(
                                    text = "${p.quantity} ${p.unit}",
                                    style = MaterialTheme.typography.bodyMedium,
                                    fontWeight = FontWeight.ExtraBold,
                                    color = TekfixGreen
                                )
                            }
                            if (p.model.isNotBlank()) {
                                Text(
                                    text = "   Model: ${p.model}",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = TextSecondary
                                )
                            }
                            if (p.remarks.isNotBlank()) {
                                Text(
                                    text = "   Remarks: ${p.remarks}",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = TextSecondary
                                )
                            }
                        }
                        if (index < orderState.cartProducts.size - 1) {
                            HorizontalDivider(modifier = Modifier.padding(vertical = 4.dp), color = CardBorder.copy(alpha = 0.5f))
                        }
                    }
                }
            }

            // Summary Card
            Card(
                shape = RoundedCornerShape(16.dp),
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Text(
                        text = "📊 ORDER SUMMARY",
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Bold,
                        color = TekfixDarkGreen
                    )

                    HorizontalDivider(modifier = Modifier.padding(vertical = 12.dp), color = CardBorder)

                    InfoRow("Total Product Types", "${orderState.totalTypes}")
                    InfoRow("Total Quantity", "${orderState.totalQuantity} Pcs", isBold = true)

                    if (orderState.generalRemarks.isNotBlank()) {
                        Spacer(modifier = Modifier.height(8.dp))
                        Text(
                            text = "📝 General Remarks:",
                            style = MaterialTheme.typography.bodySmall,
                            fontWeight = FontWeight.Bold
                        )
                        Text(
                            text = orderState.generalRemarks,
                            style = MaterialTheme.typography.bodySmall,
                            color = TextSecondary,
                            modifier = Modifier.padding(top = 2.dp)
                        )
                    }
                }
            }

            Spacer(modifier = Modifier.height(16.dp))
        }
    }
}

@Composable
private fun InfoRow(label: String, value: String, isBold: Boolean = false) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 3.dp),
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Text(
            text = value,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = if (isBold) FontWeight.Bold else FontWeight.Normal,
            color = MaterialTheme.colorScheme.onSurface
        )
    }
}
