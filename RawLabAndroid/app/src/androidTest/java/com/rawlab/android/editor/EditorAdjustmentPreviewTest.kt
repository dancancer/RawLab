package com.rawlab.android.editor

import android.net.Uri
import android.os.SystemClock
import android.util.Log
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.MainActivity
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

    @Test fun continuousExposurePublishesPixelsWithoutRevertingTheLatestValue() {
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
            for (index in 1..180) {
                value = (index % 40) * .05f
                compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = value), true) }
                SystemClock.sleep(16)
                val state = model.state.value
                assertEquals("A completed preview must not overwrite newer edits", value, state.edits.exposure, .00001f)
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
            Log.i("RawLabGesturePerf", "dragMs=$draggingMs frames=$updates firstFrameMs=$firstFrameMs releaseMs=${SystemClock.elapsedRealtime() - released} final=$value")
            File(compose.activity.getExternalFilesDir(null), "adjustment-preview.txt").writeText(
                "dragMs=$draggingMs frames=$updates firstFrameMs=$firstFrameMs releaseMs=${SystemClock.elapsedRealtime() - released} final=$value")
            assertEquals(value, model.state.value.edits.exposure, .00001f)
            assertTrue("Continuous input must show completed preview frames before release", updates > 0)
        } finally { source.delete() }
    }
}
