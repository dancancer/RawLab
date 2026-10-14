package com.rawlab.android

import android.net.Uri
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import kotlin.math.min

class GeometryEditorInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test fun cropDraftDoesNotSaveAndApplyCancelRestoreRenderedGeometry() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val source = File(context.cacheDir, "geometry-editor-${System.nanoTime()}.dng")
        InstrumentationRegistry.getInstrumentation().context.assets.open("sample.RAW").use { input ->
            source.outputStream().use { input.copyTo(it) }
        }
        val model = compose.activity.model
        fun awaitPreview() {
            compose.waitUntil(180_000) { !model.state.value.rendering || model.state.value.error != null }
            assertNull(model.state.value.error)
        }
        try {
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
            compose.waitUntil(180_000) { model.state.value.canExport || model.state.value.error != null }
            assertNull(model.state.value.error)
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = .25f)) }
            awaitPreview()
            val before = model.state.value
            val identity = before.photo!!.identity
            val records = File(context.filesDir, "edits")
            val saved = EditStore(records).load(identity)
            compose.onNodeWithTag("editor.tool-17").performClick()
            compose.waitUntil(180_000) { model.state.value.geometryPreviewReady || model.state.value.error != null }
            awaitPreview()
            assertFalse(model.state.value.canExport)
            compose.runOnUiThread { assertFalse(model.beginExport()); model.beginBatch() }
            assertNull(model.batch.value)
            compose.onNodeWithTag("geometry.ratio-SQUARE").performClick()
            compose.waitForIdle()
            val pair = model.state.value.preview!!
            assertFalse(model.state.value.rendering)
            assertSame(pair, model.state.value.preview)
            val cropBeforeDrag = model.state.value.geometryDraft!!
            val node = compose.onNodeWithTag("geometry.canvas").fetchSemanticsNode()
            val areaWidth = node.boundsInRoot.width
            val areaHeight = node.boundsInRoot.height
            val inset = 24f * compose.activity.resources.displayMetrics.density
            val fit = min((areaWidth - inset * 2f) / pair.canvasWidth, (areaHeight - inset * 2f) / pair.canvasHeight)
            val imageWidth = pair.canvasWidth * fit
            val imageHeight = pair.canvasHeight * fit
            val left = (areaWidth - imageWidth) / 2f
            val top = (areaHeight - imageHeight) / 2f
            val handle = Offset(left + cropBeforeDrag.cropX * imageWidth, top + cropBeforeDrag.cropY * imageHeight)
            compose.onNodeWithTag("geometry.canvas").performTouchInput {
                swipe(handle, handle + Offset(imageWidth * .08f, imageHeight * .08f), 300)
            }
            compose.waitForIdle()
            assertTrue(model.state.value.geometryDraft!!.cropWidth < cropBeforeDrag.cropWidth)
            assertFalse(model.state.value.rendering)
            assertSame(pair, model.state.value.preview)
            assertEquals(before.edits, model.state.value.edits)
            assertEquals(saved, EditStore(records).load(identity))
            capture("geometry-crop-${reviewConfiguration()}.png")
            val selectedArea = model.state.value.geometryDraft!!.let { it.cropWidth * it.cropHeight }
            compose.runOnUiThread {
                model.changeGeometry(model.state.value.geometryDraft!!.rotated(true), true)
                assertFalse(model.state.value.geometryPreviewReady)
                assertFalse(model.state.value.canApplyGeometry)
                model.applyGeometry()
                assertNotNull(model.state.value.geometryDraft)
                assertEquals(before.edits, model.state.value.edits)
            }
            awaitPreview()
            val refitted = model.state.value.geometryDraft!!
            assertTrue(refitted.cropWidth * refitted.cropHeight <= selectedArea + .000001f)
            assertEquals(1f, refitted.cropWidth / refitted.cropHeight * model.state.value.geometryCanvasAspect!!, .000001f)
            assertTrue(model.state.value.canApplyGeometry)
            assertEquals(1, model.state.value.geometryDraft!!.quarterTurns)
            assertEquals(before.edits, model.state.value.edits)
            assertEquals(saved, EditStore(records).load(identity))
            compose.onNodeWithTag("geometry.correct-mode").performClick()
            val description = compose.activity.getString(R.string.geometry_straighten)
            compose.onNodeWithContentDescription(description).performScrollTo()
                .performSemanticsAction(SemanticsActions.SetProgress) { it(3f) }
            awaitPreview()
            capture("geometry-correct-${reviewConfiguration()}.png")
            compose.onNodeWithTag("geometry.cancel").performClick()
            compose.waitForIdle()
            assertNull(model.state.value.geometryDraft)
            assertSame(before.preview, model.state.value.preview)
            assertEquals(before.edits, model.state.value.edits)
            assertEquals(saved, EditStore(records).load(identity))
            assertTrue(model.state.value.canExport)
            // Apply crop only: the full draft canvas must still be replaced with a cropped render.
            compose.runOnUiThread { model.beginGeometry() }
            awaitPreview()
            val uncropped = model.state.value.preview!!
            compose.runOnUiThread { model.changeGeometry(model.state.value.geometryDraft!!.copy(cropX = .2f, cropWidth = .6f)) }
            assertSame(uncropped, model.state.value.preview)
            compose.onNodeWithTag("geometry.apply").performClick()
            compose.waitUntil(180_000) { model.state.value.canExport || model.state.value.error != null }
            assertNull(model.state.value.error)
            assertEquals(.6f, model.state.value.edits.geometry.cropWidth)
            assertEquals(model.state.value.edits, EditStore(records).load(identity))
            assertTrue(model.state.value.preview!!.canvasWidth < uncropped.canvasWidth)
            val applied = model.state.value
            compose.runOnUiThread { model.beginGeometry() }
            awaitPreview()
            compose.runOnUiThread { model.resetGeometry() }
            assertEquals(GeometrySettings(), model.state.value.geometryDraft)
            assertEquals(applied.edits, model.state.value.edits)
            compose.onNodeWithTag("geometry.cancel").performClick()
            assertSame(applied.preview, model.state.value.preview)
            // A late transform result cannot replace the cancelled cropped preview.
            compose.runOnUiThread {
                model.beginGeometry()
                model.changeGeometry(model.state.value.geometryDraft!!.rotated(true), true)
                model.cancelGeometry()
            }
            assertSame(applied.preview, model.state.value.preview)
            compose.runOnUiThread { model.beginGeometry(); model.applyGeometry() }
            assertNotNull(model.state.value.geometryDraft)
            awaitPreview()
            compose.runOnUiThread { model.applyGeometry() }
            compose.waitUntil(180_000) { model.state.value.canExport || model.state.value.error != null }
            assertNull(model.state.value.error)
            assertEquals(applied.edits, model.state.value.edits)
            assertEquals(applied.preview!!.canvasWidth, model.state.value.preview!!.canvasWidth)
        } finally { source.delete() }
    }

    private fun reviewConfiguration(): String {
        val config = compose.activity.resources.configuration
        val night = config.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK == android.content.res.Configuration.UI_MODE_NIGHT_YES
        return "${config.screenWidthDp}dp-${if (night) "dark" else "light"}-font${config.fontScale}"
    }

    private fun capture(name: String) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.getExternalFilesDir(null), "geometry-ui").apply { mkdirs() }
        compose.onRoot().captureToImage().asAndroidBitmap().let { bitmap ->
            File(directory, name).outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
        }
    }
}
