package com.rawlab.android

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.UUID

class BatchWorkflowInstrumentedTest {
    val compose = createAndroidComposeRule<MainActivity>()
    private val cleanup = BatchTestCleanup(InstrumentationRegistry.getInstrumentation().targetContext)
    @get:Rule val languageAndCompose = org.junit.rules.RuleChain.outerRule(cleanup).around(LanguageTestRule()).around(ForegroundTestRule()).around(compose)

    @Test fun remembersEditsAndExportsFrozenBatchWithoutChangingTargetRecords() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val fixtureId = UUID.randomUUID().toString()
        cleanup.begin(fixtureId)
        val root = File(context.filesDir, "RawLab/BatchJobs/$fixtureId/inputs").apply { mkdirs() }
        val source = File(root, "source.dng")
        instrumentation.context.assets.open("sample.RAW").use { from -> source.outputStream().use { from.copyTo(it) } }
        val target = File(root, cleanup.targetName(fixtureId)).also { source.copyTo(it) }
        val identity = PhotoIdentity(Uri.fromFile(target).toString())
        val model = compose.activity.model
        var output: Uri? = null
        var previewPending = false
        try {
            compose.runOnUiThread { model.setGpuEnabled(false) }
            assertFalse(model.state.value.gpuEnabled)
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(target)) }
            compose.waitUntil(180_000) { model.state.value.canExport || model.state.value.error != null }
            assertNull(model.state.value.error)
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = -.75f)) }
            compose.waitUntil(180_000) { model.state.value.canExport }
            val original = model.state.value.edits
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
            compose.waitUntil(180_000) { model.state.value.canExport || model.state.value.error != null }
            assertNull(model.state.value.error)
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = .5f, contrast = .2f,
                denoise = DenoiseSettings(true, 10f, 72f, 100f))) }
            compose.waitUntil(180_000) { model.state.value.canExport }
            val settings = model.state.value.edits
            val reopened = EditStore(File(context.filesDir, "edits"))
            assertEquals(settings, reopened.load(PhotoIdentity(Uri.fromFile(source).toString())))
            compose.runOnUiThread { model.beginBatch() }
            val batch = model.batch.value!!
            cleanup.trackJob(batch.state.value.job.id)
            compose.waitUntil(60_000) { batch.state.value.phase == BatchPhase.SELECTING }
            compose.onNodeWithText("导出 0 张").assertIsNotEnabled()
            compose.runOnUiThread { batch.addUris(listOf(Uri.fromFile(target))) }
            compose.waitUntil(180_000) { batch.state.value.phase != BatchPhase.PREPARING }
            assertNull(batch.state.value.error)
            assertEquals(1, batch.state.value.job.rows.size)
            assertEquals(settings, batch.state.value.job.source.settings)
            capture("batch-confirm-portrait.png")
            compose.runOnUiThread { compose.activity.requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
            compose.waitUntil(10_000) { compose.activity.resources.configuration.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE }
            compose.onNodeWithText("导出 1 张").assertIsDisplayed()
            capture("batch-confirm-landscape.png")
            compose.runOnUiThread { compose.activity.requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT }
            compose.waitUntil(10_000) { compose.activity.resources.configuration.orientation == android.content.res.Configuration.ORIENTATION_PORTRAIT }
            compose.activityRule.scenario.recreate()
            assertSame(batch, compose.activity.model.batch.value)
            assertFalse(compose.activity.model.state.value.gpuEnabled)
            compose.onNodeWithText("导出 1 张").assertIsDisplayed()
            // phase 不覆盖效果预览；图片出现前失败都必须先隔离进程。
            previewPending = true
            val naturalTimeout = InstrumentationRegistry.getArguments().getString("batchPreviewNaturalTimeoutProbe") == "true"
            val blocker = if (naturalTimeout) Thread({
                val frozen = batch.state.value.job
                NativeProcessor(NativeProcessor.CPU).use {
                    it.export(frozen.rows.single().target.sourceFile, frozen.source.lookFile, frozen.source.settings,
                        File(root.parentFile, "preview-blocker.jpg"), ExportFormat.JPEG)
                }
            }, "batch-preview-native-blocker").apply { start() } else null
            if (blocker != null) {
                compose.waitUntil(60_000) { blocker.stackTrace.any { it.methodName == "nativeProcess" && it.className == NativeProcessor::class.java.name } }
            }
            compose.onNodeWithText("查看").performClick()
            val previewStarted = android.os.SystemClock.elapsedRealtime()
            if (naturalTimeout) {
                compose.waitUntil(10_000) { previewInNative("nativeCreate") }
                instrumentation.sendStatus(2, android.os.Bundle().apply {
                    putString("stream", "Batch preview contention cpuExportNativeProcess=true previewNativeCreateBlocked=true\n")
                })
            }
            if (InstrumentationRegistry.getArguments().getString("batchPreviewAbortProbe") == "true") {
                compose.waitUntil(60_000) {
                    Thread.getAllStackTraces().values.any { stack ->
                        stack.any { it.className == NativeProcessor::class.java.name && it.methodName == "nativeProcess" } &&
                            stack.any { it.className.startsWith("${BatchExportModel::class.java.name}\$preview\$") }
                    }
                }
                assertEquals(BatchPhase.SELECTING, batch.state.value.phase)
                assertEquals(Operation.NONE, model.state.value.operation)
                assertTrue(batch.state.value.job.source.sourceFile.isFile)
                assertTrue(batch.state.value.job.rows.single().target.sourceFile.isFile)
                instrumentation.sendStatus(2, android.os.Bundle().apply {
                    putString("stream", "Batch preview probe nativeProcessActive=true phase=SELECTING operation=NONE pid=${android.os.Process.myPid()} fixture=$fixtureId job=${batch.state.value.job.id}\n")
                })
                throw AssertionError("Injected timeout while SELECTING effect preview is in nativeProcess")
            }
            try {
                compose.waitUntil(90_000) { compose.onAllNodesWithContentDescription(target.name).fetchSemanticsNodes().isNotEmpty() }
            } catch (failure: ComposeTimeoutException) {
                if (naturalTimeout) {
                    val elapsed = android.os.SystemClock.elapsedRealtime() - previewStarted
                    assertTrue(elapsed >= 90_000)
                    assertTrue(blocker!!.stackTrace.any { it.methodName == "nativeProcess" && it.className == NativeProcessor::class.java.name })
                    assertTrue(previewInNative("nativeCreate"))
                    assertEquals(BatchPhase.SELECTING, batch.state.value.phase)
                    assertEquals(Operation.NONE, model.state.value.operation)
                    instrumentation.sendStatus(2, android.os.Bundle().apply {
                        putString("stream", "Batch preview naturalTimeout=true elapsedMs=$elapsed exception=${failure.javaClass.simpleName} cpuExportNativeProcess=true previewNativeCreateBlocked=true phase=SELECTING operation=NONE\n")
                    })
                }
                throw failure
            }
            assertFalse("Natural timeout probe NOT REACHED: native blocker finished too soon", naturalTimeout)
            previewPending = false
            instrumentation.sendStatus(2, android.os.Bundle().apply {
                putString("stream", "Batch effect preview ms=${android.os.SystemClock.elapsedRealtime() - previewStarted}\n")
            })
            capture("batch-effect.png")
            compose.onNodeWithText("确定").performClick()
            val exportStarted = android.os.SystemClock.elapsedRealtime()
            compose.onNodeWithText("导出 1 张").performClick()
            try {
                compose.waitUntil(240_000) { batch.state.value.phase !in setOf(BatchPhase.RUNNING, BatchPhase.PREPARING) }
            } catch (failure: ComposeTimeoutException) {
                instrumentation.sendStatus(2, android.os.Bundle().apply {
                    putString("stream", "Batch original-size timeout elapsedMs=${android.os.SystemClock.elapsedRealtime() - exportStarted} exception=${failure.javaClass.simpleName} phase=${batch.state.value.phase} batchNativeProcess=${exportInNative()}\n")
                })
                throw failure
            }
            instrumentation.sendStatus(2, android.os.Bundle().apply {
                putString("stream", "Batch original-size export ms=${android.os.SystemClock.elapsedRealtime() - exportStarted}\n")
            })
            assertEquals(batch.state.value.error, BatchPhase.COMPLETE, batch.state.value.phase)
            assertEquals(1, batch.state.value.successCount)
            output = Uri.parse(batch.state.value.job.rows.single().outputUri!!)
            capture("batch-result.png")
            assertEquals(original, EditStore(File(context.filesDir, "edits")).load(identity))
            assertArrayEquals(source.readBytes(), target.readBytes())
            val single = File(root, "single.jpg")
            NativeProcessor(NativeProcessor.CPU).use { it.export(target, null, settings, single, ExportFormat.JPEG) }
            val singleBitmap = BitmapFactory.decodeFile(single.path)
            val batchBitmap = context.contentResolver.openInputStream(output!!)!!.use(BitmapFactory::decodeStream)
            assertTrue("Single and batch exports have identical pixels", singleBitmap.sameAs(batchBitmap))
            singleBitmap.recycle(); batchBitmap.recycle()
            val journal = BatchJournal(File(context.filesDir, "RawLab/BatchJobs"))
            assertFalse(journal.pending().contains(batch.state.value.job.id))
            compose.onNodeWithText("关闭").performClick()
        } finally {
            val batch = model.batch.value
            batch?.state?.value?.job?.id?.let(cleanup::trackJob)
            cleanup.finish(previewPending || batch?.state?.value?.phase in setOf(BatchPhase.PREPARING, BatchPhase.RUNNING) ||
                model.state.value.operation != Operation.NONE,
                cancel = { batch?.cancel() }, close = { compose.runOnUiThread { model.closeBatch() } })
        }
    }

    @Test fun removesKnownPartialOutputBeforeResumingAndCanDiscardTheTask() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val id = UUID.randomUUID().toString()
        cleanup.begin(id)
        val journal = BatchJournal(File(context.filesDir, "RawLab/BatchJobs"))
        val storage = PhotoStorage(context)
        var batch: BatchExportModel? = null
        try {
            val raw = File(context.filesDir, "RawLab/BatchJobs/$id/inputs/source.dng").apply { parentFile!!.mkdirs(); writeBytes(byteArrayOf(1)) }
            val uri = context.contentResolver.insert(android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                android.content.ContentValues().apply {
                    put(android.provider.MediaStore.Images.Media.DISPLAY_NAME, cleanup.targetName(id).substringBeforeLast('.') + ".jpg")
                    put(android.provider.MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                    put(android.provider.MediaStore.Images.Media.RELATIVE_PATH, "Pictures/RawLab")
                    put(android.provider.MediaStore.Images.Media.IS_PENDING, 1)
                })!!
            context.contentResolver.openOutputStream(uri)!!.use { it.write(byteArrayOf(1, 2)) }
            fun abortAt(window: String) {
                if (InstrumentationRegistry.getArguments().getString("batchPartialAbortProbe") == window) {
                    instrumentation.sendStatus(2, android.os.Bundle().apply {
                        putString("stream", "Batch partial abort window=$window pendingUri=$uri fixture=$id pid=${android.os.Process.myPid()}\n")
                    })
                    android.os.Process.killProcess(android.os.Process.myPid())
                    throw AssertionError("Injected death at $window")
                }
            }
            val source = BatchSourceSnapshot(PhotoIdentity("recovery-source"), raw, EditSettings())
            val target = BatchTarget(PhotoIdentity("recovery-target"), raw, raw.name)
            val job = BatchJob(source, listOf(target), id = id).let { it.withRows(it.rows.map { row -> row.copy(status = BatchRowStatus.PUBLISHING, outputUri = uri.toString()) }) }
            abortAt("beforeCheckpoint")
            journal.save(job)
            abortAt("afterCheckpoint")
            compose.runOnUiThread { batch = BatchExportModel(context, storage, source, journal.load(job.id)) }
            compose.waitUntil(10_000) { batch!!.state.value.phase != BatchPhase.PREPARING }
            assertEquals(BatchRowStatus.PENDING, batch!!.state.value.job.rows.single().status)
            context.contentResolver.query(uri, arrayOf(android.provider.MediaStore.Images.Media._ID), null, null, null)?.use { assertEquals(0, it.count) }
            assertTrue(batch!!.discard())
            assertNull(journal.load(job.id))
        } finally {
            cleanup.finish(batch?.state?.value?.phase in setOf(BatchPhase.PREPARING, BatchPhase.RUNNING),
                cancel = { batch?.cancel() }, close = { batch?.close(); storage.close() })
        }
    }

    private fun capture(name: String) {
        compose.waitForIdle()
        InstrumentationRegistry.getInstrumentation().uiAutomation.waitForIdle(500, 5000)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val output = File(context.getExternalFilesDir(null), name)
        output.outputStream().use { InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot().compress(Bitmap.CompressFormat.PNG, 100, it) }
        val command = "cp ${output.absolutePath} /data/local/tmp/${context.packageName}-$name"
        android.os.ParcelFileDescriptor.AutoCloseInputStream(InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command)).use { it.readBytes() }
    }

    private fun previewInNative(method: String) = Thread.getAllStackTraces().values.any { stack ->
        stack.any { it.className == NativeProcessor::class.java.name && it.methodName == method } &&
            stack.any { it.className.startsWith("${BatchExportModel::class.java.name}\$preview\$") }
    }

    private fun exportInNative() = Thread.getAllStackTraces().values.any { stack ->
        stack.any { it.className == NativeProcessor::class.java.name && it.methodName == "nativeProcess" } &&
            stack.any { it.className.startsWith(BatchExportModel::class.java.name) }
    }
}
