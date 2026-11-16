package com.rawlab.android.testing

import android.content.res.Configuration
import android.content.Context
import android.os.LocaleList
import java.util.Locale
import com.rawlab.android.R

fun localizedTestConfiguration(source: Configuration, language: String, scale: Float = source.fontScale): Configuration {
    val requested = Locale.forLanguageTag(language)
    return Configuration(source).apply {
        setLocales(LocaleList(requested))
        // 同步旧字段，避免复制的配置在设备上重新解析成源语言，产生多语言假绿。
        @Suppress("DEPRECATION")
        locale = requested
        fontScale = scale
        check(locales[0].language == requested.language) { "Requested $language but resolved $locales" }
    }
}

fun localizedTestContext(base: Context, language: String, scale: Float = base.resources.configuration.fontScale): Context {
    val localized = base.createConfigurationContext(localizedTestConfiguration(base.resources.configuration, language, scale))
    val expected = mapOf("zh-Hans" to "语言", "en" to "Language", "de" to "Sprache",
        "fr" to "Langue", "ja" to "言語", "es" to "Idioma").getValue(language)
    check(localized.resources.getString(R.string.language) == expected) {
        "Requested $language but resource language is ${localized.resources.getString(R.string.language)}"
    }
    return localized
}
