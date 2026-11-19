package com.rawlab.android.editor

import android.net.Uri
import android.os.SystemClock
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.PhotoIdentity
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class EditorViewModelPreviewResizeInstrumentedTest {
    @Test fun viewportEdgeRecordedDuringDraftAppliesWhenTheDraftCloses() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val source = File(context.cacheDir, "draft-resize-${System.nanoTime()}.RAW")
        instrumentation.context.assets.open("sample.RAW").use { input ->
            source.outputStream().use { input.copyTo(it) }
        }
        val owner = ViewModelStore()
        lateinit var model: EditorViewModel
        instrumentation.runOnMainSync {
            model = EditorViewModel(context.applicationContext as android.app.Application)
            owner.put("editor", model)
        }
        val edits = EditStore(File(context.filesDir, "edits"))
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
            assertNotNull("Exposure draft must open", awaitState(30_000) { it.draft != null }.draft)
            instrumentation.runOnMainSync { model.updatePreviewSize(640) }
            instrumentation.runOnMainSync { model.discardDraft() }
            val settled = awaitState(60_000) {
                it.error != null || (it.canExport && !it.previewResizePending && edge(it) == 640)
            }
            assertNull(settled.error)
            assertEquals(640, edge(settled))
        } finally {
            instrumentation.runOnMainSync { owner.clear() }
            edits.reset(identity)
            source.delete()
        }
    }
}
