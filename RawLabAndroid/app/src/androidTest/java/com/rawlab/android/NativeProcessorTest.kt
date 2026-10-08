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
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

@RunWith(AndroidJUnit4::class)
class NativeProcessorTest {
    @Test fun whiteBalancePreviewLatency() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val input = File(instrumentation.targetContext.cacheDir, "wb-latency-test.arw")
        instrumentation.context.assets.open("sample.RAW").use { from -> input.outputStream().use { from.copyTo(it) } }
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
        instrumentation.context.assets.open("sample.RAW").use { from -> input.outputStream().use { from.copyTo(it) } }
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
        instrumentation.context.assets.open("sample.RAW").use { from -> input.outputStream().use { from.copyTo(it) } }
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
                val nativeWidth = intAt(16)
                val nativeHeight = intAt(20)
                assertTrue(nativeWidth > neutral.width && nativeHeight > neutral.height)
                assertCaptureMetadata(input, out, nativeWidth, nativeHeight)
                out.delete()
                val jpeg = File(context.cacheDir, "native-export.jpg")
                processor.export(input, storage.filmPath("velvia"), EditSettings(film = "velvia", strength = 2f), jpeg, false)
                val dimensions = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
                android.graphics.BitmapFactory.decodeFile(jpeg.path, dimensions)
                assertEquals(nativeWidth, dimensions.outWidth)
                assertEquals(nativeHeight, dimensions.outHeight)
                assertCaptureMetadata(input, jpeg, nativeWidth, nativeHeight)
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

    @Test fun nativeLookValidationAndRenderingUseSyntheticFixtures() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val cube = File(context.cacheDir, "synthetic-look.cube")
        val rlook = File(context.cacheDir, "synthetic-look.rlook")
        val input = File(context.cacheDir, "synthetic-look-input.arw")
        cube.writeText(syntheticCube())
        rlook.writeBytes(syntheticRlook())
        instrumentation.context.assets.open("sample.RAW").use { from -> input.outputStream().use { from.copyTo(it) } }
        try {
            val cubeBytes = cube.readBytes()
            val rlookBytes = rlook.readBytes()
            assertEquals(LookValidation(LookFormat.CUBE, 0), NativeProcessor.validateLook(cube))
            assertEquals(LookValidation(LookFormat.RLOOK, 1), NativeProcessor.validateLook(rlook))
            assertArrayEquals(cubeBytes, cube.readBytes())
            assertArrayEquals(rlookBytes, rlook.readBytes())
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                assertNotNull(processor.preview(input, cube, EditSettings(), 400, false))
                assertNotNull(processor.preview(input, rlook, EditSettings(), 400, false))
            }
        } finally {
            cube.delete(); rlook.delete(); input.delete()
        }
    }

    @Test fun fujiContractsUseGpuWithCpuParityWithoutChangingSource() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val cube = File(context.cacheDir, "fuji-contract.cube")
        val input = File(context.cacheDir, "fuji-contract-input.arw")
        instrumentation.context.assets.open("sample.RAW").use { from -> input.outputStream().use { from.copyTo(it) } }
        try {
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                for ((transfer, gamut) in listOf("F-Log" to "F-Gamut", "F-Log2" to "F-Gamut", "F-Log2C" to "F-GamutC")) {
                    for (output in listOf("Synthetic Look", "F-Log", "F-Log2", "F-Log2C")) {
                        cube.writeText(syntheticCube().replace("F-Log2 to Synthetic Look", "$transfer to $output")
                            .replace("F-Gamut to", "$gamut to"))
                        val bytes = cube.readBytes()
                        assertEquals(LookValidation(LookFormat.CUBE, 0), NativeProcessor.validateLook(cube))
                        for (strength in listOf(0f, .5f, 1f, 2f)) {
                            val settings = EditSettings(strength = strength, exposure = if (strength == .5f) -4f else 1f)
                            processor.setGpuMode(NativeProcessor.CPU)
                            val cpu = processor.preview(input, cube, settings, 200, false)
                            for (mode in listOf(NativeProcessor.AUTO, NativeProcessor.FORCE)) {
                                processor.setGpuMode(mode)
                                val gpu = processor.preview(input, cube, settings, 200, false)
                                assertEquals("$transfer to $output mode $mode", 2, gpu.backend)
                                assertEquals(cpu.pixels.size, gpu.pixels.size)
                                val difference = cpu.pixels.indices.maxOf { index ->
                                    kotlin.math.abs((cpu.pixels[index].toInt() and 255) - (gpu.pixels[index].toInt() and 255))
                                }
                                assertTrue("$transfer to $output strength $strength mode $mode max DN=$difference", difference <= 2)
                            }
                        }
                        assertArrayEquals(bytes, cube.readBytes())
                    }
                }
            }
        } finally { cube.delete(); input.delete() }
    }

    private fun syntheticCube() = """
        #Gamma:F-Log2 to Synthetic Look
        #Gamut:F-Gamut to ITU-R BT.709
        LUT_3D_SIZE 2
        DOMAIN_MIN 0 0 0
        DOMAIN_MAX 1 1 1
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
    """.trimIndent() + "\n"

    private fun syntheticRlook(): ByteArray {
        val out = ByteArrayOutputStream()
        fun int(value: Int) { out.write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(value).array()) }
        fun float(value: Float) { out.write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putFloat(value).array()) }
        fun double(value: Double) { out.write(ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putDouble(value).array()) }
        out.write("RLOOKDCP".toByteArray())
        listOf(1, 0, 0, 2, 2, 2, 4097, 2).forEach(::int)
        repeat(2) { repeat(9) { index -> double(if (index % 4 == 0) 1.0 else 0.0) } }
        double(1.0)
        repeat(8) { float(0f); float(1f); float(1f) }
        repeat(4097) { index -> double(index / 4096.0) }
        out.write("{}".toByteArray())
        return out.toByteArray()
    }

    private fun assertCaptureMetadata(input: File, output: File, width: Int, height: Int) {
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
        assertEquals(width, result.getAttributeInt(ExifInterface.TAG_PIXEL_X_DIMENSION, 0))
        assertEquals(height, result.getAttributeInt(ExifInterface.TAG_PIXEL_Y_DIMENSION, 0))
    }
}
