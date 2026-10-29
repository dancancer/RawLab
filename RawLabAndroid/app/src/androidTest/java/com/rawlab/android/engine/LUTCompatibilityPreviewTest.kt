package com.rawlab.android.engine

import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.looks.LUTCompatibility
import com.rawlab.android.looks.LUTReferenceConditions
import com.rawlab.android.looks.LUTCompatibilityPreview
import com.rawlab.android.editor.PendingLookCompatibility
import com.rawlab.android.photo.ImportedPhoto
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class LUTCompatibilityPreviewTest {
    @Test fun staleSourceCannotReplaceCurrentPhotoWhenLatestLoadFails() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val before = context.cacheDir.listFiles()!!.toSet()
        val root = File(context.cacheDir, "lut-source-race-${UUID.randomUUID()}").apply { mkdirs() }
        val copyingB = CountDownLatch(1)
        val releaseB = CountDownLatch(1)
        var preview: LUTCompatibilityPreview? = null
        fun awaitState(check: () -> Boolean) {
            val deadline = System.currentTimeMillis() + 15_000
            var done = false
            while (!done && System.currentTimeMillis() < deadline) {
                instrumentation.runOnMainSync { done = check() }
                if (!done) Thread.sleep(20)
            }
            assertTrue("Preview operation timed out", done)
        }
        try {
            fun photo(name: String, color: Int): ImportedPhoto {
                val file = File(root, name)
                Bitmap.createBitmap(32, 16, Bitmap.Config.ARGB_8888).let { bitmap ->
                    bitmap.eraseColor(color)
                    file.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
                    bitmap.recycle()
                }
                return ImportedPhoto(Uri.fromFile(file), name, file, inputKind = PhotoInputKind.RASTER)
            }
            val a = photo("A.png", Color.rgb(20, 80, 150))
            val b = photo("B.png", Color.rgb(230, 60, 10)).copy(validateOriginal = {
                copyingB.countDown()
                check(releaseB.await(15, TimeUnit.SECONDS)) { "Test did not release B" }
            })
            val c = photo("C.png", Color.rgb(50, 180, 70)).copy(validateOriginal = {
                throw java.io.IOException("Latest photo cannot be acquired")
            })
            val lut = File(root, "unknown.cube").apply {
                writeText("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n")
            }
            val draft = LUTCompatibility.parse(NativeProcessor.inspectLutCompatibility(lut))!!
            val configured = draft.applying(draft.candidates.first(), true)!!.copy(interpolation = "tetrahedral")
            val expected = NativeProcessor(NativeProcessor.CPU).use {
                it.previewCompatibility(a.file, PhotoInputKind.RASTER, lut, configured.previewRequest()).pixels
            }
            instrumentation.runOnMainSync {
                preview = LUTCompatibilityPreview(context, PendingLookCompatibility(Uri.fromFile(lut), lut.name, draft))
                preview!!.loadInitial(a)
            }
            awaitState { !preview!!.state.loading && preview!!.state.frames.isNotEmpty() }
            instrumentation.runOnMainSync { preview!!.loadInitial(b) }
            assertTrue("B did not start acquisition", copyingB.await(15, TimeUnit.SECONDS))
            instrumentation.runOnMainSync { preview!!.loadInitial(c) }
            releaseB.countDown()
            awaitState { !preview!!.state.loading && preview!!.state.error != null }
            instrumentation.runOnMainSync {
                assertEquals(a.name, preview!!.state.sourceName)
                preview!!.preview(configured)
            }
            awaitState { preview!!.state.frames.containsKey(configured.previewKey()) }
            instrumentation.runOnMainSync {
                assertArrayEquals("Advanced settings must still preview A after B becomes stale and C fails",
                    expected, preview!!.state.frames.getValue(configured.previewKey()).frame.pixels)
            }
            val owned = context.cacheDir.listFiles()!!.single { it !in before && it.name.startsWith("lut-preview-") }
            assertArrayEquals(a.file.readBytes(), owned.listFiles()!!.single { it.extension == "png" }.readBytes())
            assertEquals("Stale source copies must be removed", 2, owned.listFiles()!!.size)
            instrumentation.runOnMainSync { preview!!.close() }
            awaitState { !owned.exists() }
        } finally {
            releaseB.countDown()
            instrumentation.runOnMainSync { preview?.close() }
            root.deleteRecursively()
        }
    }

    @Test fun changingSourceInvalidatesReferenceAndReleasesPreviousCopy() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val before = context.cacheDir.listFiles()!!.toSet()
        val root = File(context.cacheDir, "guided-fixtures-${UUID.randomUUID()}").apply { mkdirs() }
        var preview: LUTCompatibilityPreview? = null
        try {
            val photo = File(root, "source.png")
            Bitmap.createBitmap(32, 16, Bitmap.Config.ARGB_8888).let { bitmap ->
                bitmap.eraseColor(Color.rgb(60, 90, 120))
                photo.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }; bitmap.recycle()
            }
            val lut = File(root, "unknown.cube").apply { writeText("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n") }
            val draft = LUTCompatibility.parse(NativeProcessor.inspectLutCompatibility(lut))!!
            val source = ImportedPhoto(Uri.fromFile(photo), photo.name, photo, inputKind = PhotoInputKind.RASTER)
            instrumentation.runOnMainSync {
                preview = LUTCompatibilityPreview(context, PendingLookCompatibility(Uri.fromFile(lut), lut.name, draft))
                preview!!.loadInitial(source)
            }
            fun awaitState(check: () -> Boolean) {
                val deadline = System.currentTimeMillis() + 15_000
                var done = false
                while (!done && System.currentTimeMillis() < deadline) {
                    instrumentation.runOnMainSync { done = check() }
                    if (!done) Thread.sleep(20)
                }
                assertTrue("Preview operation timed out", done)
            }
            awaitState { !preview!!.state.loading }
            assertTrue(preview!!.state.frames.isNotEmpty())
            instrumentation.runOnMainSync { preview!!.loadReference(Uri.fromFile(photo)) }
            awaitState { preview!!.state.reference != null }
            instrumentation.runOnMainSync {
                preview!!.loadInitial(source)
                assertNull(preview!!.state.reference); assertNull(preview!!.state.referenceName)
            }
            awaitState { !preview!!.state.loading }
            instrumentation.runOnMainSync { preview!!.loadReference(Uri.fromFile(photo)); preview!!.loadInitial(source) }
            awaitState { !preview!!.state.loading }
            instrumentation.runOnMainSync { assertNull(preview!!.state.reference); assertNull(preview!!.state.referenceName) }
            val owned = context.cacheDir.listFiles()!!.single { it !in before && it.name.startsWith("lut-preview-") }
            assertEquals("Only the current source and LUT copy should remain", 2, owned.listFiles()!!.size)
            instrumentation.runOnMainSync { preview!!.close() }
            awaitState { !owned.exists() }
        } finally {
            instrumentation.runOnMainSync { preview?.close() }
            root.deleteRecursively()
        }
    }
    @Test fun previewAndReferenceComparisonDoNotInstallOrConfirmTheLook() {
        val root = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "lut-preview-test-${UUID.randomUUID()}").apply { mkdirs() }
        try {
            val photo = File(root, "source.png")
            Bitmap.createBitmap(32, 16, Bitmap.Config.ARGB_8888).let { bitmap ->
                bitmap.eraseColor(Color.rgb(60, 90, 120))
                photo.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
                bitmap.recycle()
            }
            val lut = File(root, "unknown.cube").apply { writeText("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n") }
            val original = lut.readBytes()
            val draft = LUTCompatibility.parse(NativeProcessor.inspectLutCompatibility(lut))!!
            val configured = draft.applying(draft.candidates.first(), true)!!
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                val baseline = processor.previewCompatibility(photo, PhotoInputKind.RASTER, null, null)
                val preview = processor.previewCompatibility(photo, PhotoInputKind.RASTER, lut, configured.previewRequest())
                assertEquals(512, preview.width); assertEquals(256, preview.height); assertArrayEquals(baseline.pixels, preview.pixels)
                val conditions = LUTReferenceConditions(true, true, true, true, "Synthetic identity fixture; not independent author evidence")
                val comparison = JSONObject(NativeProcessor.compareLutPreviews(preview, baseline, conditions.json()))
                assertEquals(0.0, comparison.getDouble("mean_absolute_rgb"), 0.0)
                assertEquals("unverified", comparison.getString("appearance"))
                try { NativeProcessor.compareLutPreviews(preview, baseline, LUTReferenceConditions().json()); fail("Unconfirmed comparison accepted") }
                catch (_: IllegalArgumentException) { }
            }
            assertArrayEquals(original, lut.readBytes()); assertEquals(2, root.listFiles()!!.size)
            assertFalse(LUTCompatibility.parse(NativeProcessor.inspectLutCompatibility(lut))!!.canImport)
        } finally { root.deleteRecursively() }
    }
}
