package com.rawlab.android.engine

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.editor.render.HDRBitmapAdapter
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.HDRSettings
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.util.UUID
import kotlin.math.abs

class HDRNativeInstrumentedTest {
    private fun withFixture(name: String, action: (File, File) -> Unit) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        assumeTrue("Supply -PrawlabTestHDRJPEG/HEIC", instrumentation.context.assets.list("")!!.contains(name))
        val root = File(instrumentation.targetContext.cacheDir, "hdr-native-${UUID.randomUUID()}").apply { mkdirs() }
        try {
            // 应用的 WorkingCopy 使用不透明文件名，不能依赖扩展名选择 HDR 解码器。
            val source = File(root, "working-copy.RAW")
            instrumentation.context.assets.open(name).use { input -> source.outputStream().use { input.copyTo(it) } }
            action(source, root)
        } finally { root.deleteRecursively() }
    }

    @Test fun jpegPreviewIsBoundedAndFingerprintIsEnforced() = checkPreview("hdr-sample.jpg")
    @Test fun heicPreviewIsOrientedAndBounded() = checkPreview("hdr-sample.heic")

    private fun checkPreview(name: String) = withFixture(name) { file, _ ->
        val info = requireNotNull(NativeHDRBridge.probe(file))
        assertEquals(32, info.fingerprint.size)
        NativeHDRBridge.decode(file, info, 256).use { pair ->
            assertTrue(maxOf(pair.width, pair.height) <= 256)
            val dimensions = NativeHDRBridge.geometrySize(info, GeometrySettings())
            assertEquals(dimensions[0], pair.outputNativeWidth)
            assertEquals(dimensions[1], pair.outputNativeHeight)
            assertTrue(pair.hdrPlane().all(Float::isFinite))
            assertTrue(pair.hdrPlane().zip(pair.sdrPlane()).any { abs(it.first - it.second) > .01f })
            val frame = pair.snapshot()
            val bitmap = requireNotNull(HDRBitmapAdapter.bitmap(frame, HDRDisplayParameters(4f)))
            assertEquals(Bitmap.Config.RGBA_F16, bitmap.config)
            assertEquals(android.graphics.ColorSpace.Named.LINEAR_EXTENDED_SRGB.ordinal, bitmap.colorSpace!!.id)
            bitmap.recycle()
        }
        val changed = info.copy(fingerprint = info.fingerprint.copyOf().apply { this[0] = (this[0].toInt() xor 1).toByte() })
        assertThrows(IllegalArgumentException::class.java) { NativeHDRBridge.decode(file, changed, 64).close() }
    }

    @Test fun sourceCacheSharesBudgetAndProtectsActiveLeases() = withFixture("hdr-sample.jpg") { file, _ ->
        HDRSourceCache.clear()
        val info = requireNotNull(NativeHDRBridge.probe(file))
        val first = HDRSourceCache.acquire(file, info, 256)
        val second = HDRSourceCache.acquire(file, info, 128)
        try {
            assertSame(first.image, second.image)
            assertTrue(HDRSourceCache.cachedBytes() in 1..(128L * 1024 * 1024))
            HDRSourceCache.clear()
            assertEquals(0L, HDRSourceCache.cachedBytes())
            first.close()
            assertTrue(second.image.hdrPlane().isNotEmpty())
        } finally { first.close(); second.close(); HDRSourceCache.clear() }
    }

    @Test fun hdrToneUnitsProxyProtectionAndFinalExports() = withFixture("hdr-sample.jpg") { file, root ->
        val info = requireNotNull(NativeHDRBridge.probe(file))
        NativeProcessor(NativeProcessor.CPU).use { processor ->
            NativeHDRBridge.decode(file, info, 128).use { source ->
                processor.renderHDR(source, HDRSettings(), 128).use { neutral ->
                    processor.renderHDR(source, HDRSettings(contrast = 50f, highlights = -40f, shadows = 25f, saturation = 35f), 128).use { edited ->
                        assertTrue(neutral.hdrPlane().zip(edited.hdrPlane()).any { abs(it.first - it.second) > .02f })
                    }
                    assertThrows(java.io.IOException::class.java) {
                        NativeHDRBridge.exportJpeg(neutral, file, File(root, "proxy.jpg"))
                    }
                    assertThrows(java.io.IOException::class.java) {
                        NativeHDRBridge.exportSdr(neutral, file, File(root, "proxy.png"), ExportFormat.PNG.nativeValue)
                    }
                }
            }
            NativeHDRBridge.decode(file, info, 0).use { source ->
                processor.renderHDR(source, HDRSettings(exposure = .5f), 128).use { result ->
                    assertTrue(maxOf(result.width, result.height) <= 128)
                    val jpeg = File(root, "result-hdr.jpg")
                    NativeHDRBridge.exportJpeg(result, file, jpeg)
                    val roundtrip = requireNotNull(NativeHDRBridge.probe(jpeg))
                    assertEquals(result.width, roundtrip.width)
                    assertEquals(result.height, roundtrip.height)
                    assertTrue(roundtrip.contentHeadroom > 1f)
                    for (format in listOf(ExportFormat.JPEG, ExportFormat.PNG, ExportFormat.DNG)) {
                        val output = File(root, "result.${format.extension}")
                        NativeHDRBridge.exportSdr(result, file, output, format.nativeValue)
                        val bytes = output.readBytes()
                        assertTrue(bytes.size > 100)
                        if (format == ExportFormat.PNG) { assertEquals(16, bytes[24].toInt()); assertEquals(2, bytes[25].toInt()) }
                        if (format == ExportFormat.JPEG) {
                            assertNull(NativeHDRBridge.probe(output))
                            val bitmap = requireNotNull(BitmapFactory.decodeFile(output.path))
                            assertEquals(result.width, bitmap.width); assertEquals(result.height, bitmap.height); bitmap.recycle()
                        }
                    }
                }
            }
        }
    }

    @Test fun hdrSourceInSdrModeUsesLegacyEditsMeteringAndLutPreview() = withFixture("hdr-sample.jpg") { file, _ ->
        NativeProcessor(NativeProcessor.CPU).use { processor ->
            val baseline = processor.preview(file, null, EditSettings(), 256, false, PhotoInputKind.RASTER)
            val edited = processor.preview(file, null, EditSettings(exposure = 1f, contrast = .4f), 256, false, PhotoInputKind.RASTER)
            assertTrue(maxOf(edited.width, edited.height) <= 256)
            assertFalse(baseline.pixels.contentEquals(edited.pixels))
            assertTrue(processor.autoExposure(file, EditSettings(), PhotoInputKind.RASTER).isFinite())
            val wizard = processor.previewCompatibility(file, PhotoInputKind.RASTER, null, null)
            assertTrue(maxOf(wizard.width, wizard.height) <= 512)
            assertTrue(wizard.pixels.isNotEmpty())
        }
    }
}
