package com.rawlab.android.engine.memory

import android.graphics.BitmapFactory
import android.os.Bundle
import android.os.Debug
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.settings.DenoiseSettings
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.HslSettings
import com.rawlab.android.settings.PhotoEffectsSettings

@RunWith(AndroidJUnit4::class)
class NativeDngMemoryTest {
    @Test fun originalSizeExportsAfterViewportMatchIndependentFinal() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val args = InstrumentationRegistry.getArguments()
        assumeTrue("Run explicitly with the Sony fixture and a unique label", args.containsKey("dngMemoryLabel"))
        val label = args.getString("dngMemoryLabel") ?: "sony-native"
        require(label.matches(Regex("[a-zA-Z0-9_-]+")))
        val root = File(instrumentation.targetContext.filesDir, "sony-dng-memory/$label").apply { mkdirs() }
        val input = File(root, "source.ARW")
        instrumentation.context.assets.open("sample.RAW").use { from -> input.outputStream().use { from.copyTo(it) } }
        val sourceHash = digest(input)
        assertEquals("dc280884db9e0d2e1e7389dca1370958ea8fde749cef8169702f64237d98763f", sourceHash)
        val mode = when (args.getString("dngMemoryGpu")) {
            "force" -> NativeProcessor.FORCE
            "auto" -> NativeProcessor.AUTO
            else -> NativeProcessor.CPU
        }
        val formats = (args.getString("dngMemoryFormats") ?: "dng,png,jpg").split(',').map {
            when (it) { "dng" -> ExportFormat.DNG; "png" -> ExportFormat.PNG; "jpg" -> ExportFormat.JPEG; else -> error("Invalid format") }
        }
        val edge = args.getString("dngMemoryExportEdge")?.toInt()?.takeIf { it > 0 }
        val previewEdge = args.getString("dngMemoryPreviewEdge")?.toInt() ?: 128
        val reference = args.getString("dngMemoryReference") == "true"
        val settings = settings(args.getString("dngMemoryProfile") ?: "all")
        require(mode != NativeProcessor.FORCE || !settings.denoise.enabled) {
            "C5 denoise is CPU-only; use auto or cpu for this diagnostic"
        }
        val phase = AtomicReference("setup")
        val running = AtomicBoolean(true)
        val peak = AtomicLong()
        val peakRss = AtomicLong()
        val started = SystemClock.uptimeMillis()
        fun kib(lines: List<String>, key: String) = lines.firstOrNull { it.startsWith("$key:") }
            ?.substringAfter(':')?.trim()?.substringBefore(' ')?.toLongOrNull() ?: 0L
        fun mark(value: String) {
            phase.set(value)
            instrumentation.sendStatus(2, Bundle().apply {
                putString("stream", "SONY_MEMORY $label phase=$value uptime=${SystemClock.uptimeMillis()} heap=${Debug.getNativeHeapAllocatedSize()}\n")
            })
        }
        val sampler = thread(name = "sony-dng-memory-sampler", isDaemon = true) {
            File(root, "memory.csv").bufferedWriter().use { writer ->
                writer.write("elapsed_ms,phase,native_heap_bytes,rss_kib,hwm_kib,swap_kib,available_kib,swap_free_kib\n")
                while (running.get()) {
                    val heap = Debug.getNativeHeapAllocatedSize()
                    peak.accumulateAndGet(heap, ::maxOf)
                    val status = File("/proc/self/status").readLines()
                    val memory = File("/proc/meminfo").readLines()
                    peakRss.accumulateAndGet(kib(status, "VmHWM"), ::maxOf)
                    writer.write("${SystemClock.uptimeMillis() - started},${phase.get()},$heap,${kib(status, "VmRSS")},${kib(status, "VmHWM")},${kib(status, "VmSwap")},${kib(memory, "MemAvailable")},${kib(memory, "SwapFree")}\n")
                    writer.flush()
                    Thread.sleep(100)
                }
            }
        }
        try {
            PhotoStorage(instrumentation.targetContext).use { storage ->
                val look = if (settings.film == "neutral") null else storage.filmPath(settings.film)
                NativeProcessor(mode).use { processor ->
                    if (previewEdge > 0) {
                        mark("viewport-$previewEdge")
                        val frame = processor.preview(input, look, settings, previewEdge, false)
                        assertEquals(previewEdge, maxOf(frame.width, frame.height))
                        if (mode == NativeProcessor.FORCE) assertEquals(2, frame.backend)
                    }
                    for (format in formats) {
                        mark("export-${format.name}")
                        val output = File(root, "history${format.suffix}")
                        processor.export(input, look, settings, output, format, edge)
                        checkOutput(output, format, edge)
                        mark("done-${format.name}")
                    }
                }
                if (reference) {
                    NativeProcessor(mode).use { fresh ->
                        for (format in formats) {
                            mark("reference-${format.name}")
                            val output = File(root, "fresh${format.suffix}")
                            fresh.export(input, look, settings, output, format, edge)
                            checkOutput(output, format, edge)
                            assertEquals("Viewport history must not change exact ${format.name}",
                                digest(output), digest(File(root, "history${format.suffix}")))
                        }
                    }
                }
            }
            assertEquals("Original RAW remains unchanged", sourceHash, digest(input))
            args.getString("dngMemoryBudgetBytes")?.toLong()?.let {
                assertTrue("Native heap sample ${peak.get()} exceeds $it bytes", peak.get() <= it)
            }
            // VmHWM 由内核保留，避免把采样间隔内的短暂 RSS 峰值漏掉。
            val rssPeak = maxOf(peakRss.get(), kib(File("/proc/self/status").readLines(), "VmHWM")) * 1024
            args.getString("dngMemoryRssBudgetBytes")?.toLong()?.let {
                assertTrue("RSS high-water mark $rssPeak exceeds $it bytes", rssPeak <= it)
            }
            mark("complete-peak-${peak.get()}-rss-$rssPeak")
        } finally {
            running.set(false)
            sampler.join()
            input.delete()
        }
    }

    private fun settings(profile: String): EditSettings {
        val all = EditSettings(film = "velvia", strength = .65f, exposure = .35f,
            highlights = -.2f, shadows = .15f, contrast = .1f, toneCurve = .15f, saturation = -.1f,
            customWb = true, temperature = 5800f, tint = 8f, sharpening = .2f, exposureMode = 1,
            denoise = DenoiseSettings(true, 10f, 72f, 100f), displayChromaDenoise = 2,
            hsl = HslSettings().withValue(0, 2, 12f).withValue(1, 4, -15f).withValue(2, 6, 8f),
            effects = PhotoEffectsSettings(-30f, 42f, -15f, 65f, 35f, 20f, 38f, 65f))
        return when (profile) {
            "all" -> all
            "no-chroma" -> all.copy(displayChromaDenoise = 0)
            "no-denoise" -> all.copy(denoise = all.denoise.copy(enabled = false))
            "denoise-only" -> EditSettings(denoise = all.denoise)
            "neutral" -> EditSettings()
            else -> error("Invalid profile")
        }
    }

    private fun digest(file: File): String {
        val hash = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val size = input.read(buffer)
                if (size < 0) break
                hash.update(buffer, 0, size)
            }
        }
        return hash.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
    }

    private fun checkOutput(file: File, format: ExportFormat, edge: Int?) {
        assertTrue("${format.name} exists", file.isFile && file.length() > 1024)
        val width: Int
        val height: Int
        if (format == ExportFormat.DNG) {
            RandomAccessFile(file, "r").use { input ->
                val header = ByteArray(8).also { input.readFully(it) }
                assertEquals('I'.code, header[0].toInt())
                assertEquals('I'.code, header[1].toInt())
                val buffer = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
                assertEquals(42, buffer.getShort(2).toInt())
                input.seek(buffer.getInt(4).toLong() and 0xffffffffL)
                val count = input.readUnsignedByte() or (input.readUnsignedByte() shl 8)
                val fields = mutableMapOf<Int, ByteArray>()
                repeat(count) {
                    val entry = ByteArray(12).also { input.readFully(it) }
                    fields[ByteBuffer.wrap(entry).order(ByteOrder.LITTLE_ENDIAN).short.toInt() and 65535] = entry
                }
                fun values(tag: Int): List<Int> {
                    val entry = ByteBuffer.wrap(requireNotNull(fields[tag])).order(ByteOrder.LITTLE_ENDIAN)
                    val type = entry.getShort(2).toInt()
                    val size = entry.getInt(4)
                    require(size in 1..3 && type in listOf(3, 4))
                    val bytes = ByteArray(size * if (type == 3) 2 else 4)
                    if (bytes.size <= 4) System.arraycopy(entry.array(), 8, bytes, 0, bytes.size)
                    else { input.seek(entry.getInt(8).toLong() and 0xffffffffL); input.readFully(bytes) }
                    val data = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
                    return List(size) { if (type == 3) data.short.toInt() and 65535 else data.int }
                }
                width = values(256).single(); height = values(257).single()
                assertTrue("DNG is float32 RGB", values(258).all { it == 32 } && values(339).all { it == 3 })
                assertEquals(3, values(277).single())
                assertTrue(file.length() > width.toLong() * height * 12)
            }
        } else {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.path, bounds)
            width = bounds.outWidth; height = bounds.outHeight
            if (format == ExportFormat.PNG) {
                val header = ByteArray(26)
                file.inputStream().use { it.read(header) }
                assertEquals(16, header[24].toInt())
            }
        }
        if (edge == null) { assertEquals(4672, width); assertEquals(7008, height) }
        else assertEquals(edge, maxOf(width, height))
    }
}
