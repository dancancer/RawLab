package com.rawlab.android.testing

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.ComposeTestRule

class ExportRobot(private val compose: ComposeTestRule) {
    fun assertSaveNoticeDisplayed() {
        compose.onNodeWithTag("edit-save-notice").assertIsDisplayed()
    }

    fun assertSaveNoticeAbsent() {
        compose.onNodeWithTag("edit-save-notice").assertDoesNotExist()
    }

    fun retrySave() {
        compose.onNodeWithTag("edit-save-retry").assertIsDisplayed().assertHasClickAction().performClick()
    }

    fun openExportSheet(exportLabel: String) {
        compose.onNodeWithContentDescription(exportLabel).assertIsEnabled().performClick()
        compose.onNodeWithTag("export-format-JPEG").assertIsDisplayed()
    }
}
