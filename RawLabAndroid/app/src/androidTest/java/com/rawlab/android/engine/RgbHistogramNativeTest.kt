package com.rawlab.android.engine

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.EditSettings
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class RgbHistogramNativeTest {
    private fun assertCounts(frame: NativeFrame) {
        val histogram = requireNotNull(frame.histogram)
        assertEquals(frame.width, histogram.width)
        assertEquals(frame.height, histogram.height)
        val expected = LongArray(768)
        for (pixel in 0 until frame.width * frame.height) for (channel in 0..2) {
            expected[channel * 256 + (frame.pixels[pixel * 4 + channel].toInt() and 255)]++
        }
        for (channel in 0..2) {
            assertEquals(frame.width.toLong() * frame.height, (0..255).sumOf { histogram.count(channel, it) })
            for (bin in 0..255) assertEquals(expected[channel * 256 + bin], histogram.count(channel, bin))
        }
    }

    @Test fun exactBinsBelongToJniPixelsAndMatchFinalRaster() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.cacheDir, "rgb-native-${UUID.randomUUID()}").apply { mkdirs() }
        val source = File(root, "fixture.png")
        val pixels = intArrayOf(0xff000000.toInt(), 0xffffffff.toInt(), 0xffff0000.toInt(),
            0xffff0000.toInt(), 0xff00ff00.toInt(), 0xff4080c0.toInt())
        val bitmap = Bitmap.createBitmap(pixels, 3, 2, Bitmap.Config.ARGB_8888)
        source.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        bitmap.recycle()
        try {
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                val frame = processor.preview(source, null, EditSettings(), 1600, false, PhotoInputKind.RASTER)
                assertCounts(frame)
                val expected = IntArray(768).apply {
                    this[0] = 2; this[64] = 1; this[255] = 3
                    this[256] = 3; this[384] = 1; this[511] = 2
                    this[512] = 4; this[704] = 1; this[767] = 1
                }
                for (channel in 0..2) for (bin in 0..255)
                    assertEquals(expected[channel * 256 + bin].toLong(), frame.histogram!!.count(channel, bin))
                val output = File(root, "final.png")
                processor.export(source, null, EditSettings(), output, ExportFormat.PNG, null, PhotoInputKind.RASTER)
                val final = requireNotNull(BitmapFactory.decodeFile(output.path))
                try {
                    val actual = IntArray(6)
                    final.getPixels(actual, 0, 3, 0, 0, 3, 2)
                    assertArrayEquals("same settings preserve preview/FINAL RGB anchors", pixels, actual)
                } finally { final.recycle() }
                processor.setGpuMode(NativeProcessor.AUTO)
                val automatic = processor.preview(source, null, EditSettings(), 1600, false, PhotoInputKind.RASTER)
                assertCounts(automatic)
                assertArrayEquals(frame.pixels, automatic.pixels)
                assertNull(processor.preview(source, null, EditSettings(exposure = 1f), 1600, true, PhotoInputKind.RASTER).histogram)
                val settled = processor.preview(source, null, EditSettings(exposure = 1f), 1600, false, PhotoInputKind.RASTER)
                assertCounts(settled)
                assertFalse(frame.pixels.contentEquals(settled.pixels))
                // 后续请求不能改写前一份 JVM 自有统计。
                assertEquals(3L, frame.histogram!!.count(0, 255))
            }
        } finally { root.deleteRecursively() }
    }

    @Test fun rawResizeInteractiveAndSourceSwitchKeepFrameStatistics() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val root = File(instrumentation.targetContext.cacheDir, "rgb-raw-${UUID.randomUUID()}").apply { mkdirs() }
        val input = File(root, "source.RAW")
        instrumentation.context.assets.open("sample.RAW").use { source -> input.outputStream().use { source.copyTo(it) } }
        try {
            NativeProcessor(NativeProcessor.CPU).use { processor ->
                val first = processor.preview(input, null, EditSettings(), 256, false)
                assertCounts(first)
                assertNull(processor.preview(input, null, EditSettings(exposure = .5f), 128, true).histogram)
                val resized = processor.preview(input, null, EditSettings(exposure = .5f), 128, false)
                assertCounts(resized)
                assertTrue(maxOf(resized.width, resized.height) <= 128)
                val second = File(root, "second.png")
                Bitmap.createBitmap(2, 1, Bitmap.Config.ARGB_8888).also { bitmap ->
                    bitmap.eraseColor(0xff2288cc.toInt())
                    second.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                    bitmap.recycle()
                }
                assertCounts(processor.preview(second, null, EditSettings(), 1600, false, PhotoInputKind.RASTER))
                val restored = processor.preview(input, null, EditSettings(), 256, false)
                assertCounts(restored)
                assertArrayEquals(first.pixels, restored.pixels)
            }
        } finally { root.deleteRecursively() }
    }
}
