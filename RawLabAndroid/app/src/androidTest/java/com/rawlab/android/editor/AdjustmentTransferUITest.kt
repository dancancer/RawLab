package com.rawlab.android.editor

import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import com.rawlab.android.MainActivity
import com.rawlab.android.R
import com.rawlab.android.adjustments.AdjustmentField
import com.rawlab.android.settings.EditStore
import com.rawlab.android.testing.ForegroundTestRule
import com.rawlab.android.testing.LanguageTestRule
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File

class AdjustmentTransferUITest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule()).around(ForegroundTestRule()).around(compose)
    private val model get() = compose.activity.model
    private fun ready() {
        compose.waitUntil(60_000) { model.state.value.let { (it.canExport && !it.previewResizePending) || it.error != null } }
        assertNull(model.state.value.error)
    }
    private fun fixture(name: String): File = File(compose.activity.cacheDir, "$name-${System.nanoTime()}.png").also { file ->
        Bitmap.createBitmap(40, 30, Bitmap.Config.ARGB_8888).apply { eraseColor(0xff777777.toInt()) }.let { bitmap ->
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
        }
    }
    private fun openMenu(tag: String) {
        compose.onNode(hasContentDescription(compose.activity.getString(R.string.more)) and !hasAnyAncestor(hasTestTag("adjustment-dock"))).performClick()
        compose.onNodeWithTag(tag).performScrollTo().performClick()
    }
    private fun screenshot(name: String) {
        val file = File(compose.activity.getExternalFilesDir(null), "adjustment-transfer/$name.png")
        file.parentFile!!.mkdirs()
        file.outputStream().use { compose.onNodeWithTag("adjustment-transfer-root").captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
    @Test fun customClipboardIsFrozenAndPasteUndoRedoUsesSavedHistory() {
        val first = fixture("copy-source"); val second = fixture("paste-target")
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(first)) }; ready()
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = .6f, contrast = .17f)) }; ready()
            openMenu("adjustment-menu-copy")
            compose.onNodeWithTag("adjustment-copy-clear").performScrollTo().performClick()
            compose.onNodeWithTag("adjustment-group-light").performScrollTo().performClick()
            compose.onNodeWithTag("adjustment-field-light.exposure").performScrollTo().performClick()
            screenshot("copy-custom")
            compose.onNodeWithTag("adjustment-copy-confirm").performScrollTo().performClick()
            compose.runOnIdle { assertEquals(setOf(AdjustmentField.EXPOSURE), model.adjustmentClipboard!!.fields) }
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = 1.2f)) }; ready()
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(second)) }; ready()
            openMenu("adjustment-menu-paste")
            compose.onNodeWithTag("adjustment-paste-range").performScrollTo().performClick()
            compose.onNodeWithTag("adjustment-summary-count").assertTextContains("1", substring = true)
            compose.onNodeWithTag("adjustment-summary-group-light").performScrollTo().performClick()
            compose.onNodeWithTag("adjustment-summary-value-light.exposure").assertTextEquals("+0.60 EV")
            screenshot("paste-summary-frozen-value")
            compose.onNodeWithTag("adjustment-paste-preflight").assertDoesNotExist()
            compose.waitUntil(30_000) { model.adjustmentTransfer.value.prepared != null }
            compose.onNodeWithTag("adjustment-paste-apply").performScrollTo().assertIsEnabled().performClick()
            ready()
            compose.runOnIdle { assertEquals(.6f, model.state.value.edits.exposure); assertEquals(0f, model.state.value.edits.contrast) }
            screenshot("paste-result")
            compose.onNodeWithTag("adjustment-transfer-close").performClick()
            openMenu("adjustment-menu-undo"); ready()
            compose.runOnIdle { assertEquals(0f, model.state.value.edits.exposure) }
            openMenu("adjustment-menu-redo"); ready()
            compose.runOnIdle { assertEquals(.6f, model.state.value.edits.exposure) }
            openMenu("adjustment-menu-history")
            compose.onNodeWithTag("adjustment-history-list").assertExists()
            screenshot("history")
            compose.onNodeWithTag("adjustment-transfer-close").performClick()
        } finally { first.delete(); second.delete() }
    }
    @Test fun draftDecisionAndConflictReloadPreserveExplicitUserChoice() {
        val source = fixture("draft-reload")
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }; ready()
            compose.runOnUiThread {
                model.beginDraft(AdjustmentGroup.GEOMETRY)
                model.changeDraft(model.state.value.visibleEdits.copy(geometry = model.state.value.visibleEdits.geometry.copy(cropWidth = .8f)))
            }
            compose.waitUntil(30_000) { model.state.value.draftReady }
            openMenu("adjustment-menu-copy")
            compose.onNodeWithText("继续编辑").performClick()
            compose.runOnIdle { assertNotNull(model.state.value.draft) }
            openMenu("adjustment-menu-copy")
            compose.onNode(hasText("应用") and hasAnyAncestor(isDialog())).performClick()
            compose.onNodeWithTag("adjustment-copy-clear").performScrollTo().performClick()
            compose.onNodeWithTag("adjustment-group-color").performScrollTo().performClick()
            compose.onNodeWithTag("adjustment-axis-0").performScrollTo().performClick()
            compose.onNodeWithTag("adjustment-field-color.hsl.hue.red").performScrollTo().performClick()
            screenshot("copy-hsl")
            compose.onNodeWithTag("adjustment-copy-confirm").performScrollTo().performClick()
            ready()
            compose.runOnIdle {
                assertNull(model.state.value.draft)
                assertEquals(.8f, model.state.value.edits.geometry.cropWidth)
                assertEquals(setOf(AdjustmentField.HSL_HUE_RED), model.adjustmentClipboard!!.fields)
            }
            val count = model.adjustmentTransactions.size
            val store = EditStore(File(compose.activity.filesDir, "edits"))
            val identity = model.state.value.photo!!.identity
            val saved = model.state.value.edits.copy(contrast = .3f)
            store.save(identity, saved)
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = 1.4f)) }
            compose.waitUntil(30_000) { !model.state.value.rendering }
            compose.runOnIdle { assertTrue(model.adjustmentReloadRequired); assertEquals(EditSaveState.FAILED, model.state.value.saveState) }
            compose.onNodeWithTag("edit-save-retry").performClick()
            compose.onNodeWithText("取消").performClick()
            compose.runOnIdle { assertEquals(1.4f, model.state.value.edits.exposure) }
            compose.onNodeWithTag("edit-save-retry").performClick()
            compose.onNodeWithTag("adjustment-reload-confirm").performClick()
            ready()
            compose.runOnIdle {
                assertEquals(saved, model.state.value.edits)
                assertEquals(count, model.adjustmentTransactions.size)
                assertFalse(model.adjustmentReloadRequired)
            }
        } finally { source.delete() }
    }
    @Test fun cancelledRulerRestoresEntryAndReleaseMakesOneHistoryItem() {
        val source = fixture("gesture-source")
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }; ready()
            compose.onNodeWithTag("editor-groups").performScrollToNode(hasTestTag("editor-group-light"))
            compose.onNodeWithTag("editor-group-light").performClick()
            compose.onNodeWithTag("editor-tools").performScrollToNode(hasTestTag("editor-tool-2"))
            compose.onNodeWithTag("editor-tool-2").performClick()
            val before = model.state.value.edits
            val count = model.adjustmentTransactions.size
            val slider = compose.onNodeWithTag("adjustment-slider")
            slider.performTouchInput { down(center); moveBy(Offset(42f, 0f)); cancel() }; ready()
            compose.runOnIdle { assertEquals(before, model.state.value.edits); assertEquals(count, model.adjustmentTransactions.size) }
            slider.performTouchInput { down(center); moveBy(Offset(28f, 0f)); moveBy(Offset(18f, 0f)); up() }; ready()
            compose.runOnIdle { assertNotEquals(before.exposure, model.state.value.edits.exposure); assertEquals(count + 1, model.adjustmentTransactions.size) }
        } finally { source.delete() }
    }
}
