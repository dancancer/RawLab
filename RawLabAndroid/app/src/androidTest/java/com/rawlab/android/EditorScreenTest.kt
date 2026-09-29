package com.rawlab.android

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.test.platform.app.InstrumentationRegistry
import android.net.Uri
import android.graphics.Bitmap
import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class EditorScreenTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    @Test fun emptyEditorOffersImportButCannotExport() {
        compose.onNodeWithText("打开 RAW 照片").assertIsDisplayed()
        compose.onNodeWithText("从文件导入").assertIsDisplayed()
        compose.onNodeWithContentDescription("导出").assertIsNotEnabled()
        capture("empty-editor.png")
    }

    @Test fun importedPhotoSurvivesRotationAndFailedImport() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val source = File(instrumentation.targetContext.cacheDir, "editor-test.ARW")
        instrumentation.context.assets.open("DSC09067.ARW").use { from -> source.outputStream().use { from.copyTo(it) } }
        var model = compose.activity.model
        compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
        compose.waitUntil(180_000) { model.state.value.canExport || model.state.value.error != null }
        assertNull(model.state.value.error)
        assertTrue(model.state.value.canExport)
        compose.onNode(SemanticsMatcher("render timing label") { node ->
            node.config.getOrNull(SemanticsProperties.Text)?.any { Regex("(?:GPU|CPU).*ms").matches(it.text) } == true
        }).assertDoesNotExist()
        val original = model.state.value.photo
        compose.runOnUiThread { model.edit(model.state.value.edits.copy(film = "velvia", exposure = .5f)) }
        compose.activityRule.scenario.recreate()
        compose.activityRule.scenario.onActivity { model = it.model }
        compose.waitUntil(180_000) { model.state.value.canExport || model.state.value.error != null }
        assertNull(model.state.value.error)
        assertEquals("velvia", model.state.value.edits.film)
        compose.onNodeWithText("强度").performClick()
        compose.onNodeWithTag("adjustment-slider").performSemanticsAction(SemanticsActions.SetProgress) { it(200f) }
        compose.waitUntil(180_000) { model.state.value.canExport || model.state.value.error != null }
        assertEquals(2f, model.state.value.edits.strength)
        assertNull(model.state.value.error)
        compose.onNodeWithContentDescription("对比").performClick()
        compose.onNodeWithTag("comparison-wipe").assertExists().performSemanticsAction(SemanticsActions.SetProgress) { it(.3f) }
        compose.onNodeWithContentDescription("收起调整").performClick()
        compose.onNodeWithText("色温").assertDoesNotExist()
        capture("editor-collapsed.png")
        compose.onNodeWithContentDescription("展开调整").performClick()
        compose.onNodeWithText("色温").performClick()
        compose.onNodeWithTag("adjustment-slider").assertIsDisplayed()
        compose.onNodeWithText("色调").performClick()
        compose.onNodeWithTag("adjustment-slider").assertIsDisplayed()
        capture("editor-tint.png")
        compose.onNodeWithText("胶片").performClick()
        compose.waitForIdle()
        capture("editor-comparison.png")
        val empty = File(instrumentation.targetContext.cacheDir, "empty-test.dng").apply { writeBytes(byteArrayOf()) }
        compose.runOnUiThread { model.importPhoto(Uri.fromFile(empty)) }
        compose.waitUntil(10_000) { model.state.value.operation == Operation.NONE }
        assertNotNull(model.state.value.error)
        assertEquals(original, model.state.value.photo)
        assertTrue(model.state.value.canExport)
        source.delete()
        empty.delete()
    }

    private fun capture(name: String) {
        compose.waitForIdle()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val output = File(instrumentation.targetContext.getExternalFilesDir(null), name)
        output.outputStream().use { compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
}
