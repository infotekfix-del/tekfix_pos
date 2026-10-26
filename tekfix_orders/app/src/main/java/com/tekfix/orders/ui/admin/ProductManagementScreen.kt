package com.tekfix.orders.ui.admin

import android.net.Uri
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.tekfix.orders.data.model.Product
import com.tekfix.orders.ui.components.EmptyStateView
import com.tekfix.orders.ui.components.TekfixSearchBar
import com.tekfix.orders.ui.components.TekfixTopAppBar
import com.tekfix.orders.ui.theme.*
import com.tekfix.orders.util.CsvExporter
import com.tekfix.orders.util.CsvImportResult

@Composable
fun ProductManagementScreen(
    adminViewModel: AdminViewModel,
    onNavigateBack: () -> Unit,
    isOffline: Boolean = false
) {
    val context = LocalContext.current
    val products by adminViewModel.productsFlow.collectAsState()
    val uiState by adminViewModel.uiState.collectAsState()

    var searchQuery by remember { mutableStateOf("") }
    var showAddDialog by remember { mutableStateOf(false) }
    var productToEdit by remember { mutableStateOf<Product?>(null) }
    var importPreviewResult by remember { mutableStateOf<CsvImportResult?>(null) }

    // File picker launcher for CSV import
    val csvPickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.GetContent()
    ) { uri: Uri? ->
        if (uri != null) {
            try {
                val inputStream = context.contentResolver.openInputStream(uri)
                val csvContent = inputStream?.bufferedReader()?.use { it.readText() } ?: ""
                adminViewModel.importProductsCsv(csvContent) { result ->
                    importPreviewResult = result
                }
            } catch (e: Exception) {
                Toast.makeText(context, "ഫയൽ തുറക്കുന്നതിൽ പരാജയപ്പെട്ടു: ${e.message}", Toast.LENGTH_LONG).show()
            }
        }
    }

    val filteredProducts = remember(products, searchQuery) {
        products.filter { p ->
            searchQuery.isBlank() ||
                    p.name.contains(searchQuery, ignoreCase = true) ||
                    p.sku.contains(searchQuery, ignoreCase = true) ||
                    p.category.contains(searchQuery, ignoreCase = true)
        }
    }

    // CSV Import Summary Modal
    if (importPreviewResult != null) {
        val result = importPreviewResult!!
        AlertDialog(
            onDismissRequest = { importPreviewResult = null },
            title = {
                Text(
                    text = "CSV ഇമ്പോർട്ട് സംഗ്രഹം (Import Summary)",
                    fontWeight = FontWeight.Bold
                )
            },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(result.summaryText, style = MaterialTheme.typography.bodyMedium)

                    if (result.duplicateSkusInDb.isNotEmpty()) {
                        Text(
                            text = "നിലവിലുള്ള SKUകൾ (Skipped to prevent overwrite): ${result.duplicateSkusInDb.take(5).joinToString()}",
                            color = StatusPending,
                            style = MaterialTheme.typography.bodySmall
                        )
                    }

                    if (result.errors.isNotEmpty()) {
                        Text(
                            text = "പിശകുകൾ (Errors):\n${result.errors.take(3).joinToString("\n")}",
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodySmall
                        )
                    }
                }
            },
            confirmButton = {
                Button(
                    onClick = {
                        adminViewModel.commitBatchImport(result.productsToImport) {
                            importPreviewResult = null
                        }
                    },
                    enabled = result.productsToImport.isNotEmpty(),
                    colors = ButtonDefaults.buttonColors(containerColor = TekfixGreen)
                ) {
                    Text("${result.productsToImport.size} പ്രൊഡക്റ്റുകൾ ഇമ്പോർട്ട് ചെയ്യുക (Confirm Import)")
                }
            },
            dismissButton = {
                TextButton(onClick = { importPreviewResult = null }) {
                    Text("റദ്ദാക്കുക (Cancel)")
                }
            }
        )
    }

    // Add / Edit Product Dialog
    if (showAddDialog || productToEdit != null) {
        ProductFormDialog(
            initialProduct = productToEdit,
            onDismiss = {
                showAddDialog = false
                productToEdit = null
            },
            onSave = { p ->
                if (productToEdit != null) {
                    adminViewModel.updateProduct(p) {
                        productToEdit = null
                    }
                } else {
                    adminViewModel.addProduct(p) {
                        showAddDialog = false
                    }
                }
            }
        )
    }

    Scaffold(
        topBar = {
            TekfixTopAppBar(
                title = "പ്രൊഡക്റ്റ് മാനേജ്മെന്റ്",
                subtitle = "${products.size} Products in Catalog",
                canNavigateBack = true,
                onNavigateBack = onNavigateBack,
                isOffline = isOffline,
                actions = {
                    IconButton(onClick = {
                        val csv = CsvExporter.exportProductsToCsv(products)
                        CsvExporter.shareCsvFile(context, "tekfix_products.csv", csv)
                    }) {
                        Icon(Icons.Default.Download, contentDescription = "Export CSV", tint = Color.White)
                    }
                    IconButton(onClick = { csvPickerLauncher.launch("*/*") }) {
                        Icon(Icons.Default.UploadFile, contentDescription = "Import CSV", tint = Color.White)
                    }
                }
            )
        },
        floatingActionButton = {
            FloatingActionButton(
                onClick = { showAddDialog = true },
                containerColor = TekfixGreen,
                contentColor = Color.White
            ) {
                Icon(Icons.Default.Add, contentDescription = "Add Product")
            }
        },
        containerColor = MaterialTheme.colorScheme.background
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
        ) {
            // Success / Error banner
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

            PaddingValues(horizontal = 16.dp, vertical = 8.dp).let {
                Box(modifier = Modifier.padding(it)) {
                    TekfixSearchBar(
                        query = searchQuery,
                        onQueryChange = { searchQuery = it },
                        placeholder = "Search products by name, SKU, or category..."
                    )
                }
            }

            if (filteredProducts.isEmpty()) {
                EmptyStateView(
                    icon = Icons.Default.Inventory2,
                    title = "പ്രൊഡക്റ്റുകൾ ലഭ്യമല്ല",
                    subtitle = "പുതിയ പ്രൊഡക്റ്റ് ചേർക്കാനോ CSV ഫയൽ ഇമ്പോർട്ട് ചെയ്യാനോ താഴെയുള്ള ബട്ടൺ ഉപയോഗിക്കുക.",
                    actionButtonText = "+ പ്രൊഡക്റ്റ് ചേർക്കുക",
                    onActionClick = { showAddDialog = true }
                )
            } else {
                LazyColumn(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(horizontal = 16.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                    contentPadding = PaddingValues(top = 4.dp, bottom = 80.dp)
                ) {
                    items(filteredProducts, key = { it.id }) { product ->
                        Card(
                            shape = RoundedCornerShape(14.dp),
                            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                            elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(14.dp),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Text(
                                            text = product.name,
                                            style = MaterialTheme.typography.titleMedium,
                                            fontWeight = FontWeight.Bold
                                        )
                                        if (!product.active) {
                                            Spacer(modifier = Modifier.width(6.dp))
                                            Surface(
                                                color = MaterialTheme.colorScheme.errorContainer,
                                                shape = RoundedCornerShape(4.dp)
                                            ) {
                                                Text(
                                                    text = "Deactivated",
                                                    color = MaterialTheme.colorScheme.onErrorContainer,
                                                    style = MaterialTheme.typography.labelSmall,
                                                    modifier = Modifier.padding(horizontal = 4.dp, vertical = 2.dp)
                                                )
                                            }
                                        }
                                    }
                                    Text(
                                        text = "${product.category} • SKU: ${product.sku.ifBlank { "N/A" }}",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = TextSecondary
                                    )
                                    if (product.model.isNotBlank()) {
                                        Text(
                                            text = "Model: ${product.model} (${product.unit})",
                                            style = MaterialTheme.typography.bodySmall,
                                            color = TextMuted
                                        )
                                    }
                                }

                                Row {
                                    IconButton(onClick = { productToEdit = product }) {
                                        Icon(Icons.Default.Edit, contentDescription = "Edit", tint = TekfixGreen)
                                    }
                                    IconButton(onClick = { adminViewModel.toggleProductActive(product.id, !product.active) }) {
                                        Icon(
                                            imageVector = if (product.active) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                                            contentDescription = if (product.active) "Deactivate" else "Activate",
                                            tint = if (product.active) StatusPending else TekfixGreen
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
}

@Composable
fun ProductFormDialog(
    initialProduct: Product?,
    onDismiss: () -> Unit,
    onSave: (Product) -> Unit
) {
    var name by remember { mutableStateOf(initialProduct?.name ?: "") }
    var sku by remember { mutableStateOf(initialProduct?.sku ?: "") }
    var category by remember { mutableStateOf(initialProduct?.category ?: "Tempered Glass") }
    var model by remember { mutableStateOf(initialProduct?.model ?: "") }
    var variant by remember { mutableStateOf(initialProduct?.variant ?: "") }
    var unit by remember { mutableStateOf(initialProduct?.unit ?: "Pcs") }
    var inStock by remember { mutableStateOf(initialProduct?.inStock ?: true) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(
                if (initialProduct != null) "പ്രൊഡക്റ്റ് എഡിറ്റ് ചെയ്യുക (Edit Product)" else "പുതിയ പ്രൊഡക്റ്റ് ചേർക്കുക (Add Product)",
                fontWeight = FontWeight.Bold
            )
        },
        text = {
            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("പ്രൊഡക്റ്റ് പേര് (Name) *") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = sku,
                    onValueChange = { sku = it },
                    label = { Text("SKU / കോഡ്") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = category,
                    onValueChange = { category = it },
                    label = { Text("കാറ്റഗറി (Category)") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = model,
                        onValueChange = { model = it },
                        label = { Text("മോഡൽ (Model)") },
                        singleLine = true,
                        modifier = Modifier.weight(1f)
                    )
                    OutlinedTextField(
                        value = unit,
                        onValueChange = { unit = it },
                        label = { Text("യൂണിറ്റ് (Unit)") },
                        singleLine = true,
                        modifier = Modifier.weight(1f)
                    )
                }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Checkbox(checked = inStock, onCheckedChange = { inStock = it })
                    Text("സ്റ്റോക്ക് ലഭ്യമാണ് (In Stock)", style = MaterialTheme.typography.bodyMedium)
                }
            }
        },
        confirmButton = {
            Button(
                onClick = {
                    if (name.isNotBlank()) {
                        val p = initialProduct?.copy(
                            name = name.trim(),
                            sku = sku.trim(),
                            category = category.trim(),
                            model = model.trim(),
                            variant = variant.trim(),
                            unit = unit.trim(),
                            inStock = inStock
                        ) ?: Product(
                            name = name.trim(),
                            sku = sku.trim(),
                            category = category.trim(),
                            model = model.trim(),
                            variant = variant.trim(),
                            unit = unit.trim(),
                            inStock = inStock
                        )
                        onSave(p)
                    }
                },
                colors = ButtonDefaults.buttonColors(containerColor = TekfixGreen)
            ) {
                Text("സേവ് ചെയ്യുക (Save)")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("റദ്ദാക്കുക (Cancel)")
            }
        }
    )
}
