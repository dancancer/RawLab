package com.rawlab.android

import android.content.res.Configuration
import androidx.test.platform.app.InstrumentationRegistry
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class LanguageResourcesTest {
    @Test fun allSixLanguagesSelectNativeResources() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val expected = mapOf("en" to "Language", "zh-Hans" to "语言", "de" to "Sprache",
            "fr" to "Langue", "ja" to "言語", "es" to "Idioma")
        val hue = mapOf("en" to "Hue", "zh-Hans" to "色相", "de" to "Farbton",
            "fr" to "Teinte", "ja" to "色相", "es" to "Matiz")
        val recipes = mapOf("en" to "Master recipes", "zh-Hans" to "大师配方", "de" to "Master-Rezepte",
            "fr" to "Recettes maîtres", "ja" to "マスターレシピ", "es" to "Recetas maestras")
        val automatic = mapOf("en" to "Automatic", "zh-Hans" to "自动", "de" to "Automatisch",
            "fr" to "Automatique", "ja" to "自動", "es" to "Automático")
        val perspectiveHorizontal = mapOf("en" to "Horizontal perspective", "zh-Hans" to "水平透视",
            "de" to "Horizontale Perspektive", "fr" to "Perspective horizontale",
            "ja" to "水平方向の遠近補正", "es" to "Perspectiva horizontal")
        val perspectiveVertical = mapOf("en" to "Vertical perspective", "zh-Hans" to "垂直透视",
            "de" to "Vertikale Perspektive", "fr" to "Perspective verticale",
            "ja" to "垂直方向の遠近補正", "es" to "Perspectiva vertical")
        val usage = mapOf("en" to "Usage analytics", "zh-Hans" to "使用统计", "de" to "Nutzungsanalyse",
            "fr" to "Analyse d'utilisation", "ja" to "利用状況の分析", "es" to "Análisis de uso")
        expected.forEach { (language, value) ->
            val config = Configuration(context.resources.configuration)
            config.setLocale(Locale.forLanguageTag(language))
            val localized = context.createConfigurationContext(config)
            assertEquals(value, localized.getString(R.string.language))
            assertEquals(hue[language], localized.getString(R.string.hsl_hue))
            assertEquals(recipes[language], localized.getString(R.string.master_recipes))
            assertEquals(automatic[language], localized.getString(R.string.lens_automatic))
            assertEquals(perspectiveHorizontal[language], localized.getString(R.string.geometry_perspective_horizontal))
            assertEquals(perspectiveVertical[language], localized.getString(R.string.geometry_perspective_vertical))
            assertEquals(usage[language], localized.getString(R.string.usage_analytics))
            assertFalse(localized.getString(R.string.geometry_perspective_hint).isBlank())
            localized.getString(R.string.vignette_summary, 1.0, 50.0, 0.0, 50.0, 0.0)
            localized.getString(R.string.grain_summary, 1.0, 25.0, 50.0)
        }
        val config = Configuration(context.resources.configuration)
        config.setLocale(Locale.forLanguageTag(LanguageChoice.resolve("system", listOf("pt-BR"))))
        assertEquals("Language", context.createConfigurationContext(config).getString(R.string.language))
    }

    @Test fun lensStatesAndEditSnapshotStayStableAcrossAllSixLanguages() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val previous = AppStrings.preference(context)
        val languages = listOf("en", "zh-Hans", "de", "fr", "ja", "es")
        val automatic = mapOf("en" to "Automatic", "zh-Hans" to "自动", "de" to "Automatisch",
            "fr" to "Automatique", "ja" to "自動", "es" to "Automático")
        val settings = EditSettings(
            film = "velvia", strength = 1.35f, exposure = -.75f, highlights = .25f, shadows = -.2f,
            contrast = .4f, toneCurve = -.15f, saturation = .3f, customWb = true, temperature = 4200f,
            tint = 12f, denoise = DenoiseSettings(true, 10f, 72f, 100f), sharpening = .65f,
            effects = PhotoEffectsSettings(vignetteAmount = -40f, grainAmount = 65f),
            displayChromaDenoise = 2, exposureMode = 2,
            hsl = HslSettings().withValue(1, 0, -60f), recipeID = "recipe",
            lens = LensSettings(true, true, false, true, "fixture-profile"),
            geometry = GeometrySettings(perspectiveHorizontal = .45f, perspectiveVertical = -.3f),
        )
        val encoded = SettingsCodec.encode(settings)
        try {
            languages.forEach { language ->
                AppStrings.setPreference(context, language)
                val localized = AppStrings.localizedContext(context)
                assertEquals(automatic.getValue(language), localized.getString(R.string.lens_automatic))
                assertEquals(automatic.getValue(language), AppStrings.text(R.string.lens_automatic))
                listOf(R.string.lens_matching, R.string.lens_off, R.string.dng).forEach {
                    assertFalse("$language resource $it is empty", localized.getString(it).isBlank())
                }
                val stateResources = listOf(
                    R.string.lens_off, R.string.lens_matched, R.string.lens_database_unavailable,
                    R.string.lens_camera_info_missing, R.string.lens_manual_required, R.string.lens_ambiguous,
                    R.string.lens_no_calibration, R.string.lens_focal_length_missing,
                    R.string.lens_embedded_geometry, R.string.lens_input_unsupported,
                )
                stateResources.forEachIndexed { state, resource ->
                    assertEquals("$language lens state $state", localized.getString(resource), LensInfo(
                        state, "", "", false, false, 1f, emptyList()).message)
                }
                assertEquals(localized.getString(R.string.lens_corrected,
                    localized.getString(R.string.lens_distortion_short)), LensInfo(
                    1, "", "", true, false, 1f, emptyList()).message)
                assertEquals(localized.getString(R.string.lens_corrected,
                    localized.getString(R.string.lens_tca)), LensInfo(
                    1, "", "", false, true, 1f, emptyList()).message)
                assertEquals(localized.getString(R.string.lens_corrected,
                    listOf(localized.getString(R.string.lens_distortion_short), localized.getString(R.string.lens_tca))
                        .joinToString(" / ")), LensInfo(
                    1, "", "", true, true, 1f, emptyList()).message)
                assertEquals(localized.getString(R.string.lens_crop_percent, 12.5f),
                    AppStrings.format(R.string.lens_crop_percent, 12.5f))
                assertEquals(settings, SettingsCodec.decode(encoded))
            }
        } finally {
            AppStrings.setPreference(context, previous)
        }
    }
}
