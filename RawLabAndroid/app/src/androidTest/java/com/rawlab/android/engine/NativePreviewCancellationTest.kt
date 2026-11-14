package com.rawlab.android.engine

import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.settings.EditSettings
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class NativePreviewCancellationTest {
    @Test fun obsoletePreviewStopsWhileTheNextRequestCanReuseTheProcessor() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val source = File(context.cacheDir, "cancel-preview-${System.nanoTime()}.RAW")
        InstrumentationRegistry.getInstrumentation().context.assets.open("sample.RAW").use { input ->
            source.outputStream().use { input.copyTo(it) }
        }
        val worker = Executors.newSingleThreadExecutor()
        val measurements = mutableListOf<String>()
        try {
            for (mode in listOf(NativeProcessor.CPU, NativeProcessor.AUTO)) {
                NativeProcessor(mode).use { processor ->
                    processor.preview(source, null, EditSettings(), 1600, false)
                    for (edge in listOf(1000, 640, 480)) {
                        val started = SystemClock.elapsedRealtime()
                        repeat(3) { processor.preview(source, null, EditSettings(exposure = it * .05f), edge, true) }
                        measurements += "mode=$mode edge=$edge averageMs=${(SystemClock.elapsedRealtime() - started) / 3.0}"
                    }
                    val previous = processor.cancellationGeneration()
                    processor.cancelPreview()
                    val stale = assertThrows(NativeProcessingException::class.java) {
                        processor.preview(source, null, EditSettings(exposure = .5f), 1600, true,
                            cancellationGeneration = previous)
                    }
                    assertEquals(NativeProcessingException.CANCELLED, stale.status)
                    for (settings in listOf(EditSettings(exposure = 1f), EditSettings(customWb = true, temperature = 7500f))) {
                        val generation = processor.cancellationGeneration()
                        val entered = CountDownLatch(1)
                        val future = worker.submit<NativeFrame> {
                            entered.countDown()
                            processor.preview(source, null, settings, 1600, true,
                                cancellationGeneration = generation)
                        }
                        assertTrue(entered.await(5, TimeUnit.SECONDS))
                        SystemClock.sleep(10)
                        assertFalse("The fixture must still be computing when cancellation is requested", future.isDone)
                        val started = SystemClock.elapsedRealtime()
                        processor.cancelPreview()
                        val signalMs = SystemClock.elapsedRealtime() - started
                        val error = assertThrows(java.util.concurrent.ExecutionException::class.java) {
                            future.get(3, TimeUnit.SECONDS)
                        }
                        val stoppedMs = SystemClock.elapsedRealtime() - started
                        assertEquals(NativeProcessingException.CANCELLED, (error.cause as NativeProcessingException).status)
                        assertTrue("Cancellation must not wait for the render monitor", signalMs < 100)
                        val next = processor.preview(source, null, EditSettings(exposure = .75f), 1000, true,
                            cancellationGeneration = processor.cancellationGeneration())
                        assertEquals(1000, maxOf(next.width, next.height))
                        measurements += "mode=$mode customWb=${settings.customWb} signalMs=$signalMs stoppedMs=$stoppedMs next=${next.width}x${next.height}"
                    }
                }
            }
            File(context.getExternalFilesDir(null), "native-cancellation.txt").writeText(measurements.joinToString("\n"))
        } finally { worker.shutdownNow(); source.delete() }
    }

    @Test fun cancelledExportDeletesPartialOutputAndAllowsSubsequentExport() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.cacheDir, "cancel-export-${System.nanoTime()}").apply { mkdirs() }
        val source = File(root, "source.RAW")
        InstrumentationRegistry.getInstrumentation().context.assets.open("sample.RAW").use { input ->
            source.outputStream().use { input.copyTo(it) }
        }
        val worker = Executors.newSingleThreadExecutor()
        try {
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                // 1. Pre-cancelled generation rejects immediately and deletes empty temp placeholder.
                val placeholder = File.createTempFile("export-", ".jpg", root)
                val staleGeneration = processor.cancellationGeneration()
                processor.cancelPreview()
                val staleError = assertThrows(NativeProcessingException::class.java) {
                    processor.export(source, null, EditSettings(), placeholder, ExportFormat.JPEG, 300,
                        cancellationGeneration = staleGeneration)
                }
                assertEquals(NativeProcessingException.CANCELLED, staleError.status)
                assertFalse(placeholder.exists())

                // 2. Pre-cancelled generation rejects immediately without creating output.
                val cancelledGenerationOutput = File(root, "generation-cancelled.jpg")
                val staleBeforeSecondExport = processor.cancellationGeneration()
                processor.cancelPreview()
                val generationError = assertThrows(NativeProcessingException::class.java) {
                    processor.export(source, null, EditSettings(), cancelledGenerationOutput, ExportFormat.JPEG, 300,
                        cancellationGeneration = staleBeforeSecondExport)
                }
                assertEquals(NativeProcessingException.CANCELLED, generationError.status)
                assertFalse(cancelledGenerationOutput.exists())

                // 3. Concurrent cancellation via generation bump stops export, cleans staging, and keeps processor reusable.
                val inFlightOutput = File(root, "inflight.png")
                val exportGeneration = processor.cancellationGeneration()
                val entered = CountDownLatch(1)
                val future = worker.submit<Int> {
                    entered.countDown()
                    processor.export(source, null, EditSettings(exposure = .5f), inFlightOutput, ExportFormat.PNG,
                        cancellationGeneration = exportGeneration)
                }
                assertTrue(entered.await(5, TimeUnit.SECONDS))
                SystemClock.sleep(10)
                val started = SystemClock.elapsedRealtime()
                processor.cancelPreview()
                val signalMs = SystemClock.elapsedRealtime() - started
                val execError = assertThrows(java.util.concurrent.ExecutionException::class.java) {
                    future.get(30, TimeUnit.SECONDS)
                }
                assertEquals(NativeProcessingException.CANCELLED, (execError.cause as NativeProcessingException).status)
                assertTrue("Export cancellation must not block on render monitor", signalMs < 100)
                assertFalse("Cancelled export must not leave partial output", inFlightOutput.exists())
                assertEquals("No staging files may remain", listOf(source), root.listFiles()!!.toList())

                // 4. Subsequent uncancelled export on the same processor succeeds.
                val finalOutput = File(root, "completed.jpg")
                assertEquals(0, processor.export(source, null, EditSettings(), finalOutput, ExportFormat.JPEG, 300,
                    cancellationGeneration = processor.cancellationGeneration()))
                assertTrue(finalOutput.isFile && finalOutput.length() > 0L)
            }
        } finally { worker.shutdownNow(); root.deleteRecursively() }
    }
}
