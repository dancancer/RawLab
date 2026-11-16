package com.rawlab.android.testing

import android.content.res.Configuration
import android.os.LocaleList
import java.util.Locale

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
