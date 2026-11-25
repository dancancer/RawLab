package com.rawlab.android.editor.inspection

import android.graphics.Bitmap
import com.rawlab.android.geometry.GeometrySettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InspectionNativeTest {
    @Test
    fun rgbToHsbAndPatchSamplingMatchCoreContract() {
        val red = InspectionColorMath.fromRgb(255, 0, 0)
        assertEquals(0.0, red.hueDeg, 0.01)
        assertEquals(100.0, red.saturationPct, 0.01)
        assertEquals(100.0, red.brightnessPct, 0.01)
        assertEquals(0.2126, red.luminance, 1e-4)

        val bmp = Bitmap.createBitmap(4, 4, Bitmap.Config.ARGB_8888)
        for (y in 0 until 4) {
            for (x in 0 until 4) {
                val color = if (x < 2) (0xff shl 24) or (100 shl 16) or (100 shl 8) or 100
                else (0xff shl 24) or (200 shl 16) or (100 shl 8) or 50
                bmp.setPixel(x, y, color)
            }
        }
        val corner = InspectionBitmap.sampleBitmap(bmp, 0f, 0f, radiusPx = 0)
        assertNotNull(corner)
        assertEquals(100, corner!!.r)

        val straddle = InspectionBitmap.sampleBitmap(bmp, 1f / 3f, 0.5f, radiusPx = 1)
        assertNotNull(straddle)
        assertEquals(133, straddle!!.r)
    }

    @Test
    fun geometryMapperRoundTripsAndDetectsOutOfCrop() {
        val srcW = 4000
        val srcH = 3000
        val geom = GeometrySettings(0.1f, 0.2f, 0.6f, 0.5f, 1, true, false, 7.5f, 0.35f, -0.25f)
        for ((ox, oy) in listOf(0.5f to 0.5f, 0.35f to 0.6f, 0.68f to 0.42f)) {
            val src = InspectionGeometryMapper.outputNormToSourceNorm(ox, oy, srcW, srcH, geom)
            assertNotNull(src)
            val back = InspectionGeometryMapper.sourceNormToOutputNorm(src!!.first, src.second, srcW, srcH, geom)
            assertNotNull(back)
            assertEquals(ox, back!!.first, 1e-4f)
            assertEquals(oy, back.second, 1e-4f)
        }
        val cropped = GeometrySettings(0.25f, 0.25f, 0.5f, 0.5f)
        assertNull(InspectionGeometryMapper.sourceNormToOutputNorm(0.1f, 0.1f, srcW, srcH, cropped))
        assertNotNull(InspectionGeometryMapper.sourceNormToOutputNorm(0.5f, 0.5f, srcW, srcH, cropped))
    }

    @Test
    fun nativeRenderOverlayAppliesAllModesToBitmap() {
        val src = Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888)
        for (y in 0 until 8) {
            for (x in 0 until 8) {
                src.setPixel(x, y, (0xff shl 24) or (210 shl 16) or (130 shl 8) or 120)
            }
        }
        val dst = Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888)
        assertTrue(InspectionNative.nativeRenderOverlay(src, dst, InspectionOverlayMode.NEUTRAL_GRAY_50.ordinal))
        assertEquals(0xff808080.toInt(), dst.getPixel(0, 0))
    }
}
