package com.rawlab.android.editor.geometry

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.net.Uri
import androidx.compose.material3.MaterialTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.height
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.Density
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.runtime.*
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import com.rawlab.android.editor.EditorState
import com.rawlab.android.editor.canvas.PhotoCanvas
import com.rawlab.android.editor.canvas.PhotoCanvasState
import com.rawlab.android.editor.canvas.PhotoZoom
import com.rawlab.android.editor.canvas.ComparisonMode
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.editor.ui.EditorScreen
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.testing.LanguageTestRule
import com.rawlab.android.testing.setChineseContent

class PhotoCanvasTest {
    val compose = createComposeRule()
    @get:Rule val languageAndCompose = org.junit.rules.RuleChain.outerRule(LanguageTestRule()).around(compose)

    @Test fun bottomCardOnlyBlocksItsOwnWidthDuringTargetSampling() {
        val state = PhotoCanvasState()
        var begins = 0
        val target = com.rawlab.android.editor.controls.HslTargetActions(
            state = com.rawlab.android.settings.HslTargetState(enabled = true), begin = { _, _ -> begins++ })
        compose.setChineseContent { MaterialTheme {
            Box(Modifier.width(320.dp).height(240.dp)) {
                PhotoCanvas(fixture(), false, "bottom-card", state, hslTarget = target,
                    bottomOverlayInset = 0.dp, bottomOverlay = { Box(Modifier.width(80.dp).height(60.dp)) })
            }
        } }
        compose.onNodeWithTag("photo-canvas").performTouchInput {
            down(Offset(width * .2f, height * .82f)); moveBy(Offset(0f, -24f)); up()
        }
        compose.runOnIdle { assertEquals("photo beside the card must remain sampleable", 1, begins) }
    }

    @Test fun viewportCallbackTracksPhysicalSizeButNotResultReplacementOrPan() {
        val state = PhotoCanvasState()
        val original = fixture().neutral
        var pair by mutableStateOf(PreviewPair(original, original, 6500f, 0f))
        var width by mutableStateOf(300.dp)
        val edges = mutableListOf<Int>()
        compose.setContent {
            MaterialTheme {
                CompositionLocalProvider(LocalDensity provides Density(3f)) {
                    Box(Modifier.width(width).height(200.dp)) {
                        PhotoCanvas(pair, false, "viewport", state, onPreviewSizeChange = { edges += it })
                    }
                }
            }
        }
        compose.runOnIdle {
            assertEquals(852f, state.viewport!!.width, .01f)
            assertEquals(552f, state.viewport!!.height, .01f)
            assertEquals(listOf(832), edges)
            pair = PreviewPair(original, Bitmap.createScaledBitmap(original, 512, 341, false), 6500f, 0f)
        }
        compose.runOnIdle { assertEquals(1, edges.size); state.transform(1f, Offset(2f, 0f), Offset.Zero) }
        compose.runOnIdle { assertEquals(1, edges.size); width = 200.dp }
        compose.runOnIdle {
            assertEquals(2, edges.size)
            assertEquals(552f, state.viewport!!.width, .01f)
            assertEquals(576, edges.last())
        }
    }

