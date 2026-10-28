package com.rawlab.android.editor.controls

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.net.Uri
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.MainActivity
import com.rawlab.android.R
import com.rawlab.android.testing.ForegroundTestRule
import com.rawlab.android.testing.LanguageTestRule
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File

class EditorParameterRotationRuntimeTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule()).around(ForegroundTestRule()).around(compose)

    @Test fun actualLandscapeNormalTextKeepsGeometryAndLensControlsFullyOperable() = verify(1f)
    @Test fun actualLandscapeLargeTextKeepsGeometryAndLensControlsFullyOperable() = verify(1.6f)
    private fun verify(scale: Float) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val source = File(compose.activity.cacheDir, "landscape-parameters-${System.nanoTime()}.RAW")
        instrumentation.context.assets.open("sample.RAW").use { input -> source.outputStream().use { input.copyTo(it) } }
        fun ready() {
            compose.waitUntil(180_000) { compose.activity.model.state.value.let { ((it.canExport || it.draftReady) && !it.previewResizePending) || it.error != null } }
            assertNull(compose.activity.model.state.value.error)
        }
        fun bounds(tag: String) = compose.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot
        fun capture(name: String) {
            val dir = File(compose.activity.getExternalFilesDir(null), "parameter-rotation").apply { mkdirs() }
            File(dir, name).outputStream().use { compose.onRoot().captureToImage().asAndroidBitmap().compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
        }
        try {
            android.os.ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand("settings put system font_scale $scale")).use { it.readBytes() }
            compose.runOnUiThread { compose.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
            compose.waitUntil(20_000) { compose.activity.resources.configuration.let { it.orientation == Configuration.ORIENTATION_LANDSCAPE && it.fontScale == scale } }
            compose.runOnUiThread { compose.activity.model.setGpuEnabled(false); compose.activity.model.importPhoto(Uri.fromFile(source)) }
            ready()
            compose.onNodeWithTag("editor-groups").performScrollToNode(hasTestTag("editor-group-geometry"))
            compose.onNodeWithTag("editor-group-geometry").performClick()
            ready()
            val dock = bounds("adjustment-dock")
            val photo = bounds("editor-canvas")
            assertTrue("Actual rotated window keeps photo and dock separate", if (scale >= 1.3f) photo.bottom <= dock.top else photo.right <= dock.left)
            val density = compose.activity.resources.displayMetrics.density
            val viewport = bounds("editor-parameters")
            android.util.Log.i("RawLabViewportRed", "actual scale=$scale density=$density root=${compose.onRoot().fetchSemanticsNode().boundsInRoot} photo=$photo dock=$dock viewport=$viewport")
            assertTrue("Photo retains at least 96dp", photo.height >= 96 * density - 1)
            assertTrue("Real safe-area viewport supports a full operation row", viewport.height >= 48 * density)
            val committed = compose.activity.model.state.value.edits
            val number = compose.onNodeWithTag("adjustment-value-${R.string.geometry_crop_height}").performScrollTo().assertIsDisplayed()
            val numberBounds = number.fetchSemanticsNode().boundsInRoot
            val numericParts = mutableMapOf<String, androidx.compose.ui.geometry.Rect>()
            for (tag in listOf("adjustment-name-${R.string.geometry_crop_height}", "adjustment-value-${R.string.geometry_crop_height}", "adjustment-unit-${R.string.geometry_crop_height}")) {
                val node = compose.onNodeWithTag(tag)
                val visible = node.fetchSemanticsNode().boundsInRoot
                val full = node.getUnclippedBoundsInRoot()
                assertTrue("Actual short window exposes the entire label/value before the separate track: $tag $visible vs $full", visible.height >= (full.bottom - full.top).value * density - 1 && visible.width >= (full.right - full.left).value * density - 1)
                numericParts[tag] = visible
            }
            assertTrue("Actual rotated numeric entry is a full 48dp touch target", numberBounds.height >= 48 * density - 1)
            number.performTouchInput { click() }
            compose.onNodeWithTag("adjustment-input").performTextReplacement("98")
            compose.onNodeWithTag("adjustment-input-apply").performClick()
            ready()
            assertEquals("Exact numeric entry edits the intended draft axis", .98f, compose.activity.model.state.value.draft!!.value.geometry.cropHeight, .0001f)
            assertEquals("Numeric draft operation preserves committed parameters and processing", committed, compose.activity.model.state.value.edits)
            capture("geometry-value-landscape-$scale.png")
            android.util.Log.i("RawLabWholeRowEvidence", "actual scale=$scale density=$density number=$numberBounds parts=$numericParts viewport=$viewport")
            val ruler = compose.onAllNodesWithTag("adjustment-slider").onLast()
            ruler.performScrollTo().assertIsDisplayed()
            val rulerBounds = ruler.fetchSemanticsNode().boundsInRoot
            assertTrue("Last geometry ruler is wholly visible", rulerBounds.height >= 48 * density - 1 && rulerBounds.top >= viewport.top - 1 && rulerBounds.bottom <= viewport.bottom + 1)
            ruler.performSemanticsAction(SemanticsActions.SetProgress) { it(99f) }
            ready()
            assertTrue("Last geometry control really operates on draft", compose.activity.model.state.value.draft!!.changed)
            assertEquals("Track operates after the numeric row was scrolled away", .99f, compose.activity.model.state.value.draft!!.value.geometry.cropHeight, .0001f)
            capture("geometry-landscape-$scale.png")
            compose.runOnUiThread { compose.activity.model.discardDraft() }
            ready()
            compose.onNodeWithTag("editor-tools").performScrollToNode(hasTestTag("editor-tool-16"))
            compose.onNodeWithTag("editor-tool-16").performClick()
            ready()
            val crop = compose.onNodeWithTag("lens.crop").performScrollTo().assertIsDisplayed().assertIsEnabled()
            val cropBounds = crop.fetchSemanticsNode().boundsInRoot
            assertTrue("Last enabled lens switch has its entire 48dp touch target", cropBounds.height >= 48 * density - 1 && cropBounds.top >= viewport.top - 1 && cropBounds.bottom <= viewport.bottom + 1)
            crop.performTouchInput { click() }
            ready()
            assertTrue("Last lens control really operates on draft", compose.activity.model.state.value.draft!!.changed)
            for (tag in listOf("draft.apply", "draft.cancel", "editor-groups")) compose.onNodeWithTag(tag).assertIsDisplayed()
            assertEquals(dock, bounds("adjustment-dock")); assertEquals(photo, bounds("editor-canvas"))
            capture("lens-landscape-$scale.png")
            val profile = compose.onNodeWithTag("lens.profile").performScrollTo().assertIsDisplayed()
            val profileBounds = profile.fetchSemanticsNode().boundsInRoot
            val fullProfile = profile.getUnclippedBoundsInRoot()
            assertTrue("Actual last profile control retains its entire measured height", profileBounds.height >= (fullProfile.bottom - fullProfile.top).value * density - 1)
            assertTrue("Last lens profile button is fully visible", profileBounds.height >= 48 * density - 1 && profileBounds.top >= viewport.top - 1 && profileBounds.bottom <= viewport.bottom + 1)
            capture("lens-profile-landscape-$scale.png")
            android.util.Log.i("RawLabViewportEvidence", "density=$density root=${compose.onRoot().fetchSemanticsNode().boundsInRoot} photo=$photo dock=$dock parameters=$viewport ruler=$rulerBounds lens=$cropBounds profile=$profileBounds font=${compose.activity.resources.configuration.fontScale}")
        } finally {
            compose.runOnUiThread { compose.activity.model.discardDraft(); compose.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT }
            android.os.ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand("settings put system font_scale 1.0")).use { it.readBytes() }
            source.delete()
        }
    }
}
