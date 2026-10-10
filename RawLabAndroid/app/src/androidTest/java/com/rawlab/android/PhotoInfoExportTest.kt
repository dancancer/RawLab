package com.rawlab.android

import android.content.ContentUris
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.MediaStore
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.exifinterface.media.ExifInterface
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.Before
import java.io.File
import java.util.UUID

class PhotoInfoExportTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Before fun keepTestActivityVisible() {
        compose.runOnUiThread { compose.activity.window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
    }

    private fun raw(root: File, name: String): File = File(root, name).also { file ->
        InstrumentationRegistry.getInstrumentation().context.assets.open("sample.RAW").use { input ->
            file.outputStream().use { input.copyTo(it) }
        }
    }

    private fun import(file: File) {
        compose.runOnUiThread { compose.activity.model.importPhoto(Uri.fromFile(file)) }
        compose.waitUntil(180_000) { compose.activity.model.state.value.canExport || compose.activity.model.state.value.error != null }
        assertNull(compose.activity.model.state.value.error)
        assertTrue(compose.activity.model.state.value.canExport)
    }

    @Test fun metadataReadsOriginalRawAndOrientationWithoutInventingCaptureValues() {
        val root = File(context.cacheDir, "info-${UUID.randomUUID()}").apply { mkdirs() }
        try {
            val source = raw(root, "source.ARW")
            val info = PhotoInfoReader.read(source)
            assertTrue(info.camera!!.contains("SONY", ignoreCase = true))
            assertNotNull(info.lens); assertNotNull(info.captureTime); assertNotNull(info.shutter)
            assertTrue(info.originalWidth!! > 0 && info.originalHeight!! > 0)
            val raster = File(root, "empty.jpg")
            val bitmap = Bitmap.createBitmap(48, 24, Bitmap.Config.ARGB_8888)
            raster.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it) }; bitmap.recycle()
            val empty = PhotoInfoReader.read(raster)
            assertNull(empty.camera); assertNull(empty.iso); assertNull(empty.captureTime)
            ExifInterface(raster).apply {
                setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_ROTATE_90.toString())
                saveAttributes()
            }
            val rotated = PhotoInfoReader.read(raster)
            assertEquals(24, rotated.originalWidth); assertEquals(48, rotated.originalHeight)
        } finally { root.deleteRecursively() }
    }

    @Test fun realEditorCyclesInfoSwitchesPhotosAndExportsCustomSizeToAlbum() {
        val root = File(context.cacheDir, "info-ui-${UUID.randomUUID()}").apply { mkdirs() }
        val before = albumUris()
        try {
            val source = raw(root, "info-source.ARW")
            val target = raw(root, "info-target.ARW")
            import(source)
            val button = compose.onNodeWithTag("photo-info-button")
            button.performClick()
            compose.waitUntil(10_000) { compose.onAllNodesWithText("info-source.ARW", substring = true).fetchSemanticsNodes().size > 1 }
            compose.onNodeWithTag("photo-info-panel").assertIsDisplayed()
            button.performClick()
            compose.onNodeWithText("SONY", substring = true).assertIsDisplayed()
            capture("capture-info.png")
            button.performClick(); compose.onNodeWithTag("photo-info-panel").assertDoesNotExist()
            import(target)
            button.performClick()
            compose.waitUntil(10_000) { compose.onAllNodesWithText("info-target.ARW", substring = true).fetchSemanticsNodes().size > 1 }
            compose.onNodeWithText("文件名  info-source.ARW").assertDoesNotExist()
            compose.onNodeWithContentDescription("导出").performClick()
            compose.onNodeWithText(context.getString(R.string.output_original_size)).performClick()
            compose.onNodeWithText("2048 px").performClick()
            compose.onNodeWithText("2048 px").assertIsDisplayed().performClick()
            compose.onNodeWithText(context.getString(R.string.output_custom_size)).performClick()
            val input = compose.onNodeWithText(context.getString(R.string.output_long_edge))
            for (invalid in listOf("100000", "-2048", "0")) {
                input.performTextReplacement(invalid)
                compose.onNodeWithText(context.getString(R.string.save_album)).assertIsNotEnabled()
                compose.onNodeWithText(context.getString(R.string.save_file)).assertIsNotEnabled()
            }
            input.performTextReplacement("512")
            compose.onNodeWithText(context.getString(R.string.save_album)).assertIsEnabled()
            capture("export-size-custom.png")
            compose.onNodeWithText(context.getString(R.string.save_album)).performClick()
            compose.waitUntil(180_000) { compose.activity.model.state.value.operation == Operation.NONE }
            assertNull(compose.activity.model.state.value.error)
            val output = (albumUris() - before).single()
            context.contentResolver.openInputStream(output)!!.use { stream ->
                val image = BitmapFactory.decodeStream(stream)
                assertEquals(512, maxOf(image.width, image.height)); image.recycle()
            }
            context.contentResolver.openInputStream(output)!!.use { stream ->
                val exif = ExifInterface(stream)
                assertNotNull(exif.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL))
                assertEquals(ExifInterface.ORIENTATION_NORMAL, exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, 0))
            }
            assertArrayEquals(source.readBytes(), target.readBytes())
        } finally {
            (albumUris() - before).forEach { context.contentResolver.delete(it, null, null) }
            root.deleteRecursively()
        }
    }

    @Test fun jpegAndSixteenBitPngHonorFinalCapAndNeverEnlarge() {
        val root = File(context.cacheDir, "sizes-${UUID.randomUUID()}").apply { mkdirs() }
        try {
            val source = raw(root, "source.ARW")
            val original = source.readBytes()
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                processor.preview(source, null, EditSettings(exposure = 1f), 128, true)
                for (png in listOf(false, true)) {
                    val output = File(root, if (png) "limited.png" else "limited.jpg")
                    processor.export(source, null, EditSettings(), output, png, 512)
                    val image = BitmapFactory.decodeFile(output.path)
                    assertEquals(512, maxOf(image.width, image.height)); image.recycle()
                    assertEquals(PhotoInfoReader.read(source).captureTime, PhotoInfoReader.read(output).captureTime)
                    if (png) assertEquals(16, output.readBytes()[24].toInt())
                }
                val native = File(root, "native.jpg"); val capped = File(root, "no-enlarge.jpg")
                processor.export(source, null, EditSettings(), native, false)
                processor.export(source, null, EditSettings(), capped, false, 65535)
                val a = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                val b = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFile(native.path, a); BitmapFactory.decodeFile(capped.path, b)
                assertEquals(a.outWidth, b.outWidth); assertEquals(a.outHeight, b.outHeight)
            }
            assertArrayEquals(original, source.readBytes())
        } finally { root.deleteRecursively() }
    }

    @Test fun actualBatchRecoveryAndRetryKeepTheFrozenExportSize() {
        val root = File(context.cacheDir, "sized-batch-${UUID.randomUUID()}").apply { mkdirs() }
        val outputs = mutableSetOf<Uri>()
        var resumed: BatchExportModel? = null
        try {
            val source = raw(root, "source.ARW"); val target = raw(root, "target.ARW")
            val broken = raw(root, "broken.ARW")
            val identity = PhotoIdentity(Uri.fromFile(target).toString())
            val store = EditStore(File(context.filesDir, "edits"))
            val originalEdit = store.load(identity)
            import(source)
            val model = compose.activity.model
            compose.runOnUiThread { model.beginBatch() }
            val batch = model.batch.value!!
            compose.waitUntil(60_000) { batch.state.value.phase == BatchPhase.SELECTING }
            compose.runOnUiThread { batch.addUris(listOf(Uri.fromFile(target), Uri.fromFile(broken))) }
            compose.waitUntil(60_000) { batch.state.value.phase != BatchPhase.PREPARING }
            assertEquals(2, batch.state.value.job.rows.size)
            batch.state.value.job.rows.single { it.target.displayName == "broken.ARW" }.target.sourceFile.writeBytes(ByteArray(64))
            compose.runOnUiThread { batch.start(false, null, 256) }
            compose.waitUntil(240_000) { batch.state.value.phase !in setOf(BatchPhase.PREPARING, BatchPhase.RUNNING) }
            val job = batch.state.value.job
            assertEquals(1, job.rows.count { it.status == BatchRowStatus.SUCCESS })
            assertEquals(1, job.rows.count { it.status == BatchRowStatus.FAILED })
            val first = job.rows.single { it.status == BatchRowStatus.SUCCESS }.outputUri!!
            outputs += Uri.parse(first)
            val journal = BatchJournal(File(context.filesDir, "RawLab/BatchJobs"))
            val recovered = journal.load(job.id)!!
            assertEquals(256, recovered.outputLongEdge)
            source.copyTo(recovered.rows.single { it.status == BatchRowStatus.FAILED }.target.sourceFile, overwrite = true)
            batch.close()
            compose.runOnUiThread { resumed = BatchExportModel(context, model.storage, recovered.source, recovered) }
            compose.waitUntil(60_000) { resumed!!.state.value.phase != BatchPhase.PREPARING }
            compose.runOnUiThread { resumed!!.retryFailed() }
            compose.waitUntil(240_000) { resumed!!.state.value.phase !in setOf(BatchPhase.PREPARING, BatchPhase.RUNNING) }
            val result = resumed!!.state.value.job
            assertEquals(256, result.outputLongEdge)
            assertEquals(2, result.rows.count { it.status == BatchRowStatus.SUCCESS })
            assertEquals(first, result.rows.first { it.target.displayName == "target.ARW" }.outputUri)
            result.rows.forEach { row ->
                val uri = Uri.parse(row.outputUri!!); outputs += uri
                context.contentResolver.openInputStream(uri)!!.use { stream ->
                    val image = BitmapFactory.decodeStream(stream)
                    assertEquals(256, maxOf(image.width, image.height)); image.recycle()
                }
            }
            assertEquals(originalEdit, store.load(identity))
            assertArrayEquals(source.readBytes(), target.readBytes())
        } finally {
            resumed?.discard(); resumed?.close()
            outputs.forEach { context.contentResolver.delete(it, null, null) }
            root.deleteRecursively()
        }
    }

    private fun albumUris(): Set<Uri> {
        val uris = mutableSetOf<Uri>()
        context.contentResolver.query(MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            arrayOf(MediaStore.Images.Media._ID), "${MediaStore.Images.Media.DISPLAY_NAME} LIKE ?", arrayOf("RawLab-%"), null)?.use { cursor ->
            while (cursor.moveToNext()) uris += ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, cursor.getLong(0))
        }
        return uris
    }

    private fun capture(name: String) {
        compose.waitForIdle()
        val image = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        File(context.getExternalFilesDir(null), name).outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
}
