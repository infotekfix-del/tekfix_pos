package com.tekfix.orders.util

import com.tekfix.orders.data.model.Product

data class CsvImportResult(
    val productsToImport: List<Product>,
    val duplicateSkusInFile: List<String>,
    val duplicateSkusInDb: List<String>,
    val errors: List<String>,
    val totalRowsProcessed: Int
) {
    val isSuccessful: Boolean get() = errors.isEmpty() && productsToImport.isNotEmpty()
    val summaryText: String
        get() = "Processed $totalRowsProcessed rows: ${productsToImport.size} valid products ready for import, " +
                "${duplicateSkusInFile.size} duplicates in file, ${duplicateSkusInDb.size} already exist in database."
}

object CsvProductImporter {

    /**
     * Parses CSV content string, validates headers, checks duplicates, and returns import result.
     */
    fun parseCsv(
        csvContent: String,
        existingSkus: Set<String> = emptySet()
    ): CsvImportResult {
        val lines = csvContent.lines().filter { it.isNotBlank() }
        if (lines.isEmpty()) {
            return CsvImportResult(emptyList(), emptyList(), emptyList(), listOf("File is empty"), 0)
        }

        val headerLine = lines.first()
        val headers = parseCsvRow(headerLine).map { it.trim().lowercase() }

        val nameIndex = headers.indexOfFirst { it == "name" || it == "product name" || it == "product" }
        if (nameIndex == -1) {
            return CsvImportResult(
                emptyList(),
                emptyList(),
                emptyList(),
                listOf("Missing required column: 'Name' or 'Product Name'. Found: ${headers.joinToString()}"),
                0
            )
        }

        val skuIndex = headers.indexOfFirst { it == "sku" || it == "code" || it == "product code" }
        val categoryIndex = headers.indexOfFirst { it == "category" }
        val modelIndex = headers.indexOfFirst { it == "model" }
        val variantIndex = headers.indexOfFirst { it == "variant" }
        val unitIndex = headers.indexOfFirst { it == "unit" }

        val products = mutableListOf<Product>()
        val seenSkusInFile = mutableSetOf<String>()
        val duplicateSkusInFile = mutableListOf<String>()
        val duplicateSkusInDb = mutableListOf<String>()
        val errors = mutableListOf<String>()

        var totalRows = 0

        for (i in 1 until lines.size) {
            val line = lines[i]
            totalRows++
            val row = parseCsvRow(line)
            if (row.isEmpty() || row.all { it.isBlank() }) continue

            val name = row.getOrNull(nameIndex)?.trim() ?: ""
            if (name.isBlank()) {
                errors.add("Row $i: Product name cannot be empty.")
                continue
            }

            val sku = if (skuIndex != -1) row.getOrNull(skuIndex)?.trim() ?: "" else ""
            val category = if (categoryIndex != -1) row.getOrNull(categoryIndex)?.trim() ?: "Others" else "Others"
            val model = if (modelIndex != -1) row.getOrNull(modelIndex)?.trim() ?: "" else ""
            val variant = if (variantIndex != -1) row.getOrNull(variantIndex)?.trim() ?: "" else ""
            val unit = if (unitIndex != -1 && !row.getOrNull(unitIndex).isNullOrBlank()) {
                row[unitIndex].trim()
            } else {
                "Pcs"
            }

            if (sku.isNotBlank()) {
                if (seenSkusInFile.contains(sku)) {
                    duplicateSkusInFile.add(sku)
                    errors.add("Row $i: Duplicate SKU '$sku' found in CSV file.")
                    continue
                }
                seenSkusInFile.add(sku)

                if (existingSkus.contains(sku)) {
                    duplicateSkusInDb.add(sku)
                    // We report it and skip to avoid silently overwriting
                    continue
                }
            }

            products.add(
                Product(
                    name = name,
                    sku = sku,
                    category = if (category.isBlank()) "Others" else category,
                    model = model,
                    variant = variant,
                    unit = unit,
                    inStock = true,
                    active = true
                )
            )
        }

        return CsvImportResult(
            productsToImport = products,
            duplicateSkusInFile = duplicateSkusInFile,
            duplicateSkusInDb = duplicateSkusInDb,
            errors = errors,
            totalRowsProcessed = totalRows
        )
    }

    /**
     * Splits a CSV row taking quoted fields into account.
     */
    private fun parseCsvRow(line: String): List<String> {
        val result = mutableListOf<String>()
        val sb = StringBuilder()
        var inQuotes = false
        var i = 0

        while (i < line.length) {
            val c = line[i]
            when {
                c == '\"' -> {
                    if (inQuotes && i + 1 < line.length && line[i + 1] == '\"') {
                        sb.append('\"')
                        i++ // Skip escaped quote
                    } else {
                        inQuotes = !inQuotes
                    }
                }
                c == ',' && !inQuotes -> {
                    result.add(sb.toString())
                    sb.clear()
                }
                else -> {
                    sb.append(c)
                }
            }
            i++
        }
        result.add(sb.toString())
        return result
    }
}
