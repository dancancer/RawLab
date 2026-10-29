package com.rawlab.android.looks

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import com.rawlab.android.R
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.HslSettings
import com.rawlab.android.settings.ColorGradingSettings
import com.rawlab.android.settings.ColorGradingWheel
import com.rawlab.android.settings.ToneCurveSettings

data class MasterRecipe(val id: String, val name: String, val subtitle: String, val summary: String,
    val lutFileName: String, val exposure: Float, val shadows: Float, val highlights: Float,
    val contrast: Float, val saturation: Float, val tint: Float, val hsl: HslSettings,
    val settingsVersion: Int = 3, val blackPoint: Float = 0f, val whitePoint: Float = 0f, val vibrance: Float = 0f,
    val clarity: Float = 0f, val dehaze: Float = 0f, val grading: ColorGradingSettings = ColorGradingSettings(),
    val curve: ToneCurveSettings = ToneCurveSettings()) {
    init {
        require(settingsVersion in 3..4)
        require(listOf(blackPoint, whitePoint, vibrance, clarity, dehaze).all { it.isFinite() && it in -100f..100f })
    }
    companion object {
        fun load(context: Context): List<MasterRecipe> {
            val rows = JSONArray(context.assets.open("master-recipes.json").bufferedReader().use { it.readText() })
            val recipes = (0 until rows.length()).map { decode(rows.getJSONObject(it)) }
            require(recipes.size == 14 && recipes.map { it.id }.distinct().size == 14)
            return recipes
        }
        fun decode(row: JSONObject): MasterRecipe {
            val version = if (row.has("settingsVersion")) row.getInt("settingsVersion") else 3
            require(version in 3..4 && (!row.has("settingsVersion") || row.getDouble("settingsVersion") == version.toDouble()))
            val mixer = row.getJSONObject("hsl")
            val values = listOf("hue", "saturation", "lightness").flatMap { axis ->
                val array = mixer.getJSONArray(axis)
                require(array.length() == 8)
                (0 until 8).map { array.getDouble(it).toFloat() }
            }
            val tone = if (version == 4) row.getJSONObject("tone") else null
            val atmosphere = if (version == 4) row.getJSONObject("atmosphere") else null
            val grading = if (version == 4) row.getJSONObject("grading") else null
            if (version == 3) require(listOf("tone", "atmosphere", "grading", "curve").none(row::has))
            fun wheel(zone: String): ColorGradingWheel = grading?.getJSONObject(zone)?.let {
                ColorGradingWheel.fromNumbers(it.getDouble("hue"), it.getDouble("saturation"))
            } ?: ColorGradingWheel()
            fun control(group: JSONObject?, key: String): Float {
                val value = group?.getDouble(key) ?: 0.0
                require(value.isFinite() && value in -100.0..100.0)
                return value.toFloat()
            }
            return MasterRecipe(row.getString("id"), row.getString("name"), row.getString("subtitle"),
                row.getString("summary"), row.getString("lutFileName"), row.getDouble("exposureDelta").toFloat(),
                row.getDouble("shadowsDelta").toFloat() / 100, row.getDouble("highlightsDelta").toFloat() / 100,
                row.getDouble("contrastDelta").toFloat() / 100, row.getDouble("saturationDelta").toFloat() / 100,
                row.getDouble("tintDelta").toFloat(), HslSettings(values), version,
                control(tone, "blackPoint"), control(tone, "whitePoint"), control(tone, "vibrance"),
                control(atmosphere, "clarity"), control(atmosphere, "dehaze"),
                ColorGradingSettings(wheel("shadows"), wheel("midtones"), wheel("highlights")),
                if (version == 4) ToneCurveSettings.decode(row.getJSONObject("curve")) else ToneCurveSettings())
        }
    }
}

/** 选用配方：胶片回到中性，配方自带的曝光、影调、色彩与 HSL 覆盖当前参数 */
fun EditSettings.applyRecipe(recipe: MasterRecipe): EditSettings {
    val applied = copy(film = "neutral", recipeID = recipe.id, strength = 1f, masterRecipeSettingsVersion = recipe.settingsVersion,
        exposure = recipe.exposure, shadows = recipe.shadows, highlights = recipe.highlights,
        contrast = recipe.contrast, saturation = recipe.saturation, tint = recipe.tint, hsl = recipe.hsl)
    return if (recipe.settingsVersion < 4) applied else applied.copy(blackPoint = recipe.blackPoint,
        whitePoint = recipe.whitePoint, vibrance = recipe.vibrance, clarity = recipe.clarity, dehaze = recipe.dehaze,
        colorGrading = recipe.grading, curve = recipe.curve, toneCurve = 0f)
}

// ============================================================================
//  界面显示的配方名与副标题：按 id 查资源的数据表
//  汉字写的人名配方按语言显示，表外的名字本身是拉丁字母；副标题表外退回数据原文
// ============================================================================

private val recipeTitles = mapOf(
    "hamada_daylight_v2" to R.string.recipe_name_hamada_daylight_v2,
    "takashi_yasui_zen" to R.string.recipe_name_takashi_yasui_zen,
    "takahiro_sakai_blue" to R.string.recipe_name_takahiro_sakai_blue,
)

private val recipeSubtitles = mapOf(
    "hamada_daylight_v2" to R.string.recipe_subtitle_hamada_daylight_v2,
    "takashi_yasui_zen" to R.string.recipe_subtitle_takashi_yasui_zen,
    "takahiro_sakai_blue" to R.string.recipe_subtitle_takahiro_sakai_blue,
    "withluke_epic" to R.string.recipe_subtitle_withluke_epic,
    "daniel_casson_autumn" to R.string.recipe_subtitle_daniel_casson_autumn,
    "billy_dinh_cinema" to R.string.recipe_subtitle_billy_dinh_cinema,
    "rkrkrk_cyberpunk" to R.string.recipe_subtitle_rkrkrk_cyberpunk,
    "samalive_vintage" to R.string.recipe_subtitle_samalive_vintage,
    "iwona_fairy_tale" to R.string.recipe_subtitle_iwona_fairy_tale,
    "cinestill_800t" to R.string.recipe_subtitle_cinestill_800t,
    "wilson_lee_golden" to R.string.recipe_subtitle_wilson_lee_golden,
    "luizclas_portrait" to R.string.recipe_subtitle_luizclas_portrait,
    "ivan_ivanchenko_twilight" to R.string.recipe_subtitle_ivan_ivanchenko_twilight,
    "jungraphy_neon" to R.string.recipe_subtitle_jungraphy_neon,
)

val MasterRecipe.localizedName: String get() = recipeTitles[id]?.let(AppStrings::text) ?: name

val MasterRecipe.localizedSubtitle: String get() = recipeSubtitles[id]?.let(AppStrings::text) ?: subtitle
