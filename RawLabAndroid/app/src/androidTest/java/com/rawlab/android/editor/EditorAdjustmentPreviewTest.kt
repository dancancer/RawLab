package com.rawlab.android.editor

import android.net.Uri
import android.os.SystemClock
import android.util.Log
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.doubleClick
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performTouchInput
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.MainActivity
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.testing.ForegroundTestRule
import com.rawlab.android.testing.LanguageTestRule
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File

class EditorAdjustmentPreviewTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule()).around(ForegroundTestRule()).around(compose)

    // k826-1 撤牙齿：基线上 updatePreviewSize 在草稿分支直接丢弃视口边长，草稿关闭后
    // 提交预览长边卡在旧值（重开工程才恢复），此断言红；修复后按记录边长收敛为绿。
    // 碳审返工 B：模型改挂独立 ViewModelStore，等待改纯模型态轮询（对齐 AdjustmentHistory.await 的
    // 稳定形态）——MainActivity 真实 1600 画布合法重报不再与合成 640 赛跑，Compose 空闲时钟
    // 也不再参与判定；updatePreviewSize 唯一来源即本测试，任意分辨率确定性收敛。
    @Test fun viewportEdgeRecordedDuringDraftAppliesWhenTheDraftCloses() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val source = File(compose.activity.cacheDir, "draft-resize-${System.nanoTime()}.RAW")
        instrumentation.context.assets.open("sample.RAW").use { input ->
            source.outputStream().use { input.copyTo(it) }
        }
        val owner = ViewModelStore()
        val model = EditorViewModel(compose.activity.application)
        owner.put("editor", model)
        val edits = EditStore(File(compose.activity.filesDir, "edits"))
        val identity = PhotoIdentity(Uri.fromFile(source).toString())
        fun edge(state: EditorState) = state.preview?.let { maxOf(it.result.width, it.result.height) } ?: 0
        fun awaitState(timeoutMs: Long, condition: (EditorState) -> Boolean): EditorState {
            val deadline = SystemClock.uptimeMillis() + timeoutMs
            var last = model.state.value
            while (!condition(last) && SystemClock.uptimeMillis() < deadline) {
                SystemClock.sleep(20)
                last = model.state.value
            }
            return last
        }
        try {
            instrumentation.runOnMainSync { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            assertNull(awaitState(180_000) { it.error != null || it.canExport }.error)
            instrumentation.runOnMainSync { model.beginDraft(AdjustmentGroup.EXPOSURE) }
            assertNotNull("HSL/EXPOSURE draft must open", awaitState(30_000) { it.draft != null }.draft)
            // 草稿期间的视口边长变化：必须被记录，并在草稿关闭时应用。
            instrumentation.runOnMainSync { model.updatePreviewSize(640) }
            instrumentation.runOnMainSync { model.discardDraft() }
            val settled = awaitState(60_000) {
                it.error != null || (it.canExport && !it.previewResizePending && edge(it) == 640)
            }
            assertNull(settled.error)
            assertTrue("Viewport edge requested during a draft must apply when the draft closes; " +
                "edge=${edge(settled)} canExport=${settled.canExport} resizePending=${settled.previewResizePending}",
                edge(settled) == 640)
        } finally {
            instrumentation.runOnMainSync { owner.clear() }
            edits.reset(identity)
            source.delete()
        }
    }

    @Test fun completedViewportSizesAreReusedUntilThePhotoIsEdited() {
        val source = File(compose.activity.cacheDir, "viewport-reuse-${System.nanoTime()}.RAW")
        InstrumentationRegistry.getInstrumentation().context.assets.open("sample.RAW").use { input ->
            source.outputStream().use { input.copyTo(it) }
        }
        val model = compose.activity.model
        fun ready(timeout: Long = 30_000, width: (Int) -> Boolean = { true }): PreviewPair {
            val started = SystemClock.elapsedRealtime()
            compose.waitUntil(timeout) {
                model.state.value.let { it.error != null || it.canExport && !it.previewResizePending &&
                    it.preview?.result?.width?.let(width) == true }
            }
            assertNull(model.state.value.error)
            return checkNotNull(model.state.value.preview).also {
                val measurement = "viewportMs=${SystemClock.elapsedRealtime() - started} width=${it.result.width} height=${it.result.height}"
                Log.i("RawLabGesturePerf", measurement)
                File(compose.activity.getExternalFilesDir(null), "viewport-preview.txt").appendText("$measurement\n")
            }
        }
        val canvas = compose.onNodeWithTag("photo-canvas")
        fun toggleZoom(actual: Boolean) {
            canvas.performTouchInput { doubleClick(center) }
            canvas.assert(SemanticsMatcher("Actual pixels: $actual") { node ->
                (node.config[SemanticsProperties.StateDescription] == "100%") == actual
            })
        }
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            ready(180_000); compose.waitForIdle()
            val fit = ready()
            toggleZoom(actual = true)
            // 大屏的 Fit 可能已达到移动预览上限；100% 不会再请求超过 1600px 的帧。
            val zoom = ready { it >= fit.result.width }
            assertEquals(1600, maxOf(zoom.result.width, zoom.result.height))
            toggleZoom(actual = false)
            assertTrue("Fit must reuse its completed frame", fit === ready { it == fit.result.width })
            toggleZoom(actual = true)
            assertTrue("100% must reuse its completed frame", zoom === ready { it == zoom.result.width })
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = 0.5f), false) }
            assertTrue("Editing must replace the 100% frame", zoom !== ready())
            toggleZoom(actual = false)
            assertTrue("An old Fit frame must not be reused after editing", fit !== ready { it == fit.result.width })
        } finally { source.delete() }
    }

    @Test fun hdrExposureEditReusesTheUnchangedComparisonFrame() {
        val source = File(compose.activity.cacheDir, "hdr-reference-${System.nanoTime()}.jpg")
        InstrumentationRegistry.getInstrumentation().context.assets.open("apple-legacy-macos26.jpg").use { input ->
            source.outputStream().use { input.copyTo(it) }
        }
        val model = compose.activity.model
        fun ready(): PreviewPair {
            compose.waitUntil(120_000) { model.state.value.let { (it.canExport && !it.previewResizePending) || it.error != null } }
            assertNull(model.state.value.error)
            return checkNotNull(model.state.value.preview)
        }
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            ready(); compose.waitForIdle()
            val before = ready()
            assertNotNull(before.hdr)
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = 0.5f), false) }
            val after = ready()
            assertNotNull(after.hdr)
            assertSame("The neutral HDR bitmap is still valid", before.neutral, after.neutral)
            assertNotSame("An exposure change must replace the edited HDR bitmap", before.result, after.result)
        } finally { source.delete() }
    }

    @Test fun cpuViewportRequestsKeepPixelsVisibleAndReuseBothCompletedSizes() {
        val source = File(compose.activity.cacheDir, "cpu-viewport-${System.nanoTime()}.RAW")
        InstrumentationRegistry.getInstrumentation().context.assets.open("sample.RAW").use { input ->
            source.outputStream().use { input.copyTo(it) }
        }
        val model = compose.activity.model
        fun ready(edge: Int? = null): PreviewPair {
            compose.waitUntil(if (edge == null) 180_000 else 30_000) {
                model.state.value.let { it.error != null || it.canExport &&
                    (edge == null || it.preview?.result?.let { bitmap -> maxOf(bitmap.width, bitmap.height) == edge } == true) }
            }
            assertNull(model.state.value.error)
            return checkNotNull(model.state.value.preview)
        }
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            ready(); compose.waitForIdle()
            compose.runOnUiThread { model.updatePreviewSize(640) }
            ready(640)
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = .25f), false) }
            val proxy = ready(640)
            val started = SystemClock.elapsedRealtime()
            compose.runOnUiThread {
                model.updatePreviewSize(1600)
                assertSame("A viewport request must return before replacing visible pixels", proxy, model.state.value.preview)
                assertTrue(model.state.value.rendering)
            }
            val refined = ready(1600)
            val measurement = "cpuViewport640To1600Ms=${SystemClock.elapsedRealtime() - started}"
            Log.i("RawLabGesturePerf", measurement)
            File(compose.activity.getExternalFilesDir(null), "cpu-viewport-preview.txt").writeText(measurement)
            assertNotSame(proxy, refined)
            compose.runOnUiThread { model.updatePreviewSize(640) }
            assertSame(proxy, ready(640))
            compose.runOnUiThread { model.updatePreviewSize(1600) }
            assertSame(refined, ready(1600))
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = .5f), false) }
            assertNotSame(refined, ready(1600))
            compose.runOnUiThread { model.updatePreviewSize(640) }
            assertNotSame(proxy, ready(640))
        } finally { source.delete() }
    }

    @Test fun continuousExposurePublishesPixelsWithoutRevertingTheLatestValue() = continuousEdits(false)

    @Test fun continuousWhiteBalancePublishesPixelsWithoutRevertingTheLatestValue() = continuousEdits(true)

    private fun continuousEdits(whiteBalance: Boolean) {
        val source = File(compose.activity.cacheDir, "adjustment-preview-${System.nanoTime()}.RAW")
        InstrumentationRegistry.getInstrumentation().context.assets.open("sample.RAW").use { input ->
            source.outputStream().use { input.copyTo(it) }
        }
        val model = compose.activity.model
        fun ready() {
            compose.waitUntil(180_000) { model.state.value.let { (it.canExport && !it.previewResizePending) || it.error != null } }
            assertNull(model.state.value.error)
        }
        try {
            compose.runOnUiThread { model.setGpuEnabled(true); model.importPhoto(Uri.fromFile(source)) }
            ready()
            compose.runOnUiThread { model.updatePreviewSize(1600) }
            ready()
            var preview = model.state.value.preview
            var updates = 0
            val started = SystemClock.elapsedRealtime()
            var firstFrameMs: Long? = null
            var value = 0f
            var temperature = 6500f
            for (index in 1..180) {
                value = (index % 40) * .05f
                temperature = if (whiteBalance) 6500f + index * 5f else 6500f
                compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = value,
                    customWb = whiteBalance, temperature = temperature), true) }
                SystemClock.sleep(16)
                val state = model.state.value
                assertEquals("A completed preview must not overwrite newer edits", value, state.edits.exposure, .00001f)
                if (whiteBalance) assertEquals("A completed preview must not overwrite newer white balance", temperature, state.edits.temperature, .00001f)
                if (state.preview !== preview) {
                    updates++
                    if (firstFrameMs == null) firstFrameMs = SystemClock.elapsedRealtime() - started
                    preview = state.preview
                }
            }
            val draggingMs = SystemClock.elapsedRealtime() - started
            val released = SystemClock.elapsedRealtime()
            compose.runOnUiThread { model.edit(model.state.value.edits, false) }
            ready()
            val measurement = "whiteBalance=$whiteBalance dragMs=$draggingMs frames=$updates firstFrameMs=$firstFrameMs releaseMs=${SystemClock.elapsedRealtime() - released} final=$value temperature=$temperature"
            Log.i("RawLabGesturePerf", measurement)
            File(compose.activity.getExternalFilesDir(null), "adjustment-preview-$whiteBalance.txt").writeText(measurement)
            assertEquals(value, model.state.value.edits.exposure, .00001f)
            if (whiteBalance) assertEquals(temperature, model.state.value.edits.temperature, .00001f)
            assertTrue("Continuous input must show completed preview frames before release", updates > 0)
        } finally { source.delete() }
    }
}
