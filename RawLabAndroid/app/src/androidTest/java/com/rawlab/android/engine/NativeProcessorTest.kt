package com.rawlab.android.engine

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import android.os.SystemClock
import android.os.Bundle
import java.nio.ByteBuffer
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.settings.DenoisePreset
import com.rawlab.android.settings.DenoiseSettings
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.HslSettings
import com.rawlab.android.settings.LensSettings
import com.rawlab.android.settings.PhotoEffectsSettings
import com.rawlab.android.testing.syntheticRlook

@RunWith(AndroidJUnit4::class)
class NativeProcessorTest {
    @Test fun eachPerspectiveAxisReachesFinalExportAndForceRejectsIt() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val root = File(instrumentation.targetContext.cacheDir, "perspective-axes-${java.util.UUID.randomUUID()}").apply { mkdirs() }
        val input = File(root, "source.RAW")
        instrumentation.context.assets.open("sample.RAW").use { from -> input.outputStream().use { from.copyTo(it) } }
        val sourceHash = java.security.MessageDigest.getInstance("SHA-256").digest(input.readBytes())
        try {
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                val original = processor.preview(input, null, EditSettings(), 300, false)
                for ((horizontal, vertical) in listOf(.35f to 0f, 0f to -.25f, .35f to -.25f)) {
                    val settings = EditSettings(geometry = GeometrySettings(perspectiveHorizontal = horizontal, perspectiveVertical = vertical))
                    val exact = processor.preview(input, null, settings, 300, false)
                    assertTrue("Each perspective axis changes the full canvas", exact.geometryWidth != original.geometryWidth || exact.geometryHeight != original.geometryHeight)
                    assertFalse(original.pixels.contentEquals(exact.pixels))
                    val output = File(root, "$horizontal-$vertical.png")
                    assertEquals(0, processor.export(input, null, settings, output, ExportFormat.PNG, 300))
                    val reference = File(root, "reference.png")
                    NativeProcessor(NativeProcessor.CPU).use { fresh ->
                        fresh.export(input, null, settings, reference, ExportFormat.PNG, 300)
                    }
                    assertArrayEquals("FINAL is independent of preview/session history", reference.readBytes(), output.readBytes())
                    val exported = checkNotNull(android.graphics.BitmapFactory.decodeFile(output.path))
                    assertEquals(exact.width, exported.width)
                    assertEquals(exact.height, exported.height)
                    exported.recycle()
                    processor.setGpuMode(NativeProcessor.FORCE)
                    assertThrows(java.io.IOException::class.java) { processor.preview(input, null, settings, 300, false) }
                    val sentinel = output.readBytes()
                    assertThrows(java.io.IOException::class.java) { processor.export(input, null, settings, output, ExportFormat.PNG, 300) }
                    assertArrayEquals(sentinel, output.readBytes())
                    processor.setGpuMode(NativeProcessor.AUTO)
                    val automatic = processor.preview(input, null, settings, 300, false)
                    assertEquals(exact.geometryWidth, automatic.geometryWidth)
                    assertEquals(exact.geometryHeight, automatic.geometryHeight)
                    assertEquals(0, automatic.backend)
                    assertEquals(0, processor.export(input, null, settings, output, ExportFormat.PNG, 300))
                    NativeProcessor(NativeProcessor.AUTO).use { fresh ->
                        assertEquals(0, fresh.export(input, null, settings, reference, ExportFormat.PNG, 300))
                    }
                    assertArrayEquals("AUTO FINAL keeps the active-geometry CPU reporting contract", reference.readBytes(), output.readBytes())
                    processor.setGpuMode(NativeProcessor.CPU)
                }
                assertArrayEquals(original.pixels, processor.preview(input, null, EditSettings(), 300, false).pixels)
            }
            assertArrayEquals(sourceHash, java.security.MessageDigest.getInstance("SHA-256").digest(input.readBytes()))
        } finally { root.deleteRecursively() }
    }

    @Test fun geometryReachesExactInteractivePreviewFinalExportAndSessionReset() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val input = File(context.cacheDir, "geometry-test.RAW")
        val output = File(context.cacheDir, "geometry-test.png")
        instrumentation.context.assets.open("sample.RAW").use { from -> input.outputStream().use { from.copyTo(it) } }
        try {
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                val original = processor.preview(input, null, EditSettings(), 300, false)
                val settings = EditSettings(geometry = GeometrySettings(.15f, .1f, .75f, .8f, 1, true, false, 8f, .35f, -.25f))
                val exact = processor.preview(input, null, settings, 300, false)
                val interactive = processor.preview(input, null, settings, 300, true)
                assertEquals(exact.width, interactive.width)
                assertEquals(exact.height, interactive.height)
                assertEquals(exact.geometryWidth, interactive.geometryWidth)
                assertEquals(exact.geometryHeight, interactive.geometryHeight)
                assertArrayEquals(exact.pixels, interactive.pixels)
                assertTrue(maxOf(exact.geometryWidth, exact.geometryHeight) >= maxOf(exact.width, exact.height))
                processor.export(input, null, settings, output, ExportFormat.PNG, 300)
                val exported = checkNotNull(android.graphics.BitmapFactory.decodeFile(output.path))
                assertEquals(exact.width, exported.width)
                assertEquals(exact.height, exported.height)
                assertTrue(processor.autoExposure(input, settings).isFinite())
                val reset = processor.preview(input, null, EditSettings(), 300, false)
                assertEquals(original.width, reset.width)
                assertEquals(original.height, reset.height)
                assertArrayEquals(original.pixels, reset.pixels)
            }
        } finally { input.delete(); output.delete() }
    }

    @Test fun perspectiveAloneChangesNeutralCanvasAndZeroValuesClearReusedSession() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val input = File(instrumentation.targetContext.cacheDir, "perspective-test.RAW")
        instrumentation.context.assets.open("sample.RAW").use { from -> input.outputStream().use { from.copyTo(it) } }
        try {
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                val identity = EditSettings()
                val original = processor.preview(input, null, identity, 300, false)
                val settings = identity.copy(geometry = GeometrySettings(perspectiveHorizontal = -.4f, perspectiveVertical = .3f))
                val transformed = processor.preview(input, null, settings, 300, false)
                assertFalse(original.pixels.contentEquals(transformed.pixels))
                assertTrue(transformed.geometryWidth < original.geometryWidth || transformed.geometryHeight < original.geometryHeight)
                val interactive = processor.preview(input, null, settings, 300, true)
                assertEquals(transformed.geometryWidth, interactive.geometryWidth)
                assertEquals(transformed.geometryHeight, interactive.geometryHeight)
                assertArrayEquals(transformed.pixels, interactive.pixels)
                assertEquals(processor.autoExposure(input, settings), processor.autoExposure(input, identity), .000001f)
                val reset = processor.preview(input, null, identity, 300, false)
                assertEquals(original.geometryWidth, reset.geometryWidth)
                assertEquals(original.geometryHeight, reset.geometryHeight)
                assertArrayEquals(original.pixels, reset.pixels)
            }
        } finally { input.delete() }
    }

    @Test fun lensCorrectionReachesPreviewExportAndReset() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val input = File(context.cacheDir, "lens-test.RAW")
        val output = File(context.cacheDir, "lens-test.png")
        instrumentation.context.assets.open("sample.RAW").use { from -> input.outputStream().use { from.copyTo(it) } }
        try {
            NativeProcessor(NativeProcessor.CPU, PhotoStorage(context).lensDatabase()).use { processor ->
                val off = processor.preview(input, null, EditSettings(), 300, false)
                val unselected = processor.preview(input, null,
                    EditSettings(lens = LensSettings(distortion = true, manual = true)), 300, false)
                assertEquals(4, unselected.lens!!.state)
                assertArrayEquals(off.pixels, unselected.pixels)
                val candidate = off.lens!!.candidates.first { it.isMatch && it.hasDistortion }
                val settings = EditSettings(lens = LensSettings(true, true, true, true, candidate.id))
                val corrected = processor.preview(input, null, settings, 300, false)
                assertTrue(corrected.lens!!.appliedDistortion)
                assertEquals(candidate.hasTca, corrected.lens!!.appliedTca)
                assertEquals(off.width, corrected.width); assertEquals(off.height, corrected.height)
                assertFalse(off.pixels.contentEquals(corrected.pixels))
                processor.setGpuMode(NativeProcessor.FORCE)
                val gpu = processor.preview(input, null, settings, 300, false)
                assertEquals(2, gpu.backend)
                assertTrue(corrected.pixels.indices.maxOf { kotlin.math.abs((corrected.pixels[it].toInt() and 255) - (gpu.pixels[it].toInt() and 255)) } <= 2)
                processor.setGpuMode(NativeProcessor.CPU)
                val automatic = processor.preview(input, null, settings.copy(lens = settings.lens.copy(manual = false)), 300, false)
                if (off.lens!!.candidates.count { it.isMatch } == 1) assertArrayEquals(corrected.pixels, automatic.pixels)
                else assertEquals(5, automatic.lens!!.state)
                val reset = processor.preview(input, null, EditSettings(), 300, false)
                assertArrayEquals(off.pixels, reset.pixels); assertEquals(0, reset.lens!!.state)
                processor.export(input, null, settings, output, ExportFormat.PNG, 300)
                assertEquals(16, output.readBytes()[24].toInt())
            }
        } finally { input.delete(); output.delete() }
    }

    @Test fun hslAndAutomaticExposureReachTheSharedCore() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val input = File(instrumentation.targetContext.cacheDir, "hsl-auto-test.dng")
        instrumentation.context.assets.open("sample.RAW").use { from -> input.outputStream().use { from.copyTo(it) } }
        try {
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                val settings = EditSettings()
                val identity = processor.preview(input, null, settings, 200, false)
                val hsl = HslSettings(List(24) { if (it in 8..15) -100f else 0f })
                val edited = settings.copy(hsl = hsl)
                val cpu = processor.preview(input, null, edited, 200, false)
                assertFalse(identity.pixels.contentEquals(cpu.pixels))
                processor.setGpuMode(NativeProcessor.AUTO)
                val automatic = processor.preview(input, null, edited, 200, false)
                assertEquals(2, automatic.backend)
                assertTrue(cpu.pixels.indices.maxOf { kotlin.math.abs((cpu.pixels[it].toInt() and 255) - (automatic.pixels[it].toInt() and 255)) } <= 2)
                processor.setGpuMode(NativeProcessor.FORCE)
                val forced = processor.preview(input, null, edited, 200, false)
                assertEquals(2, forced.backend)
                assertArrayEquals(automatic.pixels, forced.pixels)
                val reset = processor.preview(input, null, settings, 200, false)
                assertEquals(2, reset.backend)
                assertTrue(identity.pixels.indices.maxOf { kotlin.math.abs((identity.pixels[it].toInt() and 255) - (reset.pixels[it].toInt() and 255)) } <= 2)
                assertArrayEquals(forced.pixels, processor.preview(input, null, edited, 200, false).pixels)
                val ev = processor.autoExposure(input, settings)
                assertTrue(ev.isFinite() && ev in -4f..4f)
                assertEquals(ev, processor.autoExposure(input, edited.copy(exposure = 3f)))
                for (mode in 0..2) assertTrue(processor.autoExposure(input, settings.copy(exposureMode = mode)).isFinite())
            }
        } finally { input.delete() }
    }
    @Test fun photoEffectsAndDisplayChromaReachPreviewAndExport() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val input = File(context.cacheDir, "effects-test.dng")
        val output = File(context.cacheDir, "effects-test.png")
        instrumentation.context.assets.open("sample.RAW").use { from -> input.outputStream().use { from.copyTo(it) } }
        try {
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                val neutral = processor.preview(input, null, EditSettings(), 200, false)
                val settings = EditSettings(
                    displayChromaDenoise = 2,
                    denoise = DenoiseSettings().withPreset(DenoisePreset.CLEAN),
                    effects = PhotoEffectsSettings(vignetteAmount = -65f, vignetteMidpoint = 20f,
                        vignetteRoundness = -35f, vignetteFeather = 70f, vignetteHighlights = 75f,
                        grainAmount = 70f, grainSize = 60f, grainRoughness = 80f),
                )
                val result = processor.preview(input, null, settings, 200, false)
                assertFalse(neutral.pixels.contentEquals(result.pixels))
                processor.setGpuMode(NativeProcessor.AUTO)
                val gpu = processor.preview(input, null, settings, 200, false)
                assertEquals(2, gpu.backend)
                assertEquals(result.pixels.size, gpu.pixels.size)
                val maximum = result.pixels.indices.maxOf { index ->
                    kotlin.math.abs((result.pixels[index].toInt() and 255) - (gpu.pixels[index].toInt() and 255))
                }
                assertTrue("Combined effects/wavelet/chroma CPU/GLES parity max DN=$maximum", maximum <= 2)
                assertArrayEquals(gpu.pixels, processor.preview(input, null, settings, 200, false).pixels)
                processor.export(input, null, settings, output, ExportFormat.PNG)
                assertTrue(output.isFile && output.length() > 0)
            }
        } finally { input.delete(); output.delete() }
    }

    @Test fun waveletDenoisePreviewAndExportShareTheSameSettings() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val input = File(context.cacheDir, "wavelet-test.dng")
        val output = File(context.cacheDir, "wavelet-test.png")
        val reference = File(context.cacheDir, "wavelet-reference.png")
        val jpeg = File(context.cacheDir, "wavelet-test.jpg")
        val jpegReference = File(context.cacheDir, "wavelet-reference.jpg")
        val settings = EditSettings(denoise = DenoiseSettings().withPreset(DenoisePreset.CLEAN))
        instrumentation.context.assets.open("sample.RAW").use { from -> input.outputStream().use { from.copyTo(it) } }
        try {
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                val off = processor.preview(input, null, EditSettings(), 1600, false)
                val clean = processor.preview(input, null, settings, 1600, false)
                assertFalse(off.pixels.contentEquals(clean.pixels))
                assertEquals(0, clean.backend)
                processor.preview(input, null, settings, 128, true)
                assertArrayEquals(clean.pixels, processor.preview(input, null, settings, 1600, false).pixels)
                assertArrayEquals(off.pixels, processor.preview(input, null,
                    settings.copy(denoise = settings.denoise.copy(enabled = false)), 1600, false).pixels)
                processor.setGpuMode(NativeProcessor.FORCE)
                assertThrows(java.io.IOException::class.java) {
                    processor.preview(input, null, settings, 1600, false)
                }
                processor.setGpuMode(NativeProcessor.AUTO)
                val gpu = processor.preview(input, null, settings, 1600, false)
                assertEquals(2, gpu.backend)
                assertEquals(clean.pixels.size, gpu.pixels.size)
                val difference = clean.pixels.indices.maxOf { index ->
                    kotlin.math.abs((clean.pixels[index].toInt() and 255) - (gpu.pixels[index].toInt() and 255))
                }
                assertTrue("Wavelet GLES CPU parity max DN=$difference", difference <= 2)
                processor.setGpuMode(NativeProcessor.CPU)
                instrumentation.sendStatus(2, Bundle().apply { putString("stream", "Applied viewport denoise; begin native PNG\n") })
                processor.export(input, null, settings, output, ExportFormat.PNG)
                processor.preview(input, null, settings.copy(exposure = .35f), 320, true)
                processor.export(input, null, settings.copy(exposure = .35f), jpeg, ExportFormat.JPEG)
            }
            val header = ByteArray(26)
            java.io.DataInputStream(output.inputStream()).use { it.readFully(header) }
            assertEquals(16, header[24].toInt())
            val width = ByteBuffer.wrap(header, 16, 4).int
            val height = ByteBuffer.wrap(header, 20, 4).int
            assertTrue(maxOf(width, height) > 1600)
            // 独立基准串行执行，避免把两个完整 RAW session 的峰值叠加到测试中。
            NativeProcessor(NativeProcessor.CPU).use { fresh ->
                fresh.export(input, null, settings, reference, ExportFormat.PNG)
                fresh.export(input, null, settings.copy(exposure = .35f), jpegReference, ExportFormat.JPEG)
            }
            for ((actualFile, expectedFile) in listOf(output to reference, jpeg to jpegReference)) {
                val actual = android.graphics.BitmapFactory.decodeFile(actualFile.path)
                val expected = android.graphics.BitmapFactory.decodeFile(expectedFile.path)
                assertEquals(width, actual.width)
                assertEquals(height, actual.height)
                assertTrue("${actualFile.extension} matches independent FINAL after viewport denoise", actual.sameAs(expected))
                actual.recycle(); expected.recycle()
            }
        } finally { input.delete(); output.delete(); reference.delete(); jpeg.delete(); jpegReference.delete() }
    }

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

    @Test fun fileExportsReportActualCpuGlesAndAutoFallbackBackend() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val root = File(instrumentation.targetContext.cacheDir, "export-backend-${java.util.UUID.randomUUID()}").apply { mkdirs() }
        val input = File(root, "source.arw")
        instrumentation.context.assets.open("sample.RAW").use { from -> input.outputStream().use { from.copyTo(it) } }
        try {
            for (mode in listOf(NativeProcessor.CPU, NativeProcessor.FORCE, NativeProcessor.AUTO)) {
                NativeProcessor(mode).use { processor ->
                    val backend: Any = processor.export(input, null, EditSettings(customWb = true), File(root, "$mode.png"), ExportFormat.PNG, 300)
                    assertEquals("File export must report its actual backend", if (mode == NativeProcessor.CPU) 0 else 2, backend)
                }
            }
            val look = File(root, "cpu-only.rlook").apply { writeBytes(syntheticRlook()) }
            NativeProcessor(NativeProcessor.AUTO).use { processor ->
                val backend: Any = processor.export(input, look, EditSettings(customWb = true), File(root, "fallback.png"), ExportFormat.PNG, 300)
                assertEquals("AUTO file export must report actual CPU fallback", 0, backend)
            }
        } finally { root.deleteRecursively() }
    }
}
