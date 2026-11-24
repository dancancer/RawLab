package com.rawlab.android.engine

import com.rawlab.android.format.OutputSharpening
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.ProcessingIdentity
import com.rawlab.android.settings.X3fMode
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeProcessRequestTest {
    @Test fun sdrSessionStateSerializesCoreUnitsWithoutFakePaths() {
        val settings = EditSettings(
            strength = 0.8f,
            exposure = 1.5f,
            highlights = -0.4f,
            shadows = -0.25f,
            contrast = 1.3f,
            toneCurve = -0.2f,
            saturation = 0.85f,
            customWb = true,
            temperature = 5200f,
            tint = 14f,
            sharpening = 0.9f,
            exposureMode = 0,
            processing = ProcessingIdentity.CURRENT,
            x3fMode = X3fMode.LEGACY,
        )
        val json = settings.toSdrSessionStateJson(
            isRaster = false,
            lutPath = "/tmp/provia.cube",
            outputSharpening = OutputSharpening.STANDARD,
        )
        assertFalse(json.contains("session.raw"))
        assertFalse(json.contains("session.png"))

        val root = JSONObject(json)
        assertEquals(17, root.getInt("schema_version"))
        assertEquals("legacy", root.getString("x3f_mode"))
        assertEquals(3, root.getJSONObject("processing").getInt("version"))
        assertEquals("standard", root.getJSONObject("output").getString("output_sharpening"))

        val edits = root.getJSONObject("edits")
        assertEquals("scene", edits.getJSONObject("exposure").getString("mode"))
        assertEquals(1.5, edits.getJSONObject("exposure").getDouble("ev"), 1e-6)
        val wb = edits.getJSONObject("white_balance")
        assertEquals("temperature", wb.getString("mode"))
        assertEquals(5200.0, wb.getDouble("temperature_kelvin"), 1e-6)
        assertEquals(14.0, wb.getDouble("tint"), 1e-6)
        val look = edits.getJSONObject("look")
        assertEquals("/tmp/provia.cube", look.getString("path"))
        assertEquals(0.8, look.getDouble("strength"), 1e-6)
        val tone = edits.getJSONObject("tone")
        assertEquals(1.3, tone.getDouble("contrast"), 1e-6)
        assertEquals(-0.4, tone.getDouble("highlights"), 1e-6)
        assertEquals(-0.25, tone.getDouble("shadows"), 1e-6)
        assertEquals(-0.2, tone.getDouble("s_curve"), 1e-6)
        assertEquals(0.85, tone.getDouble("saturation"), 1e-6)
        assertEquals(0.9, edits.getJSONObject("detail").getDouble("sharpening"), 1e-6)
    }

    @Test fun recipeScalingAppliesCoreClampAndMasterRecipeWb() {
        val settings = EditSettings(
            recipeID = "hamada",
            strength = 2.0f,
            exposure = 1.5f,
            highlights = -0.8f,
            shadows = 0.75f,
            contrast = 1.8f,
            toneCurve = 0.25f,
            saturation = 0.2f,
            sharpening = 1.9f,
            customWb = false,
            tint = 6f,
        )
        val json = settings.toSdrSessionStateJson(isRaster = false, lutPath = null)
        val root = JSONObject(json)
        val edits = root.getJSONObject("edits")

        assertTrue(edits.getJSONObject("look").isNull("path"))
        assertEquals(0.0, edits.getJSONObject("look").getDouble("strength"), 0.0)
        assertEquals("camera", edits.getJSONObject("white_balance").getString("mode"))
        val masterRecipe = edits.getJSONObject("master_recipe")
        assertTrue(masterRecipe.getBoolean("active"))
        assertEquals(2.0, masterRecipe.getDouble("strength"), 0.0)
        assertFalse(masterRecipe.getBoolean("custom_wb"))
        assertEquals(6500.0, masterRecipe.getDouble("temperature_kelvin"), 0.0)
        assertEquals(6.0, masterRecipe.getDouble("tint"), 0.0)
        assertEquals("error", masterRecipe.getString("uncalibrated_fallback"))

        assertEquals(3.0, edits.getJSONObject("exposure").getDouble("ev"), 1e-6)
        val tone = edits.getJSONObject("tone")
        // Scaled values (contrast=2.6, saturation=-0.6, highlights=-1.6, shadows=1.5) are clamped by core-clamp!
        assertEquals(2.0, tone.getDouble("contrast"), 1e-6)
        assertEquals(0.0, tone.getDouble("saturation"), 1e-6)
        assertEquals(-1.0, tone.getDouble("highlights"), 1e-6)
        assertEquals(1.0, tone.getDouble("shadows"), 1e-6)
        assertEquals(1.9, edits.getJSONObject("detail").getDouble("sharpening"), 1e-6)
    }

    @Test fun processingAndCompatibilitySessionStatesCarryMinimalExpectedFields() {
        val proc = JSONObject(CanonicalEditRecipe.processingSessionStateJson(2, "sensor"))
        assertEquals(2, proc.getJSONObject("processing").getInt("version"))
        assertEquals("sensor", proc.getJSONObject("edits").getJSONObject("exposure").getString("mode"))

        val compat = JSONObject(
            CanonicalEditRecipe.compatibilityPreviewStateJson(
                processingVersion = 3,
                exposureMode = "preview",
                lutPath = "/tmp/look.cube",
                lutStrength = 0.75,
            ),
        )
        assertEquals("preview", compat.getJSONObject("edits").getJSONObject("exposure").getString("mode"))
        assertEquals("/tmp/look.cube", compat.getJSONObject("edits").getJSONObject("look").getString("path"))
        assertEquals(0.75, compat.getJSONObject("edits").getJSONObject("look").getDouble("strength"), 1e-6)
    }
}
