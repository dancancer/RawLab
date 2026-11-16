package com.rawlab.android.editor.geometry

import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.test.*
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.unit.dp
import com.rawlab.android.R
import androidx.compose.ui.test.junit4.createComposeRule
import com.rawlab.android.editor.EditorState
import com.rawlab.android.editor.AdjustmentDraft
import com.rawlab.android.editor.AdjustmentGroup
import com.rawlab.android.editor.canvas.PhotoCanvasState
import com.rawlab.android.editor.canvas.PhotoViewOptions
import com.rawlab.android.editor.render.HDRPreview
import com.rawlab.android.editor.render.HDRPreviewFrame
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.editor.ui.EditorCanvas
import com.rawlab.android.editor.ui.EditorScreen
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.testing.LanguageTestRule
import com.rawlab.android.testing.openWorkbenchTool
import com.rawlab.android.testing.openWorkbenchMore
import com.rawlab.android.testing.toggleWorkbenchFine
import com.rawlab.android.testing.dismissWorkbenchMenu
import com.rawlab.android.testing.setChineseContent
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File

class PhotoViewInteractionTest {
    private val compose = createComposeRule()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule()).around(compose)
    private fun editor() {
        val neutral = Bitmap.createBitmap(600, 400, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.BLUE) }
        val after = Bitmap.createBitmap(600, 400, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.RED) }
        val state = EditorState(photo = ImportedPhoto(Uri.parse("content://view/a"), "photo-a", File("a")),
            preview = PreviewPair(neutral, after, 6500f, 0f), exact = true)
        compose.setChineseContent { MaterialTheme { EditorScreen(state, {}, {}, { _, _ -> error("Viewing must never edit") }, {}, {}, {}, {}, {}) } }
    }

    @Test fun singleTapAndBackRestoreTheSameToolAndFineState() {
        editor()
        compose.openWorkbenchTool(14)
        compose.toggleWorkbenchFine()
        compose.openWorkbenchMore()
        compose.onNodeWithTag("adjustment-fine").assertIsSelected()
        compose.dismissWorkbenchMenu()
        val lastAxis = compose.onNodeWithTag("adjustment-value-${R.string.hsl_lightness}").performScrollTo()
        val scrollPosition = lastAxis.fetchSemanticsNode().boundsInRoot
        val canvas = compose.onNodeWithTag("photo-canvas")
        canvas.performTouchInput { doubleClick(center); swipeLeft() }
        val originalView = canvas.fetchSemanticsNode().config[SemanticsProperties.StateDescription]
        canvas.performTouchInput { click(center) }
        compose.waitUntil(3_000) { compose.onAllNodesWithTag("adjustment-dock").fetchSemanticsNodes().isEmpty() }
        compose.onNodeWithTag("adjustment-dock").assertDoesNotExist()
        androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().uiAutomation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK)
        compose.waitUntil(3_000) { compose.onAllNodesWithTag("adjustment-dock").fetchSemanticsNodes().isNotEmpty() }
        compose.openWorkbenchMore()
        compose.onNodeWithTag("adjustment-fine").assertIsSelected()
        compose.dismissWorkbenchMenu()
        compose.onNodeWithTag("adjustment-row-${R.string.hsl_hue}").assertExists()
        compose.onNodeWithTag("editor-groups").assertDoesNotExist()
        assertEquals("Pure preview keeps parameter scroll", scrollPosition, lastAxis.fetchSemanticsNode().boundsInRoot)
        canvas.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, originalView))
    }

    @Test fun doubleTapAndPanDoNotEnterPurePreview() {
        editor()
        val canvas = compose.onNodeWithTag("photo-canvas")
        canvas.performTouchInput { doubleClick(center) }
        compose.onNodeWithTag("adjustment-dock").assertIsDisplayed()
        canvas.performTouchInput { swipeLeft() }
        compose.onNodeWithTag("adjustment-dock").assertIsDisplayed()
    }

    @Test fun comparisonCanCloseDirectlyAndReopenThePreferredWipe() {
        editor()
        compose.onNodeWithContentDescription("开启对比").performClick()
        compose.onNodeWithTag("comparison-before").assertIsDisplayed()
        compose.onNodeWithTag("comparison-mode").performClick()
        compose.onNodeWithText("分割线").performClick()
        compose.onNodeWithTag("comparison-wipe").assertIsDisplayed()
        compose.onNodeWithContentDescription("开启对比").performClick()
        compose.onNodeWithTag("comparison-wipe").assertDoesNotExist()
        compose.onNodeWithContentDescription("开启对比").performClick()
        compose.onNodeWithTag("comparison-wipe").assertIsDisplayed()
    }

    @Test fun geometryDraftKeepsCropGestureAndBlocksViewingActions() {
        val bitmap = Bitmap.createBitmap(600, 400, Bitmap.Config.ARGB_8888)
        val edits = com.rawlab.android.settings.EditSettings(geometry = com.rawlab.android.geometry.GeometrySettings(.1f, .1f, .8f, .8f))
        var state by mutableStateOf(EditorState(photo = ImportedPhoto(Uri.parse("content://view/crop"), "crop", File("crop")),
            edits = edits, preview = PreviewPair(bitmap, bitmap, 6500f, 0f), exact = true,
            draft = com.rawlab.android.editor.AdjustmentDraft.begin(com.rawlab.android.editor.AdjustmentGroup.GEOMETRY, edits)))
        compose.setChineseContent { MaterialTheme { EditorScreen(state, {}, {}, { _, _ -> error("Crop cannot commit") }, {}, {}, {}, {}, {},
            onDraftEdit = { next, _ -> state = state.copy(draft = state.draft!!.update(next)) }) } }
        compose.onNodeWithContentDescription("开启对比").assertIsNotEnabled()
        compose.onNodeWithTag("photo-canvas").assertDoesNotExist()
        compose.onNodeWithTag("geometry.canvas").performTouchInput { swipe(center, Offset(centerX + 50f, centerY), 400) }
        compose.runOnIdle { assertTrue(state.draft!!.changed); assertEquals(edits, state.edits) }
        compose.onNodeWithTag("adjustment-dock").assertIsDisplayed()
        compose.onNodeWithTag("comparison-before").assertDoesNotExist()
    }

    @Test fun longPressReleaseDoesNotDispatchTheSingleTap() {
        editor()
        compose.onNodeWithTag("photo-canvas").performTouchInput { longClick(center, 800) }
        compose.onNodeWithTag("adjustment-dock").assertIsDisplayed()
        compose.onNodeWithTag("comparison-before").assertDoesNotExist()
    }

    @Test fun straighteningShowsDimmedPhotoBeyondTheCrop() {
        val bitmap = Bitmap.createBitmap(600, 400, Bitmap.Config.ARGB_8888).apply {
            eraseColor(android.graphics.Color.RED)
        }
        val edits = EditSettings()
        val draft = AdjustmentDraft.begin(AdjustmentGroup.GEOMETRY, edits)
            .update(edits.copy(geometry = GeometrySettings(straightenDegrees = 15.1f)))
        val state = EditorState(photo = ImportedPhoto(Uri.parse("content://view/straighten"), "straighten", File("straighten")),
            edits = edits, preview = PreviewPair(bitmap, bitmap, 6500f, 0f), exact = true, draft = draft)
        compose.setChineseContent { MaterialTheme { EditorScreen(state, {}, {}, { _, _ -> }, {}, {}, {}, {}, {}) } }

        val pixels = compose.onNodeWithTag("geometry.canvas").captureToImage().toPixelMap()
        var dimmed = 0
        for (y in 0 until pixels.height step 4) for (x in 0 until pixels.width step 4) {
            val color = pixels[x, y]
            if (color.red in .25f..0.65f && color.green < .05f && color.blue < .05f) dimmed++
        }
        assertTrue("The rotated photo extends past the crop and is dimmed there", dimmed > pixels.width * pixels.height / 1600)
    }

    @Test fun projectedCropKeepsTheViewingMarginUntilTheExactFrameArrives() {
        val bitmap = redBitmap(600, 400)
        val crop = GeometrySettings(cropWidth = .5f, cropHeight = .5f)
        var state by mutableStateOf(EditorState(
            edits = EditSettings(geometry = crop), preview = PreviewPair(bitmap, bitmap, 6500f, 0f)))
        showCanvas(PhotoViewOptions(margins = true)) { state }
        fun photoBounds(): IntRange {
            val pixels = compose.onNodeWithTag("editor-canvas").captureToImage().toPixelMap()
            val photo = (0 until pixels.width).filter { x ->
                val pixel = pixels[x, pixels.height / 2]
                pixel.red > .8f && pixel.green < .1f && pixel.blue < .1f
            }
            return photo.first()..photo.last()
        }

        val projected = photoBounds()
        compose.runOnIdle {
            val cropped = redBitmap(300, 200)
            state = state.copy(preview = PreviewPair(cropped, cropped, 6500f, 0f, renderedGeometry = crop), exact = true)
        }
        val exact = photoBounds()
        assertTrue("Viewing margin must be visible on the exact frame", exact.first > 0)
        assertEquals("The projected crop has the same visible insets as the exact frame", exact, projected)
    }

    @Test fun geometryDraftKeepsTheDisplayedHDRFalseColor() {
        val bitmap = redBitmap(360, 240)
        val samples = FloatArray(bitmap.width * bitmap.height * 3) { .5f }
        val frame = HDRPreviewFrame(bitmap.width, bitmap.height, samples, samples, 1f, 1f)
        val edits = EditSettings()
        var state by mutableStateOf(EditorState(
            photo = ImportedPhoto(Uri.parse("content://view/hdr-geometry"), "HDR", File("hdr")),
            edits = edits, preview = PreviewPair(bitmap, bitmap, 6500f, 0f, hdr = HDRPreview(frame, frame)), exact = true))
        showCanvas { state }
        val monitor = compose.onNodeWithTag("hdr-monitoring")
        monitor.performClick()
        compose.onNodeWithTag("hdr-false-color").performClick().assertIsOn()
        compose.waitUntil(10_000) {
            compose.onAllNodes(hasTestTag("comparison-after") and
                SemanticsMatcher.keyIsDefined(SemanticsProperties.StateDescription)).fetchSemanticsNodes().isNotEmpty()
        }
        monitor.performClick()
        fun centerPixel() = compose.onNodeWithTag("editor-canvas").captureToImage().toPixelMap().let {
            it[it.width / 2, it.height / 2]
        }
        val viewing = centerPixel()
        assertTrue("False color replaces the red SDR fallback", viewing.green > .3f)
        compose.runOnIdle {
            val draft = AdjustmentDraft.begin(AdjustmentGroup.GEOMETRY, edits)
                .update(edits.copy(geometry = GeometrySettings(straightenDegrees = 15.1f)))
                .copy(geometryGrid = false)
            state = state.copy(draft = draft)
        }
        compose.onNodeWithTag("geometry.canvas").assertIsDisplayed()
        val projected = centerPixel()
        assertEquals(viewing.red, projected.red, .02f)
        assertEquals(viewing.green, projected.green, .02f)
        assertEquals(viewing.blue, projected.blue, .02f)
    }

    private fun redBitmap(width: Int, height: Int) = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        .apply { eraseColor(android.graphics.Color.RED) }

    private fun showCanvas(view: PhotoViewOptions = PhotoViewOptions(), state: () -> EditorState) {
        compose.setChineseContent {
            MaterialTheme {
                EditorCanvas(state(), compare = false, photoCanvas = remember { PhotoCanvasState() }, photoInfo = null,
                    infoMode = 0, onInfoClick = {}, modifier = Modifier.size(280.dp), onAlbum = {}, onFile = {},
                    onLicenses = {}, onPreviewSizeChange = {}, onDraftEdit = { _, _ -> }, onSaveRetry = {}, view = view)
            }
        }
    }
}
