package com.rawlab.android

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.net.Uri
import androidx.compose.material3.MaterialTheme
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

class PhotoCanvasTest {
    @get:Rule val compose = createComposeRule()

    @Test fun doubleTapPinchAndPanUseNativePixels() {
        val state = PhotoCanvasState()
        val pair = fixture()
        compose.setContent { MaterialTheme { PhotoCanvas(pair, false, "zoom-test", state) } }
        val canvas = compose.onNodeWithTag("photo-canvas")
        canvas.performTouchInput { doubleClick(center) }
        canvas.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "100%"))
        capture("zoom-actual-pixels.png")
        canvas.performTouchInput { doubleClick(center) }
        compose.runOnIdle { assertEquals(state.viewport!!.fitScale, state.zoom!!.scale, .001f) }
        canvas.performTouchInput {
            pinch(Offset(centerX - 80, centerY), Offset(centerX + 80, centerY),
                Offset(centerX - 240, centerY), Offset(centerX + 240, centerY), 600)
        }
        compose.runOnIdle { assertTrue(state.zoom!!.scale > state.viewport!!.fitScale * 2) }
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
        compose.setContent { MaterialTheme { PhotoCanvas(pair, true, "comparison-test", state) } }
        val canvas = compose.onNodeWithTag("photo-canvas")
        canvas.performTouchInput {
            pinch(Offset(centerX - 80, centerY), Offset(centerX + 80, centerY),
                Offset(centerX - 240, centerY), Offset(centerX + 240, centerY), 600)
        }
        compose.runOnIdle {
            assertTrue(state.zoom!!.scale > state.viewport!!.fitScale * 2)
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
        var editor by mutableStateOf(EditorState(photo = ImportedPhoto(Uri.EMPTY, "photo-a", File("photo-a")), preview = pair))
        restoration.setContent {
            MaterialTheme {
                EditorScreen(editor, {}, {}, { _, _ -> }, {}, {}, {}, {}, {}, {})
            }
        }
        val canvas = compose.onNodeWithTag("photo-canvas")
        canvas.performTouchInput { doubleClick(center) }
        canvas.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "100%"))
        restoration.emulateSavedInstanceStateRestore()
        canvas.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "100%"))
        val smaller = Bitmap.createScaledBitmap(pair.result, 1200, 800, false)
        compose.runOnIdle { editor = editor.copy(preview = PreviewPair(smaller, smaller, 6500f, 0f)) }
        canvas.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "100%"))
        compose.onNodeWithContentDescription("对比").performClick()
        canvas.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "100%"))
        compose.runOnIdle { editor = editor.copy(photo = ImportedPhoto(Uri.EMPTY, "photo-b", File("photo-b")), preview = pair) }
        canvas.assert(SemanticsMatcher("photo starts fitted") {
            it.config[SemanticsProperties.StateDescription].startsWith("适应画面")
        })
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
