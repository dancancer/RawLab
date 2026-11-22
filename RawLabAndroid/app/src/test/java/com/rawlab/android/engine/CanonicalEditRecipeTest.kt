package com.rawlab.android.engine

import com.rawlab.android.format.OutputSharpening
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.settings.ColorGradingSettings
import com.rawlab.android.settings.ColorGradingWheel
import com.rawlab.android.settings.DenoiseSettings
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.HslSettings
import com.rawlab.android.settings.LensSettings
import com.rawlab.android.settings.PhotoEffectsSettings
import com.rawlab.android.settings.ProcessingIdentity
import com.rawlab.android.settings.ToneCurveChannels
import com.rawlab.android.settings.ToneCurveMode
import com.rawlab.android.settings.ToneCurveParametric
import com.rawlab.android.settings.ToneCurvePoint
import com.rawlab.android.settings.ToneCurveSettings
import com.rawlab.android.settings.ToneCurveShape
import com.rawlab.android.settings.X3fMode
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CanonicalEditRecipeTest {
    @Test
    fun rawSettingsSerializeToCanonicalV7Json() {
        val settings = EditSettings(
            processing = ProcessingIdentity.C5,
            x3fMode = X3fMode.LEGACY,
            exposureMode = 0,
            blackPoint = -25f,
            whitePoint = 40f,
            vibrance = 15f,
            clarity = 30f,
            dehaze = -10f,
            colorGrading = ColorGradingSettings(
                shadows = ColorGradingWheel(200f, 30f),
                midtones = ColorGradingWheel(45f, 10f),
                highlights = ColorGradingWheel(350f, 20f),
            ),
            curve = ToneCurveSettings(
                mode = ToneCurveMode.CUSTOM,
                points = listOf(ToneCurvePoint(0.0, 0.0), ToneCurvePoint(0.5, 0.6), ToneCurvePoint(1.0, 1.0)),
                channels = ToneCurveChannels(
                    red = ToneCurveShape(ToneCurveMode.CUSTOM, listOf(ToneCurvePoint(0.0, 0.0), ToneCurvePoint(0.5, 0.55), ToneCurvePoint(1.0, 1.0))),
                ),
            ),
            hsl = HslSettings().withValue(0, 0, 12f),
            geometry = GeometrySettings(0.1f, 0.2f, 0.7f, 0.6f, 1, true, false, -2.5f, 0.2f, -0.1f),
            lens = LensSettings(distortion = true, tca = true, autoCrop = false, manual = true, profileId = "lens-and", vignetting = true),
            effects = PhotoEffectsSettings(vignetteAmount = -50f, grainAmount = 25f),
            denoise = DenoiseSettings(enabled = true, luma = 15f, chroma = 60f, coarse = 70f),
            displayChromaDenoise = 1,
        )

        val root = JSONObject(settings.toCanonicalRecipeJson(isRaster = false))
        assertEquals(7, root.getInt("schema_version"))
        assertEquals("legacy", root.getString("x3f_mode"))
        assertEquals(2, root.getJSONObject("processing").getInt("version"))

        val edits = root.getJSONObject("edits")
        assertEquals("scene", edits.getJSONObject("exposure").getString("mode"))
        val tone = edits.getJSONObject("tone")
        assertEquals(-0.25, tone.getDouble("black_point"), 1e-6)
        assertEquals(0.40, tone.getDouble("white_point"), 1e-6)
        assertTrue(tone.getJSONObject("curve").has("channels"))
        assertEquals(0.15, edits.getJSONObject("color").getDouble("vibrance"), 1e-6)
        assertEquals(0.30, edits.getJSONObject("effects").getDouble("clarity"), 1e-6)
        assertEquals(-0.10, edits.getJSONObject("effects").getDouble("dehaze"), 1e-6)
        assertEquals("lens-and", edits.getJSONObject("lens_correction").getString("profile_id"))
        assertEquals(1, edits.getJSONObject("denoise").getInt("chroma_mode"))
        assertTrue(edits.getJSONObject("denoise").getJSONObject("wavelet").getBoolean("enabled"))
    }

    @Test
    fun rasterSettingsSerializeToCanonicalV5WithoutX3fAndForcesSensor() {
        val settings = EditSettings(
            processing = ProcessingIdentity.LEGACY,
            exposureMode = 1,
            lens = LensSettings(distortion = true, manual = false),
            displayChromaDenoise = 2,
        )

        val root = JSONObject(settings.toCanonicalRecipeJson(isRaster = true, includeDenoise = false))
        assertEquals(5, root.getInt("schema_version"))
        assertFalse(root.has("x3f_mode"))
        assertEquals("raster", root.getJSONObject("input").getString("type"))
        val edits = root.getJSONObject("edits")
        assertEquals("sensor", edits.getJSONObject("exposure").getString("mode"))
        assertEquals("none", edits.getJSONObject("white_balance").getString("mode"))
        assertFalse(edits.getJSONObject("lens_correction").has("profile_id"))
        assertEquals(0, edits.getJSONObject("denoise").getInt("chroma_mode"))
        assertFalse(edits.getJSONObject("denoise").has("wavelet"))
    }

    @Test
    fun v012ExtensionsSerializeToCanonicalV17Json() {
        val settings = EditSettings(
            colorGrading = ColorGradingSettings(
                shadows = ColorGradingWheel(200f, 30f, -10f),
                global = ColorGradingWheel(45f, 15f, 8f),
                blending = 65f,
                balance = -20f,
            ),
            curve = ToneCurveSettings(
                mode = ToneCurveMode.CUSTOM,
                points = listOf(ToneCurvePoint(0.0, 0.08), ToneCurvePoint(1.0, 0.94)),
                applyToLuminosity = true,
                parametric = ToneCurveParametric(highlights = -12.0, shadows = 18.0),
            ),
        )
        val root = JSONObject(settings.toCanonicalRecipeJson(outputSharpening = OutputSharpening.STANDARD))
        assertEquals(17, root.getInt("schema_version"))
        assertEquals("standard", root.getJSONObject("output").getString("sharpening"))
        val curve = root.getJSONObject("edits").getJSONObject("tone").getJSONObject("curve")
        assertTrue(curve.getBoolean("apply_to_luminosity"))
        assertEquals(-12.0, curve.getJSONObject("parametric").getDouble("highlights"), 1e-6)
        val grading = root.getJSONObject("edits").getJSONObject("color_grading")
        assertEquals(-10.0, grading.getJSONObject("shadows").getDouble("luminance"), 1e-6)
        assertEquals(65.0, grading.getDouble("blending"), 1e-6)
        assertEquals(-20.0, grading.getDouble("balance"), 1e-6)
    }
}
