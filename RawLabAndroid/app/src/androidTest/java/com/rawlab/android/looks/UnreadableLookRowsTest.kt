package com.rawlab.android.looks

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.R
import com.rawlab.android.editor.ui.UnreadableLookRows
import com.rawlab.android.engine.LookFormat
import com.rawlab.android.engine.LookValidation
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.Properties
import java.util.UUID

class UnreadableLookRowsTest {
    @get:Rule val compose = createComposeRule()

    @Test fun badRowsShowReasonConfirmDeletionAndKeepSiblingAndValidLook() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.cacheDir, "unreadable-look-ui-${UUID.randomUUID()}")
        val validator = LookValidator { LookValidation(LookFormat.CUBE, 0) }
        try {
            val library = LookLibrary(root, validator)
            val valid = library.importLook("valid".byteInputStream(), "Good.cube")
            val registry = File(root, "registry.properties")
            val properties = Properties().apply { registry.inputStream().use { load(it) } }
            properties.setProperty("count", "3")
            properties.setProperty("item.1.name", "Future look")
            properties.setProperty("item.1.id", valid.id)
            properties.setProperty("item.1.path", valid.relativePath)
            properties.setProperty("item.1.version", "99")
            properties.setProperty("item.2.name", "Sibling look")
            registry.outputStream().use { properties.store(it, null) }
            val rows = mutableStateOf(LookLibraryEntries.load(library))
            compose.setContent {
                MaterialTheme {
                    UnreadableLookRows(rows.value.unreadable, true) { entry ->
                        rows.value = LookLibraryEntries.removeUnreadable(library, entry)
                    }
                }
            }
            compose.onNodeWithText("Future look").assertIsDisplayed()
            compose.onNodeWithText("Sibling look").assertIsDisplayed()
            compose.onAllNodesWithText(context.getString(R.string.look_unreadable_reason)).assertCountEquals(2)
            File(context.getExternalFilesDir(null), "unreadable-looks.png").outputStream().use {
                InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot().compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
            }
            compose.onAllNodesWithTag("looks.deleteUnreadable")[0].performClick()
            compose.onNodeWithText(context.getString(R.string.cancel)).performClick()
            compose.onAllNodesWithTag("looks.rowUnreadable").assertCountEquals(2)
            assertEquals(2, library.listUnreadable().size)
            compose.onAllNodesWithTag("looks.deleteUnreadable")[0].performClick()
            compose.onNodeWithTag("looks.deleteUnreadable.confirm").performClick()
            compose.onNodeWithText("Future look").assertDoesNotExist()
            compose.onNodeWithText("Sibling look").assertIsDisplayed()
            assertEquals(listOf(valid.id), LookLibrary(root, validator).list().map { it.id })
            assertTrue(valid.file(root).isFile)
            assertEquals(listOf("Sibling look"), LookLibrary(root, validator).listUnreadable().map { it.name })
            compose.onNodeWithTag("looks.deleteUnreadable").performClick()
            compose.onNodeWithTag("looks.deleteUnreadable.confirm").performClick()
            compose.onNodeWithTag("looks.unreadable").assertDoesNotExist()
            assertTrue(LookLibrary(root, validator).listUnreadable().isEmpty())
        } finally { root.deleteRecursively() }
    }
}
