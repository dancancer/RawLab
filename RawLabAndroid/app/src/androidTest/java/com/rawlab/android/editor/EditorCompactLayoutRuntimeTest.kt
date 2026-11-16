package com.rawlab.android.editor

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.*
import androidx.compose.ui.unit.dp
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.MainActivity
import com.rawlab.android.R
import com.rawlab.android.testing.ForegroundTestRule
import com.rawlab.android.testing.openWorkbenchTool
import com.rawlab.android.testing.selectWorkbenchGroup
import com.rawlab.android.testing.toggleWorkbenchFine
import com.rawlab.android.testing.assertWorkbenchFine
import com.rawlab.android.testing.LanguageTestRule
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File

class EditorCompactLayoutRuntimeTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule()).around(ForegroundTestRule()).around(compose)

    @Test fun importedRawKeepsEditsFineAndNavigationThroughCompactAndWideLayouts() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val source = File(compose.activity.cacheDir, "compact-layout-${System.nanoTime()}.RAW")
        instrumentation.context.assets.open("sample.RAW").use { input -> source.outputStream().use { input.copyTo(it) } }
        val orientation = compose.activity.requestedOrientation
        fun ready() {
            compose.waitUntil(180_000) {
                compose.activity.model.state.value.let { ((it.canExport || it.draftReady) && !it.previewResizePending) || it.error != null }
            }
            assertNull(compose.activity.model.state.value.error)
        }
        fun group(id: String) = compose.openWorkbenchTool(when (id) {
            "light" -> 2
            "color" -> 8
            else -> error("Unknown fixture group $id")
        })
        fun tool(id: Int) = compose.openWorkbenchTool(id)
        fun capture(name: String) {
            val dir = File(compose.activity.getExternalFilesDir(null), "compact-layout-runtime").apply { mkdirs() }
            File(dir, "$name.png").outputStream().use {
                compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it)
            }
        }
        try {
            compose.runOnUiThread {
                compose.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                compose.activity.model.setGpuEnabled(false)
                compose.activity.model.importPhoto(Uri.fromFile(source))
            }
            ready(); compose.selectWorkbenchGroup("light")
            val first = compose.onNodeWithTag("editor-tool-2").fetchSemanticsNode().boundsInRoot
            val last = compose.onNodeWithTag("editor-tool-4").fetchSemanticsNode().boundsInRoot
            val dock = compose.onNodeWithTag("adjustment-dock").fetchSemanticsNode().boundsInRoot
            assertEquals(dock.width - 16f * compose.density.density, last.right - first.left, 1f)
            tool(2)
            compose.onNodeWithTag("adjustment-value-${R.string.exposure}").performClick()
            compose.onNodeWithTag("adjustment-input").performTextReplacement("0.35")
            compose.onNodeWithTag("adjustment-input-apply").performClick()
            ready()
            assertEquals(.35f, compose.activity.model.state.value.visibleEdits.exposure, .0001f)
            val ruler = compose.onNodeWithTag("adjustment-slider")
            val rulerFrame = ruler.fetchSemanticsNode().boundsInRoot
            ruler.performTouchInput { down(center); moveBy(Offset(32.dp.toPx(), 0f)) }
            compose.waitForIdle()
            assertEquals(.55f, compose.activity.model.state.value.visibleEdits.exposure, .0001f)
            assertEquals(rulerFrame, ruler.fetchSemanticsNode().boundsInRoot)
            ruler.performTouchInput { moveBy(Offset(32.dp.toPx(), 0f)); up() }
            ready()
            assertEquals(.75f, compose.activity.model.state.value.visibleEdits.exposure, .0001f)
            assertEquals(rulerFrame, ruler.fetchSemanticsNode().boundsInRoot)
            compose.toggleWorkbenchFine(); compose.assertWorkbenchFine(true)
            capture("phone-exposure")
            assertEquals(0f, compose.activity.model.state.value.edits.exposure, .0001f)
            compose.onNodeWithTag("draft.apply").performClick(); ready()
            assertEquals(.75f, compose.activity.model.state.value.edits.exposure, .0001f)
            tool(3); compose.assertWorkbenchFine(false)
            capture("phone-highlights")
            group("color"); tool(14)
            compose.onNodeWithTag("adjustment-value-${R.string.hsl_lightness}").performScrollTo().assertIsDisplayed()
            capture("phone-hsl")
            group("light")
            compose.toggleWorkbenchFine(); compose.assertWorkbenchFine(true)
            compose.runOnUiThread { compose.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
            compose.waitUntil(20_000) { compose.activity.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE }
            ready()
            compose.assertWorkbenchFine(true)
            assertEquals(.75f, compose.activity.model.state.value.visibleEdits.exposure, .0001f)
            capture("landscape-exposure")
        } finally {
            compose.runOnUiThread { compose.activity.requestedOrientation = orientation }
            source.delete()
        }
    }
}
