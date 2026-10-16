package com.rawlab.android

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import androidx.lifecycle.ViewModelStore
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList

class BatchGpuModeInstrumentedTest {
    val compose = createAndroidComposeRule<MainActivity>()
    private val cleanup = BatchTestCleanup(InstrumentationRegistry.getInstrumentation().targetContext)
    @get:Rule val isolatedCompose = RuleChain.outerRule(cleanup).around(ForegroundTestRule()).around(compose)
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Test fun disabledNewBatchValidatesImportedTargetWithCpu() {
        val modes = CopyOnWriteArrayList<Int>()
        val store = ViewModelStore()
        lateinit var model: EditorViewModel
        compose.runOnUiThread {
            model = EditorViewModel(compose.activity.application) { mode, database ->
                modes += mode
                NativeProcessor(mode, database)
            }
            store.put("validation", model)
        }
        try {
            withBatch(false, EditSettings(customWb = true), resumed = false, model = model, expectCompleted = false) { batch ->
                assertEquals(BatchPhase.SELECTING, batch.state.value.phase)
                assertEquals(1, batch.state.value.job.rows.size)
                assertEquals("Target validation must inherit GPU off, with one real processor", listOf(NativeProcessor.CPU), modes.toList())
                status("targetValidation modes=$modes gpuEnabled=${model.state.value.gpuEnabled} realNative=true")
            }
        } finally { compose.runOnUiThread { store.clear() } }
    }

    @Test fun perspectiveSnapshotReachesNewAndResumedBatchPreviewAndFinal() {
        val settings = EditSettings(customWb = true, exposure = .25f,
            geometry = GeometrySettings(cropX = .1f, cropY = .1f, cropWidth = .8f, cropHeight = .7f,
                quarterTurns = 1, perspectiveHorizontal = .3f, perspectiveVertical = -.2f))
        for (gpuEnabled in listOf(false, true)) for (resumed in listOf(false, true)) {
            val mode = if (gpuEnabled) NativeProcessor.AUTO else NativeProcessor.CPU
            withBatch(gpuEnabled = gpuEnabled, settings = settings, resumed = resumed, longEdge = 300) { batch ->
                val source = batch.state.value.job.source
                assertEquals(settings, source.settings)
                val target = batch.state.value.job.rows.single().target
                val expected = NativeProcessor(mode).use { it.preview(target.sourceFile, null, settings, 1280, true).bitmap() }
                val actual = runBlocking { batch.preview(target) }
                try { assertTrue("Frozen perspective reaches batch preview", actual.sameAs(expected)) }
                finally { actual.recycle(); expected.recycle() }
                exportAndCompare(batch, mode, "${if (resumed) "resumed" else "new"}-perspective-$mode")
            }
        }
    }

