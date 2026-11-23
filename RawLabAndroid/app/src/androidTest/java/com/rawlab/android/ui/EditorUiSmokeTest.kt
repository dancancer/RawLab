package com.rawlab.android.ui

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.MainActivity
import com.rawlab.android.R
import com.rawlab.android.RawLabTheme
import com.rawlab.android.editor.EditSaveState
import com.rawlab.android.editor.EditorState
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.editor.ui.EditorScreen
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.testing.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File
import java.util.UUID

class EditorUiSmokeTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule("zh-Hans")).around(ForegroundTestRule()).around(compose)

    private fun rasterFixture(name: String): File = File(compose.activity.cacheDir, "$name-${UUID.randomUUID()}.png").also { file ->
        Bitmap.createBitmap(96, 64, Bitmap.Config.ARGB_8888).let { bitmap ->
            bitmap.eraseColor(0xFF336699.toInt())
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
        }
    }

    @Test fun emptyEditorAboutAndLicensesSmoke() {
        compose.onNodeWithContentDescription(compose.activity.getString(R.string.export)).assertIsNotEnabled()
        compose.openEditorMenu()
        compose.onNodeWithText(compose.activity.getString(R.string.licenses)).performScrollTo().performClick()
        compose.waitUntil(15_000) {
            compose.onAllNodes(hasText("GLib-COPYING", substring = true)).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText(compose.activity.getString(R.string.confirm)).performClick()
        compose.openEditorMenu()
        compose.onNodeWithText(compose.activity.getString(R.string.about_rawlab)).performScrollTo().performClick()
        val version = compose.activity.packageManager.getPackageInfo(compose.activity.packageName, 0).versionName
        compose.onNodeWithText("版本 $version").assertIsDisplayed()
        compose.onNodeWithText(compose.activity.getString(R.string.confirm)).performClick()
    }

    @Test fun workbenchGroupsToolsDraftApplyCancelUndoRedoResetSmoke() {
        val source = rasterFixture("workbench")
        val model = compose.activity.model
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            compose.waitUntilEditorReady(model)

            compose.openWorkbenchTool(2)
            compose.setNumericAdjustmentValue(R.string.exposure, "0.45")
            compose.waitUntilDraftReady(model)
            assertEquals(0.45f, model.state.value.visibleEdits.exposure, 0.001f)
            assertEquals(0f, model.state.value.edits.exposure, 0.001f)

            compose.cancelWorkbenchDraft(model)
            assertEquals(0f, model.state.value.edits.exposure, 0.001f)

            compose.openWorkbenchTool(2)
            compose.setNumericAdjustmentValue(R.string.exposure, "0.60")
            compose.applyWorkbenchDraft(model)
            assertEquals(0.60f, model.state.value.edits.exposure, 0.001f)

            compose.onNodeWithTag("workspace-undo").assertIsEnabled().performClick()
            compose.waitUntilEditorReady(model)
            assertEquals(0f, model.state.value.edits.exposure, 0.001f)
            compose.onNodeWithTag("workspace-redo").assertIsEnabled().performClick()
            compose.waitUntilEditorReady(model)
            assertEquals(0.60f, model.state.value.edits.exposure, 0.001f)
        } finally {
            EditStore(File(compose.activity.filesDir, "edits")).reset(PhotoIdentity(Uri.fromFile(source).toString()))
            source.delete()
        }
    }

    @Test fun compactPortraitAndLandscapeOrientationWithFineModeSmoke() {
        val source = rasterFixture("rotation")
        val model = compose.activity.model
        val originalOrientation = compose.activity.requestedOrientation
        try {
            compose.runOnUiThread {
                compose.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                model.setGpuEnabled(false)
                model.importPhoto(Uri.fromFile(source))
            }
            compose.waitUntilEditorReady(model)
            compose.openWorkbenchTool(2)
            compose.toggleWorkbenchFine()
            compose.assertWorkbenchFine(true)
            compose.toggleWorkbenchHistogram()
            compose.onNodeWithTag("rgb-histogram-popup").assertIsDisplayed()
            compose.onNodeWithTag("rgb-histogram-plot").assertIsDisplayed()

            compose.runOnUiThread { compose.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
            compose.waitUntil(20_000) { compose.activity.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE }
            compose.assertWorkbenchFine(true)
            compose.onNodeWithTag("adjustment-dock").assertIsDisplayed()
            compose.onNodeWithTag("editor-canvas").assertIsDisplayed()
            compose.cancelWorkbenchDraft(model)
        } finally {
            compose.runOnUiThread { compose.activity.requestedOrientation = originalOrientation }
            EditStore(File(compose.activity.filesDir, "edits")).reset(PhotoIdentity(Uri.fromFile(source).toString()))
            source.delete()
        }
    }

    @Test fun advancedControlsToneCurveHslGradingDenoiseEffectsLensSmoke() {
        val source = File(compose.activity.cacheDir, "controls-${UUID.randomUUID()}.RAW")
        InstrumentationRegistry.getInstrumentation().context.assets.open("sample.RAW").use { input ->
            source.outputStream().use { input.copyTo(it) }
        }
        val model = compose.activity.model
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            compose.waitUntilEditorReady(model)

            compose.openWorkbenchTool(6)
            compose.onNodeWithTag("curve-channel-red").performScrollTo().performClick()
            compose.onNodeWithTag("curve-edit-point").performScrollTo().assertIsDisplayed()
            compose.cancelWorkbenchDraft(model)

            compose.openWorkbenchTool(14)
            compose.onNodeWithTag("adjustment-value-${R.string.hsl_hue}").performScrollTo().assertIsDisplayed()
            compose.cancelWorkbenchDraft(model)

            compose.openWorkbenchTool(21)
            compose.onNodeWithTag("grading-wheel").performScrollTo().assertIsDisplayed()
            compose.cancelWorkbenchDraft(model)

            compose.openWorkbenchTool(10)
            compose.onNodeWithTag("adjustment-value-${R.string.sharpening}").performScrollTo().assertIsDisplayed()
            compose.cancelWorkbenchDraft(model)

            compose.openWorkbenchTool(11)
            compose.onNodeWithTag("adjustment-value-${R.string.denoise_luma}").performScrollTo().assertIsDisplayed()
            compose.cancelWorkbenchDraft(model)

            compose.openWorkbenchTool(12)
            compose.onNodeWithTag("adjustment-value-${R.string.vignette_amount}").performScrollTo().assertIsDisplayed()
            compose.cancelWorkbenchDraft(model)

            compose.openWorkbenchTool(16)
            compose.onNodeWithTag("lens.profile").performScrollTo().assertIsDisplayed()
            compose.cancelWorkbenchDraft(model)
        } finally {
            EditStore(File(compose.activity.filesDir, "edits")).reset(PhotoIdentity(Uri.fromFile(source).toString()))
            source.delete()
        }
    }

    @Test fun canvasZoomComparisonWipeAndSaveRetrySmoke() {
        val source = rasterFixture("canvas-zoom")
        val model = compose.activity.model
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            compose.waitUntilEditorReady(model)

            val canvas = compose.onNodeWithTag("photo-canvas")
            canvas.performTouchInput { doubleClick(center) }
            canvas.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "100%"))
            canvas.performTouchInput { doubleClick(center) }

            compose.onNodeWithContentDescription(compose.activity.getString(R.string.editor_compare_enable)).performClick()
            compose.onNodeWithTag("comparison-before").assertIsDisplayed()
            compose.onNodeWithTag("comparison-mode").performClick()
            compose.onNodeWithText(compose.activity.getString(R.string.editor_compare_wipe)).performClick()
            compose.onNodeWithTag("comparison-wipe").assertIsDisplayed()

            val exportRobot = ExportRobot(compose)
            exportRobot.openExportSheet(compose.activity.getString(R.string.export))
            InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
        } finally {
            EditStore(File(compose.activity.filesDir, "edits")).reset(PhotoIdentity(Uri.fromFile(source).toString()))
            source.delete()
        }
    }
}
