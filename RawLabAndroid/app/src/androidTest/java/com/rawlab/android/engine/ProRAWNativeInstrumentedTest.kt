package com.rawlab.android.engine

import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.withHDRMode
import com.rawlab.android.settings.synchronizeHDR
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class ProRAWNativeInstrumentedTest {
    private fun fixture(action: (File, File) -> Unit) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        assumeTrue("Supply -PrawlabTestProRAW", instrumentation.context.assets.list("")!!.contains("proraw-sample.dng"))
        val root = File(instrumentation.targetContext.cacheDir, "proraw-native-${UUID.randomUUID()}").apply { mkdirs() }
        try {
            val source = File(root, "opaque.RAW")
            instrumentation.context.assets.open("proraw-sample.dng").use { input -> source.outputStream().use(input::copyTo) }
            action(source, root)
        } finally { HDRSourceCache.clear(); root.deleteRecursively() }
    }

    @Test fun explicitSourcePreviewAndStreamedRenditionsRetainNativeGeometry() = fixture { file, root ->
        val before = com.rawlab.android.batch.BatchFrozenSettings.checksum(file)
        val info = requireNotNull(NativeHDRBridge.probeCameraRaw(file))
        assertTrue(info.isProRAW)
        assertFalse(com.rawlab.android.photo.HDRSourceInfo.mayContainGainMap(file))
        NativeProcessor(NativeProcessor.CPU).use { processor ->
            val first = HDRSourceCache.acquire(file, info, 256) { processor.decodeHDRCamera(file, info, 256) }
            val second = HDRSourceCache.acquire(file, info, 128) { error("Cache should reuse immutable source") }
            try {
                assertSame(first.image, second.image)
                assertTrue(maxOf(first.image.width, first.image.height) <= 256)
                assertEquals(info.width, first.image.nativeWidth)
                assertTrue(first.image.hdrPlane().all(Float::isFinite))
                assertTrue(first.image.sdrPlane().all(Float::isFinite))
                val modified = file.lastModified()
                assertTrue(file.setLastModified(modified + 2000))
                try {
                    assertThrows(IllegalArgumentException::class.java) {
                        HDRSourceCache.acquire(file, info, 128).close()
                    }
                } finally { assertTrue(file.setLastModified(modified)) }
            } finally { first.close(); second.close(); HDRSourceCache.clear() }
            val edits = EditSettings().withHDRMode(true, false, cameraRaw = true, proRAW = true)
                .copy(exposure = .5f, geometry = GeometrySettings(quarterTurns = 1, flipHorizontal = true)).synchronizeHDR()
            for (hdr in listOf(true, false)) {
                val output = File(root, "result-$hdr.jpg")
                processor.exportProRAW(file, info, edits, output, hdr, 512, processor.cancellationGeneration())
                assertEquals(hdr, NativeHDRBridge.probe(output) != null)
                if (hdr) assertEquals(2, NativeHDRBridge.probe(output)!!.colorDescription)
                val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
                android.graphics.BitmapFactory.decodeFile(output.path, bounds)
                assertEquals(512, maxOf(bounds.outWidth, bounds.outHeight))
                assertEquals(info.width > info.height, bounds.outHeight > bounds.outWidth)
                output.delete()
            }
            assertEquals(before, com.rawlab.android.batch.BatchFrozenSettings.checksum(file))
            assertEquals(listOf(file), root.listFiles()!!.toList())
        }
    }

    @Test fun cancelledStreamKeepsDestinationAndCanRetry() = fixture { file, root ->
        val info = requireNotNull(NativeHDRBridge.probeCameraRaw(file))
        val edits = EditSettings().withHDRMode(true, false, cameraRaw = true, proRAW = true)
        val output = File(root, "result.jpg").apply { writeText("existing destination") }
        NativeProcessor(NativeProcessor.CPU).use { processor ->
            val executor = Executors.newSingleThreadExecutor()
            try {
                val generation = processor.cancellationGeneration()
                val future = executor.submit<Throwable?> {
                    try { processor.exportProRAW(file, info, edits, output, true, 512, generation); null }
                    catch (error: Throwable) { error }
                }
                Thread.sleep(100)
                processor.cancelPreview()
                val error = future.get(120, TimeUnit.SECONDS)
                assertTrue(error.toString(), error is NativeProcessingException)
                assertEquals(NativeProcessingException.CANCELLED, (error as NativeProcessingException).status)
                assertEquals("existing destination", output.readText())
                assertEquals(setOf(file, output), root.listFiles()!!.toSet())
                processor.exportProRAW(file, info, edits, output, true, 512, processor.cancellationGeneration())
                assertNotNull(NativeHDRBridge.probe(output))
            } finally { executor.shutdownNow() }
        }
    }

    @Test fun forceGpuRejectsProRAWWithoutPublishingOrLeakingScratch() = fixture { file, root ->
        val info = requireNotNull(NativeHDRBridge.probeCameraRaw(file))
        NativeProcessor(NativeProcessor.FORCE).use { processor ->
            val error = assertThrows(HDRProcessingException::class.java) {
                processor.decodeHDRCamera(file, info, 128).close()
            }
            assertEquals(13, error.reason)
            assertEquals(listOf(file), root.listFiles()!!.toList())
        }
    }
}
