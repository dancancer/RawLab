package com.rawlab.android.i18n

internal object LanguageChoice {
    val codes = listOf("system", "zh-Hans", "en", "de", "fr", "ja", "es")
    val nativeNames = listOf("", "简体中文", "English", "Deutsch", "Français", "日本語", "Español")

    fun resolve(preference: String, preferredLanguages: List<String>): String {
        if (preference in codes && preference != "system") return preference
        for (identifier in preferredLanguages) {
            val parts = identifier.replace('_', '-').lowercase().split('-')
            if (parts.first() == "zh") {
                if (parts.any { it in listOf("hant", "tw", "hk", "mo") }) continue
                return "zh-Hans"
            }
            if (parts.first() in codes && parts.first() != "system") return parts.first()
        }
        return "en"
    }
}
