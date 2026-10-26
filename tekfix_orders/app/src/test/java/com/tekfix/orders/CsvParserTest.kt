package com.tekfix.orders

import com.tekfix.orders.util.CsvProductImporter
import org.junit.Assert.*
import org.junit.Test

class CsvParserTest {

    @Test
    fun testParseCsv_validAndDuplicates() {
        val csv = """
            Name,SKU,Category,Model,Unit
            iPhone 15 Case,SKU-001,Cases,iPhone 15,Pcs
            Type-C Cable,SKU-002,Cables,Fast,Pcs
            Duplicate Item,SKU-001,Others,V1,Pcs
            Existing Item,SKU-999,Others,V2,Pcs
        """.trimIndent()

        val existingSkus = setOf("SKU-999")
        val result = CsvProductImporter.parseCsv(csv, existingSkus)

        assertEquals(2, result.productsToImport.size)
        assertEquals("iPhone 15 Case", result.productsToImport[0].name)
        assertEquals("Type-C Cable", result.productsToImport[1].name)

        assertEquals(1, result.duplicateSkusInFile.size)
        assertEquals("SKU-001", result.duplicateSkusInFile[0])

        assertEquals(1, result.duplicateSkusInDb.size)
        assertEquals("SKU-999", result.duplicateSkusInDb[0])
    }

    @Test
    fun testParseCsv_missingNameColumn() {
        val invalidCsv = """
            ItemCode,Category,Price
            123,Cases,100
        """.trimIndent()

        val result = CsvProductImporter.parseCsv(invalidCsv)
        assertFalse(result.isSuccessful)
        assertTrue(result.errors.any { it.contains("Missing required column") })
    }
}
