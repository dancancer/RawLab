package com.rawlab.android.engine

import com.rawlab.android.settings.HDRSettings
import org.junit.Assert.assertArrayEquals
import org.junit.Test

class HDRNativeRequestTest {
    @Test fun nativeRequestRetainsSharedHdrPercentageUnits() {
        val request = HDRSettings(exposure = 1.25f, temperature = 10000f, tint = 42f,
            contrast = -75f, highlights = 50f, shadows = 100f, saturation = -30f).requestValues()
        assertArrayEquals(floatArrayOf(1.25f, 10000f, 42f, -75f, 50f, 100f, -30f), request.copyOfRange(0, 7), 0f)
    }
}
