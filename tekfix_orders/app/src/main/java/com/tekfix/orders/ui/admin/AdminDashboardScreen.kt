package com.tekfix.orders.ui.admin

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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.tekfix.orders.data.model.OrderStatus
import com.tekfix.orders.data.model.User
import com.tekfix.orders.ui.components.OrderStatusBadge
import com.tekfix.orders.ui.components.StatCard
import com.tekfix.orders.ui.components.TekfixTopAppBar
import com.tekfix.orders.ui.components.WhatsAppStatusBadge
import com.tekfix.orders.ui.theme.*

@Composable
fun AdminDashboardScreen(
    currentUser: User,
    adminViewModel: AdminViewModel,
    onNavigateToProducts: () -> Unit,
    onNavigateToStaff: () -> Unit,
    onNavigateToReports: () -> Unit,
    onNavigateToWhatsAppSettings: () -> Unit,
    onNavigateToOrderDetail: (String) -> Unit,
    onLogout: () -> Unit,
    isOffline: Boolean = false
) {
    val orders by adminViewModel.ordersFlow.collectAsState()
    val products by adminViewModel.productsFlow.collectAsState()
    val staffList by adminViewModel.staffFlow.collectAsState()

    val pendingCount = orders.count { it.status == OrderStatus.SUBMITTED || it.status == OrderStatus.PENDING }
    val confirmedCount = orders.count { it.status == OrderStatus.CONFIRMED || it.status == OrderStatus.PROCESSING }
    val completedCount = orders.count { it.status == OrderStatus.COMPLETED }
    val activeStaffCount = staffList.count { it.active }

    var showLogoutDialog by remember { mutableStateOf(false) }

    if (showLogoutDialog) {
        AlertDialog(
            onDismissRequest = { showLogoutDialog = false },
            title = { Text("ലോഗ് ഔട്ട് (Log Out)") },
            text = { Text("അഡ്മിൻ പോർട്ടലിൽ നിന്നും ലോഗ് ഔട്ട് ചെയ്യണമെന്ന് ഉറപ്പാണോ?") },
            confirmButton = {
                Button(
                    onClick = {
                        showLogoutDialog = false
                        onLogout()
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)
                ) {
                    Text("ലോഗ് ഔട്ട്")
                }
            },
            dismissButton = {
                TextButton(onClick = { showLogoutDialog = false }) {
                    Text("റദ്ദാക്കുക")
                }
            }
        )
    }

    Scaffold(
        topBar = {
            TekfixTopAppBar(
                title = "Tekfix Orders • Admin",
                subtitle = "അഡ്മിനിസ്ട്രേറ്റർ കൺട്രോൾ പാനൽ",
                isOffline = isOffline,
                actions = {
                    IconButton(onClick = { showLogoutDialog = true }) {
                        Icon(Icons.Default.Logout, contentDescription = "Log Out", tint = Color.White)
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

                // Stats Overview Row 1
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    StatCard(
                        title = "ആകെ ഓർഡറുകൾ (Total)",
                        value = "${orders.size}",
                        icon = Icons.Default.ReceiptLong,
                        iconColor = TekfixGreen,
                        modifier = Modifier.weight(1f)
                    )
                    StatCard(
                        title = "അംഗീകരിക്കാനുള്ളവ (Pending)",
                        value = "$pendingCount",
                        icon = Icons.Default.PendingActions,
                        iconColor = StatusPending,
                        modifier = Modifier.weight(1f)
                    )
                }
            }

            item {
                // Stats Overview Row 2
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    StatCard(
                        title = "സ്ഥിരീകരിച്ചവ (Confirmed)",
                        value = "$confirmedCount",
                        icon = Icons.Default.ThumbUp,
                        iconColor = StatusConfirmed,
                        modifier = Modifier.weight(1f)
                    )
                    StatCard(
                        title = "സ്റ്റാഫ് അംഗങ്ങൾ (Staff)",
                        value = "$activeStaffCount",
                        icon = Icons.Default.People,
                        iconColor = StatusProcessing,
                        modifier = Modifier.weight(1f),
                        onClick = onNavigateToStaff
                    )
                }
            }

            // Quick Navigation Hub
            item {
                Text(
                    text = "അഡ്മിൻ മാനേജ്മെന്റ് (Management Hub)",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Spacer(modifier = Modifier.height(8.dp))

                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        AdminTile(
                            title = "പ്രൊഡക്റ്റുകൾ\n(Products)",
                            subtitle = "${products.size} Products",
                            icon = Icons.Default.Inventory2,
                            color = TekfixGreen,
                            modifier = Modifier.weight(1f),
                            onClick = onNavigateToProducts
                        )
                        AdminTile(
                            title = "സ്റ്റാഫ് അക്കൗണ്ട്സ്\n(Staff)",
                            subtitle = "$activeStaffCount Active",
                            icon = Icons.Default.ManageAccounts,
                            color = Color(0xFF0284C7),
                            modifier = Modifier.weight(1f),
                            onClick = onNavigateToStaff
                        )
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        AdminTile(
                            title = "റിപ്പോർട്ടുകൾ\n(Reports & CSV)",
                            subtitle = "Export data",
                            icon = Icons.Default.BarChart,
                            color = Color(0xFFD97706),
                            modifier = Modifier.weight(1f),
                            onClick = onNavigateToReports
                        )
                        AdminTile(
                            title = "വാട്സാപ്പ് സെറ്റിംഗ്സ്\n(WhatsApp)",
                            subtitle = "Group Integration",
                            icon = Icons.Default.Groups,
                            color = WhatsAppDarkGreen,
                            modifier = Modifier.weight(1f),
                            onClick = onNavigateToWhatsAppSettings
                        )
                    }
                }
            }

            // Live Incoming Orders Stream Header
            item {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = "എല്ലാ ഓർഡറുകളും (All Orders Queue)",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                    Text(
                        text = "${orders.size} Orders",
                        style = MaterialTheme.typography.labelMedium,
                        color = TextSecondary
                    )
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
                                .padding(24.dp),
                            horizontalAlignment = Alignment.CenterHorizontally
                        ) {
                            Text("ഇതുവരെ ഓർഡറുകൾ ഒന്നും സമർപ്പിച്ചിട്ടില്ല (No orders received yet)")
                        }
                    }
                }
            } else {
                items(orders.take(20), key = { it.orderId }) { order ->
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
                                Column {
                                    Text(
                                        text = order.orderId,
                                        style = MaterialTheme.typography.titleMedium,
                                        fontWeight = FontWeight.Bold,
                                        color = TekfixGreen
                                    )
                                    Text(
                                        text = "By ${order.staffName}",
                                        style = MaterialTheme.typography.bodySmall,
                                        fontWeight = FontWeight.Medium
                                    )
                                }
                                OrderStatusBadge(order.status)
                            }

                            Spacer(modifier = Modifier.height(8.dp))

                            Text(
                                text = "${order.totalTypes} Types • ${order.totalQuantity} Total Quantity",
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = FontWeight.SemiBold
                            )

                            Spacer(modifier = Modifier.height(8.dp))

                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(
                                    text = "${order.createdDate} at ${order.createdTime}",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = TextSecondary
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

@Composable
private fun AdminTile(
    title: String,
    subtitle: String,
    icon: ImageVector,
    color: Color,
    modifier: Modifier = Modifier,
    onClick: () -> Unit
) {
    Card(
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
        modifier = modifier.clickable { onClick() }
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .clip(CircleShape)
                    .background(color.copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center
            ) {
                Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(24.dp))
            }
            Spacer(modifier = Modifier.width(12.dp))
            Column {
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}