    @Test fun resumedBatchWithGpuDisabledUsesCpuForPreviewAndOriginalSizeCleanExport() {
        val settings = EditSettings(customWb = true, exposure = .5f, contrast = .2f,
            denoise = DenoiseSettings(true, 10f, 72f, 100f))
        withBatch(gpuEnabled = false, settings = settings, resumed = true, format = ExportFormat.JPEG) { batch ->
            if (InstrumentationRegistry.getArguments().getString("batchAbortProbe") == "true") {
                compose.runOnUiThread { batch.retryFailed() }
                compose.waitUntil(60_000) {
                    Thread.getAllStackTraces().values.any { stack -> stack.any {
                        it.className == NativeProcessor::class.java.name && it.methodName == "nativeProcess"
                    } }
                }
                status("injectedFailure nativeProcessActive=true")
                throw AssertionError("Injected failure while real native export is active")
            }
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

    @Test fun enabledNewAndResumedBatchesExportOriginalSizeCleanWithAuto() {
        val settings = EditSettings(customWb = true, exposure = .5f, contrast = .2f,
            denoise = DenoiseSettings(true, 10f, 72f, 100f))
        for (resumed in listOf(true, false)) {
            withBatch(gpuEnabled = true, settings = settings, resumed = resumed, format = ExportFormat.JPEG) { batch ->
                assertPreviewMatchesMode(batch, NativeProcessor.FORCE)
                exportAndCompare(batch, NativeProcessor.FORCE, "${if (resumed) "resumed" else "new"}-auto-original-clean",
                    ExportFormat.JPEG, null)
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
                          model: EditorViewModel = compose.activity.model, expectCompleted: Boolean = true,
                          check: (BatchExportModel) -> Unit) {
        val id = UUID.randomUUID().toString()
        cleanup.begin(id)
        val journalRoot = File(context.filesDir, "RawLab/BatchJobs")
        val inputs = File(journalRoot, "$id/inputs").apply { mkdirs() }
        val source = File(inputs, "source.dng")
        instrumentation.context.assets.open("sample.RAW").use { from -> source.outputStream().use { from.copyTo(it) } }
        val target = File(inputs, cleanup.targetName(id)).also { source.copyTo(it) }
        val before = digest(source)
        val look = if (rlook) File(inputs, "batch-gpu-$id.rlook").apply { writeBytes(syntheticRlook()) } else null
        val journal = BatchJournal(journalRoot)
        try {
            val effectiveSettings = if (look != null && !resumed) {
                cleanup.trackLookImport(look.name)
                val imported = PhotoStorage(context, lookValidator = LookValidator { staged ->
                    cleanup.trackLookStage(staged)
                    val validated = NativeLookValidator.validate(staged)
                    if (InstrumentationRegistry.getArguments().getString("batchLookStageAbortProbe") == "true") {
                        val importId = staged.name.removePrefix(".").substringBefore(".stage")
                        assertTrue(File(staged.parentFile, ".import-$importId.pending").isFile)
                        status("lookImportStage nativeValidated=true id=$importId staged=${staged.name} beforeCommit=true")
                        android.os.Process.killProcess(android.os.Process.myPid())
                        throw AssertionError("Injected death during a real look import")
                    }
                    validated
                }).use { it.importLook(Uri.fromFile(look)) }
                if (InstrumentationRegistry.getArguments().getString("batchLookAbortProbe") == "true") {
                    status("injectedFailure importedLook=${imported.id} beforeBatch=true")
                    android.os.Process.killProcess(android.os.Process.myPid())
                    throw AssertionError("Injected failure after managed look import")
                }
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
                cleanup.trackJob(model.batch.value!!.state.value.job.id)
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
                cleanup.trackJob(model.batch.value!!.state.value.job.id)
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
            if (expectCompleted) assertFalse(journal.pending().contains(batch.state.value.job.id))
        } finally {
            val batch = model.batch.value
            batch?.state?.value?.job?.id?.let(cleanup::trackJob)
            cleanup.finish(batch?.state?.value?.phase in setOf(BatchPhase.PREPARING, BatchPhase.RUNNING) ||
                model.state.value.operation != Operation.NONE,
                cancel = { batch?.cancel() }, close = { compose.runOnUiThread { model.closeBatch() } })
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
        val backendLog = android.os.ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(
            "logcat -d --pid=${android.os.Process.myPid()} -v raw -s RawLabBatch:I")).use { it.bufferedReader().readText() }
        val reports = backendLog.lineSequence().filter { it.startsWith("job=${completed.id} exportBackend=") }.toList()
        val expectedBackend = if (referenceMode == NativeProcessor.FORCE) 2 else 0
        assertEquals("The actual batch render must report its own backend exactly once",
            listOf("job=${completed.id} exportBackend=$expectedBackend"), reports)
        status("$label actualBatchExportBackend=$expectedBackend job=${completed.id}")
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
        NativeProcessor(mode).use {
            val backend = it.export(target, job.source.lookFile, job.source.settings, file, job.outputFormat, job.outputLongEdge)
            assertEquals("Reference export reports actual backend", if (mode == NativeProcessor.FORCE) 2 else 0, backend)
            status("reference mode=$mode actualExportBackend=$backend")
        }
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
