package com.rawlab.android.engine

import android.app.Application
import android.content.Context
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.os.Process
import android.os.SystemClock
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.viewModelScope
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import kotlinx.coroutines.Job
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import com.rawlab.android.batch.workflow.BatchTestCleanup
import com.rawlab.android.editor.EditSaveState
import com.rawlab.android.editor.EditorViewModel
import com.rawlab.android.editor.Operation
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.PhotoIdentity

class RestoredLookGpuModeTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    @get:Rule internal val cleanup = BatchTestCleanup(context)

    @Test fun disabledGpuUsesCpuWhileValidatingARestoredMissingLook() = validate(false, 0)

    @Test fun enabledGpuKeepsAutoWhileValidatingARestoredMissingLook() = validate(true, 2)

    private fun validate(gpuEnabled: Boolean, expectedBackend: Int) {
        val id = UUID.randomUUID().toString()
        cleanup.begin(id)
        val input = File(context.filesDir, "RawLab/BatchJobs/$id/inputs/source.arw").apply { parentFile!!.mkdirs() }
        val application = OwnedApplication(context, File(input.parentFile!!.parentFile, "editor"))
        val uri = Uri.fromFile(input)
        val identity = PhotoIdentity(uri.toString())
        val settings = EditSettings(film = UUID.randomUUID().toString(), customWb = true, exposure = .25f)
        val store = ViewModelStore()
        var model: EditorViewModel? = null
        try {
            instrumentation.context.assets.open("sample.RAW").use { from -> input.outputStream().use { from.copyTo(it) } }
            NativeProcessor(NativeProcessor.AUTO).use {
                assertEquals("Probe NOT REACHED: AUTO fixture must actually support GLES", 2,
                    it.preview(input, null, settings.copy(film = "neutral"), 256, false).backend)
            }
            EditStore(File(application.filesDir, "edits")).save(identity, settings)
            val before = reports()
            instrumentation.runOnMainSync {
                model = EditorViewModel(application).also {
                    store.put("missing-look", it)
                    it.setGpuEnabled(gpuEnabled)
                    it.importPhoto(uri)
                }
            }
            val deadline = SystemClock.elapsedRealtime() + 30_000
            while (model!!.state.value.operation != Operation.NONE && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(10)
            val state = model!!.state.value
            assertEquals(Operation.NONE, state.operation)
            assertFalse(state.rendering)
            assertEquals(gpuEnabled, state.gpuEnabled)
            assertEquals(identity, state.photo?.identity)
            assertTrue(state.photo!!.file.canonicalPath.startsWith(application.cacheDir.canonicalPath + File.separator))
            assertEquals(settings, state.edits)
            assertEquals(EditSaveState.RESTORED, state.saveState)
            assertNotNull(state.error)
            assertNull(state.preview)
            val after = reports()
            assertEquals("The log cursor must remain intact", before, after.take(before.size))
            assertEquals("Observe the actual validation frame, not a later session probe", listOf(
                "missingLookValidationBackend=$expectedBackend"), after.drop(before.size))
            instrumentation.sendStatus(2, android.os.Bundle().apply {
                putString("stream", "Restored missing look gpuEnabled=$gpuEnabled actualValidationBackend=$expectedBackend realNative=true\n")
            })
        } finally {
            cleanup.finish(active = model?.state?.value?.let { it.rendering || it.operation != Operation.NONE } == true,
                cancel = {}, close = {
                    instrumentation.runOnMainSync { store.clear() }
                    runBlocking { withTimeout(10_000) { model?.viewModelScope?.coroutineContext?.get(Job)?.join() } }
                    model?.storage?.let { synchronized(it) { } }
                })
        }
    }

    private fun reports() = ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(
        "logcat -d --pid=${Process.myPid()} -v raw -s RawLabImport:I")).use { stream ->
        stream.bufferedReader().readLines().filter { it.startsWith("missingLookValidationBackend=") }
    }

    // 崩溃后无法调用 ViewModel.close；编辑记录和随机工作副本也必须属于已登记的 fixture。
    private class OwnedApplication(context: Context, private val root: File) : Application() {
        init { attachBaseContext(context) }
        override fun getFilesDir() = File(root, "files").apply { mkdirs() }
        override fun getCacheDir() = File(root, "cache").apply { mkdirs() }
    }
}
