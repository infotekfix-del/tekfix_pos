package com.tekfix.orders.ui.admin

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Leaderboard
import androidx.compose.material.icons.filled.ReceiptLong
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.tekfix.orders.ui.components.StatCard
import com.tekfix.orders.ui.components.TekfixTopAppBar
import com.tekfix.orders.ui.theme.CardBorder
import com.tekfix.orders.ui.theme.TekfixDarkGreen
import com.tekfix.orders.ui.theme.TekfixGreen
import com.tekfix.orders.ui.theme.TextSecondary
import com.tekfix.orders.util.CsvExporter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
fun ReportsScreen(
    adminViewModel: AdminViewModel,
    onNavigateBack: () -> Unit,
    isOffline: Boolean = false
) {
    val context = LocalContext.current
    val orders by adminViewModel.ordersFlow.collectAsState()

    var selectedRange by remember { mutableStateOf("All Time") }
    val ranges = listOf("All Time", "Today")

    val todayStr = remember { SimpleDateFormat("dd-MM-yyyy", Locale.getDefault()).format(Date()) }

    val filteredOrders = remember(orders, selectedRange) {
        when (selectedRange) {
            "Today" -> orders.filter { it.createdDate == todayStr }
            else -> orders
        }
    }

    val totalProductQty = remember(filteredOrders) {
        filteredOrders.sumOf { it.totalQuantity }
    }

    // Top ordered products aggregate
    val productAggregates = remember(filteredOrders) {
        val map = mutableMapOf<String, Int>()
        for (order in filteredOrders) {
            for (p in order.products) {
                val key = if (p.model.isNotBlank()) "${p.name} (${p.model})" else p.name
                map[key] = (map[key] ?: 0) + p.quantity
            }
        }
        map.toList().sortedByDescending { it.second }
    }

    // Orders by staff
    val staffAggregates = remember(filteredOrders) {
        val map = mutableMapOf<String, Int>()
        for (order in filteredOrders) {
            val name = order.staffName.ifBlank { "Unknown" }
            map[name] = (map[name] ?: 0) + 1
        }
        map.toList().sortedByDescending { it.second }
    }

    Scaffold(
        topBar = {
            TekfixTopAppBar(
                title = "ഓർഡർ റിപ്പോർട്ടുകൾ (Reports)",
                subtitle = "${filteredOrders.size} Orders Analyzed",
                canNavigateBack = true,
                onNavigateBack = onNavigateBack,
                isOffline = isOffline,
                actions = {
                    IconButton(onClick = {
                        val csv = CsvExporter.exportOrdersToCsv(filteredOrders)
                        CsvExporter.shareCsvFile(context, "tekfix_orders_report.csv", csv)
                    }) {
                        Icon(Icons.Default.Download, contentDescription = "Export CSV", tint = Color.White)
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
            verticalArrangement = Arrangement.spacedBy(16.dp),
            contentPadding = PaddingValues(vertical = 12.dp)
        ) {
            // Range Filter Chips
            item {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(ranges) { r ->
                        FilterChip(
                            selected = selectedRange == r,
                            onClick = { selectedRange = r },
                            label = { Text(r) }
                        )
                    }
                }
            }

            // Summary Stats Row
            item {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    StatCard(
                        title = "ആകെ ഓർഡറുകൾ (Orders)",
                        value = "${filteredOrders.size}",
                        icon = Icons.Default.ReceiptLong,
                        iconColor = TekfixGreen,
                        modifier = Modifier.weight(1f)
                    )
                    StatCard(
                        title = "ആകെ പ്രൊഡക്റ്റുകൾ (Units)",
                        value = "$totalProductQty",
                        icon = Icons.Default.Leaderboard,
                        iconColor = Color(0xFF0284C7),
                        modifier = Modifier.weight(1f)
                    )
                }
            }

            // Top Ordered Products Leaderboard
            item {
                Card(
                    shape = RoundedCornerShape(16.dp),
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                    elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Text(
                            text = "🔥 കൂടുതൽ ആവശ്യപ്പെട്ട പ്രൊഡക്റ്റുകൾ (Top Products)",
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                            color = TekfixDarkGreen
                        )
                        HorizontalDivider(modifier = Modifier.padding(vertical = 10.dp), color = CardBorder)

                        if (productAggregates.isEmpty()) {
                            Text("ഡാറ്റ ലഭ്യമല്ല (No product data)", style = MaterialTheme.typography.bodySmall, color = TextSecondary)
                        } else {
                            productAggregates.take(10).forEachIndexed { index, pair ->
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(vertical = 4.dp),
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Text(
                                        text = "${index + 1}. ${pair.first}",
                                        style = MaterialTheme.typography.bodyMedium,
                                        fontWeight = FontWeight.Medium,
                                        modifier = Modifier.weight(1f)
                                    )
                                    Text(
                                        text = "${pair.second} Pcs",
                                        style = MaterialTheme.typography.bodyMedium,
                                        fontWeight = FontWeight.Bold,
                                        color = TekfixGreen
                                    )
                                }
                            }
                        }
                    }
                }
            }

            // Staff Orders Leaderboard
            item {
                Card(
                    shape = RoundedCornerShape(16.dp),
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                    elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Text(
                            text = "👥 സ്റ്റാഫ് ഓർഡറുകൾ (Orders by Staff)",
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                            color = TekfixDarkGreen
                        )
                        HorizontalDivider(modifier = Modifier.padding(vertical = 10.dp), color = CardBorder)

                        if (staffAggregates.isEmpty()) {
                            Text("ഡാറ്റ ലഭ്യമല്ല (No staff data)", style = MaterialTheme.typography.bodySmall, color = TextSecondary)
                        } else {
                            staffAggregates.forEach { pair ->
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(vertical = 4.dp),
                                    horizontalArrangement = Arrangement.SpaceBetween
                                ) {
                                    Text(text = pair.first, style = MaterialTheme.typography.bodyMedium)
                                    Text(text = "${pair.second} Orders", style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Bold)
                                }
                            }
                        }
                    }
                }
            }

            // Export to CSV Button
            item {
                Button(
                    onClick = {
                        val csv = CsvExporter.exportOrdersToCsv(filteredOrders)
                        CsvExporter.shareCsvFile(context, "tekfix_orders_report.csv", csv)
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = TekfixGreen),
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(50.dp)
                ) {
                    Icon(Icons.Default.Download, contentDescription = null)
                    Spacer(modifier = Modifier.width(8.dp))
                    Text("റിപ്പോർട്ട് CSV ആയി ഡൗൺലോഡ് ചെയ്യുക (Export CSV)", fontWeight = FontWeight.Bold)
                }
            }

            item {
                Spacer(modifier = Modifier.height(20.dp))
            }
        }
    }
}
