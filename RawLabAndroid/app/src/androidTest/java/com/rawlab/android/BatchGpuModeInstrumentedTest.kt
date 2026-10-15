package com.rawlab.android

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID

class BatchGpuModeInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Test fun resumedBatchWithGpuDisabledUsesCpuForPreviewAndOriginalSizeCleanExport() {
        val settings = EditSettings(customWb = true, exposure = .5f, contrast = .2f,
            denoise = DenoiseSettings(true, 10f, 72f, 100f))
        withBatch(gpuEnabled = false, settings = settings, resumed = true, format = ExportFormat.JPEG) { batch ->
            assertPreviewMatchesMode(batch, NativeProcessor.CPU)
            exportAndCompare(batch, NativeProcessor.CPU, "resumed-cpu-clean", ExportFormat.JPEG, null)
        }
    }

    @Test fun enabledNewAndResumedBatchesUseGlesInsteadOfBeingPinnedToCpu() {
        val settings = EditSettings(customWb = true, exposure = .5f, contrast = .2f)
        for (resumed in listOf(true, false)) {
            withBatch(gpuEnabled = true, settings = settings, resumed = resumed, longEdge = 300) { batch ->
                assertPreviewMatchesMode(batch, NativeProcessor.FORCE)
                exportAndCompare(batch, NativeProcessor.FORCE, "${if (resumed) "resumed" else "new"}-auto-gles", distinguishCpu = true)
            }
        }
    }

    @Test fun enabledNewAndResumedBatchesFallBackForCpuOnlyRlookWhileForceExportFails() {
        val settings = EditSettings(film = "synthetic-fallback", customWb = true, exposure = .5f)
        for (resumed in listOf(true, false)) {
            withBatch(gpuEnabled = true, settings = settings, resumed = resumed, longEdge = 300,
                rlook = true) { batch ->
                val source = batch.state.value.job.source
                val target = batch.state.value.job.rows.single().target.sourceFile
                val rejected = File(target.parentFile, "force-rejected.png")
                val sentinel = byteArrayOf(7, 11, 19)
                rejected.writeBytes(sentinel)
                NativeProcessor(NativeProcessor.FORCE).use { processor ->
                    assertThrows(IOException::class.java) {
                        processor.export(target, source.lookFile, source.settings, rejected, ExportFormat.PNG, 300)
                    }
                }
                assertArrayEquals("Force must reject rather than overwrite the output", sentinel, rejected.readBytes())
                NativeProcessor(NativeProcessor.AUTO).use { processor ->
                    val frame = processor.preview(target, source.lookFile, source.settings, 1280, true)
                    assertEquals(0, frame.backend)
                    val expected = frame.bitmap()
                    val actual = runBlocking { batch.preview(batch.state.value.job.rows.single().target) }
                    try { assertTrue("AUTO batch preview falls back for RLOOK", actual.sameAs(expected)) }
                    finally { expected.recycle(); actual.recycle() }
                }
                status("rlook forceExportRejected=true existingOutputUnchanged=true autoPreviewBackend=0")
                exportAndCompare(batch, NativeProcessor.CPU, "${if (resumed) "resumed" else "new"}-auto-rlook-fallback")
            }
        }
    }

    private fun withBatch(gpuEnabled: Boolean, settings: EditSettings, resumed: Boolean,
                          longEdge: Int? = null, rlook: Boolean = false, format: ExportFormat = ExportFormat.PNG,
                          check: (BatchExportModel) -> Unit) {
        val id = UUID.randomUUID().toString()
        val journalRoot = File(context.filesDir, "RawLab/BatchJobs")
        val inputs = File(journalRoot, "$id/inputs").apply { mkdirs() }
        val source = File(inputs, "source.dng")
        instrumentation.context.assets.open("sample.RAW").use { from -> source.outputStream().use { from.copyTo(it) } }
        val target = File(inputs, "target.dng").also { source.copyTo(it) }
        val before = digest(source)
        val look = if (rlook) File(inputs, "synthetic.rlook").apply { writeBytes(syntheticRlook()) } else null
        val journal = BatchJournal(journalRoot)
        val model = compose.activity.model
        var managedLookId: String? = null
        try {
            val effectiveSettings = if (look != null && !resumed) {
                val imported = PhotoStorage(context).use { it.importLook(Uri.fromFile(look)) }
                managedLookId = imported.id
                settings.copy(film = imported.id)
            } else settings
            compose.runOnUiThread { model.setGpuEnabled(gpuEnabled) }
            assertEquals(gpuEnabled, model.state.value.gpuEnabled)
            if (resumed) {
                val snapshot = BatchSourceSnapshot(PhotoIdentity(Uri.fromFile(source).toString()), source, effectiveSettings, lookFile = look)
                val job = BatchJob(snapshot, listOf(BatchTarget(PhotoIdentity(Uri.fromFile(target).toString()), target, target.name)),
                    id = id, outputFormat = format, outputLongEdge = longEdge)
                journal.save(job.withRows(job.rows.map { it.copy(status = BatchRowStatus.PROCESSING) }))
                val loaded = requireNotNull(journal.load(id))
                assertEquals(BatchRowStatus.PENDING, loaded.rows.single().status)
                compose.runOnUiThread { model.resumeBatch(loaded) }
                compose.waitUntil(60_000) { model.batch.value?.state?.value?.phase != BatchPhase.PREPARING }
                assertEquals(BatchPhase.CANCELLED, model.batch.value!!.state.value.phase)
            } else {
                compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
                compose.waitUntil(180_000) { model.state.value.canExport || model.state.value.error != null }
                assertNull(model.state.value.error)
                compose.runOnUiThread { model.edit(effectiveSettings) }
                compose.waitUntil(180_000) { model.state.value.canExport || model.state.value.error != null }
                assertNull(model.state.value.error)
                compose.runOnUiThread { model.beginBatch() }
                compose.waitUntil(60_000) { model.batch.value?.state?.value?.phase == BatchPhase.SELECTING }
                compose.runOnUiThread { model.batch.value!!.addUris(listOf(Uri.fromFile(target))) }
                compose.waitUntil(180_000) { model.batch.value!!.state.value.phase != BatchPhase.PREPARING }
            }
            val batch = requireNotNull(model.batch.value)
            assertNull(batch.state.value.error)
            assertEquals(effectiveSettings, batch.state.value.job.source.settings)
            check(batch)
            assertEquals(before, digest(source))
            assertEquals(before, digest(target))
            assertFalse(journal.pending().contains(batch.state.value.job.id))
        } finally {
            val batch = model.batch.value
            batch?.state?.value?.job?.rows?.mapNotNull { it.outputUri }?.forEach {
                context.contentResolver.delete(Uri.parse(it), null, null)
            }
            if (batch?.state?.value?.phase in setOf(BatchPhase.PREPARING, BatchPhase.RUNNING)) batch?.cancel()
            else {
                compose.runOnUiThread { model.closeBatch() }
                batch?.state?.value?.job?.id?.let(journal::discard)
                journal.discard(id)
                managedLookId?.let { lookId -> PhotoStorage(context).use { it.deleteLook(lookId) } }
            }
        }
    }

    private fun assertPreviewMatchesMode(batch: BatchExportModel, expectedMode: Int) {
        val source = batch.state.value.job.source
        val target = batch.state.value.job.rows.single().target.sourceFile
        val cpu = NativeProcessor(NativeProcessor.CPU).use { it.preview(target, source.lookFile, source.settings, 1280, true) }
        val gles = NativeProcessor(NativeProcessor.FORCE).use { it.preview(target, source.lookFile, source.settings, 1280, true) }
        assertEquals(0, cpu.backend)
        assertEquals(2, gles.backend)
        val cpuBitmap = cpu.bitmap()
        val glesBitmap = gles.bitmap()
        val actual = runBlocking { batch.preview(batch.state.value.job.rows.single().target) }
        try {
            assertFalse("Fixture must distinguish CPU and GLES preview pixels", cpuBitmap.sameAs(glesBitmap))
            assertTrue("Batch preview must use the editor-selected mode",
                actual.sameAs(if (expectedMode == NativeProcessor.CPU) cpuBitmap else glesBitmap))
            status("preview expectedMode=$expectedMode pixelParity=true cpuGlesDistinct=true")
        } finally { cpuBitmap.recycle(); glesBitmap.recycle(); actual.recycle() }
    }

    private fun exportAndCompare(batch: BatchExportModel, referenceMode: Int, label: String,
                                 format: ExportFormat = ExportFormat.PNG, longEdge: Int? = 300,
                                 distinguishCpu: Boolean = false) {
        val started = SystemClock.elapsedRealtime()
        status("$label exportStarted format=$format longEdge=$longEdge")
        compose.runOnUiThread {
            if (batch.state.value.phase == BatchPhase.SELECTING) batch.start(format, null, longEdge)
            else batch.retryFailed()
        }
        compose.waitUntil(240_000) { batch.state.value.phase !in setOf(BatchPhase.RUNNING, BatchPhase.PREPARING) }
        status("$label exportMs=${SystemClock.elapsedRealtime() - started}")
        assertEquals(batch.state.value.error, BatchPhase.COMPLETE, batch.state.value.phase)
        assertEquals(1, batch.state.value.successCount)
        val completed = batch.state.value.job
        assertEquals(format, completed.outputFormat)
        assertEquals(longEdge, completed.outputLongEdge)
        val output = Uri.parse(requireNotNull(completed.rows.single().outputUri))
        val actual = context.contentResolver.openInputStream(output)!!.use { requireNotNull(BitmapFactory.decodeStream(it)) }
        try {
            val reference = referenceExport(completed, referenceMode, "reference${format.suffix}")
            try { assertTrue("$label final export pixels", actual.sameAs(reference)) }
            finally { reference.recycle() }
            if (distinguishCpu) {
                val cpu = referenceExport(completed, NativeProcessor.CPU, "cpu-reference${format.suffix}")
                try { assertFalse("Final export must distinguish AUTO/GLES from CPU", actual.sameAs(cpu)) }
                finally { cpu.recycle() }
            }
            status("$label output=${actual.width}x${actual.height} pixelParity=true")
        } finally { actual.recycle() }
    }

    private fun referenceExport(job: BatchJob, mode: Int, name: String): Bitmap {
        val target = job.rows.single().target.sourceFile
        val file = File(target.parentFile, name)
        NativeProcessor(mode).use { it.export(target, job.source.lookFile, job.source.settings, file, job.outputFormat, job.outputLongEdge) }
        return requireNotNull(BitmapFactory.decodeFile(file.path))
    }

    private fun status(message: String) {
        instrumentation.sendStatus(2, Bundle().apply { putString("stream", "BATCH_GPU $message\n") })
    }

    private fun digest(file: File): String {
        val hash = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                hash.update(buffer, 0, count)
            }
        }
        return hash.digest().joinToString("") { "%02x".format(it) }
    }
}
