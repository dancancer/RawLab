package com.rawlab.android.engine.memory

import android.graphics.BitmapFactory
import android.os.Bundle
import android.os.Debug
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.settings.DenoisePreset
import com.rawlab.android.settings.DenoiseSettings
import com.rawlab.android.settings.EditSettings

@RunWith(AndroidJUnit4::class)
class NativeMemoryTest {
    @Test fun nativeDenoiseExportsFitLimitedMemory() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val args = InstrumentationRegistry.getArguments()
        val label = args.getString("memoryLabel") ?: "current"
        val warm = args.getString("memoryWarmDenoise") == "true"
        val exposureMode = args.getString("memoryExposureMode")?.toInt() ?: EditSettings().exposureMode
        val directory = File(instrumentation.targetContext.filesDir, "memory-probe").apply { mkdirs() }
        val input = File(directory, "input.RW2")
        instrumentation.context.assets.open("sample.RAW").use { from -> input.outputStream().use { from.copyTo(it) } }
        val phase = AtomicReference("setup")
        val running = AtomicBoolean(true)
        val peakHeap = AtomicLong()
        val started = SystemClock.elapsedRealtime()
        fun mark(value: String) {
            phase.set(value)
            instrumentation.sendStatus(2, Bundle().apply {
                putString("stream", "MEMORY $label phase=$value ms=${SystemClock.elapsedRealtime() - started}\n")
            })
        }
        val sampler = thread(name = "native-memory-sampler", isDaemon = true) {
            File(directory, "$label.csv").bufferedWriter().use { writer ->
                writer.write("elapsed_ms,phase,native_heap_bytes,rss_kib,hwm_kib\n")
                while (running.get()) {
                    val heap = Debug.getNativeHeapAllocatedSize()
                    peakHeap.accumulateAndGet(heap, ::maxOf)
                    val status = File("/proc/self/status").readLines()
                    fun kib(key: String) = status.firstOrNull { it.startsWith("$key:") }
                        ?.substringAfter(':')?.trim()?.substringBefore(' ')?.toLongOrNull() ?: 0L
                    writer.write("${SystemClock.elapsedRealtime() - started},${phase.get()},$heap,${kib("VmRSS")},${kib("VmHWM")}\n")
                    writer.flush()
                    Thread.sleep(100)
                }
            }
        }
        val png = File(directory, "$label.png")
        val jpeg = File(directory, "$label.jpg")
        try {
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                val settings = EditSettings(denoise = DenoiseSettings().withPreset(DenoisePreset.CLEAN),
                    exposureMode = exposureMode)
                mark("preview-off")
                processor.preview(input, null, EditSettings(exposureMode = exposureMode), 1600, false)
                if (warm) {
                    mark("preview-denoise")
                    processor.preview(input, null, settings, 1600, false)
                }
                mark("native-png")
                processor.export(input, null, settings, png, ExportFormat.PNG)
                mark("preview-between-formats")
                processor.preview(input, null, settings.copy(exposure = .35f), 640, true)
                mark("native-jpeg")
                processor.export(input, null, settings.copy(exposure = .35f), jpeg, ExportFormat.JPEG)
                if (args.getString("memoryRecomputeDenoise") == "true") {
                    mark("native-recompute")
                    val recomputed = File(directory, "$label-recomputed.png")
                    processor.export(input, null, settings.copy(denoise = settings.denoise.copy(luma = 11f)), recomputed, ExportFormat.PNG)
                    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    BitmapFactory.decodeFile(recomputed.path, bounds)
                    assertTrue(maxOf(bounds.outWidth, bounds.outHeight) > 1600)
                }
            }
            val header = ByteArray(26)
            png.inputStream().use { assertEquals(header.size, it.read(header)) }
            assertEquals(16, header[24].toInt())
            val width = ByteBuffer.wrap(header, 16, 4).int
            val height = ByteBuffer.wrap(header, 20, 4).int
            assertTrue(maxOf(width, height) > 1600)
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(jpeg.path, bounds)
            assertEquals(width, bounds.outWidth)
            assertEquals(height, bounds.outHeight)
            args.getString("memoryBudgetBytes")?.toLong()?.let { budget ->
                assertTrue("Native heap ${peakHeap.get()} exceeds $budget bytes", peakHeap.get() <= budget)
            }
            mark("complete-${width}x$height")
        } finally {
            running.set(false)
            sampler.join()
            input.delete()
        }
    }
}
