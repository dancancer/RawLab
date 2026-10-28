package com.rawlab.android.settings

import org.junit.Assert.*
import org.junit.Test
import com.rawlab.android.looks.MasterRecipe
import com.rawlab.android.looks.applyRecipe

class MasterRecipeTest {
    @Test fun leavingRecipeWithoutCameraWhiteBalanceKeepsNeutralSettingsFinite() {
        for (cameraTint in listOf(null, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY)) {
            for (recipeTint in listOf(0f, 2f)) {
                for (filmID in listOf("neutral", "provia")) {
                    val selected = EditSettings(recipeID = "takashi_yasui_zen", tint = recipeTint)
                        .selectFilm(filmID, cameraTint)
                    assertNull(selected.recipeID)
                    assertEquals(filmID, selected.film)
                    assertEquals(0f, selected.tint)
                    assertFalse(selected.customWb)
                }
            }
        }
    }

    @Test fun leavingRecipeWithCustomWhiteBalanceIgnoresUnavailableCameraTint() {
        for (cameraTint in listOf(null, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY)) {
            val selected = EditSettings(recipeID = "takashi_yasui_zen", customWb = true,
                temperature = 8000f, tint = 24f).selectFilm("provia", cameraTint)
            assertNull(selected.recipeID)
            assertEquals("provia", selected.film)
            assertEquals(24f, selected.tint)
            assertEquals(8000f, selected.temperature)
            assertTrue(selected.customWb)
        }
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
        val film = edited.selectFilm("provia", 8f)
        assertNull(film.recipeID); assertEquals(13f, film.tint); assertTrue(film.customWb)
        assertEquals(film.hsl, film.copy(strength = 0f).renderHsl)
    }
}
