package com.rawlab.android.export

import android.graphics.Bitmap
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import android.provider.DocumentsContract
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import com.rawlab.android.MainActivity
import com.rawlab.android.R
import com.rawlab.android.batch.BatchExportModel
import com.rawlab.android.batch.BatchJob
import com.rawlab.android.batch.journal.BatchJournal
import com.rawlab.android.batch.BatchPhase
import com.rawlab.android.batch.BatchRowStatus
import com.rawlab.android.batch.BatchSourceSnapshot
import com.rawlab.android.batch.BatchTarget
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.settings.DenoiseSettings
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.HslSettings
import com.rawlab.android.settings.PhotoEffectsSettings
import com.rawlab.android.settings.PhotoIdentity

class RenderedDngInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    private val artifacts get() = File(context.getExternalFilesDir(null), "rendered-dng-validation").apply { mkdirs() }

    private fun settings() = EditSettings(film = "velvia", strength = .65f, exposure = .35f,
        highlights = -.2f, shadows = .15f, contrast = .1f, toneCurve = .15f, saturation = -.1f,
        customWb = true, temperature = 5800f, tint = 8f, sharpening = .2f, exposureMode = 1,
        denoise = DenoiseSettings(true, 10f, 72f, 100f), displayChromaDenoise = 2,
        hsl = HslSettings().withValue(0, 2, 12f).withValue(1, 4, -15f).withValue(2, 6, 8f),
        effects = PhotoEffectsSettings(-30f, 42f, -15f, 65f, 35f, 20f, 38f, 65f))

    private fun raw(root: File, name: String): File = File(root, name).also { file ->
        instrumentation.context.assets.open("sample.RAW").use { input -> file.outputStream().use { input.copyTo(it) } }
    }

    private fun digest(file: File): ByteArray {
        val hash = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                hash.update(buffer, 0, count)
            }
        }
        return hash.digest()
    }

    @Test fun nativeDngBakesAllAdjustmentsOnCpuAndForcedGles() {
        val root = File(context.cacheDir, "dng-native-${UUID.randomUUID()}").apply { mkdirs() }
        val input = raw(root, "source.ARW")
        val before = digest(input)
        try {
            PhotoStorage(context).use { storage ->
                val look = storage.filmPath("velvia")
                for ((name, mode) in listOf("cpu" to NativeProcessor.CPU, "gles" to NativeProcessor.FORCE)) {
                    NativeProcessor(mode).use { processor ->
                        val started = SystemClock.elapsedRealtime()
                        val preview = processor.preview(input, look, settings(), 128, false)
                        assertEquals(if (mode == NativeProcessor.CPU) 0 else 2, preview.backend)
                        for (format in listOf(ExportFormat.DNG, ExportFormat.PNG)) {
                            val output = File(artifacts, "$name${format.suffix}")
                            processor.export(input, look, settings(), output, format, 128)
                            assertTrue("$name ${format.name} is a real output", output.isFile && output.length() > 1024)
                            if (format == ExportFormat.DNG) output.copyTo(File(artifacts, "$name-readable.dng"), overwrite = true)
                        }
                        instrumentation.sendStatus(2, Bundle().apply {
                            putString("stream", "Rendered DNG $name preview+exports ms=${SystemClock.elapsedRealtime() - started}\n")
                        })
                    }
                }
            }
            assertArrayEquals("Native export never modifies source RAW", before, digest(input))
        } finally { root.deleteRecursively() }
    }

    @Test fun singleAndBatchPublishDngThroughSafAndRecoverWithoutReplacingCompletedFiles() {
        for (name in listOf("cpu", "gles")) {
            val output = File(artifacts, "$name.dng")
            if (output.isFile) output.copyTo(File(artifacts, "$name-readable.dng"), overwrite = true)
        }
        val tree = Uri.parse(requireNotNull(InstrumentationRegistry.getArguments().getString("dngTreeUri")) {
            "Grant a dedicated output tree through the app UI and pass -e dngTreeUri URI"
        })
        assertTrue("The test tree is granted by the system document picker",
            context.contentResolver.persistedUriPermissions.any { it.uri == tree && it.isReadPermission && it.isWritePermission })
        val root = File(context.cacheDir, "dng-workflow-${UUID.randomUUID()}").apply { mkdirs() }
        val source = raw(root, "source.ARW")
        val targets = listOf("target-a.ARW", "target-b.ARW").map { name -> File(root, name).also { source.copyTo(it) } }
        val sourceHash = digest(source)
        val originalTargetEdits = mutableMapOf<PhotoIdentity, EditSettings>()
        val model = compose.activity.model
        val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        var single: Uri? = null
        val ownedOutputs = mutableSetOf<Uri>()
        var recovery: BatchExportModel? = null
        val journal = BatchJournal(File(context.filesDir, "RawLab/BatchJobs"))
        try {
            for (target in targets) {
                compose.runOnUiThread { model.importPhoto(Uri.fromFile(target)) }
                compose.waitUntil(240_000) { model.state.value.canExport || model.state.value.error != null }
                assertNull(model.state.value.error)
                compose.runOnUiThread { model.edit(EditSettings(exposure = -.75f)) }
                compose.waitUntil(240_000) { model.state.value.canExport || model.state.value.error != null }
                assertNull(model.state.value.error)
                assertEquals(-.75f, model.state.value.edits.exposure)
                originalTargetEdits[PhotoIdentity(Uri.fromFile(target).toString())] = model.state.value.edits
            }
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
            compose.waitUntil(240_000) { model.state.value.canExport || model.state.value.error != null }
            assertNull(model.state.value.error)
            compose.runOnUiThread { model.edit(settings()) }
            compose.waitUntil(240_000) { model.state.value.canExport || model.state.value.error != null }
            assertNull(model.state.value.error)
            val frozen = model.state.value.edits
            compose.onNodeWithContentDescription(context.getString(R.string.export)).performClick()
            compose.onNodeWithText(context.getString(R.string.dng)).performScrollTo().performClick()
            compose.onNodeWithText(context.getString(R.string.save_album)).assertDoesNotExist()
            compose.onNodeWithText(context.getString(R.string.save_file)).assertIsDisplayed()
            capture("single-format-dng.png")
            compose.onNodeWithText(context.getString(R.string.cancel)).performClick()
            single = DocumentsContract.createDocument(context.contentResolver, parent, ExportFormat.DNG.mimeType,
                "single-${UUID.randomUUID()}.dng")!!
            ownedOutputs += single!!
            compose.runOnUiThread { assertTrue(model.beginExport()); model.export(single, ExportFormat.DNG, 128) }
            compose.waitUntil(300_000) { model.state.value.canExport || model.state.value.error != null }
            assertNull(model.state.value.error)
            val singleBytes = context.contentResolver.openInputStream(single!!)!!.use { it.readBytes() }
            File(artifacts, "single-model.dng").writeBytes(singleBytes)
            assertTrue(singleBytes.size > 1024)
            assertEquals(frozen, model.state.value.edits)

            compose.runOnUiThread { model.beginBatch() }
            val batch = model.batch.value!!
            compose.waitUntil(60_000) { batch.state.value.phase != BatchPhase.PREPARING }
            assertEquals(BatchPhase.SELECTING, batch.state.value.phase)
            compose.runOnUiThread { batch.addUris(targets.map { Uri.fromFile(it) }) }
            compose.waitUntil(240_000) { batch.state.value.phase != BatchPhase.PREPARING }
            assertNull(batch.state.value.error)
            assertEquals(2, batch.state.value.selectedCount)
            assertEquals(frozen, batch.state.value.job.source.settings)
            compose.onNodeWithText(context.getString(R.string.dng)).performScrollTo().performClick()
            compose.onNodeWithText("照片图库").assertDoesNotExist()
            compose.onNodeWithText("导出 2 张").assertIsNotEnabled()
            capture("batch-dng-requires-directory.png")
            compose.runOnUiThread { batch.start(ExportFormat.DNG, tree, 128) }
            compose.waitUntil(600_000) { batch.state.value.phase !in setOf(BatchPhase.PREPARING, BatchPhase.RUNNING) }
            assertEquals(batch.state.value.error, BatchPhase.COMPLETE, batch.state.value.phase)
            val complete = batch.state.value.job
            assertEquals(2, batch.state.value.successCount)
            assertEquals(ExportFormat.DNG, complete.outputFormat)
            assertEquals(128, complete.outputLongEdge)
            complete.rows.forEachIndexed { index, row ->
                assertTrue(row.outputName.endsWith(".dng") && row.outputReady)
                val output = Uri.parse(row.outputUri!!)
                ownedOutputs += output
                val bytes = context.contentResolver.openInputStream(output)!!.use { it.readBytes() }
                assertArrayEquals("Single and batch preserve the same FINAL adjustments", singleBytes, bytes)
                File(artifacts, "batch-$index.dng").writeBytes(bytes)
            }
            capture("batch-dng-completed.png")
            val interrupted = complete.withRows(complete.rows.map { it.copy(status = BatchRowStatus.PUBLISHING) })
            journal.save(interrupted)
            val reloaded = journal.load(complete.id)!!
            assertTrue(reloaded.rows.all { it.status == BatchRowStatus.NEEDS_CONFIRMATION && it.outputReady })
            compose.runOnUiThread { recovery = BatchExportModel(context, model.storage, reloaded.source, reloaded) }
            compose.waitUntil(30_000) { recovery!!.state.value.phase != BatchPhase.PREPARING }
            assertTrue(recovery!!.state.value.job.rows.all { it.status == BatchRowStatus.SUCCESS })
            compose.runOnUiThread { recovery!!.retryFailed() }
            assertEquals(2, recovery!!.state.value.successCount)
            assertTrue(journal.load(complete.id)!!.rows.all { it.status == BatchRowStatus.SUCCESS })
            complete.rows.forEach { row ->
                val bytes = context.contentResolver.openInputStream(Uri.parse(row.outputUri!!))!!.use { it.readBytes() }
                assertArrayEquals("Recovery never replaces completed DNG output", singleBytes, bytes)
            }
            assertArrayEquals(sourceHash, digest(source))
            targets.forEach { assertArrayEquals(sourceHash, digest(it)) }
            val persistedEdits = EditStore(File(context.filesDir, "edits"))
            originalTargetEdits.forEach { (identity, settings) -> assertEquals(settings, persistedEdits.load(identity)) }
            assertEquals(frozen, persistedEdits.load(PhotoIdentity(Uri.fromFile(source).toString())))
            compose.runOnUiThread { model.closeBatch() }
        } finally {
            recovery?.close()
            model.batch.value?.let { batch ->
                ownedOutputs += batch.state.value.job.rows.mapNotNull { it.outputUri?.let(Uri::parse) }
                batch.discard()
                compose.runOnUiThread { model.closeBatch() }
            }
            root.deleteRecursively()
            ownedOutputs.forEach { runCatching { DocumentsContract.deleteDocument(context.contentResolver, it) } }
            assertTrue("Test-owned SAF outputs are removed after artifact collection", ownedOutputs.all { output ->
                !runCatching { context.contentResolver.openInputStream(output)?.use { true } == true }.getOrDefault(false)
            })
        }
    }

    private fun capture(name: String) {
        compose.waitForIdle()
        instrumentation.uiAutomation.takeScreenshot().let { bitmap ->
            File(artifacts, name).outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
        }
    }

    @Test fun removesKnownPartialDngDocumentAndPersistsPendingRecovery() {
        val tree = Uri.parse(requireNotNull(InstrumentationRegistry.getArguments().getString("dngTreeUri")))
        val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val partial = DocumentsContract.createDocument(context.contentResolver, parent, ExportFormat.DNG.mimeType,
            "partial-${UUID.randomUUID()}.dng")!!
        val input = File.createTempFile("dng-recovery-", ".ARW", context.cacheDir).apply { writeBytes(byteArrayOf(1)) }
        context.contentResolver.openOutputStream(partial)!!.use { it.write(byteArrayOf(1, 2, 3)) }
        val source = BatchSourceSnapshot(PhotoIdentity("recovery-${UUID.randomUUID()}"), input, EditSettings())
        val initial = BatchJob(source, listOf(BatchTarget(source.identity, input, input.name)), outputFormat = ExportFormat.DNG,
            destination = tree.toString()).let { job ->
            job.withRows(job.rows.map { it.copy(status = BatchRowStatus.PUBLISHING, outputUri = partial.toString(), outputReady = false) })
        }
        val journal = BatchJournal(File(context.filesDir, "RawLab/BatchJobs"))
        journal.save(initial)
        var recovery: BatchExportModel? = null
        PhotoStorage(context).use { storage ->
            try {
                compose.runOnUiThread { recovery = BatchExportModel(context, storage, source, journal.load(initial.id)) }
                compose.waitUntil(30_000) { recovery!!.state.value.phase != BatchPhase.PREPARING }
                val row = recovery!!.state.value.job.rows.single()
                assertEquals(BatchRowStatus.PENDING, row.status)
                assertNull(row.outputUri)
                assertFalse(runCatching { context.contentResolver.openInputStream(partial)?.use { true } == true }.getOrDefault(false))
                val saved = journal.load(initial.id)!!
                assertEquals(ExportFormat.DNG, saved.outputFormat)
                assertEquals(BatchRowStatus.PENDING, saved.rows.single().status)
                assertNull(saved.rows.single().outputUri)
                assertTrue(recovery!!.discard())
                kotlinx.coroutines.runBlocking { kotlinx.coroutines.withTimeout(10_000) { recovery!!.discardDraftOrCompleted()?.await() } }
                assertNull(journal.load(initial.id))
            } finally {
                recovery?.close()
                journal.discard(initial.id)
                input.delete()
                runCatching { DocumentsContract.deleteDocument(context.contentResolver, partial) }
            }
        }
    }
}
