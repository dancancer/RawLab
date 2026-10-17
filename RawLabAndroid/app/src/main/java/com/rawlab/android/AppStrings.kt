package com.rawlab.android

import android.app.Application
import android.app.LocaleManager
import android.content.Context
import android.content.res.Configuration
import android.content.res.Resources
import android.os.Build
import android.os.LocaleList
import java.util.Locale

// ============================================================================
//  界面文字：一律取自 Android 资源，语言跟随应用内选择
//  ViewModel、批量导出、镜头状态等非界面代码没有 Context，借用 Application；
//  它由 RawLabApplication.onCreate 注入，早于任何界面、ViewModel 与测试。
//  未注入就取字是接线错误：直接抛出，绝不悄悄退回某一种语言。
// ============================================================================

internal object AppStrings {
    private lateinit var application: Application
    fun initialize(application: Application) { this.application = application }

    fun preference(context: Context): String {
        if (Build.VERSION.SDK_INT >= 33) {
            val locales = context.getSystemService(LocaleManager::class.java).applicationLocales
            return if (locales.isEmpty) "system" else LanguageChoice.resolve("system", listOf(locales[0].toLanguageTag()))
        }
        return context.getSharedPreferences("language", Context.MODE_PRIVATE).getString("choice", "system") ?: "system"
    }

    fun setPreference(context: Context, preference: String) {
        require(preference in LanguageChoice.codes)
        if (Build.VERSION.SDK_INT >= 33) {
            context.getSystemService(LocaleManager::class.java).applicationLocales =
                if (preference == "system") LocaleList.getEmptyLocaleList() else LocaleList.forLanguageTags(preference)
        } else {
            check(context.getSharedPreferences("language", Context.MODE_PRIVATE).edit().putString("choice", preference).commit())
        }
    }

    fun localizedContext(context: Context): Context {
        val system = Resources.getSystem().configuration.locales
        val language = LanguageChoice.resolve(preference(context), (0 until system.size()).map { system[it].toLanguageTag() })
        val configuration = Configuration(context.resources.configuration)
        configuration.setLocales(LocaleList(Locale.forLanguageTag(language)))
        return context.createConfigurationContext(configuration)
    }

    fun text(id: Int): String = localizedContext(application).getString(id)
    fun format(id: Int, vararg arguments: Any): String = localizedContext(application).getString(id, *arguments)

    fun recipeSubtitle(recipe: MasterRecipe): String {
        val resource = when (recipe.id) {
            "hamada_daylight_v2" -> R.string.recipe_subtitle_hamada_daylight_v2
            "takashi_yasui_zen" -> R.string.recipe_subtitle_takashi_yasui_zen
            "takahiro_sakai_blue" -> R.string.recipe_subtitle_takahiro_sakai_blue
            "withluke_epic" -> R.string.recipe_subtitle_withluke_epic
            "daniel_casson_autumn" -> R.string.recipe_subtitle_daniel_casson_autumn
            "billy_dinh_cinema" -> R.string.recipe_subtitle_billy_dinh_cinema
            "rkrkrk_cyberpunk" -> R.string.recipe_subtitle_rkrkrk_cyberpunk
            "samalive_vintage" -> R.string.recipe_subtitle_samalive_vintage
            "iwona_fairy_tale" -> R.string.recipe_subtitle_iwona_fairy_tale
            "cinestill_800t" -> R.string.recipe_subtitle_cinestill_800t
            "wilson_lee_golden" -> R.string.recipe_subtitle_wilson_lee_golden
            "luizclas_portrait" -> R.string.recipe_subtitle_luizclas_portrait
            "ivan_ivanchenko_twilight" -> R.string.recipe_subtitle_ivan_ivanchenko_twilight
            "jungraphy_neon" -> R.string.recipe_subtitle_jungraphy_neon
            else -> return recipe.subtitle
        }
        return text(resource)
    }
}
