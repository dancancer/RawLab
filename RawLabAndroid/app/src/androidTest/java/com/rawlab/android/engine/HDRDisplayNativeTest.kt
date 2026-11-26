package com.rawlab.android.engine

import android.graphics.Bitmap
import com.rawlab.android.editor.render.HDRBitmapAdapter
import com.rawlab.android.editor.render.HDRPreviewFrame
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test
import java.nio.ShortBuffer

/** HDR 统计与显示映射经 JNI 调用共享核心；这里锚定绑定、标志位与按行段映射的可见结果。 */
class HDRDisplayNativeTest {
    private fun frame(width: Int, height: Int, hdr: Float, sdr: Float, contentHeadroom: Float) = HDRPreviewFrame(
        width, height, FloatArray(width * height * 3) { hdr }, FloatArray(width * height * 3) { sdr },
        contentHeadroom, contentHeadroom, statistics = HDRStatistics(IntArray(256), 0, contentHeadroom, width * height),
    )

    private fun halves(bitmap: Bitmap): ShortArray {
        assertEquals(Bitmap.Config.RGBA_F16, bitmap.config)
        val values = ShortArray(bitmap.width * bitmap.height * 4)
        bitmap.copyPixelsToBuffer(ShortBuffer.wrap(values))
        bitmap.recycle()
        return values
    }

    private fun assertEveryPixel(values: ShortArray, r: Int, g: Int, b: Int) {
        for (offset in values.indices step 4) {
            assertEquals(r, values[offset].toInt() and 0xffff)
            assertEquals(g, values[offset + 1].toInt() and 0xffff)
            assertEquals(b, values[offset + 2].toInt() and 0xffff)
            assertEquals(0x3c00, values[offset + 3].toInt() and 0xffff)
        }
    }

    @Test
    fun statisticsComeFromTheSharedCore() {
        val stats = HDRStatistics.analyze(floatArrayOf(0f, 0f, 0f, 1f, 1f, 1f, 2f, 2f, 2f, 4f, 4f, 4f), 4, 1, 12)
        assertEquals(2, stats.aboveWhite)
        assertEquals(4f, stats.headroom)
        assertEquals(4, stats.pixels)
        assertEquals(listOf(1, 1, 1), listOf(stats.bins[0], stats.bins[144], stats.bins[160]))
        assertEquals(4, stats.bins.sum())
        assertThrows(IllegalArgumentException::class.java) { HDRStatistics.analyze(floatArrayOf(Float.NaN, 0f, 0f), 1, 1, 3) }
        assertThrows(IllegalArgumentException::class.java) { HDRStatistics.analyze(FloatArray(3), 2, 1, 6) }
    }

    @Test
    fun bitmapMapsEveryRowBandThroughTheSharedCore() {
        // 40 行跨越多个行段，SDR 模式与肩部映射都覆盖全部像素。
        val hdr = frame(3, 40, 4f, .5f, 4f)
        assertEveryPixel(halves(requireNotNull(HDRBitmapAdapter.bitmap(hdr, HDRDisplayParameters(8f, HDRPreviewMode.SDR)))),
            0x3800, 0x3800, 0x3800)
        assertEveryPixel(halves(requireNotNull(HDRBitmapAdapter.bitmap(hdr, HDRDisplayParameters(2f)))), 0x4000, 0x4000, 0x4000)
        assertEveryPixel(halves(requireNotNull(HDRBitmapAdapter.bitmap(hdr, HDRDisplayParameters(2f, falseColor = true)))),
            0x3c00, 0x0000, 0x359a)
        var checks = 0
        assertThrows(IllegalStateException::class.java) {
            HDRBitmapAdapter.bitmap(hdr, HDRDisplayParameters(2f)) { if (++checks == 2) throw IllegalStateException("cancelled") }
        }
    }

    @Test
    fun unrepresentableOrNonFiniteInputKeepsPreviousBehavior() {
        assertNull(HDRBitmapAdapter.bitmap(frame(2, 2, 70000f, .5f, 1f), HDRDisplayParameters(2f)))
        assertThrows(IllegalArgumentException::class.java) {
            HDRBitmapAdapter.bitmap(frame(2, 2, Float.NaN, .5f, 1f), HDRDisplayParameters(2f))
        }
    }
}
