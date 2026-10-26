package com.tekfix.orders.ui.staff

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.tekfix.orders.ui.components.EmptyStateView
import com.tekfix.orders.ui.components.TekfixTopAppBar
import com.tekfix.orders.ui.theme.TekfixGreen
import com.tekfix.orders.ui.theme.TextMuted
import com.tekfix.orders.ui.theme.TextSecondary

@Composable
fun OrderCartScreen(
    orderViewModel: OrderViewModel,
    onNavigateBack: () -> Unit,
    onNavigateToPreview: () -> Unit,
    isOffline: Boolean = false
) {
    val orderState by orderViewModel.orderState.collectAsState()
    var generalRemarks by remember(orderState.generalRemarks) { mutableStateOf(orderState.generalRemarks) }

    Scaffold(
        topBar = {
            TekfixTopAppBar(
                title = "ഓർഡർ കാർട്ട് (Order Cart)",
                subtitle = "${orderState.totalTypes} Types • ${orderState.totalQuantity} Pcs",
                canNavigateBack = true,
                onNavigateBack = onNavigateBack,
                isOffline = isOffline
            )
        },
        bottomBar = {
            if (orderState.cartProducts.isNotEmpty()) {
                Surface(
                    color = MaterialTheme.colorScheme.surface,
                    shadowElevation = 8.dp,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Text(
                                text = "ആകെ (Total Summary):",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold
                            )
                            Text(
                                text = "${orderState.totalTypes} Types • ${orderState.totalQuantity} Pcs",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold,
                                color = TekfixGreen
                            )
                        }

                        Spacer(modifier = Modifier.height(12.dp))

                        Button(
                            onClick = {
                                orderViewModel.setGeneralRemarks(generalRemarks)
                                onNavigateToPreview()
                            },
                            enabled = orderState.isValid,
                            colors = ButtonDefaults.buttonColors(containerColor = TekfixGreen),
                            shape = RoundedCornerShape(12.dp),
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(52.dp)
                        ) {
                            Text(
                                text = "പ്രിവ്യൂ & സമർപ്പിക്കുക (Preview Order)",
                                fontWeight = FontWeight.Bold,
                                fontSize = 16.sp
                            )
                            Spacer(modifier = Modifier.width(8.dp))
                            Icon(Icons.Default.ArrowForward, contentDescription = null)
                        }
                    }
                }
            }
        },
        containerColor = MaterialTheme.colorScheme.background
    ) { innerPadding ->
        if (orderState.cartProducts.isEmpty()) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(innerPadding)
            ) {
                EmptyStateView(
                    icon = Icons.Default.RemoveShoppingCart,
                    title = "കാർട്ട് ശൂന്യമാണ് (Cart is empty)",
                    subtitle = "ഓർഡർ സമർപ്പിക്കാൻ പ്രൊഡക്റ്റുകൾ ചേർക്കുക.",
                    actionButtonText = "+ പ്രൊഡക്റ്റുകൾ ചേർക്കുക (+ Add Products)",
                    onActionClick = onNavigateBack
                )
            }
        } else {
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(innerPadding)
                    .padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
                contentPadding = PaddingValues(vertical = 14.dp)
            ) {
                // Add More Products Button
                item {
                    OutlinedButton(
                        onClick = onNavigateBack,
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Icon(Icons.Default.Add, contentDescription = null, tint = TekfixGreen)
                        Spacer(modifier = Modifier.width(8.dp))
                        Text(
                            "+ കൂടുതൽ പ്രൊഡക്റ്റുകൾ ചേർക്കുക (+ ADD MORE PRODUCTS)",
                            fontWeight = FontWeight.Bold,
                            color = TekfixGreen
                        )
                    }
                }

                // List of Cart Products
                itemsIndexed(orderState.cartProducts) { index, item ->
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
                                verticalAlignment = Alignment.Top
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Text(
                                            text = item.name,
                                            style = MaterialTheme.typography.titleMedium,
                                            fontWeight = FontWeight.Bold,
                                            color = MaterialTheme.colorScheme.onSurface
                                        )
                                        if (item.isCustom) {
                                            Spacer(modifier = Modifier.width(6.dp))
                                            Surface(
                                                color = MaterialTheme.colorScheme.secondaryContainer,
                                                shape = RoundedCornerShape(6.dp)
                                            ) {
                                                Text(
                                                    text = "Custom",
                                                    style = MaterialTheme.typography.labelSmall,
                                                    color = MaterialTheme.colorScheme.onSecondaryContainer,
                                                    modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                                                )
                                            }
                                        }
                                    }

                                    if (item.model.isNotBlank()) {
                                        Text(
                                            text = "Model: ${item.model}",
                                            style = MaterialTheme.typography.bodySmall,
                                            color = TextSecondary
                                        )
                                    }
                                    if (item.sku.isNotBlank()) {
                                        Text(
                                            text = "SKU: ${item.sku}",
                                            style = MaterialTheme.typography.labelSmall,
                                            color = TextMuted
                                        )
                                    }
                                }

                                IconButton(
                                    onClick = { orderViewModel.removeProduct(index) },
                                    modifier = Modifier.size(28.dp)
                                ) {
                                    Icon(
                                        imageVector = Icons.Default.Close,
                                        contentDescription = "Remove",
                                        tint = MaterialTheme.colorScheme.error
                                    )
                                }
                            }

                            if (item.remarks.isNotBlank()) {
                                Spacer(modifier = Modifier.height(4.dp))
                                Surface(
                                    color = MaterialTheme.colorScheme.surfaceVariant,
                                    shape = RoundedCornerShape(8.dp)
                                ) {
                                    Text(
                                        text = "Remarks: ${item.remarks}",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = TextSecondary,
                                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp)
                                    )
                                }
                            }

                            Spacer(modifier = Modifier.height(12.dp))

                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(
                                    text = "അളവ് (Quantity):",
                                    style = MaterialTheme.typography.bodyMedium,
                                    fontWeight = FontWeight.Medium
                                )

                                // Quantity Stepper
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    IconButton(
                                        onClick = { orderViewModel.updateProductQuantity(index, item.quantity - 1) },
                                        modifier = Modifier
                                            .size(32.dp)
                                            .clip(CircleShape)
                                            .background(MaterialTheme.colorScheme.surfaceVariant)
                                    ) {
                                        Icon(Icons.Default.Remove, contentDescription = "Decrease", modifier = Modifier.size(16.dp))
                                    }

                                    Text(
                                        text = "${item.quantity} ${item.unit}",
                                        fontWeight = FontWeight.Bold,
                                        style = MaterialTheme.typography.titleMedium,
                                        modifier = Modifier.padding(horizontal = 12.dp)
                                    )

                                    IconButton(
                                        onClick = { orderViewModel.updateProductQuantity(index, item.quantity + 1) },
                                        modifier = Modifier
                                            .size(32.dp)
                                            .clip(CircleShape)
                                            .background(MaterialTheme.colorScheme.surfaceVariant)
                                    ) {
                                        Icon(Icons.Default.Add, contentDescription = "Increase", modifier = Modifier.size(16.dp))
                                    }
                                }
                            }
                        }
                    }
                }

                // General Order Remarks Section (Section 9)
                item {
                    Card(
                        shape = RoundedCornerShape(16.dp),
                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Column(modifier = Modifier.padding(16.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Default.Notes, contentDescription = null, tint = TekfixGreen)
                                Spacer(modifier = Modifier.width(8.dp))
                                Text(
                                    text = "പൊതു നിർദ്ദേശങ്ങൾ (General Order Remarks)",
                                    style = MaterialTheme.typography.titleSmall,
                                    fontWeight = FontWeight.Bold
                                )
                            }
                            Spacer(modifier = Modifier.height(10.dp))
                            OutlinedTextField(
                                value = generalRemarks,
                                onValueChange = {
                                    generalRemarks = it
                                    orderViewModel.setGeneralRemarks(it)
                                },
                                placeholder = { Text("e.g. Urgent order / Required tomorrow morning / Special packing") },
                                maxLines = 3,
                                shape = RoundedCornerShape(12.dp),
                                modifier = Modifier.fillMaxWidth()
                            )
                        }
                    }
                }

                item {
                    Spacer(modifier = Modifier.height(16.dp))
                }
            }
        }
    }
}
