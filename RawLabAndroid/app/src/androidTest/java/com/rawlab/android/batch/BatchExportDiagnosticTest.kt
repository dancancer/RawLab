package com.rawlab.android.batch

import android.graphics.BitmapFactory
import android.os.Bundle
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.Timeout
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import java.util.UUID
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.settings.DenoiseSettings
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.SettingsCodec

/** DSC00316.ARW native control; the production batch test keeps its own timeout unchanged. */
class BatchExportDiagnosticTest {
    @get:Rule val budget = Timeout(240, TimeUnit.SECONDS)

    @Test fun originalSizeJpegWithinUnchangedBudget() {
        val testStarted = SystemClock.elapsedRealtime()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val arguments = InstrumentationRegistry.getArguments()
        assumeTrue("Requires explicit diagnostic opt-in", arguments.getString("batchDiagnosticEnabled") == "true")
        val modeName = arguments.getString("batchDiagnosticGpu", "cpu")!!
        val mode = when (modeName) {
            "cpu" -> NativeProcessor.CPU
            "auto" -> NativeProcessor.AUTO
            "force" -> NativeProcessor.FORCE
            else -> error("Unknown GPU mode: $modeName")
        }
        val denoise = arguments.getString("batchDiagnosticDenoise", "true")!!.toBooleanStrict()
        val runId = UUID.randomUUID().toString()
        val artifacts = File(context.getExternalFilesDir(null), "batch-diagnostic/$modeName-$denoise-$runId").apply { mkdirs() }
        val root = File(context.cacheDir, "batch-diagnostic-${System.nanoTime()}").apply { mkdirs() }
        val input = File(root, "target.dng")
        instrumentation.context.assets.open("sample.RAW").use { from -> input.outputStream().use { from.copyTo(it) } }
        val before = digest(input)
        assertEquals("93a37abeaa3cd199773d25978a1045e580e26dbf884755f5d69c530e0bed5014", before)
        val result = JSONObject().put("gpuMode", modeName).put("denoise", denoise)
            .put("sourceSha256", before).put("budgetMs", 240_000).put("budgetScope", "whole-test")
            .put("runId", runId).put("longEdge", JSONObject.NULL).put("exportBackend", JSONObject.NULL).put("passed", false)
        val report = File(artifacts, "result.json")
        fun record(stage: String) {
            result.put("stage", stage)
            report.writeText(result.toString(2))
            instrumentation.sendStatus(2, Bundle().apply { putString("stream", "BATCH_DIAGNOSTIC ${result}\n") })
        }
        try {
            PhotoStorage(context).use { storage ->
                val started = SystemClock.elapsedRealtime()
                record("preview-start")
                val frame = NativeProcessor(mode, storage.lensDatabase()).use {
                    it.preview(input, null, EditSettings(), 128, false)
                }
                result.put("previewMs", SystemClock.elapsedRealtime() - started).put("previewBackend", frame.backend)
                when (mode) {
                    NativeProcessor.CPU -> assertEquals(0, frame.backend)
                    NativeProcessor.FORCE -> assertEquals(2, frame.backend)
                    else -> assertTrue(frame.backend in listOf(0, 2))
                }
                // Batch export creates a fresh processor, separate from its target preview.
                NativeProcessor(mode, storage.lensDatabase()).use { processor ->
                    val settings = EditSettings(exposure = .5f, contrast = .2f,
                        temperature = frame.temperature, tint = frame.tint,
                        denoise = DenoiseSettings(denoise, 10f, 72f, 100f))
                    result.put("settings", SettingsCodec.encode(settings))
                    val output = File(artifacts, "result.jpg")
                    val exportStarted = SystemClock.elapsedRealtime()
                    record("export-start")
                    processor.export(input, null, settings, output, ExportFormat.JPEG)
                    result.put("exportMs", SystemClock.elapsedRealtime() - exportStarted)
                    val size = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    BitmapFactory.decodeFile(output.path, size)
                    result.put("width", size.outWidth).put("height", size.outHeight).put("bytes", output.length())
                    record("export-done")
                    assertEquals(7008, maxOf(size.outWidth, size.outHeight))
                    assertEquals(4672, minOf(size.outWidth, size.outHeight))
                    assertTrue(output.length() > 1024)
                    assertTrue(result.getLong("exportMs") < 240_000)
                    assertEquals(before, digest(input))
                }
            }
            result.put("totalMs", SystemClock.elapsedRealtime() - testStarted)
            assertTrue(result.getLong("totalMs") < 240_000)
            result.put("passed", true)
            record("done")
        } catch (error: Throwable) {
            result.put("error", error.toString())
            record("failed")
            throw error
        } finally { root.deleteRecursively() }
    }

    private fun digest(file: File): String {
        val hash = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                hash.update(buffer, 0, count)
            }
        }
        return hash.digest().joinToString("") { "%02x".format(it) }
    }
}
