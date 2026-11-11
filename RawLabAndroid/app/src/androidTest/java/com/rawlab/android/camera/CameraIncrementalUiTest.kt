package com.rawlab.android.camera

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.MediaStore
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.test.platform.app.InstrumentationRegistry
import androidx.exifinterface.media.ExifInterface
import com.rawlab.android.MainActivity
import com.rawlab.android.camera.protocol.CameraIncrementalSessionFixture
import com.rawlab.android.photo.MediaPhotoLibrary
import com.rawlab.android.testing.LanguageTestRule
import org.junit.Assert.assertEquals
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * Real Compose/queue/MediaStore coverage for an incremental Sony import.
 * The protocol fixture is a loopback PTP/IP responder, not a fake queue.
 */
class CameraIncrementalUiTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val languageAndCompose: RuleChain = RuleChain.outerRule(LanguageTestRule()).around(compose)

    @Test
    fun incrementalImportReconnectsOnlyTheInterruptedJpegAndKeepsMediaUris() {
        compose.waitUntil(10_000) { !compose.activity.camera.state.value.preparing }
        val model = compose.activity.camera
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val savedUris = mutableListOf<String>()

        CameraIncrementalSessionFixture(context.cacheDir).use { fixture ->
            try {
                connect(model, fixture)
                // Enter the real camera page while the injected PTP/IP session is connected.
                compose.onNodeWithTag("editor-camera").performClick()
                compose.onNodeWithTag("camera-mode-IMPORT").performClick()
                compose.onNodeWithTag("camera-import-mode-INCREMENTAL").performClick()
                compose.onNodeWithTag("camera-incremental-options").assertIsDisplayed()
                compose.onNodeWithTag("camera-incremental-format-RAW").performClick()
                assertTrue(checkNotNull(model.state.value.incrementalScan).assets.single().raw)
                compose.onNodeWithTag("camera-incremental-format-JPEG").performClick()
                assertFalse(checkNotNull(model.state.value.incrementalScan).assets.single().raw)
                compose.onNodeWithTag("camera-incremental-format-RAW_AND_JPEG").performClick()
                compose.waitUntil(10_000) {
                    model.state.value.incrementalScan?.assets?.size == 2
                }
                assertTrue("Incremental import requires no manual selection", model.state.value.selected.isEmpty())
                compose.onNodeWithTag("camera-incremental-pending-count").assertIsDisplayed()

                // Exercise the real JPEG controls before the queue freezes the plan.
                compose.onNodeWithTag("camera-jpeg-adjust").performClick()
                compose.waitUntil(10_000) { model.state.value.incrementalJpeg.adjust }
                compose.onNodeWithTag("camera-jpeg-size").performScrollTo().performTextReplacement("16")
                compose.onNodeWithTag("camera-jpeg-quality").performScrollTo().performTextReplacement("82")
                compose.waitUntil(10_000) {
                    model.state.value.incrementalJpeg == CameraJPEGOptions(adjust = true, longEdge = 16, quality = 82)
                }
                capture("settings")

                // One click starts both transfers. RAW is published before the first JPEG disconnect.
                compose.onNodeWithTag("camera-import").performClick()
                compose.waitUntil(30_000) {
                    val job = model.state.value.job
                    !model.state.value.transferring && !model.state.value.closing &&
                        job?.items?.count { it.saved != null } == 1 &&
                        job.items.any { it.photo.name == fixture.jpegName && it.saved == null }
                }
                compose.onNodeWithText("上次导入未完成").assertIsDisplayed()
                val paused = checkNotNull(model.state.value.job)
                assertEquals(1, paused.items.count { it.saved != null })
                assertTrue(paused.items.first { it.photo.name == fixture.rawName }.saved != null)
                assertNull(paused.items.first { it.photo.name == fixture.jpegName }.saved)
                assertEquals(listOf(1, 2), fixture.downloadRequests.map { it.file })

                val rawUri = checkNotNull(paused.items.first { it.photo.name == fixture.rawName }.saved).uri
                savedUris += rawUri
                assertPublished(context, rawUri)
                capture("paused")

                // Reconnect the actual session, then exercise the task page's Continue button.
                connect(model, fixture)
                assertEquals(CameraImportMode.INCREMENTAL, model.state.value.importMode)
                assertEquals(2, model.state.value.incrementalScan?.assets?.size)
                assertEquals(paused.id, model.state.value.resumableIncrementalJob?.id)
                assertEquals(CameraJPEGOptions(adjust = true, longEdge = 16, quality = 82), model.state.value.incrementalJpeg)
                compose.onNodeWithTag("camera-resume").performClick()
                compose.waitUntil(30_000) {
                    !model.state.value.transferring && model.state.value.job?.status == CameraJobStatus.COMPLETE
                }
                compose.onNodeWithText("导入完成").assertIsDisplayed()

                val complete = checkNotNull(model.state.value.job)
                assertEquals(paused.id, complete.id)
                assertEquals(paused.items.map { it.photo.key }, complete.items.map { it.photo.key })
                assertEquals(2, complete.savedCount)
                val completeUris = complete.items.mapNotNull { it.saved?.uri }
                assertEquals(2, completeUris.size)
                assertEquals(2, completeUris.toSet().size)
                assertEquals(rawUri, complete.items.first { it.photo.name == fixture.rawName }.saved?.uri)
                val jpegUri = complete.items.first { it.photo.name == fixture.jpegName }.saved!!.uri
                savedUris += jpegUri
                savedUris.forEach { assertPublished(context, it) }
                assertEquals(CameraJPEGOptions(adjust = true, longEdge = 16, quality = 82), complete.incremental?.jpeg)
                assertJpegOutput(context, jpegUri)
                assertEquals(listOf(1, 2, 12), fixture.downloadRequests.map { it.file })
                assertNotEquals(fixture.downloadRequests[1].content, fixture.downloadRequests[2].content)

                // The same card is scanned again through the real incremental controls.
                compose.onNodeWithTag("camera-back").performClick()
                compose.onNodeWithTag("camera-incremental-refresh").performScrollTo().performClick()
                compose.waitUntil(10_000) {
                    model.state.value.stage == null && model.state.value.incrementalScan?.assets?.isEmpty() == true
                }
                compose.onNodeWithTag("camera-incremental-no-new").assertIsDisplayed()
                assertEquals(savedUris, model.state.value.job!!.items.mapNotNull { it.saved?.uri })
                assertEquals("Rescanning an unchanged card must not download a duplicate", 3, fixture.downloadRequests.size)
                capture("no-new-files")

                // A fresh session rechecks same-time boundary files by digest and reuses their existing MediaStore rows.
                compose.runOnUiThread { model.disconnect() }
                compose.waitUntil(10_000) { !model.state.value.closing }
                connect(model, fixture)
                assertEquals(2, model.state.value.incrementalScan?.assets?.size)
                compose.onNodeWithTag("camera-import").performClick()
                compose.waitUntil(30_000) {
                    val job = model.state.value.job
                    !model.state.value.transferring && job?.id != complete.id && job?.status == CameraJobStatus.COMPLETE
                }
                val duplicate = checkNotNull(model.state.value.job)
                assertTrue(duplicate.items.all { it.duplicate })
                assertEquals(completeUris, duplicate.items.mapNotNull { it.saved?.uri })
                assertEquals(listOf(1, 2, 12, 21, 22), fixture.downloadRequests.map { it.file })
            } finally {
                compose.runOnUiThread { model.disconnect() }
                compose.waitUntil(10_000) { !model.state.value.closing }
                savedUris.distinct().forEach { uri ->
                    context.contentResolver.delete(Uri.parse(uri), null, null)
                    context.getSharedPreferences("camera-media-sources", 0).edit().remove(uri).commit()
                }
                model.state.value.jobs.filter { it.cameraId == fixture.cameraId }.forEach {
                    File(context.filesDir, "camera-media-imports/${it.id}.json").delete()
                }
                val preferences = context.getSharedPreferences("camera-import", 0)
                val edit = preferences.edit()
                preferences.all.keys.filter { it.startsWith("camera:${fixture.cameraId}:") }.forEach(edit::remove)
                edit.commit()
            }
        }
    }

    private fun connect(model: CameraImportViewModel, fixture: CameraIncrementalSessionFixture) {
        compose.runOnUiThread { model.connectImport(fixture.factory, fixture.address, fixture.cameraId) }
        compose.waitUntil(15_000) { model.state.value.connected && model.state.value.photos.size == 2 }
    }

    private fun assertPublished(context: android.content.Context, uri: String) {
        val media = MediaPhotoLibrary(context).inspect(uri)
        assertNotNull("MediaStore row missing for $uri", media)
        assertFalse("Published camera media must not remain pending", checkNotNull(media).pending)
    }

    private fun assertJpegOutput(context: android.content.Context, uri: String) {
        val library = MediaPhotoLibrary(context)
        context.contentResolver.query(
            Uri.parse(uri),
            arrayOf(MediaStore.Images.Media.MIME_TYPE, MediaStore.Images.Media.IS_PENDING),
            null,
            null,
            null,
        )!!.use { cursor ->
            assertTrue("MediaStore JPEG row missing", cursor.moveToFirst())
            assertEquals("image/jpeg", cursor.getString(0))
            assertEquals(0, cursor.getInt(1))
        }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        library.open(uri).use { input -> BitmapFactory.decodeStream(input, null, bounds) }
        assertEquals(16, bounds.outWidth)
        assertEquals(8, bounds.outHeight)
        library.open(uri).use {
            val exif = ExifInterface(it)
            assertEquals(ExifInterface.ORIENTATION_ROTATE_90,
                exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_UNDEFINED))
            assertEquals("2026:11:11 08:30:00", exif.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL))
        }
        val jpeg = library.open(uri).use { it.readBytes() }
        val reference = Bitmap.createBitmap(16, 8, Bitmap.Config.ARGB_8888)
        try {
            val expected = ByteArrayOutputStream().also { reference.compress(Bitmap.CompressFormat.JPEG, 82, it) }
            assertArrayEquals(quantizationTable(expected.toByteArray()), quantizationTable(jpeg))
        } finally { reference.recycle() }
    }

    private fun quantizationTable(jpeg: ByteArray): ByteArray {
        var offset = 2 // Start after the JPEG SOI marker.
        while (offset + 4 <= jpeg.size && jpeg[offset].toInt() and 0xff == 0xff) {
            val type = jpeg[offset + 1].toInt() and 0xff
            val length = ((jpeg[offset + 2].toInt() and 0xff) shl 8) or (jpeg[offset + 3].toInt() and 0xff)
            if (type == 0xdb) return jpeg.copyOfRange(offset + 4, offset + 2 + length)
            if (type == 0xda || length < 2) break
            offset += 2 + length
        }
        error("JPEG quantization table missing")
    }

    private fun capture(name: String) {
        val directory = File(compose.activity.getExternalFilesDir(null), "camera-incremental").apply { mkdirs() }
        val bitmap = checkNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot())
        try { File(directory, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) } }
        finally { bitmap.recycle() }
    }
}
