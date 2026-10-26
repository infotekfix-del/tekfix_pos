package com.tekfix.orders.ui.staff

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.tekfix.orders.data.model.Order
import com.tekfix.orders.data.model.OrderStatus
import com.tekfix.orders.data.model.User
import com.tekfix.orders.ui.components.*
import com.tekfix.orders.ui.theme.TekfixGreen
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
fun OrderHistoryScreen(
    currentUser: User,
    orderViewModel: OrderViewModel,
    onNavigateBack: () -> Unit,
    onNavigateToOrderDetail: (String) -> Unit,
    onNavigateToNewOrder: () -> Unit,
    isOffline: Boolean = false
) {
    val orders by orderViewModel.staffOrders.collectAsState()

    var searchQuery by remember { mutableStateOf("") }
    var selectedStatusFilter by remember { mutableStateOf("All") }
    var todayOnlyFilter by remember { mutableStateOf(false) }

    val todayStr = remember { SimpleDateFormat("dd-MM-yyyy", Locale.getDefault()).format(Date()) }

    val statusFilters = listOf("All") + OrderStatus.entries.map { it.displayName }

    val filteredOrders = remember(orders, searchQuery, selectedStatusFilter, todayOnlyFilter) {
        orders.filter { order ->
            val matchesSearch = searchQuery.isBlank() ||
                    order.orderId.contains(searchQuery, ignoreCase = true) ||
                    order.products.any { it.name.contains(searchQuery, ignoreCase = true) }

            val matchesStatus = selectedStatusFilter == "All" ||
                    order.status.displayName.equals(selectedStatusFilter, ignoreCase = true)

            val matchesToday = !todayOnlyFilter || order.createdDate == todayStr

            matchesSearch && matchesStatus && matchesToday
        }
    }

    Scaffold(
        topBar = {
            TekfixTopAppBar(
                title = "ഓർഡർ ഹിസ്റ്ററി (Order History)",
                subtitle = "${orders.size} Total Orders",
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
        ) {
            // Search Input
            PaddingValues(horizontal = 16.dp, vertical = 8.dp).let {
                Box(modifier = Modifier.padding(it)) {
                    TekfixSearchBar(
                        query = searchQuery,
                        onQueryChange = { searchQuery = it },
                        placeholder = "Search by Order ID or Product name..."
                    )
                }
            }

            // Quick Filter Chips (Today vs All Statuses)
            LazyRow(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                item {
                    FilterChip(
                        selected = todayOnlyFilter,
                        onClick = { todayOnlyFilter = !todayOnlyFilter },
                        label = { Text("ഇന്നത്തെ ഓർഡറുകൾ (Today Only)") },
                        leadingIcon = {
                            if (todayOnlyFilter) Icon(Icons.Default.Check, contentDescription = null, modifier = Modifier.size(16.dp))
                        }
                    )
                }
                items(statusFilters) { status ->
                    FilterChip(
                        selected = selectedStatusFilter == status,
                        onClick = { selectedStatusFilter = status },
                        label = { Text(status) }
                    )
                }
            }

            if (filteredOrders.isEmpty()) {
                EmptyStateView(
                    icon = Icons.Default.HistoryToggleOff,
                    title = "ഓർഡറുകൾ കണ്ടെത്തിയില്ല",
                    subtitle = "ഫിൽട്ടറുകൾ മാറ്റി വീണ്ടും ശ്രമിക്കുക."
                )
            } else {
                LazyColumn(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(horizontal = 16.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                    contentPadding = PaddingValues(vertical = 12.dp)
                ) {
                    items(filteredOrders, key = { it.orderId }) { order ->
                        OrderCardItem(
                            order = order,
                            onCardClick = { onNavigateToOrderDetail(order.orderId) },
                            onDuplicateClick = {
                                orderViewModel.duplicateOrder(order, currentUser)
                                onNavigateToNewOrder()
                            }
                        )
                    }
                }
            }
        }
    }
}

@Composable
fun OrderCardItem(
    order: Order,
    onCardClick: () -> Unit,
    onDuplicateClick: () -> Unit
) {
    Card(
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onCardClick() }
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

            // Short summary of first 2 products
            val productsSummary = order.products.take(2).joinToString(", ") { "${it.name} (${it.quantity})" } +
                    if (order.products.size > 2) " +${order.products.size - 2} more" else ""
            Text(
                text = productsSummary,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            Spacer(modifier = Modifier.height(10.dp))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column {
                    Text(
                        text = "${order.createdDate} • ${order.createdTime}",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(modifier = Modifier.height(2.dp))
                    WhatsAppStatusBadge(order.whatsappDeliveryStatus)
                }

                Row {
                    OutlinedButton(
                        onClick = onDuplicateClick,
                        shape = RoundedCornerShape(8.dp),
                        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp)
                    ) {
                        Icon(Icons.Default.ContentCopy, contentDescription = null, modifier = Modifier.size(14.dp))
                        Spacer(modifier = Modifier.width(4.dp))
                        Text("റീഓർഡർ (Reorder)", style = MaterialTheme.typography.labelSmall)
                    }
                }
            }
        }
    }
}