    @Test fun doubleTapPinchAndPanUseNativePixels() {
        val state = PhotoCanvasState()
        val pair = fixture()
        compose.setChineseContent { MaterialTheme { PhotoCanvas(pair, false, "zoom-test", state) } }
        val canvas = compose.onNodeWithTag("photo-canvas")
        canvas.performTouchInput { doubleClick(center) }
        canvas.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "100%"))
        capture("zoom-actual-pixels.png")
        canvas.performTouchInput { doubleClick(center) }
        compose.runOnIdle { assertEquals(state.viewport!!.fitScale, state.zoom!!.scale, .001f) }
        canvas.performTouchInput {
            pinch(start0 = Offset(centerX - 80, centerY), end0 = Offset(centerX - 240, centerY),
                start1 = Offset(centerX + 80, centerY), end1 = Offset(centerX + 240, centerY), durationMillis = 600)
        }
        compose.runOnIdle { assertEquals(3f, state.view.magnification, .15f) }
        canvas.performTouchInput { swipeLeft() }
        compose.runOnIdle {
            assertTrue(state.zoom!!.x < 0)
            assertEquals(state.zoom, state.zoom!!.constrained(state.viewport!!))
        }
        capture("zoom-pinch-pan.png")
        canvas.performTouchInput { doubleClick(center) }
        compose.runOnIdle { assertEquals(PhotoZoom(state.viewport!!.fitScale), state.zoom) }
    }

    @Test fun comparisonWipeDoesNotCompeteWithPinchOrTwoFingerPan() {
        val state = PhotoCanvasState()
        val pair = fixture()
        compose.setChineseContent { MaterialTheme { PhotoCanvas(pair, true, "comparison-test", state, mode = ComparisonMode.WIPE) } }
        val canvas = compose.onNodeWithTag("photo-canvas")
        canvas.performTouchInput {
            pinch(start0 = Offset(centerX - 80, centerY), end0 = Offset(centerX - 240, centerY),
                start1 = Offset(centerX + 80, centerY), end1 = Offset(centerX + 240, centerY), durationMillis = 600)
        }
        compose.runOnIdle {
            assertEquals(3f, state.view.magnification, .15f)
            assertEquals(.5f, state.split, .001f)
        }
        canvas.performTouchInput {
            down(0, Offset(centerX - 50, centerY))
            down(1, Offset(centerX + 50, centerY))
            moveBy(0, Offset(-100f, 0f), 100)
            moveBy(1, Offset(-100f, 0f), 100)
            up(1)
            moveBy(0, Offset(-50f, 0f), 100)
            up(0)
        }
        compose.runOnIdle {
            assertTrue(state.zoom!!.x < 0)
            assertEquals(.5f, state.split, .001f)
        }
        val scale = state.zoom!!.scale
        canvas.performTouchInput { swipe(Offset(centerX, centerY), Offset(width * .7f, centerY), 400) }
        compose.runOnIdle {
            assertEquals(.7f, state.split, .02f)
            assertEquals(scale, state.zoom!!.scale, .001f)
        }
        capture("zoom-comparison.png")
    }

    @Test fun editsAndPreviewQualityKeepZoomButNewPhotoResetsIt() {
        val restoration = StateRestorationTester(compose)
        val pair = fixture()
        var editor by mutableStateOf(EditorState(photo = ImportedPhoto(Uri.parse("content://rawlab.test/photo-a"), "photo-a", File("photo-a")), preview = pair))
        restoration.setContent {
            MaterialTheme {
                EditorScreen(editor, {}, {}, { _, _ -> }, {}, {}, {}, {}, {})
            }
        }
        val canvas = compose.onNodeWithTag("photo-canvas")
        canvas.performTouchInput { doubleClick(center) }
        canvas.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "100%"))
        restoration.emulateSavedInstanceStateRestore()
        canvas.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "100%"))
        val smaller = Bitmap.createScaledBitmap(pair.result, 1200, 800, false)
        compose.runOnIdle { editor = editor.copy(preview = pair.copy(neutral = smaller, result = smaller)) }
        canvas.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "100%"))
        compose.onNodeWithContentDescription("开启对比").performClick()
        compose.onNodeWithTag("comparison-before").assertIsDisplayed()
        // 并排按同一相对 fit 焦点投影，pane 内的显示像素百分比可随布局变化。
        canvas.assert(SemanticsMatcher("comparison retains magnification above fit") {
            !it.config[SemanticsProperties.StateDescription].startsWith("适合窗口")
        })
        compose.runOnIdle { editor = editor.copy(photo = ImportedPhoto(Uri.parse("content://rawlab.test/photo-b"), "photo-b", File("photo-b")), preview = pair) }
        canvas.assert(SemanticsMatcher("photo starts fitted") {
            it.config[SemanticsProperties.StateDescription].startsWith("适合窗口")
        })
    }

    @Test fun denoiseProxyAndExactKeepOriginalNativeZoomAndPan() {
        val state = PhotoCanvasState()
        val original = fixture().neutral
        var pair by mutableStateOf(PreviewPair(original, original, 6500f, 0f))
        compose.setChineseContent { MaterialTheme { PhotoCanvas(pair, true, "denoise-photo", state, mode = ComparisonMode.WIPE) } }
        val canvas = compose.onNodeWithTag("photo-canvas")
        canvas.performTouchInput { doubleClick(center) }
        canvas.performTouchInput {
            down(0, Offset(centerX - 50, centerY))
            down(1, Offset(centerX + 50, centerY))
            moveBy(0, Offset(-100f, 0f), 100)
            moveBy(1, Offset(-100f, 0f), 100)
            up(1)
            up(0)
        }
        val before = state.zoom
        for (width in listOf(720, 1600)) {
            compose.runOnIdle {
                pair = PreviewPair(original, Bitmap.createScaledBitmap(original, width, width * 2 / 3, false), 6500f, 0f)
            }
            canvas.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "100%"))
            compose.runOnIdle {
                assertSame(original, pair.neutral)
                assertEquals(before, state.zoom)
            }
        }
        capture("denoise-proxy-exact-pan.png")
    }

    @Test fun wipeAccessibilityTargetAndHandleStayInsideTheLetterboxedPhoto() {
        val state = PhotoCanvasState()
        compose.setChineseContent {
            MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f)) {
                Box(Modifier.width(300.dp).height(300.dp)) { PhotoCanvas(fixture(), true, "wipe-bounds", state, mode = ComparisonMode.WIPE) }
            } }
        }
        val rect = compose.onNodeWithTag("comparison-wipe").fetchSemanticsNode().boundsInRoot
        assertEquals("Wipe AX hit target excludes top and bottom letterbox", 189.333f, rect.height, 1f)
        assertEquals(55.333f, rect.top, 1f)
        assertEquals(244.667f, rect.bottom, 1f)
        for (split in listOf(0f, 1f)) {
            compose.onNodeWithTag("comparison-wipe").performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.SetProgress) { it(split) }
            val handle = compose.onNodeWithTag("comparison-handle", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
            assertTrue("Visible handle stays inside the photograph at $split: $handle in $rect", handle.left >= rect.left && handle.right <= rect.right && handle.top >= rect.top && handle.bottom <= rect.bottom)
        }
    }

    @Test fun pinchAcrossBothComparisonPanesChangesOneSharedPhotoView() {
        val state = PhotoCanvasState()
        compose.setChineseContent { MaterialTheme { PhotoCanvas(fixture(), true, "both-panes", state) } }
        compose.onNodeWithTag("photo-canvas").performTouchInput {
            pinch(start0 = Offset(centerX, centerY - 60f), end0 = Offset(centerX, centerY - 180f),
                start1 = Offset(centerX, centerY + 60f), end1 = Offset(centerX, centerY + 180f), durationMillis = 600)
        }
        compose.runOnIdle { assertEquals("A threefold cross-pane pinch is applied once to the shared view", 3f, state.view.magnification, .15f) }
    }

    @Test fun crossPanePinchCannotBecomeSingleFingerPanAfterOneFingerLifts() {
        val state = PhotoCanvasState()
        compose.setChineseContent { MaterialTheme { PhotoCanvas(fixture(), true, "both-panes-handoff", state) } }
        val canvas = compose.onNodeWithTag("photo-canvas")
        canvas.performTouchInput {
            down(0, Offset(centerX, centerY - 60f)); down(1, Offset(centerX, centerY + 60f))
            moveTo(0, Offset(centerX, centerY - 180f), 300)
            moveTo(1, Offset(centerX, centerY + 180f), 300)
        }
        var before = com.rawlab.android.editor.canvas.PhotoViewTransform()
        compose.runOnIdle {
            assertEquals(3f, state.view.magnification, .15f)
            before = state.view
        }
        canvas.performTouchInput { up(1); moveBy(0, Offset(100f, 0f), 200); up(0) }
        compose.runOnIdle { assertEquals("Lifting one finger does not start a new pan or wipe", before, state.view); assertEquals(.5f, state.split, 0f) }
    }

    @Test fun verticalCrossPaneFocusDoesNotDependOnFirstPointer() = crossPaneFocus(false, false)
    @Test fun verticalCrossPaneReverseFocusDoesNotDependOnFirstPointer() = crossPaneFocus(false, true)
    @Test fun horizontalCrossPaneFocusDoesNotDependOnFirstPointer() = crossPaneFocus(true, false)
    @Test fun horizontalCrossPaneReverseFocusDoesNotDependOnFirstPointer() = crossPaneFocus(true, true)
    private fun crossPaneFocus(horizontal: Boolean, reverse: Boolean) {
        val state = PhotoCanvasState()
        compose.setChineseContent { MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f)) {
            Box(Modifier.width(if (horizontal) 600.dp else 300.dp).height(if (horizontal) 300.dp else 600.dp)) {
                PhotoCanvas(fixture(), true, "pane-focus", state)
            }
        } } }
        compose.onNodeWithTag("photo-canvas").performTouchInput {
            val direction = if (horizontal) Offset(1f, 0f) else Offset(0f, 1f)
            val sign = if (reverse) -1f else 1f
            pinch(start0 = center - direction * 50f * sign, end0 = center - direction * 150f * sign,
                start1 = center + direction * 50f * sign, end1 = center + direction * 150f * sign, durationMillis = 600)
        }
        compose.runOnIdle {
            assertEquals(3f, state.view.magnification, .15f)
            assertEquals("Both pane pointers anchor the same photo X", .5f, state.view.focusX, .005f)
            assertEquals("Both pane pointers anchor the same photo Y", .5f, state.view.focusY, .005f)
            assertEquals(0f, state.zoom!!.x, 1f); assertEquals(0f, state.zoom!!.y, 1f)
        }
    }

    @Test fun normalPhotoLabelsDoNotOverlapTheInformationControl() {
        compose.setChineseContent { MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f)) {
            Box(Modifier.width(300.dp).height(200.dp)) { PhotoCanvas(fixture(), true, "normal-labels", PhotoCanvasState(), mode = ComparisonMode.WIPE) }
        } } }
        val button = compose.onNodeWithTag("photo-info-button").fetchSemanticsNode().boundsInRoot
        val label = compose.onNodeWithText("调整前").fetchSemanticsNode().boundsInRoot
        assertFalse("Normal photo keeps before label clear of information control: $label $button", label.overlaps(button))
    }

    private fun shortLargePhoto() {
        val state = PhotoCanvasState()
        compose.setChineseContent { MaterialTheme { CompositionLocalProvider(LocalDensity provides Density(1f, 1.6f)) {
            Box(Modifier.width(400.dp).height(100.dp)) { PhotoCanvas(fixture(), true, "short-overlays", state,
                mode = ComparisonMode.WIPE, bottomOverlayInset = 60.dp) }
        } } }
    }

    @Test fun shortLargePhotoKeepsInformationTarget() {
        shortLargePhoto()
        val button = compose.onNodeWithTag("photo-info-button").fetchSemanticsNode().boundsInRoot
        assertEquals("Information target remains 48dp despite save-overlay inset", 48f, button.height, 1f)
        val description = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext.getString(com.rawlab.android.R.string.info_hidden)
        val glyph = compose.onNode(hasContentDescription(description) and !hasClickAction(), useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
        assertEquals(24f, glyph.width, 1f); assertEquals(24f, glyph.height, 1f)
    }

    @Test fun shortLargePhotoKeepsFullComparisonLabels() {
        shortLargePhoto()
        val image = compose.onNodeWithTag("comparison-wipe").fetchSemanticsNode().boundsInRoot
        val handle = compose.onNodeWithTag("comparison-handle-glyph", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
        assertEquals(24f, handle.width, 1f); assertEquals(24f, handle.height, 1f)
        for (tag in listOf("comparison-label-before", "comparison-label-after")) {
            val background = compose.onNodeWithTag(tag, useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
            assertFalse("Actual label background must leave the 24dp handle body visible: $background $handle", background.overlaps(handle))
        }
        for (label in listOf("调整前", "调整后")) {
            val node = compose.onNodeWithText(label)
            val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
            node.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
            val layout = layouts.single()
            val bounds = node.fetchSemanticsNode().boundsInRoot
            android.util.Log.i("RawLabShortLabelEvidence", "label=$label size=${layout.size} lines=${layout.lineCount} widthOverflow=${layout.didOverflowWidth} heightOverflow=${layout.didOverflowHeight} right=${layout.getLineRight(0)} left=${layout.getLineLeft(0)} ellipsis=${layout.isLineEllipsized(0)} rect=$bounds image=$image")
            val dir = java.io.File(androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null), "view-native").apply { mkdirs() }
            java.io.File(dir, "short-overlays.png").outputStream().use { compose.onRoot().captureToImage().asAndroidBitmap().compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
            assertFalse("Label has no clipped lines", layout.didOverflowHeight)
            assertEquals(1, layout.lineCount)
            assertTrue("Both labels have complete glyphs inside their measured width: $label", !layout.isLineEllipsized(0) && layout.getLineLeft(0) >= -1f && layout.getLineRight(0) <= layout.size.width + 1f)
            assertTrue("Whole label is visible", bounds.width >= layout.size.width - 1 && bounds.height >= layout.size.height - 1)
            assertTrue("Label stays in visible photograph", bounds.left >= image.left && bounds.right <= image.right && bounds.top >= image.top && bounds.bottom <= image.bottom)
        }
    }

    @Test fun photoInformationTextDoesNotBlockPhotoPan() {
        val state = PhotoCanvasState()
        compose.setChineseContent { MaterialTheme { PhotoCanvas(fixture(), false, "info-pan", state,
            info = com.rawlab.android.photo.PhotoInfo(fileName = "information"), infoMode = 1) } }
        compose.runOnIdle { state.zoom = PhotoZoom(1f) }
        compose.onNodeWithTag("photo-info-panel").performTouchInput { swipe(Offset(width * .2f, centerY), Offset(width * .8f, centerY), 500) }
        compose.runOnIdle { assertTrue("Noninteractive info text lets the canvas pan", state.zoom!!.x > 0f) }
    }

    private fun fixture(): PreviewPair {
        val bitmap = Bitmap.createBitmap(2400, 1600, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(Color.CYAN)
        canvas.drawRect(0f, 0f, 800f, 1600f, Paint().apply { color = Color.RED })
        canvas.drawRect(1600f, 0f, 2400f, 1600f, Paint().apply { color = Color.YELLOW })
        return PreviewPair(bitmap, bitmap, 6500f, 0f)
    }

    private fun capture(name: String) {
        compose.waitForIdle()
        val image = compose.onRoot().captureToImage().asAndroidBitmap()
        assertNotEquals("Canvas must render the image", image.getPixel(0, 0), image.getPixel(image.width / 2, image.height / 2))
        val directory = InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null)
        File(directory, name).outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
}
