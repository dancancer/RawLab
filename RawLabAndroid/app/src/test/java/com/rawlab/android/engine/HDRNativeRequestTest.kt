package com.rawlab.android.engine

import com.rawlab.android.format.OutputSharpening
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.settings.ColorGradingSettings
import com.rawlab.android.settings.ColorGradingWheel
import com.rawlab.android.settings.HDRCameraDevelopmentSettings
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
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class HDRNativeRequestTest {
    @Test fun sessionStatePopulatesLookAndSharpeningFields() {
        val sha = "a".repeat(64)
        val lookDir = File("/tmp/looks")
        val settings = HDRSettings().withLook(HDRLookSettings(sha, "HDR", .65f))
        val json = settings.toHdrSessionStateJson(lookDirectory = lookDir, outputSharpening = OutputSharpening.STANDARD)
        val root = JSONObject(json)
        assertEquals("rawlab_hdr", root.getJSONObject("processing").getString("family"))
        assertEquals(16, root.getInt("schema_version"))
        val look = root.getJSONObject("edits").getJSONObject("look")
        assertEquals(File(lookDir, "$sha.cube").absolutePath, look.getString("path"))
        assertEquals(sha, look.getString("sha256"))
        assertEquals(.65, look.getDouble("strength"), 1e-6)
        assertEquals("standard", root.getJSONObject("output").getString("output_sharpening"))
        assertFalse(json.contains("session.raw"))
        assertFalse(json.contains("session.png"))
    }

    @Test fun sessionStatePopulatesDetailEffectsAndRendition() {
        val fx = PhotoEffectsSettings(vignetteAmount = -25f, grainAmount = 40f)
        val rend = HDRRenditionSettings(peakLimitEV = 2.5f, sdrExposureEV = -0.5f, sdrContrast = 20f, sdrSaturation = -15f)
        val settings = HDRSettings()
            .withRendition(rend)
            .withEffects(fx)
            .withDetail(HDRDetailSettings(1.25f, .5f, -.4f, .65f))
        val edits = JSONObject(settings.toHdrSessionStateJson()).getJSONObject("edits")
        val rendition = edits.getJSONObject("rendition")
        assertEquals(2.5, rendition.getDouble("peak_limit_ev"), 1e-6)
        assertEquals(-0.5, rendition.getDouble("sdr_exposure_ev"), 1e-6)
        assertEquals(0.20, rendition.getDouble("sdr_contrast"), 1e-6)
        assertEquals(-0.15, rendition.getDouble("sdr_saturation"), 1e-6)
        val detail = edits.getJSONObject("detail")
        assertEquals(1.25, detail.getDouble("sharpening"), 1e-6)
        assertEquals(0.5, detail.getDouble("clarity"), 1e-6)
        assertEquals(-0.4, detail.getDouble("dehaze"), 1e-6)
        assertEquals(0.65, detail.getDouble("denoise"), 1e-6)
    }

    @Test fun sessionStatePopulatesHslColorGradingAndChannelCurves() {
        val color = HDRColorSettings(
            vibrance = 27f,
            hsl = HslSettings().withValue(1, 6, -12.5f),
            grading = ColorGradingSettings(
                shadows = ColorGradingWheel(200f, 30f, -15f),
                global = ColorGradingWheel(50f, 15f, 10f),
                blending = 70f,
                balance = -20f,
            ),
        )
        val redCurve = ToneCurveSettings(
            mode = ToneCurveMode.CUSTOM,
            points = listOf(ToneCurvePoint(0.0, 0.1), ToneCurvePoint(1.0, 0.9)),
            applyToLuminosity = true,
            parametric = ToneCurveParametric(highlights = 20.0, shadows = -15.0),
        ).replacing(
            ToneCurveChannel.RED,
            ToneCurveShape.identity.inserting(0.5, 0.7),
        )
        val hdr = HDRSettings()
            .withTone(HDRToneSettings(-25f, 50f, 30f, curve = redCurve))
            .withColor(color)
        assertEquals(9, hdr.processingVersion)
        val edits = JSONObject(hdr.toHdrSessionStateJson()).getJSONObject("edits")
        assertEquals(0.27, edits.getJSONObject("color").getDouble("vibrance"), 1e-6)
        assertEquals(-12.5, edits.getJSONObject("hsl").getJSONArray("saturation").getDouble(6), 1e-6)
        val grading = edits.getJSONObject("color_grading")
        assertEquals(-15.0, grading.getJSONObject("shadows").getDouble("luminance"), 1e-6)
        assertEquals(50.0, grading.getJSONObject("global").getDouble("hue"), 1e-6)
        assertEquals(70.0, grading.getDouble("blending"), 1e-6)
        assertEquals(-20.0, grading.getDouble("balance"), 1e-6)
        val curve = edits.getJSONObject("tone").getJSONObject("curve")
        assertTrue(curve.getBoolean("apply_to_luminosity"))
        assertEquals(20.0, curve.getJSONObject("parametric").getDouble("highlights"), 1e-6)
        assertEquals("custom", curve.getJSONObject("channels").getJSONObject("red").getString("mode"))
        assertEquals("legacy", curve.getJSONObject("channels").getJSONObject("green").getString("mode"))
    }

    @Test fun sessionStateRetainsSharedHdrPercentageUnitsAndGeometry() {
        val geometry = GeometrySettings(0.1f, 0.2f, 0.7f, 0.6f, 2, true, false, -4f, 0.2f, -0.3f)
        val json = HDRSettings(
            exposure = 1.25f,
            temperature = 10000f,
            tint = 42f,
            contrast = -75f,
            highlights = 50f,
            shadows = 100f,
            saturation = -30f,
            geometry = geometry,
        ).toHdrSessionStateJson()
        val edits = JSONObject(json).getJSONObject("edits")
        assertEquals(1.25, edits.getJSONObject("exposure").getDouble("ev"), 1e-6)
        val wb = edits.getJSONObject("white_balance")
        assertEquals("relative", wb.getString("mode"))
        assertEquals(10000.0, wb.getDouble("relative_temperature"), 1e-6)
        assertEquals(42.0, wb.getDouble("relative_tint"), 1e-6)
        val tone = edits.getJSONObject("tone")
        assertEquals(0.25, tone.getDouble("contrast"), 1e-6)
        assertEquals(-0.5, tone.getDouble("highlights"), 1e-6)
        assertEquals(1.0, tone.getDouble("shadows"), 1e-6)
        assertEquals(0.7, tone.getDouble("saturation"), 1e-6)
        assertEquals(2, edits.getJSONObject("geometry").getInt("quarter_turns"))
    }

    @Test fun cameraDevelopmentPreservesSourceProcessingVersionAcrossVersions1To3() {
        val camera = HDRCameraDevelopmentSettings(
            customWhiteBalance = true,
            temperature = 5600f,
            tint = 8f,
            sensorExposure = true,
            fbddLevel = 1,
            lensDistortion = true,
            lensProfile = "rf24",
        )
        for (version in listOf(1, 2, 3)) {
            val standalone = JSONObject(camera.toCameraDevelopmentJson(processingVersion = version))
                .getJSONObject("camera_development")
            assertEquals(version, standalone.getInt("processing_version"))
            assertEquals("temperature", standalone.getString("wb_mode"))
            assertEquals("sensor", standalone.getString("exposure_reference"))
            assertEquals("rf24", standalone.getString("lens_profile_id"))

            val embedded = JSONObject(
                HDRSettings().toHdrSessionStateJson(
                    camera = camera,
                    cameraProcessingVersion = version,
                ),
            ).getJSONObject("camera_development")
            assertEquals(version, embedded.getInt("processing_version"))
        }
    }
}
