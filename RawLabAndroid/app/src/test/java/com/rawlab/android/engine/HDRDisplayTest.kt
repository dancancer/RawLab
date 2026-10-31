package com.rawlab.android.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HDRDisplayTest {
    @Test
    fun sdrModeUsesTheSdrRenditionAndHdrModeMapsContentToScreenHeadroom() {
        val hdr = floatArrayOf(4f, 4f, 4f)
        val sdr = floatArrayOf(.5f, .5f, .5f)

        val sdrValue = HDRDisplayMath.pixel(hdr, sdr, 4f, HDRDisplayParameters(8f, HDRPreviewMode.SDR))
        val hdrValue = HDRDisplayMath.pixel(hdr, sdr, 4f, HDRDisplayParameters(2f))

        assertEquals(.5f, sdrValue[0], 1e-5f)
        assertEquals(2f, hdrValue[0], 1e-5f)
    }

    @Test
    fun halfPackingCarriesRoundedMantissaAndUsesTiesToEven() {
        val values=floatArrayOf(1.9999f,3.9998f,-3.9998f,1f+1f/2048,1f+3f/2048)
        val bits=HDRDisplayMath.packHalf(values)!!.map {it.toInt() and 0xffff}
        assertEquals(listOf(0x4000,0x4400,0xc400,0x3c00,0x3c02),bits)
    }

    @Test
    fun allFiniteHalfValuesRoundTripWithoutChangingBits() {
        for(bits in 0..65535) {
            if((bits ushr 10) and 31 == 31)continue
            val value=HDRDisplayMath.halfToFloat(bits.toShort())
            assertEquals(bits,HDRDisplayMath.packHalf(floatArrayOf(value))!![0].toInt() and 0xffff)
        }
    }

    @Test
    fun statisticsAndHalfPackingPreserveExtendedValues() {
        val stats = HDRStatistics.analyze(floatArrayOf(0f, 0f, 0f, 1f, 1f, 1f, 2f, 2f, 2f, 4f, 4f, 4f), 4, 1, 12)

        assertEquals(2, stats.aboveWhite)
        assertEquals(4f, stats.headroom, 1e-5f)
        val packed = HDRDisplayMath.packHalf(floatArrayOf(-.25f, 2f, 4f, 1f))
        assertEquals(-.25f, HDRDisplayMath.halfToFloat(packed!![0]), 1e-5f)
        assertEquals(2f, HDRDisplayMath.halfToFloat(packed[1]), 1e-5f)
        assertTrue(HDRDisplayMath.packHalf(floatArrayOf(70000f, 1f, 1f, 1f)) == null)
    }
}
