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
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test fun remembersEditsAndExportsFrozenBatchWithoutChangingTargetRecords() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val root = File(context.cacheDir, "batch-test-${UUID.randomUUID()}").apply { mkdirs() }
        val source = File(root, "source.dng")
        instrumentation.context.assets.open("sample.RAW").use { from -> source.outputStream().use { from.copyTo(it) } }
        val target = File(root, "target.dng").also { source.copyTo(it) }
        val identity = PhotoIdentity(Uri.fromFile(target).toString())
        val model = compose.activity.model
        var output: Uri? = null
        try {
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
            compose.onNodeWithText("导出 1 张").assertIsDisplayed()
            compose.onNodeWithText("查看").performClick()
            val previewStarted = android.os.SystemClock.elapsedRealtime()
            compose.waitUntil(90_000) { compose.onAllNodesWithContentDescription("target.dng").fetchSemanticsNodes().isNotEmpty() }
            instrumentation.sendStatus(2, android.os.Bundle().apply {
                putString("stream", "Batch effect preview ms=${android.os.SystemClock.elapsedRealtime() - previewStarted}\n")
            })
            capture("batch-effect.png")
            compose.onNodeWithText("确定").performClick()
            compose.onNodeWithText("导出 1 张").performClick()
            compose.waitUntil(240_000) { batch.state.value.phase !in setOf(BatchPhase.RUNNING, BatchPhase.PREPARING) }
            assertEquals(batch.state.value.error, BatchPhase.COMPLETE, batch.state.value.phase)
            assertEquals(1, batch.state.value.successCount)
            output = Uri.parse(batch.state.value.job.rows.single().outputUri!!)
            capture("batch-result.png")
            assertEquals(original, EditStore(File(context.filesDir, "edits")).load(identity))
            assertArrayEquals(source.readBytes(), target.readBytes())
            val single = File(root, "single.jpg")
            NativeProcessor().use { it.export(target, null, settings, single, false) }
            val singleBitmap = BitmapFactory.decodeFile(single.path)
            val batchBitmap = context.contentResolver.openInputStream(output!!)!!.use(BitmapFactory::decodeStream)
            assertTrue("Single and batch exports have identical pixels", singleBitmap.sameAs(batchBitmap))
            singleBitmap.recycle(); batchBitmap.recycle()
            val journal = BatchJournal(File(context.filesDir, "RawLab/BatchJobs"))
            assertFalse(journal.pending().contains(batch.state.value.job.id))
            compose.onNodeWithText("关闭").performClick()
        } finally {
            output?.let { context.contentResolver.delete(it, null, null) }
            root.deleteRecursively()
        }
    }

    @Test fun removesKnownPartialOutputBeforeResumingAndCanDiscardTheTask() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val raw = File(context.cacheDir, "recovery-${UUID.randomUUID()}.dng").apply { writeBytes(byteArrayOf(1)) }
        val uri = context.contentResolver.insert(android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            android.content.ContentValues().apply {
                put(android.provider.MediaStore.Images.Media.DISPLAY_NAME, "rawlab-partial-${UUID.randomUUID()}.jpg")
                put(android.provider.MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                put(android.provider.MediaStore.Images.Media.IS_PENDING, 1)
            })!!
        context.contentResolver.openOutputStream(uri)!!.use { it.write(byteArrayOf(1, 2)) }
        val source = BatchSourceSnapshot(PhotoIdentity("recovery-source"), raw, EditSettings())
        val target = BatchTarget(PhotoIdentity("recovery-target"), raw, raw.name)
        val job = BatchJob(source, listOf(target)).let { it.withRows(it.rows.map { row -> row.copy(status = BatchRowStatus.PUBLISHING, outputUri = uri.toString()) }) }
        val journal = BatchJournal(File(context.filesDir, "RawLab/BatchJobs"))
        journal.save(job)
        val storage = PhotoStorage(context)
        lateinit var batch: BatchExportModel
        try {
            compose.runOnUiThread { batch = BatchExportModel(context, storage, source, journal.load(job.id)) }
            compose.waitUntil(10_000) { batch.state.value.phase != BatchPhase.PREPARING }
            assertEquals(BatchRowStatus.PENDING, batch.state.value.job.rows.single().status)
            context.contentResolver.query(uri, arrayOf(android.provider.MediaStore.Images.Media._ID), null, null, null)?.use { assertEquals(0, it.count) }
            assertTrue(batch.discard())
            assertNull(journal.load(job.id))
        } finally { batch.close(); storage.close(); raw.delete(); runCatching { context.contentResolver.delete(uri, null, null) } }
    }

    private fun capture(name: String) {
        compose.waitForIdle()
        InstrumentationRegistry.getInstrumentation().uiAutomation.waitForIdle(500, 5000)
        val output = File(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null), name)
        output.outputStream().use { InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot().compress(Bitmap.CompressFormat.PNG, 100, it) }
        val command = "cp ${output.absolutePath} /data/local/tmp/rawlab-$name"
        android.os.ParcelFileDescriptor.AutoCloseInputStream(InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command)).use { it.readBytes() }
    }
}
