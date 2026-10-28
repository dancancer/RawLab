package com.rawlab.android.settings

import org.junit.Assert.*
import org.junit.Test
import com.rawlab.android.looks.MasterRecipe
import com.rawlab.android.looks.applyRecipe

class MasterRecipeTest {
    @Test fun refinedCatalogAppliesAndPersistsEditableControls() {
        val recipe = MasterRecipe.decode(org.json.JSONObject(java.io.File("../../Shared/fixtures/master-recipe-v4.json").readText()))
        val applied = EditSettings(blackPoint = -20f, clarity = -40f, toneCurve = .35f,
            temperature = 8000f, sharpening = .75f).applyRecipe(recipe)
        assertEquals(50f, applied.blackPoint); assertEquals(-60f, applied.whitePoint); assertEquals(15f, applied.vibrance)
        assertEquals(12f, applied.clarity); assertEquals(-6f, applied.dehaze)
        assertEquals(ColorGradingWheel(210f, 8f), applied.colorGrading.shadows)
        assertEquals(ToneCurveMode.CUSTOM, applied.curve.mode); assertEquals(5, applied.curve.points.size)
        assertEquals(0f, applied.toneCurve); assertEquals(8000f, applied.temperature); assertEquals(.75f, applied.sharpening)
        assertEquals(applied, SettingsCodec.decode(SettingsCodec.encode(applied)))
        assertEquals(4, applied.masterRecipeSettingsVersion)
        for (strength in listOf(0f, .5f, 1f, 2f)) {
            val state = applied.copy(strength = strength)
            assertEquals((50f * strength).coerceIn(-100f, 100f), state.renderBlackPoint)
            assertEquals((-60f * strength).coerceIn(-100f, 100f).canonicalZero(), state.renderWhitePoint)
            assertEquals(15f * strength, state.renderVibrance)
            assertEquals(12f * strength, state.renderClarity); assertEquals((-6f * strength).canonicalZero(), state.renderDehaze)
            assertEquals(ColorGradingWheel(210f, 8f * strength), state.renderColorGrading.shadows)
            assertTrue(strength != 0f || state.renderCurve.isIdentity)
            assertEquals(50f, state.blackPoint); assertEquals(5, state.curve.points.size)
            assertEquals(state, SettingsCodec.decode(SettingsCodec.encode(state)))
            val removed = state.selectFilm("neutral", 8f, 5300f)
            assertNull(removed.recipeID)
            assertEquals(state.renderBlackPoint, removed.blackPoint); assertEquals(state.renderWhitePoint, removed.whitePoint)
            assertEquals(state.renderVibrance, removed.vibrance); assertEquals(state.renderClarity, removed.clarity)
            assertEquals(state.renderDehaze, removed.dehaze); assertEquals(state.renderCurve, removed.curve)
            assertEquals(state.renderColorGrading, removed.colorGrading); assertEquals(state.renderHsl, removed.hsl)
            assertEquals(state.exposure * strength, removed.exposure)
        }
        assertThrows(IllegalArgumentException::class.java) { applied.copy(exposure = 4f, strength = 2f).selectFilm("neutral", 8f, 5300f) }
        val legacy = org.json.JSONObject(SettingsCodec.encode(applied.copy(strength = 2f)).removePrefix("v2:"))
        legacy.getJSONObject("settings").remove("masterRecipeSettingsVersion")
        val old = SettingsCodec.decode("v2:$legacy")
        assertEquals(3, old.masterRecipeSettingsVersion); assertEquals(old.blackPoint, old.renderBlackPoint)
        assertEquals(old.curve, old.renderCurve); assertEquals(old.colorGrading, old.renderColorGrading)
        legacy.getJSONObject("settings").put("masterRecipeSettingsVersion", 5)
        assertThrows(IllegalArgumentException::class.java) { SettingsCodec.decode("v2:$legacy") }
        val flat = ToneCurveSettings(ToneCurveMode.CUSTOM, listOf(ToneCurvePoint(0.0, 0.0),
            ToneCurvePoint(.2, .8), ToneCurvePoint(.4, .8), ToneCurvePoint(1.0, 1.0)))
        assertEquals(listOf(0.0, 1.0, 1.0, 1.0), flat.scaled(2f).points.map { it.y })
    }
    @Test fun leavingRecipeRequiresCalibrationOnlyWhenWhiteBalanceContributes() {
        for (cameraTint in listOf(null, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY)) {
            for (filmID in listOf("neutral", "provia")) {
                val neutral = EditSettings(recipeID = "takashi_yasui_zen").selectFilm(filmID, cameraTint)
                assertNull(neutral.recipeID); assertEquals(filmID, neutral.film)
                assertEquals(0f, neutral.tint); assertFalse(neutral.customWb)
                for (source in listOf(EditSettings(recipeID = "takashi_yasui_zen", tint = 2f),
                    EditSettings(recipeID = "takashi_yasui_zen", customWb = true, temperature = 8000f, tint = 24f))) {
                    assertThrows(IllegalArgumentException::class.java) { source.selectFilm(filmID, cameraTint) }
                }
            }
        }
        val raster = EditSettings(recipeID = "takashi_yasui_zen", tint = 5f, strength = .5f,
            masterRecipeSettingsVersion = 4, blackPoint = 40f)
            .selectFilm("neutral", input = com.rawlab.android.format.PhotoInputKind.RASTER)
        assertNull(raster.recipeID); assertEquals(20f, raster.blackPoint)
    }

