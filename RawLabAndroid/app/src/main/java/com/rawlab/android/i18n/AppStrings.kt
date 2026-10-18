package com.rawlab.android.i18n

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
}
