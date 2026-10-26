package com.tekfix.orders.ui.staff

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
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
import com.tekfix.orders.data.model.OrderStatus
import com.tekfix.orders.data.model.User
import com.tekfix.orders.ui.components.OrderStatusBadge
import com.tekfix.orders.ui.components.StatCard
import com.tekfix.orders.ui.components.TekfixTopAppBar
import com.tekfix.orders.ui.components.WhatsAppStatusBadge
import com.tekfix.orders.ui.theme.*
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
fun StaffDashboardScreen(
    currentUser: User,
    orderViewModel: OrderViewModel,
    onNavigateToNewOrder: () -> Unit,
    onNavigateToOrderHistory: () -> Unit,
    onNavigateToOrderDetail: (String) -> Unit,
    onLogout: () -> Unit,
    isOffline: Boolean = false
) {
    val orders by orderViewModel.staffOrders.collectAsState()

    LaunchedEffect(currentUser.uid) {
        orderViewModel.loadStaffOrders(currentUser.uid)
    }

    val todayStr = remember { SimpleDateFormat("dd-MM-yyyy", Locale.getDefault()).format(Date()) }
    val todayDisplay = remember { SimpleDateFormat("EEEE, dd MMM yyyy", Locale.getDefault()).format(Date()) }

    val todayOrdersCount = orders.count { it.createdDate == todayStr }
    val pendingCount = orders.count { it.status == OrderStatus.SUBMITTED || it.status == OrderStatus.PENDING }
    val confirmedCount = orders.count { it.status == OrderStatus.CONFIRMED || it.status == OrderStatus.PROCESSING }
    val completedCount = orders.count { it.status == OrderStatus.COMPLETED }

    var showLogoutDialog by remember { mutableStateOf(false) }

    if (showLogoutDialog) {
        AlertDialog(
            onDismissRequest = { showLogoutDialog = false },
            title = { Text("ലോഗ് ഔട്ട് (Log Out)") },
            text = { Text("ആപ്പിൽ നിന്നും ലോഗ് ഔട്ട് ചെയ്യണമെന്ന് ഉറപ്പാണോ?\n(Are you sure you want to log out?)") },
            confirmButton = {
                Button(
                    onClick = {
                        showLogoutDialog = false
                        onLogout()
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)
                ) {
                    Text("ലോഗ് ഔട്ട് (Log Out)")
                }
            },
            dismissButton = {
                TextButton(onClick = { showLogoutDialog = false }) {
                    Text("റദ്ദാക്കുക (Cancel)")
                }
            }
        )
    }

    Scaffold(
        topBar = {
            TekfixTopAppBar(
                title = "Tekfix Orders",
                subtitle = todayDisplay,
                isOffline = isOffline,
                actions = {
                    IconButton(onClick = { showLogoutDialog = true }) {
                        Icon(
                            imageVector = Icons.Default.Logout,
                            contentDescription = "Log Out",
                            tint = Color.White
                        )
                    }
                }
            )
        },
        containerColor = MaterialTheme.colorScheme.background
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            item {
                Spacer(modifier = Modifier.height(4.dp))

                // Welcome Header Card
                Card(
                    shape = RoundedCornerShape(20.dp),
                    colors = CardDefaults.cardColors(containerColor = TekfixDarkGreen),
                    elevation = CardDefaults.cardElevation(defaultElevation = 3.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(20.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Box(
                            modifier = Modifier
                                .size(52.dp)
                                .clip(CircleShape)
                                .background(Color.White.copy(alpha = 0.2f)),
                            contentAlignment = Alignment.Center
                        ) {
                            Text(
                                text = if (currentUser.name.isNotBlank()) currentUser.name.take(1).uppercase() else "S",
                                style = MaterialTheme.typography.titleLarge,
                                fontWeight = FontWeight.Bold,
                                color = Color.White
                            )
                        }

                        Spacer(modifier = Modifier.width(16.dp))

                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = "സ്വാഗതം (Welcome),",
                                style = MaterialTheme.typography.bodySmall,
                                color = Color.White.copy(alpha = 0.8f)
                            )
                            Text(
                                text = currentUser.name,
                                style = MaterialTheme.typography.titleLarge,
                                fontWeight = FontWeight.Bold,
                                color = Color.White
                            )
                            Text(
                                text = "സ്റ്റാഫ് ഓർഡർ പോർട്ടൽ",
                                style = MaterialTheme.typography.labelSmall,
                                color = WhatsAppGreen
                            )
                        }
                    }
                }
            }

            // High Prominence "NEW ORDER" Action Button
            item {
                Button(
                    onClick = {
                        orderViewModel.initNewOrder(currentUser)
                        onNavigateToNewOrder()
                    },
                    shape = RoundedCornerShape(16.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = TekfixGreen),
                    elevation = ButtonDefaults.buttonElevation(defaultElevation = 4.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(64.dp)
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.Center
                    ) {
                        Box(
                            modifier = Modifier
                                .size(36.dp)
                                .clip(CircleShape)
                                .background(Color.White.copy(alpha = 0.25f)),
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                imageVector = Icons.Default.AddShoppingCart,
                                contentDescription = null,
                                tint = Color.White,
                                modifier = Modifier.size(20.dp)
                            )
                        }
                        Spacer(modifier = Modifier.width(14.dp))
                        Column {
                            Text(
                                text = "+ പുതിയ ഓർഡർ (NEW ORDER)",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.ExtraBold,
                                color = Color.White
                            )
                            Text(
                                text = "Create daily staff product order",
                                style = MaterialTheme.typography.labelSmall,
                                color = Color.White.copy(alpha = 0.85f)
                            )
                        }
                    }
                }
            }

            // Stat Cards Grid (2x2)
            item {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        StatCard(
                            title = "ഇന്നത്തെ ഓർഡറുകൾ (Today)",
                            value = "$todayOrdersCount",
                            icon = Icons.Default.Today,
                            iconColor = TekfixGreen,
                            modifier = Modifier.weight(1f),
                            onClick = onNavigateToOrderHistory
                        )
                        StatCard(
                            title = "പെൻഡിംഗ് (Pending)",
                            value = "$pendingCount",
                            icon = Icons.Default.PendingActions,
                            iconColor = StatusPending,
                            modifier = Modifier.weight(1f),
                            onClick = onNavigateToOrderHistory
                        )
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        StatCard(
                            title = "സ്ഥിരീകരിച്ചവ (Confirmed)",
                            value = "$confirmedCount",
                            icon = Icons.Default.ThumbUp,
                            iconColor = StatusConfirmed,
                            modifier = Modifier.weight(1f),
                            onClick = onNavigateToOrderHistory
                        )
                        StatCard(
                            title = "പൂർത്തിയായവ (Completed)",
                            value = "$completedCount",
                            icon = Icons.Default.CheckCircle,
                            iconColor = StatusCompleted,
                            modifier = Modifier.weight(1f),
                            onClick = onNavigateToOrderHistory
                        )
                    }
                }
            }

            // Recent Orders Header with "View All"
            item {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = "സമീപകാല ഓർഡറുകൾ (Recent Orders)",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                    TextButton(onClick = onNavigateToOrderHistory) {
                        Text(
                            "എല്ലാം കാണുക (View All)",
                            fontWeight = FontWeight.Bold,
                            color = TekfixGreen
                        )
                    }
                }
            }

            if (orders.isEmpty()) {
                item {
                    Card(
                        shape = RoundedCornerShape(16.dp),
                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 12.dp)
                    ) {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(28.dp),
                            horizontalAlignment = Alignment.CenterHorizontally
                        ) {
                            Icon(
                                imageVector = Icons.Default.ReceiptLong,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(40.dp)
                            )
                            Spacer(modifier = Modifier.height(10.dp))
                            Text(
                                "ഓർഡറുകൾ ലഭ്യമല്ല (No orders placed yet)",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            Text(
                                "പുതിയ ഓർഡർ നൽകാൻ മുകളിലുള്ള ബട്ടൺ ക്ലിക്ക് ചെയ്യുക.",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                }
            } else {
                items(orders.take(5)) { order ->
                    Card(
                        shape = RoundedCornerShape(16.dp),
                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onNavigateToOrderDetail(order.orderId) }
                    ) {
                        Column(modifier = Modifier.padding(16.dp)) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(
                                    text = order.orderId,
                                    style = MaterialTheme.typography.titleMedium,
                                    fontWeight = FontWeight.Bold,
                                    color = TekfixGreen
                                )
                                OrderStatusBadge(order.status)
                            }

                            Spacer(modifier = Modifier.height(8.dp))

                            Text(
                                text = "${order.totalTypes} Product Types • ${order.totalQuantity} Total Quantity",
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = FontWeight.SemiBold,
                                color = MaterialTheme.colorScheme.onSurface
                            )

                            Spacer(modifier = Modifier.height(4.dp))

                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(
                                    text = "${order.createdDate} • ${order.createdTime}",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                                WhatsAppStatusBadge(order.whatsappDeliveryStatus)
                            }
                        }
                    }
                }
            }

            item {
                Spacer(modifier = Modifier.height(24.dp))
            }
        }
    }
}
