package com.rawlab.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import android.os.SystemClock
import android.os.Bundle
import androidx.exifinterface.media.ExifInterface

@RunWith(AndroidJUnit4::class)
class NativeProcessorTest {
    @Test fun whiteBalancePreviewLatency() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val input = File(instrumentation.targetContext.cacheDir, "wb-latency-test.arw")
        instrumentation.context.assets.open("DSC09067.ARW").use { from -> input.outputStream().use { from.copyTo(it) } }
        val budget = InstrumentationRegistry.getArguments().getString("wbPreviewBudgetMs")?.toLong()
        val changed = mutableListOf<Long>()
        val report = StringBuilder()
        try {
            NativeProcessor(NativeProcessor.FORCE).use { processor ->
                val lut = PhotoStorage(instrumentation.targetContext).filmPath("velvia")
                fun measure(label: String, settings: EditSettings, interactive: Boolean): Long {
                    val started = SystemClock.elapsedRealtime()
                    val edge = if (interactive) 1000 else 1600
                    val neutral = processor.preview(input, null, settings, edge, interactive)
                    val film = processor.preview(input, lut, settings, edge, interactive)
                    assertEquals(2, neutral.backend)
                    assertEquals(2, film.backend)
                    val elapsed = SystemClock.elapsedRealtime() - started
                    val line = "$label ms=$elapsed\n"
                    report.append(line)
                    instrumentation.sendStatus(2, Bundle().apply { putString("stream", line) })
                    return elapsed
                }
                measure("initial camera WB", EditSettings(), false)
                for (temperature in listOf(4200f, 5200f, 7200f)) {
                    val settings = EditSettings(customWb = true, temperature = temperature, tint = 12f)
                    changed += measure("changed WB $temperature", settings, true)
                    measure("cached WB $temperature", settings, true)
                }
                measure("exact WB after drag", EditSettings(customWb = true, temperature = 7200f, tint = 12f), false)
            }
            if (budget != null) assertTrue("Changed WB paired previews $changed must each finish within $budget ms", changed.all { it <= budget })
        } finally {
            File(instrumentation.targetContext.getExternalFilesDir(null), "wb-latency.txt").writeText(report.toString())
            input.delete()
        }
    }

    @Test fun gpuCanBeDisabledAndRestoredWithoutLosingSession() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val input = File(instrumentation.targetContext.cacheDir, "gpu-mode-test.arw")
        instrumentation.context.assets.open("DSC09067.ARW").use { from -> input.outputStream().use { from.copyTo(it) } }
        try {
            NativeProcessor(NativeProcessor.FORCE).use { processor ->
                assertEquals(2, processor.preview(input, null, EditSettings(), 400, false).backend)
                processor.setGpuMode(NativeProcessor.CPU)
                assertEquals(0, processor.preview(input, null, EditSettings(), 400, false).backend)
                processor.setGpuMode(NativeProcessor.AUTO)
                assertEquals(2, processor.preview(input, null, EditSettings(), 400, false).backend)
            }
        } finally { input.delete() }
    }
    @Test fun realRawPreviewAndFullResolutionExport() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val input = File(context.cacheDir, "native-test.arw")
        instrumentation.context.assets.open("DSC09067.ARW").use { from -> input.outputStream().use { from.copyTo(it) } }
        try {
            NativeProcessor().use { processor ->
                val storage = PhotoStorage(context)
                val neutral = processor.preview(input, null, EditSettings(), 400, false)
                assertEquals(400, maxOf(neutral.width, neutral.height))
                assertEquals(neutral.width * neutral.height * 4, neutral.pixels.size)
                val film = processor.preview(input, storage.filmPath("velvia"), EditSettings(film = "velvia"), 400, false)
                assertFalse(neutral.pixels.contentEquals(film.pixels))
                val strong = processor.preview(input, storage.filmPath("velvia"), EditSettings(film = "velvia", strength = 2f), 400, false)
                assertFalse(film.pixels.contentEquals(strong.pixels))
                val bright = processor.preview(input, null, EditSettings(exposure = 1f), 400, false)
                assertFalse(neutral.pixels.contentEquals(bright.pixels))
                if (neutral.temperature.isFinite()) {
                    val warm = processor.preview(input, null, EditSettings(customWb = true, temperature = 9000f), 400, false)
                    assertFalse(neutral.pixels.contentEquals(warm.pixels))
                }
                val out = File(context.cacheDir, "native-export.png")
                processor.export(input, null, EditSettings(), out, true)
                val header = ByteArray(26)
                java.io.DataInputStream(out.inputStream()).use { it.readFully(header) }
                assertEquals(16, header[24].toInt())
                fun intAt(i: Int) = java.nio.ByteBuffer.wrap(header, i, 4).int
                assertEquals(7008, intAt(16))
                assertEquals(4672, intAt(20))
                assertCaptureMetadata(input, out)
                out.delete()
                val jpeg = File(context.cacheDir, "native-export.jpg")
                processor.export(input, storage.filmPath("velvia"), EditSettings(film = "velvia", strength = 2f), jpeg, false)
                val dimensions = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
                android.graphics.BitmapFactory.decodeFile(jpeg.path, dimensions)
                assertEquals(7008, dimensions.outWidth)
                assertEquals(4672, dimensions.outHeight)
                assertCaptureMetadata(input, jpeg)
                jpeg.delete()
                assertThrows(Exception::class.java) { processor.preview(File(context.cacheDir, "missing.dng"), null, EditSettings(), 400, false) }
            }
        } finally { input.delete() }
    }

    @Test fun closedProcessorCannotRender() {
        val processor = NativeProcessor()
        processor.close()
        processor.close()
        assertThrows(IllegalStateException::class.java) { processor.preview(File("missing.dng"), null, EditSettings(), 400, false) }
    }

    private fun assertCaptureMetadata(input: File, output: File) {
        val source = ExifInterface(input)
        val result = ExifInterface(output)
        for (tag in listOf(ExifInterface.TAG_MAKE, ExifInterface.TAG_MODEL,
            ExifInterface.TAG_DATETIME_ORIGINAL, ExifInterface.TAG_LENS_MODEL)) {
            assertNotNull("Fixture must contain $tag", source.getAttribute(tag))
            assertEquals(tag, source.getAttribute(tag), result.getAttribute(tag))
        }
        for (tag in listOf(ExifInterface.TAG_F_NUMBER, ExifInterface.TAG_EXPOSURE_TIME)) {
            assertTrue(source.getAttributeDouble(tag, 0.0) > 0)
            assertEquals(tag, source.getAttributeDouble(tag, 0.0), result.getAttributeDouble(tag, 0.0), .000001)
        }
        assertEquals(1, result.getAttributeInt(ExifInterface.TAG_ORIENTATION, 0))
        assertEquals(7008, result.getAttributeInt(ExifInterface.TAG_PIXEL_X_DIMENSION, 0))
        assertEquals(4672, result.getAttributeInt(ExifInterface.TAG_PIXEL_Y_DIMENSION, 0))
    }
}
