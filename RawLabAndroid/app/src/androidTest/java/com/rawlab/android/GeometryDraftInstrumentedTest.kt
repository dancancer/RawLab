package com.rawlab.android

import android.net.Uri
import androidx.lifecycle.ViewModelStore
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File
import java.security.MessageDigest

class GeometryDraftInstrumentedTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule()).around(ForegroundTestRule()).around(compose)

    @Test fun originalRatioUsesNativeSourceAfterCropResizeRotationAndSwap() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val root = File(instrumentation.targetContext.cacheDir, "geometry-original-${System.nanoTime()}").apply { mkdirs() }
        val source = File(root, "source.RAW")
        instrumentation.context.assets.open("sample.RAW").use { from -> source.outputStream().use { from.copyTo(it) } }
        val store = ViewModelStore()
        lateinit var model: EditorViewModel
        // 由测试独占预览尺寸请求，避免画布按屏幕尺寸再次提交需求。
        compose.runOnUiThread {
            model = EditorViewModel(compose.activity.application)
            store.put("original-ratio", model)
        }
        fun ready(draft: Boolean = false) {
            compose.waitUntil(180_000) { model.state.value.error != null ||
                if (draft) model.state.value.canApplyDraft else model.state.value.canExport }
            assertNull(model.state.value.error)
        }
        try {
            val reference = NativeProcessor(NativeProcessor.CPU).use { it.preview(source, null, EditSettings(), 127, false) }
            val originalAspect = reference.geometryWidth.toFloat() / reference.geometryHeight
            assertTrue("Fixture must expose full native dimensions", maxOf(reference.geometryWidth, reference.geometryHeight) > 1600)
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            ready()
            val pair = model.state.value.preview!!
            assertEquals(originalAspect, pair.originalAspect, .000001f)
            assertTrue("Fixture must distinguish resized bitmap aspect", kotlin.math.abs(originalAspect - pair.neutral.width.toFloat() / pair.neutral.height) > .00001f)
            compose.runOnUiThread {
                model.edit(EditSettings(customWb = true, geometry = GeometrySettings(cropWidth = .63f, cropHeight = .71f,
                    quarterTurns = 1, perspectiveHorizontal = .25f)))
            }
            ready()
            compose.runOnUiThread { model.updatePreviewSize(320) }
            compose.waitUntil(180_000) { model.state.value.error != null || (model.state.value.canExport &&
                model.state.value.preview!!.result.let { maxOf(it.width, it.height) <= 320 }) }
            assertNull(model.state.value.error)
            assertEquals(originalAspect, model.state.value.preview!!.originalAspect, .000001f)
            compose.runOnUiThread { model.beginDraft(AdjustmentGroup.GEOMETRY) }
            ready(true)
            val portrait = originalAspect >= 1f
            assertEquals(portrait, model.state.value.draft!!.geometryPortrait)
            for (direction in listOf(portrait, !portrait)) {
                compose.runOnUiThread { model.chooseGeometryRatio(GeometryRatio.ORIGINAL, direction) }
                val draft = model.state.value.draft!!
                val landscape = maxOf(originalAspect, 1f / originalAspect)
                val expected = if (direction) 1f / landscape else landscape
                assertEquals(expected, draft.geometryAspect!!, .000001f)
                assertEquals(expected, draft.value.geometry.cropWidth * draft.geometryCanvasAspect / draft.value.geometry.cropHeight, .00001f)
            }
            compose.runOnUiThread { model.discardDraft() }
            ready()
        } finally {
            compose.runOnUiThread { store.clear() }
            root.deleteRecursively()
        }
    }

    @Test fun perspectiveDraftApplyCancelLeaveRecreationAndRestart() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val phase = InstrumentationRegistry.getArguments().getString("geometryRestartPhase") ?: "complete"
        require(phase in listOf("complete", "prepare", "resume"))
        val root = File(context.cacheDir, "geometry-draft-runtime")
        val source = File(root, "source.RAW")
        val expectedFile = File(root, "expected.txt")
        val hashFile = File(root, "source.sha256")
        var model = compose.activity.model
        fun ready(draft: Boolean = false) {
            compose.waitUntil(180_000) { model.state.value.error != null ||
                if (draft) model.state.value.canApplyDraft else model.state.value.canExport }
            assertNull(model.state.value.error)
        }
        fun hash() = MessageDigest.getInstance("SHA-256").digest(source.readBytes()).joinToString("") { "%02x".format(it) }
        try {
            if (phase != "resume") {
                root.mkdirs()
                instrumentation.context.assets.open("sample.RAW").use { from -> source.outputStream().use { from.copyTo(it) } }
                hashFile.writeText(hash())
                compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
                ready()
                compose.runOnUiThread { model.edit(EditSettings(customWb = true, exposure = .5f)) }
                ready()
                val original = model.state.value.edits
                val identity = model.state.value.photo!!.identity
                fun stored() = EditStore(File(context.filesDir, "edits")).load(identity)
                compose.runOnUiThread {
                    model.beginDraft(AdjustmentGroup.GEOMETRY)
                    model.changeDraft(original.copy(geometry = GeometrySettings(perspectiveHorizontal = .25f, perspectiveVertical = -.2f)))
                    assertFalse(model.state.value.canApplyDraft)
                    model.applyDraft()
                    assertEquals(original, model.state.value.edits)
                }
                ready(true)
                compose.runOnUiThread { model.chooseGeometryRatio(GeometryRatio.FOUR_THREE, false) }
                val preview = model.state.value.preview
                compose.runOnUiThread {
                    val edits = model.state.value.visibleEdits
                    model.changeDraft(edits.copy(geometry = GeometryCropMath.resize(edits.geometry, GeometryCropCorner.BOTTOM_RIGHT,
                        -.15f, -.15f, 4f / 3f, model.state.value.draft!!.geometryCanvasAspect)))
                    assertFalse(model.state.value.rendering)
                    assertSame(preview, model.state.value.preview)
                }
                val beforeTransform = model.state.value.visibleEdits.geometry
                var newestCrop = beforeTransform
                compose.runOnUiThread {
                    model.changeDraft(model.state.value.visibleEdits.copy(geometry = beforeTransform.copy(quarterTurns = 1, straightenDegrees = 7f)))
                    assertFalse(model.state.value.canApplyDraft)
                    assertFalse(model.beginExport())
                    model.beginBatch()
                    assertNull(model.batch.value)
                    newestCrop = model.state.value.visibleEdits.geometry.moveCrop(.03f, -.02f)
                    model.changeDraft(model.state.value.visibleEdits.copy(geometry = newestCrop), true)
                }
                ready(true)
                val refitted = model.state.value.visibleEdits.geometry
                assertEquals(4f / 3f, refitted.cropWidth * model.state.value.draft!!.geometryCanvasAspect / refitted.cropHeight, .0001f)
                assertTrue(refitted.cropWidth * refitted.cropHeight <= beforeTransform.cropWidth * beforeTransform.cropHeight + .00001f)
                assertEquals(newestCrop.cropX + newestCrop.cropWidth / 2f, refitted.cropX + refitted.cropWidth / 2f, .00001f)
                assertEquals(newestCrop.cropY + newestCrop.cropHeight / 2f, refitted.cropY + refitted.cropHeight / 2f, .00001f)
                assertEquals(original, stored())
                compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
                compose.onNodeWithText(context.getString(R.string.adjustment_continue)).performClick()
                assertNotNull(model.state.value.draft)
                compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
                compose.onNodeWithText(context.getString(R.string.adjustment_discard)).performClick()
                ready()
                assertEquals(original, model.state.value.edits)
                assertEquals(original, stored())
                compose.runOnUiThread {
                    model.beginDraft(AdjustmentGroup.GEOMETRY)
                    model.changeDraft(original.copy(geometry = refitted))
                }
                ready(true)
                val expectedDraft = model.state.value.draft
                compose.activityRule.scenario.recreate()
                compose.activityRule.scenario.onActivity { model = it.model }
                assertEquals(expectedDraft, model.state.value.draft)
                compose.runOnUiThread { model.applyDraft() }
                ready()
                val applied = model.state.value.edits
                assertEquals(refitted, applied.geometry)
                assertEquals(applied, stored())
                expectedFile.writeText(SettingsCodec.encode(applied))
                if (phase == "prepare") return
            }
            assertTrue("Run the prepare invocation before the process-restart resume", source.isFile && expectedFile.isFile && hashFile.isFile)
            val expected = SettingsCodec.decode(expectedFile.readText())
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            ready()
            assertEquals(expected, model.state.value.edits)
            assertEquals(EditSaveState.RESTORED, model.state.value.saveState)
            assertNull(model.state.value.draft)
            assertEquals(hashFile.readText(), hash())
            compose.runOnUiThread { model.beginDraft(AdjustmentGroup.GEOMETRY) }
            ready(true)
            assertEquals(expected.geometry, model.state.value.visibleEdits.geometry)
            compose.runOnUiThread {
                model.changeDraft(model.state.value.visibleEdits.copy(
                    geometry = model.state.value.visibleEdits.geometry.copy(perspectiveHorizontal = -.5f)), true)
                model.discardDraft()
            }
            ready()
            assertEquals(expected, model.state.value.edits)
        } finally {
            // prepare 保留测试专属输入，供宿主 force-stop 后的新进程恢复验证。
            if (phase != "prepare") root.deleteRecursively()
        }
    }
}
