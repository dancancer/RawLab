package com.rawlab.android.editor

import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.ui.graphics.asAndroidBitmap
import android.os.FileObserver
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.MainActivity
import com.rawlab.android.R
import com.rawlab.android.settings.ProcessingIdentity
import com.rawlab.android.testing.ForegroundTestRule
import com.rawlab.android.testing.LanguageTestRule
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

class ParameterInputRuntimeTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule()).around(ForegroundTestRule()).around(compose)

    @Test fun legacyHalfValueNoOpHasNoSaveOrPreviewAndNewValueKeepsOtherAxes() = verify(ProcessingIdentity.LEGACY)
    @Test fun currentHalfValueNoOpHasNoSaveOrPreviewAndNewValueKeepsOtherAxes() = verify(ProcessingIdentity.CURRENT)

    private fun verify(processing: ProcessingIdentity) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val source = File(compose.activity.cacheDir, "parameter-input-${System.nanoTime()}.RAW")
        instrumentation.context.assets.open("sample.RAW").use { input -> source.outputStream().use { input.copyTo(it) } }
        val model = compose.activity.model
        fun ready() {
            compose.waitUntil(180_000) { model.state.value.let { (it.canExport && !it.previewResizePending) || it.error != null } }
            assertNull(model.state.value.error)
        }
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            ready()
            compose.runOnUiThread { model.edit(model.state.value.edits.let { it.copy(processing = processing, hsl = it.hsl.withValue(0, 0, .5f)) }) }
            ready()
            compose.onNodeWithTag("editor-groups").performScrollToNode(hasTestTag("editor-group-color"))
            compose.onNodeWithTag("editor-group-color").performClick()
            compose.onNodeWithTag("editor-tools").performScrollToNode(hasTestTag("editor-tool-14"))
            compose.onNodeWithTag("editor-tool-14").performClick()
            ready()
            val snapshot = model.state.value
            val revision = EditorViewModel::class.java.getDeclaredField("currentRevision").apply { isAccessible = true }
            val beforeRequest = revision.getLong(model)
            val record = File(compose.activity.filesDir, "edits/edits.properties")
            val bytes = record.readBytes()
            val writes = AtomicInteger()
            val observer = object : FileObserver(record.parentFile!!, CLOSE_WRITE or MOVED_TO) {
                override fun onEvent(event: Int, path: String?) { if (path == record.name) writes.incrementAndGet() }
            }
            observer.startWatching()
            try {
                compose.onNodeWithTag("adjustment-value-${R.string.hsl_hue}").performScrollTo().assertTextContains("0.5").performClick()
                compose.onNodeWithTag("adjustment-input").assertTextContains("0.5").performTextReplacement("0.50")
                compose.onNodeWithTag("adjustment-input-apply").performClick()
                compose.waitForIdle()
                assertEquals(snapshot.edits, model.state.value.edits)
                assertSame(snapshot.preview, model.state.value.preview)
                assertEquals(beforeRequest, revision.getLong(model))
                assertArrayEquals(bytes, record.readBytes())
                assertEquals("Unchanged input performs zero disk writes", 0, writes.get())
                compose.onNodeWithTag("adjustment-input").assertDoesNotExist()
                val screenshots = File(compose.activity.getExternalFilesDir(null), "parameter-input-raw").apply { mkdirs() }
                File(screenshots, "${if (processing == ProcessingIdentity.LEGACY) "legacy" else "current"}-hsl-old.png").outputStream().use {
                    compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it)
                }
                compose.onNodeWithTag("adjustment-value-${R.string.hsl_hue}").performClick()
                compose.onNodeWithTag("adjustment-input").performTextReplacement("1")
                compose.onNodeWithTag("adjustment-input-apply").performClick()
                ready()
                assertEquals(snapshot.edits.copy(hsl = snapshot.edits.hsl.withValue(0, 0, 1f)), model.state.value.edits)
                assertEquals(processing, model.state.value.edits.processing)
                assertEquals("One new scalar input submits one render revision", beforeRequest + 1, revision.getLong(model))
            } finally { observer.stopWatching() }
        } finally { source.delete() }
    }
}
