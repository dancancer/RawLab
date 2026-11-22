package com.rawlab.android.engine

import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.settings.ColorGradingSettings
import com.rawlab.android.settings.ColorGradingWheel
import com.rawlab.android.settings.HDRColorSettings
import com.rawlab.android.settings.HDRDetailSettings
import com.rawlab.android.settings.HDRLookSettings
import com.rawlab.android.settings.HDRRenditionSettings
import com.rawlab.android.settings.HDRSettings
import com.rawlab.android.settings.HDRToneSettings
import com.rawlab.android.settings.HslSettings
import com.rawlab.android.settings.PhotoEffectsSettings
import com.rawlab.android.settings.ToneCurveChannel
import com.rawlab.android.settings.ToneCurveMode
import com.rawlab.android.settings.ToneCurveParametric
import com.rawlab.android.settings.ToneCurvePoint
import com.rawlab.android.settings.ToneCurveSettings
import com.rawlab.android.settings.ToneCurveShape
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class HDRNativeRequestTest {
    @Test fun nativeLookPopulatesLookSectionAfterDetail() {
        val sha = "a".repeat(64)
        val lookDir = File("/tmp/looks")
        val settings = HDRSettings().withLook(HDRLookSettings(sha, "HDR", .65f))
        val request = settings.toNativeRequest(longEdge = 1024, lookDirectory = lookDir)
        assertEquals(1024, request.longEdge)
        assertEquals(NativeHDRLook(File(lookDir, "$sha.cube").absolutePath, sha, .65f), request.look)
        assertEquals(settings.copy(look = null).toNativeRequest(1024, lookDir), request.copy(look = null))
        assertNull(request.channelCurves)
    }

    @Test fun nativeDetailPopulatesDetailSectionAfterEffects() {
        val settings = HDRSettings().withDetail(HDRDetailSettings(1.25f, .5f, -.4f, .65f))
        val request = settings.toNativeRequest()
        assertEquals(NativeHDRDetail(1.25f, .5f, -.4f, .65f), request.detail)
        assertNull(request.look)
        assertEquals(settings.copy(detail = null).toNativeRequest(), request.copy(detail = null))
    }

    @Test fun nativeEffectsAndRenditionPopulateStructuredSections() {
        val fx = PhotoEffectsSettings(vignetteAmount = -25f, grainAmount = 40f)
        val rend = HDRRenditionSettings(peakLimitEV = 2.5f, sdrExposureEV = -0.5f, sdrContrast = 20f, sdrSaturation = -15f)
        val settings = HDRSettings().withRendition(rend).withEffects(fx)
        val request = settings.toNativeRequest()
        assertEquals(NativeHDRRendition(2.5f, -0.5f, 20f, -15f), request.rendition)
        assertEquals(fx.toNativePhotoEffects(), request.effects)
        assertNull(request.detail)
    }

    @Test fun nativeColorPopulatesHslAndColorGradingAfterTone() {
        val color = HDRColorSettings(
            vibrance = 27f,
            hsl = HslSettings().withValue(1, 6, -12.5f),
            grading = ColorGradingSettings(highlights = ColorGradingWheel(210f, 34f)),
        )
        val settings = HDRSettings().withColor(color)
        val request = settings.toNativeRequest()
        val nativeColor = requireNotNull(request.color)
        assertEquals(27f, nativeColor.vibrance, 0f)
        assertArrayEquals(color.hsl.packed(), nativeColor.hsl, 0f)
        assertEquals(NativeColorGrading(highlightsHue = 210f, highlightsSaturation = 34f), nativeColor.grading)
        assertNull(request.rendition)
    }

    @Test fun nativeRenderRequestAddsToneAndChannelCurvesInStructuredFields() {
        val base = HDRSettings(exposure = 1f)
        val baseRequest = base.toNativeRequest()
        assertNull(baseRequest.tone)

        val toneRequest = base.withTone(HDRToneSettings(-25f, 50f, 30f)).toNativeRequest()
        assertEquals(NativeHDRTone(-25f, 50f, 30f, NativeToneCurve(0, DoubleArray(0))), toneRequest.tone)
        assertNull(toneRequest.color)

        val redCurve = ToneCurveSettings().replacing(
            ToneCurveChannel.RED,
            ToneCurveShape.identity.inserting(0.5, 0.7),
        )
        val channelRequest = base.withTone(HDRToneSettings(curve = redCurve)).toNativeRequest()
        val channels = requireNotNull(channelRequest.channelCurves)
        assertEquals(ToneCurveMode.CUSTOM.nativeValue, channels.red.mode)
        assertArrayEquals(doubleArrayOf(0.0, 0.0, 0.5, 0.7, 1.0, 1.0), channels.red.points, 0.0)
        assertEquals(ToneCurveMode.LEGACY.nativeValue, channels.green.mode)
    }

    @Test fun nativeRequestRetainsSharedHdrPercentageUnitsAndGeometry() {
        val geometry = GeometrySettings(0.1f, 0.2f, 0.7f, 0.6f, 2, true, false, -4f, 0.2f, -0.3f)
        val request = HDRSettings(
            exposure = 1.25f,
            temperature = 10000f,
            tint = 42f,
            contrast = -75f,
            highlights = 50f,
            shadows = 100f,
            saturation = -30f,
            geometry = geometry,
        ).toNativeRequest(longEdge = 512)
        assertEquals(1.25f, request.exposureEv, 0f)
        assertEquals(10000f, request.temperature, 0f)
        assertEquals(42f, request.tint, 0f)
        assertEquals(-75f, request.contrast, 0f)
        assertEquals(50f, request.highlights, 0f)
        assertEquals(100f, request.shadows, 0f)
        assertEquals(-30f, request.saturation, 0f)
        assertEquals(geometry.toNativeGeometry(), request.geometry)
        assertEquals(512, request.longEdge)
    }

    @Test fun nativeRequestPopulatesV9ToneCurveAndColorGradingV2() {
        val v2Curve = ToneCurveSettings(
            mode = ToneCurveMode.CUSTOM,
            points = listOf(ToneCurvePoint(0.0, 0.1), ToneCurvePoint(1.0, 0.9)),
            applyToLuminosity = true,
            parametric = ToneCurveParametric(highlights = 20.0, shadows = -15.0),
        )
        val settings = HDRSettings()
            .withTone(HDRToneSettings(curve = v2Curve))
            .withColor(HDRColorSettings(grading = ColorGradingSettings(blending = 70f, balance = -15f)))
        val request = settings.toNativeRequest()
        val tone = requireNotNull(request.tone)
        assertTrue(tone.applyToLuminosity)
        assertEquals(NativeToneCurveParametric(highlights = 20f, shadows = -15f), tone.parametric)
        val gradingV2 = requireNotNull(request.gradingV2)
        assertEquals(70f, gradingV2.blending, 0f)
        assertEquals(-15f, gradingV2.balance, 0f)
    }
}
