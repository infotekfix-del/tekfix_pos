package com.tekfix.orders.ui.staff

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
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
import com.tekfix.orders.data.model.Product
import com.tekfix.orders.data.model.User
import com.tekfix.orders.ui.components.EmptyStateView
import com.tekfix.orders.ui.components.TekfixSearchBar
import com.tekfix.orders.ui.components.TekfixTopAppBar
import com.tekfix.orders.ui.theme.*

@Composable
fun NewOrderScreen(
    currentUser: User,
    orderViewModel: OrderViewModel,
    onNavigateBack: () -> Unit,
    onNavigateToCart: () -> Unit,
    isOffline: Boolean = false
) {
    val orderState by orderViewModel.orderState.collectAsState()
    val catalogProducts by orderViewModel.productsFlow.collectAsState()

    var selectedTab by remember { mutableIntStateOf(0) } // 0: Catalog, 1: Custom Product
    var searchQuery by remember { mutableStateOf("") }
    var selectedCategory by remember { mutableStateOf("All") }

    // Custom Product Form States
    var customName by remember { mutableStateOf("") }
    var customModel by remember { mutableStateOf("") }
    var customQtyStr by remember { mutableStateOf("1") }
    var customUnit by remember { mutableStateOf("Pcs") }
    var customRemarks by remember { mutableStateOf("") }
    var customError by remember { mutableStateOf<String?>(null) }

    val categories = remember(catalogProducts) {
        listOf("All") + catalogProducts.map { it.category }.distinct().filter { it.isNotBlank() }
    }

    val filteredProducts = remember(catalogProducts, searchQuery, selectedCategory) {
        catalogProducts.filter { p ->
            val matchesCategory = selectedCategory == "All" || p.category.equals(selectedCategory, ignoreCase = true)
            val matchesQuery = searchQuery.isBlank() ||
                    p.name.contains(searchQuery, ignoreCase = true) ||
                    p.sku.contains(searchQuery, ignoreCase = true) ||
                    p.model.contains(searchQuery, ignoreCase = true)
            matchesCategory && matchesQuery
        }
    }

    Scaffold(
        topBar = {
            TekfixTopAppBar(
                title = "പുതിയ ഓർഡർ (New Order)",
                subtitle = orderState.orderId,
                canNavigateBack = true,
                onNavigateBack = onNavigateBack,
                isOffline = isOffline,
                actions = {
                    if (orderState.hasDraft) {
                        IconButton(onClick = { orderViewModel.clearDraftAndReset(currentUser) }) {
                            Icon(Icons.Default.DeleteOutline, contentDescription = "Clear Draft", tint = Color.White)
                        }
                    }
                }
            )
        },
        bottomBar = {
            // Floating Order Cart Summary Bar
            if (orderState.cartProducts.isNotEmpty()) {
                Surface(
                    color = MaterialTheme.colorScheme.surface,
                    shadowElevation = 8.dp,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 12.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column {
                            Text(
                                text = "${orderState.totalTypes} Types • ${orderState.totalQuantity} Pcs",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold,
                                color = TekfixDarkGreen
                            )
                            Text(
                                text = "കാർട്ടിൽ ചേർത്തവ (Items in Cart)",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }

                        Button(
                            onClick = onNavigateToCart,
                            colors = ButtonDefaults.buttonColors(containerColor = TekfixGreen),
                            shape = RoundedCornerShape(12.dp)
                        ) {
                            Icon(Icons.Default.ShoppingCart, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(modifier = Modifier.width(8.dp))
                            Text("കാർട്ട് കാണുക (View Cart)", fontWeight = FontWeight.Bold)
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
        ) {
            // Top Order Information Banner (Section 6)
            Card(
                shape = RoundedCornerShape(0.dp),
                colors = CardDefaults.cardColors(containerColor = TekfixLightGreen),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Text(
                        text = "NEW PRODUCT ORDER",
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Bold,
                        color = TekfixDarkGreen
                    )
                    Spacer(modifier = Modifier.height(4.dp))
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text(
                            text = "Order ID: ${orderState.orderId}",
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.Bold,
                            color = TekfixDarkGreen
                        )
                        Text(
                            text = "${orderState.orderDate} • ${orderState.orderTime}",
                            style = MaterialTheme.typography.bodySmall,
                            color = TextSecondary
                        )
                    }
                    Text(
                        text = "Staff: ${orderState.staffName}",
                        style = MaterialTheme.typography.bodySmall,
                        color = TextSecondary
                    )
                }
            }

            // Tab Navigation: Catalog vs Custom Product
            TabRow(
                selectedTabIndex = selectedTab,
                containerColor = MaterialTheme.colorScheme.surface,
                contentColor = TekfixGreen
            ) {
                Tab(
                    selected = selectedTab == 0,
                    onClick = { selectedTab = 0 },
                    text = {
                        Text(
                            "കാറ്റലോഗ് (Catalog)",
                            fontWeight = if (selectedTab == 0) FontWeight.Bold else FontWeight.Normal
                        )
                    },
                    icon = { Icon(Icons.Default.Inventory2, contentDescription = null, modifier = Modifier.size(18.dp)) }
                )
                Tab(
                    selected = selectedTab == 1,
                    onClick = { selectedTab = 1 },
                    text = {
                        Text(
                            "+ കസ്റ്റം പ്രൊഡക്റ്റ് (+ Custom)",
                            fontWeight = if (selectedTab == 1) FontWeight.Bold else FontWeight.Normal
                        )
                    },
                    icon = { Icon(Icons.Default.AddCircleOutline, contentDescription = null, modifier = Modifier.size(18.dp)) }
                )
            }

            if (selectedTab == 0) {
                // METHOD A: SELECT FROM PRODUCT CATALOG
                Column(modifier = Modifier.fillMaxSize()) {
                    // Search Bar
                    PaddingValues(horizontal = 16.dp, vertical = 8.dp).let {
                        Box(modifier = Modifier.padding(it)) {
                            TekfixSearchBar(
                                query = searchQuery,
                                onQueryChange = { searchQuery = it },
                                placeholder = "Search by name, SKU or model..."
                            )
                        }
                    }

                    // Category Filter Chips
                    LazyRow(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 4.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        items(categories) { cat ->
                            FilterChip(
                                selected = selectedCategory == cat,
                                onClick = { selectedCategory = cat },
                                label = { Text(cat) },
                                colors = FilterChipDefaults.filterChipColors(
                                    selectedContainerColor = TekfixGreen,
                                    selectedLabelColor = Color.White
                                )
                            )
                        }
                    }

                    // Product List
                    if (filteredProducts.isEmpty()) {
                        EmptyStateView(
                            icon = Icons.Default.SearchOff,
                            title = "പ്രൊഡക്റ്റുകൾ ലഭ്യമല്ല",
                            subtitle = "തിരഞ്ഞ വാക്കിന് അനുയോജ്യമായ പ്രൊഡക്റ്റുകൾ കണ്ടെത്തിയില്ല.\nകസ്റ്റം പ്രൊഡക്റ്റ് ടാബ് വഴി നേരിട്ട് നൽകാവുന്നതാണ്.",
                            actionButtonText = "+ കസ്റ്റം പ്രൊഡക്റ്റ് ചേർക്കുക",
                            onActionClick = { selectedTab = 1 }
                        )
                    } else {
                        LazyColumn(
                            modifier = Modifier
                                .fillMaxWidth()
                                .weight(1f)
                                .padding(horizontal = 16.dp),
                            verticalArrangement = Arrangement.spacedBy(10.dp),
                            contentPadding = PaddingValues(vertical = 10.dp)
                        ) {
                            items(filteredProducts, key = { it.id }) { product ->
                                CatalogProductCard(
                                    product = product,
                                    onAddToCart = { qty, remarks ->
                                        orderViewModel.addCatalogProduct(product, qty, remarks)
                                    }
                                )
                            }
                        }
                    }
                }
            } else {
                // METHOD B: ADD CUSTOM PRODUCT
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(20.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp)
                ) {
                    Text(
                        text = "കസ്റ്റം പ്രൊഡക്റ്റ് ചേർക്കുക (Add Custom Product)",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurface
                    )

                    if (customError != null) {
                        Surface(
                            color = MaterialTheme.colorScheme.errorContainer,
                            shape = RoundedCornerShape(8.dp),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Text(
                                text = customError ?: "",
                                color = MaterialTheme.colorScheme.onErrorContainer,
                                style = MaterialTheme.typography.bodySmall,
                                modifier = Modifier.padding(10.dp)
                            )
                        }
                    }

                    OutlinedTextField(
                        value = customName,
                        onValueChange = {
                            customName = it
                            customError = null
                        },
                        label = { Text("പ്രൊഡക്റ്റ് പേര് (Product Name) *") },
                        placeholder = { Text("e.g. iPhone 15 Pro Max Back Glass") },
                        singleLine = true,
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth()
                    )

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        OutlinedTextField(
                            value = customModel,
                            onValueChange = { customModel = it },
                            label = { Text("മോഡൽ / വേരിയന്റ് (Model / Variant)") },
                            placeholder = { Text("e.g. Black / 256GB") },
                            singleLine = true,
                            shape = RoundedCornerShape(12.dp),
                            modifier = Modifier.weight(1.5f)
                        )

                        OutlinedTextField(
                            value = customQtyStr,
                            onValueChange = { customQtyStr = it.filter { c -> c.isDigit() } },
                            label = { Text("അളവ് (Qty) *") },
                            singleLine = true,
                            shape = RoundedCornerShape(12.dp),
                            modifier = Modifier.weight(1f)
                        )
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        OutlinedTextField(
                            value = customUnit,
                            onValueChange = { customUnit = it },
                            label = { Text("യൂണിറ്റ് (Unit)") },
                            placeholder = { Text("Pcs, Box, Set") },
                            singleLine = true,
                            shape = RoundedCornerShape(12.dp),
                            modifier = Modifier.weight(1f)
                        )

                        OutlinedTextField(
                            value = customRemarks,
                            onValueChange = { customRemarks = it },
                            label = { Text("റിമാർക്ക്സ് (Remarks)") },
                            placeholder = { Text("e.g. Urgent / Original") },
                            singleLine = true,
                            shape = RoundedCornerShape(12.dp),
                            modifier = Modifier.weight(1.5f)
                        )
                    }

                    Spacer(modifier = Modifier.height(10.dp))

                    Button(
                        onClick = {
                            val qty = customQtyStr.toIntOrNull() ?: 1
                            val success = orderViewModel.addCustomProduct(
                                name = customName,
                                model = customModel,
                                quantity = qty,
                                unit = customUnit,
                                remarks = customRemarks
                            )
                            if (success) {
                                customName = ""
                                customModel = ""
                                customQtyStr = "1"
                                customRemarks = ""
                                customError = null
                                selectedTab = 0 // Switch back to catalog or show added feedback
                            } else {
                                customError = "പ്രൊഡക്റ്റ് പേര് നൽകേണ്ടതാണ് (Product name is required)"
                            }
                        },
                        colors = ButtonDefaults.buttonColors(containerColor = TekfixGreen),
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(50.dp)
                    ) {
                        Icon(Icons.Default.Add, contentDescription = null)
                        Spacer(modifier = Modifier.width(8.dp))
                        Text("+ കസ്റ്റം പ്രൊഡക്റ്റ് കാർട്ടിലേക്ക് ചേർക്കുക", fontWeight = FontWeight.Bold)
                    }
                }
            }
        }
    }
}

@Composable
fun CatalogProductCard(
    product: Product,
    onAddToCart: (Int, String) -> Unit
) {
    var quantity by remember { mutableIntStateOf(1) }
    var remarks by remember { mutableStateOf("") }
    var showRemarksField by remember { mutableStateOf(false) }

    Card(
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(modifier = Modifier.padding(14.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = product.name,
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                    if (product.model.isNotBlank()) {
                        Text(
                            text = "Model: ${product.model}",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    if (product.sku.isNotBlank()) {
                        Text(
                            text = "SKU: ${product.sku}",
                            style = MaterialTheme.typography.labelSmall,
                            color = TextMuted
                        )
                    }
                }

                Surface(
                    color = if (product.inStock) TekfixLightGreen else Color(0xFFFFEBEE),
                    shape = RoundedCornerShape(8.dp)
                ) {
                    Text(
                        text = if (product.inStock) "In Stock" else "Low Stock",
                        color = if (product.inStock) TekfixDarkGreen else Color(0xFFC62828),
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp)
                    )
                }
            }

            if (showRemarksField) {
                Spacer(modifier = Modifier.height(8.dp))
                OutlinedTextField(
                    value = remarks,
                    onValueChange = { remarks = it },
                    placeholder = { Text("പ്രത്യേക നിർദ്ദേശങ്ങൾ (Item remarks)...", style = MaterialTheme.typography.bodySmall) },
                    singleLine = true,
                    shape = RoundedCornerShape(10.dp),
                    modifier = Modifier.fillMaxWidth()
                )
            }

            Spacer(modifier = Modifier.height(10.dp))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                // Quantity Stepper
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(
                        onClick = { if (quantity > 1) quantity-- },
                        modifier = Modifier
                            .size(32.dp)
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.surfaceVariant)
                    ) {
                        Icon(Icons.Default.Remove, contentDescription = "Decrease", modifier = Modifier.size(16.dp))
                    }

                    Text(
                        text = "$quantity ${product.unit}",
                        fontWeight = FontWeight.Bold,
                        style = MaterialTheme.typography.titleSmall,
                        modifier = Modifier.padding(horizontal = 10.dp)
                    )

                    IconButton(
                        onClick = { quantity++ },
                        modifier = Modifier
                            .size(32.dp)
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.surfaceVariant)
                    ) {
                        Icon(Icons.Default.Add, contentDescription = "Increase", modifier = Modifier.size(16.dp))
                    }
                }

                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = { showRemarksField = !showRemarksField }) {
                        Icon(
                            imageVector = Icons.Default.EditNote,
                            contentDescription = "Remarks",
                            tint = if (remarks.isNotBlank()) TekfixGreen else MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }

                    Button(
                        onClick = {
                            onAddToCart(quantity, remarks)
                            remarks = ""
                            showRemarksField = false
                            quantity = 1
                        },
                        colors = ButtonDefaults.buttonColors(containerColor = TekfixGreen),
                        shape = RoundedCornerShape(10.dp),
                        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 6.dp)
                    ) {
                        Text("+ കാർട്ടിലേക്ക് (+ Add)", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold)
                    }
                }
            }
        }
    }
}
