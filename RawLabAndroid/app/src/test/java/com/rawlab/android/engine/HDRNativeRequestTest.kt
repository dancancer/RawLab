package com.rawlab.android.engine

import com.rawlab.android.settings.HDRSettings
import com.rawlab.android.settings.HDRToneSettings
import com.rawlab.android.settings.HDRColorSettings
import com.rawlab.android.settings.HDRDetailSettings
import com.rawlab.android.settings.HDRLookSettings
import com.rawlab.android.settings.HslSettings
import com.rawlab.android.settings.ColorGradingSettings
import com.rawlab.android.settings.ColorGradingWheel
import org.junit.Assert.assertArrayEquals
import org.junit.Test

class HDRNativeRequestTest {
    @Test fun nativeLookAppendsStrengthToTheDetailRequest() {
        val settings = HDRSettings().withLook(HDRLookSettings("a".repeat(64), "HDR", .65f))
        val request = settings.renderRequestValues()
        assertArrayEquals(settings.copy(look = null).renderRequestValues(), request.copyOfRange(0, 67), 0f)
        assertArrayEquals(floatArrayOf(.65f), request.copyOfRange(67, request.size), 0f)
    }

    @Test fun nativeDetailAppendsFourFloatsToTheEffectsRequest() {
        val settings = HDRSettings().withDetail(HDRDetailSettings(1.25f, .5f, -.4f, .65f))
        val request = settings.renderRequestValues()
        assertArrayEquals(settings.copy(detail = null).renderRequestValues(), request.copyOfRange(0, 63), 0f)
        assertArrayEquals(floatArrayOf(1.25f, .5f, -.4f, .65f), request.copyOfRange(63, request.size), 0f)
    }
    @Test fun nativeColorAppendsToTheToneRequest() {
        val color = HDRColorSettings(27f, HslSettings().withValue(1, 6, -12.5f),
            ColorGradingSettings(highlights = ColorGradingWheel(210f, 34f)))
        val settings = HDRSettings().withColor(color)
        val request = settings.renderRequestValues()
        assertArrayEquals(settings.copy(color = null).renderRequestValues(), request.copyOfRange(0, 20), 0f)
        assertArrayEquals(floatArrayOf(27f) + color.hsl.packed() + floatArrayOf(0f, 0f, 0f, 0f, 210f, 34f),
            request.copyOfRange(20, request.size), 0f)
    }
    @Test fun nativeRenderRequestAddsToneAfterTheLegacyGeometry() {
        val base = HDRSettings(exposure = 1f)
        val request = base.withTone(HDRToneSettings(-25f, 50f, 30f)).renderRequestValues()
        assertArrayEquals(base.requestValues(), request.copyOfRange(0, 17), 0f)
        assertArrayEquals(floatArrayOf(-25f, 50f, 30f), request.copyOfRange(17, 20), 0f)
    }

    @Test fun nativeRequestRetainsSharedHdrPercentageUnits() {
        val request = HDRSettings(exposure = 1.25f, temperature = 10000f, tint = 42f,
            contrast = -75f, highlights = 50f, shadows = 100f, saturation = -30f).requestValues()
        assertArrayEquals(floatArrayOf(1.25f, 10000f, 42f, -75f, 50f, 100f, -30f), request.copyOfRange(0, 7), 0f)
    }
}