    @Test fun recipeIdentityMustBelongToEditSettings() {
        assertNotNull("Master recipe identity is missing", EditSettings::class.java.methods.firstOrNull { it.name == "getRecipeID" })
    }
    @Test fun applicationScalingAndFrozenSettingsMatchMac() {
        val hsl = HslSettings().withValue(1, 4, 4f)
        val recipe = MasterRecipe("hamada_daylight_v2", "Hamada", "daylight", "daylight", "hamada_daylight_pro_v2.cube",
            .4f, .2f, -.15f, -.15f, -.08f, 5f, hsl)
        val applied = EditSettings(film = "velvia", exposure = 2f, tint = 80f, temperature = 8000f, sharpening = .75f,
            hsl = HslSettings().withValue(0, 7, 80f)).applyRecipe(recipe)
        assertEquals(recipe.id, applied.recipeID); assertEquals("neutral", applied.film)
        assertEquals(.4f, applied.exposure); assertEquals(hsl, applied.hsl)
        assertEquals(8000f, applied.temperature); assertEquals(.75f, applied.sharpening)
        val edited = applied.copy(hsl = hsl.withValue(0, 7, 37f).withValue(1, 5, -80f))
        for (strength in listOf(0f, .5f, 1f, 2f)) {
            val state = edited.copy(strength = strength)
            assertEquals(37f * strength, state.renderHsl.value(0, 7))
            assertEquals(if (strength == 0f) 0f else (-80f * strength).coerceIn(-100f, 100f), state.renderHsl.value(1, 5))
            assertEquals(edited.hsl, state.hsl)
            assertEquals(state, SettingsCodec.decode(SettingsCodec.encode(state)))
        }
        val directory = java.nio.file.Files.createTempDirectory("recipe-edits").toFile()
        try {
            val identity = PhotoIdentity("recipe-photo")
            EditStore(directory).save(identity, edited.copy(strength = .5f))
            assertEquals(18.5f, EditStore(directory).load(identity)!!.renderHsl.value(0, 7))
        } finally { directory.deleteRecursively() }
        val film = edited.selectFilm("provia", 8f, 5300f)
        assertNull(film.recipeID); assertEquals(13f, film.tint); assertTrue(film.customWb)
        assertEquals(film.hsl, film.copy(strength = 0f).renderHsl)
    }
}
