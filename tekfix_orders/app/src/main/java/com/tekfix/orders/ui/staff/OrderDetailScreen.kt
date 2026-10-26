package com.tekfix.orders.ui.staff

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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.tekfix.orders.data.model.Order
import com.tekfix.orders.data.model.OrderStatus
import com.tekfix.orders.data.model.User
import com.tekfix.orders.data.repository.OrderRepository
import com.tekfix.orders.ui.components.OrderStatusBadge
import com.tekfix.orders.ui.components.TekfixTopAppBar
import com.tekfix.orders.ui.components.WhatsAppActionDialog
import com.tekfix.orders.ui.components.WhatsAppStatusBadge
import com.tekfix.orders.ui.theme.CardBorder
import com.tekfix.orders.ui.theme.TekfixDarkGreen
import com.tekfix.orders.ui.theme.TekfixGreen
import com.tekfix.orders.ui.theme.TextSecondary
import kotlinx.coroutines.launch

@Composable
fun OrderDetailScreen(
    orderId: String,
    currentUser: User,
    orderViewModel: OrderViewModel,
    orderRepository: OrderRepository = OrderRepository(),
    onNavigateBack: () -> Unit,
    onNavigateToNewOrder: () -> Unit,
    isOffline: Boolean = false
) {
    val scope = rememberCoroutineScope()
    var order by remember { mutableStateOf<Order?>(null) }
    var isLoading by remember { mutableStateOf(true) }
    var showWhatsAppDialog by remember { mutableStateOf(false) }

    LaunchedEffect(orderId) {
        isLoading = true
        val res = orderRepository.getOrderById(orderId)
        res.onSuccess { order = it }
        isLoading = false
    }

    if (showWhatsAppDialog && order != null) {
        WhatsAppActionDialog(
            order = order!!,
            onDismiss = { showWhatsAppDialog = false }
        )
    }

    Scaffold(
        topBar = {
            TekfixTopAppBar(
                title = "ഓർഡർ വിവരങ്ങൾ",
                subtitle = orderId,
                canNavigateBack = true,
                onNavigateBack = onNavigateBack,
                isOffline = isOffline
            )
        },
        bottomBar = {
            if (order != null) {
                Surface(
                    color = MaterialTheme.colorScheme.surface,
                    shadowElevation = 8.dp,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(16.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        OutlinedButton(
                            onClick = {
                                orderViewModel.duplicateOrder(order!!, currentUser)
                                onNavigateToNewOrder()
                            },
                            shape = RoundedCornerShape(12.dp),
                            modifier = Modifier
                                .weight(1f)
                                .height(50.dp)
                        ) {
                            Icon(Icons.Default.ContentCopy, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(modifier = Modifier.width(6.dp))
                            Text("റീഓർഡർ (Reorder)")
                        }

                        Button(
                            onClick = { showWhatsAppDialog = true },
                            colors = ButtonDefaults.buttonColors(containerColor = TekfixGreen),
                            shape = RoundedCornerShape(12.dp),
                            modifier = Modifier
                                .weight(1f)
                                .height(50.dp)
                        ) {
                            Icon(Icons.Default.Share, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
                            Spacer(modifier = Modifier.width(6.dp))
                            Text("വാട്സാപ്പ് (WhatsApp)", color = Color.White, fontWeight = FontWeight.Bold)
                        }
                    }
                }
            }
        },
        containerColor = MaterialTheme.colorScheme.background
    ) { innerPadding ->
        if (isLoading) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(innerPadding),
                contentAlignment = Alignment.Center
            ) {
                CircularProgressIndicator(color = TekfixGreen)
            }
        } else if (order == null) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(innerPadding),
                contentAlignment = Alignment.Center
            ) {
                Text("ഓർഡർ കണ്ടെത്താനായില്ല (Order not found)")
            }
        } else {
            val ord = order!!
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(innerPadding)
                    .verticalScroll(rememberScrollState())
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                // Header Status Card
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
                                text = ord.orderId,
                                style = MaterialTheme.typography.titleLarge,
                                fontWeight = FontWeight.Bold,
                                color = TekfixDarkGreen
                            )
                            OrderStatusBadge(ord.status)
                        }

                        Spacer(modifier = Modifier.height(10.dp))

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                text = "Ordered by: ${ord.staffName}",
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = FontWeight.SemiBold
                            )
                            WhatsAppStatusBadge(ord.whatsappDeliveryStatus)
                        }

                        Spacer(modifier = Modifier.height(4.dp))

                        Text(
                            text = "${ord.createdDate} at ${ord.createdTime}",
                            style = MaterialTheme.typography.bodySmall,
                            color = TextSecondary
                        )

                        // Admin Status Update Dropdown (if user is Admin)
                        if (currentUser.isAdmin) {
                            HorizontalDivider(modifier = Modifier.padding(vertical = 12.dp), color = CardBorder)
                            Text(
                                text = "സ്റ്റാറ്റസ് മാറ്റുക (Update Status - Admin):",
                                style = MaterialTheme.typography.labelMedium,
                                fontWeight = FontWeight.Bold
                            )
                            Spacer(modifier = Modifier.height(8.dp))
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                listOf(OrderStatus.CONFIRMED, OrderStatus.COMPLETED, OrderStatus.CANCELLED).forEach { st ->
                                    FilterChip(
                                        selected = ord.status == st,
                                        onClick = {
                                            scope.launch {
                                                orderRepository.updateOrderStatus(ord.orderId, st)
                                                order = ord.copy(status = st)
                                            }
                                        },
                                        label = { Text(st.displayName, style = MaterialTheme.typography.labelSmall) }
                                    )
                                }
                            }
                        }
                    }
                }

                // Product Items Card
                Card(
                    shape = RoundedCornerShape(16.dp),
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                    elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Text(
                            text = "🛒 പ്രൊഡക്റ്റുകൾ (Products - ${ord.totalTypes} Types)",
                            style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.Bold,
                            color = TekfixDarkGreen
                        )

                        HorizontalDivider(modifier = Modifier.padding(vertical = 12.dp), color = CardBorder)

                        ord.products.forEachIndexed { index, p ->
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
                            if (index < ord.products.size - 1) {
                                HorizontalDivider(modifier = Modifier.padding(vertical = 4.dp), color = CardBorder.copy(alpha = 0.5f))
                            }
                        }
                    }
                }

                // Summary & Remarks Card
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

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Text("ആകെ ഇനങ്ങൾ (Total Types):", style = MaterialTheme.typography.bodyMedium)
                            Text("${ord.totalTypes}", style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Bold)
                        }

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Text("ആകെ അളവ് (Total Quantity):", style = MaterialTheme.typography.bodyMedium)
                            Text("${ord.totalQuantity} Pcs", style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.ExtraBold, color = TekfixGreen)
                        }

                        if (ord.generalRemarks.isNotBlank()) {
                            Spacer(modifier = Modifier.height(10.dp))
                            Text("📝 General Remarks:", style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.Bold)
                            Text(ord.generalRemarks, style = MaterialTheme.typography.bodySmall, color = TextSecondary)
                        }
                    }
                }

                Spacer(modifier = Modifier.height(20.dp))
            }
        }
    }
}
