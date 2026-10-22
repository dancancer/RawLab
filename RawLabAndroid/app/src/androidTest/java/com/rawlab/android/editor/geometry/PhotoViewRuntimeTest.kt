package com.rawlab.android.editor.geometry

import android.graphics.Bitmap
import android.net.Uri
import android.os.FileObserver
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.MainActivity
import com.rawlab.android.editor.AdjustmentGroup
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.LensSettings
import com.rawlab.android.settings.ProcessingIdentity
import com.rawlab.android.testing.ForegroundTestRule
import com.rawlab.android.testing.LanguageTestRule
import com.rawlab.android.testing.assertHistogramMatches
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

@OptIn(ExperimentalTestApi::class)
class PhotoViewRuntimeTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule()).around(ForegroundTestRule()).around(compose)
    @Test fun currentRawViewsKeepDefaultReferenceCommittedCompositionAndZeroWrites() = verify(ProcessingIdentity.CURRENT)
    @Test fun legacyRawViewsKeepDefaultReferenceCommittedCompositionAndZeroWrites() = verify(ProcessingIdentity.LEGACY)
    @Test fun rasterViewsKeepSensorReferenceAndZeroWrites() = verify(ProcessingIdentity.CURRENT, true)

    @Test fun actualRotationNormalKeepsSharedViewAndZeroWrites() = rotate(1f)
    @Test fun actualRotationLargeKeepsSharedViewAndZeroWrites() = rotate(1.6f)

    private fun rotate(scale: Float) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val source = File(compose.activity.cacheDir, "view-rotation-${UUID.randomUUID()}.RAW")
        instrumentation.context.assets.open("sample.RAW").use { input -> source.outputStream().use { input.copyTo(it) } }
        var observer: FileObserver? = null
        fun shell(command: String) = android.os.ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command)).use { it.readBytes() }
        try {
            shell("settings put system font_scale $scale")
            compose.waitUntil(20_000) { compose.activity.resources.configuration.fontScale == scale }
            compose.runOnUiThread { compose.activity.model.setGpuEnabled(false); compose.activity.model.importPhoto(Uri.fromFile(source)) }
            ready()
            val committed = compose.activity.model.state.value.edits
            val record = File(compose.activity.filesDir, "edits/edits.properties")
            val bytes = record.readBytes(); val inode = android.system.Os.stat(record.absolutePath).st_ino
            val writes = AtomicInteger()
            observer = object : FileObserver(record.parentFile!!.absolutePath, FileObserver.MOVED_TO) {
                override fun onEvent(event: Int, path: String?) { if (path == record.name) writes.incrementAndGet() }
            }.also { it.startWatching() }
            compose.onNodeWithContentDescription("开启对比").performClick(); ready()
            compose.onNodeWithTag("photo-canvas").performTouchInput {
                pinch(start0 = androidx.compose.ui.geometry.Offset(centerX - 40f, centerY), end0 = androidx.compose.ui.geometry.Offset(centerX - 80f, centerY),
                    start1 = androidx.compose.ui.geometry.Offset(centerX + 40f, centerY), end1 = androidx.compose.ui.geometry.Offset(centerX + 80f, centerY), durationMillis = 500)
            }; ready()
            compose.runOnUiThread { compose.activity.requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
            compose.waitUntil(20_000) { compose.activity.resources.configuration.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE }
            ready()
            compose.onNodeWithTag("comparison-before").assertIsDisplayed()
            compose.onNodeWithTag("comparison-after").assertIsDisplayed()
            compose.onNodeWithTag("adjustment-dock").assertIsDisplayed()
            compose.onNodeWithTag("photo-canvas").assert(SemanticsMatcher("Rotation retains magnification above fit") {
                !it.config[androidx.compose.ui.semantics.SemanticsProperties.StateDescription].startsWith("适合窗口")
            })
            capture("rotation-$scale-side.png")
            compose.onNodeWithTag("comparison-mode").performClick(); compose.onNodeWithText("分割线").performClick(); ready()
            val wipe = compose.onNodeWithTag("comparison-wipe")
            val photo = wipe.fetchSemanticsNode().boundsInRoot
            wipe.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.SetProgress) { it(.7f) }
            wipe.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.RequestFocus) { it() }
            wipe.performKeyInput { pressKey(androidx.compose.ui.input.key.Key.MoveHome) }
            wipe.assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.ProgressBarRangeInfo,
                androidx.compose.ui.semantics.ProgressBarRangeInfo(.5f, 0f..1f)))
            val density = compose.activity.resources.displayMetrics.density
            val handle = compose.onNodeWithTag("comparison-handle-glyph", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
            assertEquals(24f * density, handle.width, 1f); assertEquals(24f * density, handle.height, 1f)
            val backgrounds = listOf("comparison-label-before", "comparison-label-after").associateWith { tag ->
                compose.onNodeWithTag(tag, useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
            }
            for ((tag, background) in backgrounds) assertFalse("Actual short label background leaves the handle body visible: $tag $background $handle", background.overlaps(handle))
            android.util.Log.i("RawLabShortOverlayEvidence", "scale=$scale density=$density photo=$photo glyph=$handle backgrounds=$backgrounds")
            capture("rotation-$scale-wipe.png")
            android.util.Log.i("RawLabViewRotationEvidence", "scale=$scale root=${compose.onRoot().fetchSemanticsNode().boundsInRoot} photo=$photo dock=${compose.onNodeWithTag("adjustment-dock").fetchSemanticsNode().boundsInRoot}")
            assertEquals(committed, compose.activity.model.state.value.edits)
            assertEquals(inode, android.system.Os.stat(record.absolutePath).st_ino); assertArrayEquals(bytes, record.readBytes()); assertEquals(0, writes.get())
        } finally {
            observer?.stopWatching()
            compose.runOnUiThread { compose.activity.requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT }
            shell("settings put system font_scale 1.0"); source.delete()
        }
    }

    @Test fun backgroundCancelsAPhysicalHoldBeforeTheActivityResumes() {
        val source = File(compose.activity.cacheDir, "hold-${UUID.randomUUID()}.jpg")
        val bitmap = Bitmap.createBitmap(300, 200, Bitmap.Config.ARGB_8888).apply { eraseColor(android.graphics.Color.BLUE) }
        source.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it) }; bitmap.recycle()
        try {
            compose.runOnUiThread { compose.activity.model.setGpuEnabled(false); compose.activity.model.importPhoto(Uri.fromFile(source)) }; ready()
            compose.onNodeWithTag("photo-canvas").performTouchInput { down(center) }
            compose.waitUntil(3_000) { compose.onAllNodesWithTag("comparison-before").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithTag("comparison-before").assertIsDisplayed()
            compose.activityRule.scenario.moveToState(androidx.lifecycle.Lifecycle.State.CREATED)
            compose.activityRule.scenario.moveToState(androidx.lifecycle.Lifecycle.State.RESUMED)
            compose.onNodeWithTag("comparison-before").assertDoesNotExist()
            compose.onNodeWithTag("photo-canvas").performTouchInput { cancel() }
            compose.onNodeWithTag("adjustment-dock").assertIsDisplayed()
        } finally { source.delete() }
    }

    private fun ready() {
        compose.waitForIdle()
        compose.waitUntil(180_000) { compose.activity.model.state.value.let { it.canExport || it.error != null } }
        assertNull(compose.activity.model.state.value.error)
        compose.waitForIdle()
        compose.waitUntil(180_000) { compose.activity.model.state.value.let { it.canExport || it.error != null } }
        assertNull(compose.activity.model.state.value.error)
    }
    private fun previewEdge(model: com.rawlab.android.editor.EditorViewModel) =
        com.rawlab.android.editor.EditorViewModel::class.java.getDeclaredField("previewLongEdge").apply { isAccessible = true }.getInt(model)
    private fun capture(name: String) {
        val dir = File(compose.activity.getExternalFilesDir(null), "view-native").apply { mkdirs() }
        val screenshot = requireNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot())
        try { File(dir, name).outputStream().use { screenshot.compress(Bitmap.CompressFormat.PNG, 100, it) } }
        finally { screenshot.recycle() }
    }
    private fun verify(processing: ProcessingIdentity, raster: Boolean = false) {
        val source = File(compose.activity.cacheDir, "view-${UUID.randomUUID()}.${if (raster) "jpg" else "RAW"}")
        if (raster) {
            val bitmap = Bitmap.createBitmap(300, 200, Bitmap.Config.ARGB_8888)
            for (y in 0 until 200) for (x in 0 until 300) bitmap.setPixel(x, y, android.graphics.Color.rgb(x * 255 / 299, y * 255 / 199, 80))
            source.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it) }
            bitmap.recycle()
        } else InstrumentationRegistry.getInstrumentation().context.assets.open("sample.RAW").use { input -> source.outputStream().use { input.copyTo(it) } }
        val model = compose.activity.model
        var observer: FileObserver? = null
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            ready()
            if (model.state.value.edits.processing != processing) {
                compose.runOnUiThread { model.edit(model.state.value.edits.copy(processing = processing)) }
                ready()
            }
            compose.runOnUiThread {
                model.beginDraft(AdjustmentGroup.GEOMETRY)
                model.changeDraft(model.state.value.visibleEdits.copy(geometry = GeometrySettings(.1f, .1f, .8f, .8f, quarterTurns = 1)))
            }
            compose.waitUntil(180_000) { model.state.value.draftReady || model.state.value.error != null }
            assertNull(model.state.value.error)
            compose.runOnUiThread { assertTrue(model.applyDraft()) }
            ready()
            if (!raster) {
                compose.runOnUiThread {
                    model.beginDraft(AdjustmentGroup.LENS)
                    model.changeDraft(model.state.value.visibleEdits.copy(lens = LensSettings(distortion = true)))
                }
                compose.waitUntil(180_000) { model.state.value.draftReady || model.state.value.error != null }
                assertNull(model.state.value.error)
                compose.runOnUiThread { assertTrue(model.applyDraft()) }
                ready()
            }
            val neutralBeforeTone = model.state.value.preview!!.neutral
            val neutralBeforeHistogram = requireNotNull(model.state.value.preview!!.neutralHistogram)
            compose.runOnUiThread {
                val edit = model.state.value.edits.copy(exposure = .75f)
                model.edit(if (raster) edit else edit.copy(customWb = true, temperature = 4000f, tint = 5f))
            }
            ready()
            assertSame("User tone and WB cannot replace the neutral reference", neutralBeforeTone, model.state.value.preview!!.neutral)
            val settings = model.state.value.edits
            val accepted = model.state.value.preview!!
            assertSame(neutralBeforeHistogram, accepted.neutralHistogram)
            assertHistogramMatches(accepted.neutral, accepted.neutralHistogram)
            assertHistogramMatches(accepted.result, accepted.resultHistogram)
            NativeProcessor(NativeProcessor.CPU, model.storage.lensDatabase()).use { native ->
                val expected = native.preview(model.state.value.photo!!.file, null,
                    EditSettings(geometry = settings.geometry, lens = settings.lens, processing = processing),
                    previewEdge(model), false, model.state.value.photo!!.inputKind).bitmap()
                assertTrue("Actual default native reference includes committed geometry/lens and processing", expected.sameAs(accepted.neutral))
                expected.recycle()
            }
            val record = File(compose.activity.filesDir, "edits/edits.properties")
            val bytes = record.readBytes()
            val inode = android.system.Os.stat(record.absolutePath).st_ino
            val writes = AtomicInteger()
            observer = object : FileObserver(record.parentFile!!.absolutePath, FileObserver.MOVED_TO) {
                override fun onEvent(event: Int, path: String?) { if (path == record.name) writes.incrementAndGet() }
            }.also { it.startWatching() }
            compose.onNodeWithContentDescription("开启对比").performClick(); ready()
            compose.onNodeWithTag("comparison-before").assertIsDisplayed()
            val label = if (raster) "raster" else if (processing == ProcessingIdentity.LEGACY) "legacy" else "current"
            compose.onNodeWithTag("rgb-histogram-toggle").performClick()
            compose.onNodeWithTag("rgb-histogram-source").assertTextEquals("调整后")
            compose.onNodeWithTag("rgb-histogram-plot").assertIsDisplayed()
            capture("$label-rgb.png")
            compose.onNodeWithTag("rgb-histogram-close").performClick()
            capture("$label-side.png")
            compose.onNodeWithTag("comparison-mode").performClick()
            compose.onNodeWithText("分割线").performClick(); ready()
            compose.onNodeWithTag("comparison-wipe").performTouchInput { swipe(center, androidx.compose.ui.geometry.Offset(width * .7f, centerY), 400) }
            capture("$label-wipe.png")
            compose.onNodeWithContentDescription("关闭对比").performClick(); ready()
            compose.onNodeWithTag("rgb-histogram-toggle").performClick()
            compose.onNodeWithTag("photo-canvas").performCustomAccessibilityActionWithLabel("查看调整前")
            compose.onNodeWithTag("rgb-histogram-source").assertTextEquals("调整前")
            compose.onNodeWithTag("photo-canvas").performCustomAccessibilityActionWithLabel("返回调整后")
            compose.onNodeWithTag("rgb-histogram-source").assertTextEquals("调整后")
            compose.onNodeWithTag("photo-canvas").performTouchInput { down(androidx.compose.ui.geometry.Offset(8f, centerY)) }
            compose.waitUntil(3_000) { compose.onAllNodesWithText("调整前").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithTag("rgb-histogram-source").assertTextEquals("调整前")
            compose.onNodeWithTag("photo-canvas").performTouchInput { up() }
            compose.onNodeWithTag("rgb-histogram-source").assertTextEquals("调整后")
            compose.onNodeWithTag("adjustment-dock").assertIsDisplayed()
            compose.onNodeWithTag("photo-canvas").performTouchInput { click(androidx.compose.ui.geometry.Offset(8f, centerY)) }
            compose.waitUntil(3_000) { compose.onAllNodesWithTag("adjustment-dock").fetchSemanticsNodes().isEmpty() }; ready()
            compose.onNodeWithTag("adjustment-dock").assertDoesNotExist()
            compose.onNodeWithTag("rgb-histogram-popup").assertDoesNotExist()
            capture("$label-pure.png")
            InstrumentationRegistry.getInstrumentation().uiAutomation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK)
            compose.waitUntil(3_000) { compose.onAllNodesWithTag("adjustment-dock").fetchSemanticsNodes().isNotEmpty() }
            ready()
            compose.onNodeWithTag("adjustment-dock").assertIsDisplayed()
            compose.onNodeWithTag("rgb-histogram-plot").assertIsDisplayed()
            compose.onNodeWithTag("rgb-histogram-close").performClick()
            assertEquals(settings, model.state.value.edits)
            assertEquals(processing, model.state.value.edits.processing)
            assertEquals(inode, android.system.Os.stat(record.absolutePath).st_ino)
            assertArrayEquals(bytes, record.readBytes())
            assertEquals("View operations and viewport demand never save", 0, writes.get())
            android.util.Log.i("RawLabViewRuntimeEvidence", "$label processing=$processing writes=${writes.get()} inode=$inode neutral=${accepted.neutral.width}x${accepted.neutral.height} geometry=${settings.geometry} lens=${settings.lens}")
        } finally { observer?.stopWatching(); compose.runOnUiThread { model.discardDraft() }; source.delete() }
    }
}
