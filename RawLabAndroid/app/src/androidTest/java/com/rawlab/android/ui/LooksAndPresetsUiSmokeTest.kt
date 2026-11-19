package com.rawlab.android.ui

import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import com.rawlab.android.MainActivity
import com.rawlab.android.R
import com.rawlab.android.adjustments.AdjustmentField
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.testing.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File
import java.util.UUID

class LooksAndPresetsUiSmokeTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule("zh-Hans")).around(ForegroundTestRule()).around(compose)

    private fun rasterFixture(name: String): File = File(compose.activity.cacheDir, "$name-${UUID.randomUUID()}.png").also { file ->
        Bitmap.createBitmap(64, 48, Bitmap.Config.ARGB_8888).let { bitmap ->
            bitmap.eraseColor(0xFF446688.toInt())
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
        }
    }

    @Test fun lookSearchAndMasterRecipeSwitchSmoke() {
        val source = rasterFixture("looks")
        val model = compose.activity.model
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            compose.waitUntilEditorReady(model)

            compose.openWorkbenchTool(0)
            compose.onNodeWithTag("looks.search.open").performScrollTo().performClick()
            compose.onNodeWithTag("looks.search").performScrollTo().performTextReplacement("ACROS")
            compose.onNodeWithTag("looks.search").performImeAction()
            compose.onNodeWithText("ACROS", substring = true).performScrollTo().performClick()
            compose.applyWorkbenchDraft(model)
            assertEquals("acros", model.state.value.edits.film)

            compose.openWorkbenchTool(15)
            compose.onNodeWithText("保井崇志").performScrollTo().performClick()
            compose.applyWorkbenchDraft(model)
            assertEquals("takashi_yasui_zen", model.state.value.edits.recipeID)
        } finally {
            EditStore(File(compose.activity.filesDir, "edits")).reset(PhotoIdentity(Uri.fromFile(source).toString()))
            source.delete()
        }
    }

    @Test fun quickPresetsCreateApplyAndManageSmoke() {
        val source = rasterFixture("presets")
        val model = compose.activity.model
        val originalIds = model.presetStore.list().map { it.id }.toSet()
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            compose.waitUntilEditorReady(model)
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = 0.5f)) }
            compose.waitUntilEditorReady(model)

            compose.openWorkbenchMenuItem("preset-menu")
            compose.onNodeWithTag("preset.quick.root").assertIsDisplayed()
            compose.onNodeWithTag("preset.quick.manage").performClick()
            compose.onNodeWithTag("preset-create").performClick()
            compose.onNodeWithTag("preset-name").performTextReplacement("Smoke Preset")
            compose.onNodeWithTag("preset-name").performImeAction()
            compose.onNodeWithTag("preset-save").performClick()
            compose.waitUntil(30_000) { !model.state.value.committingAdjustments }
            assertTrue(model.presetStore.list().any { it.name == "Smoke Preset" })
        } finally {
            model.presetStore.list().filter { it.id !in originalIds }.forEach { model.presetStore.delete(it) }
            EditStore(File(compose.activity.filesDir, "edits")).reset(PhotoIdentity(Uri.fromFile(source).toString()))
            source.delete()
        }
    }

    @Test fun adjustmentTransferSummaryAndPasteSmoke() {
        val first = rasterFixture("copy-src")
        val second = rasterFixture("paste-dst")
        val model = compose.activity.model
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(first)) }
            compose.waitUntilEditorReady(model)
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = 0.6f)) }
            compose.waitUntilEditorReady(model)

            compose.openWorkbenchMenuItem("adjustment-menu-copy")
            compose.onNodeWithTag("adjustment-copy-clear").performScrollTo().performClick()
            compose.onNodeWithTag("adjustment-group-light").performScrollTo().performClick()
            compose.onNodeWithTag("adjustment-field-light.exposure").performScrollTo().performClick()
            compose.onNodeWithTag("adjustment-copy-confirm").performScrollTo().performClick()
            compose.runOnIdle { assertEquals(setOf(AdjustmentField.EXPOSURE), model.adjustmentClipboard!!.fields) }

            compose.runOnUiThread { model.importPhoto(Uri.fromFile(second)) }
            compose.waitUntilEditorReady(model)
            compose.openWorkbenchMenuItem("adjustment-menu-paste")
            compose.onNodeWithTag("adjustment-paste-range").performScrollTo().performClick()
            compose.onNodeWithTag("adjustment-summary-group-light").performScrollTo().performClick()
            compose.onNodeWithTag("adjustment-summary-value-light.exposure").assertTextEquals("+0.60 EV")
            compose.waitUntil(30_000) { model.adjustmentTransfer.value.prepared != null }
            compose.onNodeWithTag("adjustment-paste-apply").performScrollTo().assertIsEnabled().performClick()
            compose.waitUntilEditorReady(model)
            assertEquals(0.6f, model.state.value.edits.exposure, 0.001f)
            compose.onNodeWithTag("adjustment-transfer-close").performClick()
        } finally {
            EditStore(File(compose.activity.filesDir, "edits")).reset(PhotoIdentity(Uri.fromFile(first).toString()))
            EditStore(File(compose.activity.filesDir, "edits")).reset(PhotoIdentity(Uri.fromFile(second).toString()))
            first.delete()
            second.delete()
        }
    }
}
