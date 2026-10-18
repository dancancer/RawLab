package com.rawlab.android.i18n

import org.junit.Assert.assertEquals
import org.junit.Test

class LanguageChoiceTest {
    @Test fun resolvesRegionalSystemLanguage() {
        assertEquals("de", LanguageChoice.resolve("system", listOf("de-DE")))
        assertEquals("es", LanguageChoice.resolve("system", listOf("es-MX")))
        assertEquals("zh-Hans", LanguageChoice.resolve("system", listOf("zh-Hans-CN")))
    }
    @Test fun unsupportedLanguageFallsBackToEnglish() {
        assertEquals("en", LanguageChoice.resolve("system", listOf("pt-BR")))
        assertEquals("en", LanguageChoice.resolve("system", listOf("zh-Hant-TW")))
    }
    @Test fun explicitLanguageOverridesSystem() {
        assertEquals("ja", LanguageChoice.resolve("ja", listOf("fr-FR")))
        assertEquals("fr", LanguageChoice.resolve("invalid", listOf("fr-FR")))
    }
}
