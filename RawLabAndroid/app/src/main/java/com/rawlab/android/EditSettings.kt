package com.rawlab.android

data class EditSettings(
    val film: String = "neutral",
    val strength: Float = 1f,
    val exposure: Float = 0f,
    val customWb: Boolean = false,
    val temperature: Float = 6500f,
    val tint: Float = 0f,
    val denoise: DenoiseSettings = DenoiseSettings(),
) {
    init {
        require(strength.isFinite() && strength in 0f..2f)
        require(exposure.isFinite() && exposure in -5f..5f)
        require(temperature.isFinite() && temperature in 2000f..50000f)
        require(tint.isFinite() && tint in -150f..150f)
    }
    fun reset() = EditSettings(film = film)
}

enum class DenoisePreset { DETAIL, CLEAN, CUSTOM }

data class DenoiseSettings(val enabled: Boolean = false, val luma: Float = 0f,
    val chroma: Float = 46f, val coarse: Float = 50f) {
    init { require(listOf(luma, chroma, coarse).all { it.isFinite() && it in 0f..100f }) }
    val preset: DenoisePreset get() = when {
        luma == 0f && chroma == 46f && coarse == 50f -> DenoisePreset.DETAIL
        luma == 10f && chroma == 72f && coarse == 100f -> DenoisePreset.CLEAN
        else -> DenoisePreset.CUSTOM
    }
    fun withPreset(value: DenoisePreset) = when (value) {
        DenoisePreset.DETAIL -> DenoiseSettings(enabled = true)
        DenoisePreset.CLEAN -> DenoiseSettings(true, 10f, 72f, 100f)
        DenoisePreset.CUSTOM -> this
    }
}

data class Film(val id: String, val name: String, val file: String?) {
    companion object {
        val all = listOf(
            Film("neutral", "中性", null),
            Film("provia", "PROVIA", "PROVIA"), Film("velvia", "Velvia", "Velvia"),
            Film("astia", "ASTIA", "ASTIA"), Film("classic-chrome", "CLASSIC CHROME", "CLASSIC-CHROME"),
            Film("classic-neg", "CLASSIC Neg.", "CLASSIC-Neg."), Film("reala-ace", "REALA ACE", "REALA-ACE"),
            Film("pro-neg-std", "PRO Neg. Std", "PRO-Neg.Std"), Film("eterna", "ETERNA", "ETERNA"),
            Film("eterna-bb", "ETERNA BLEACH BYPASS", "ETERNA-BB"), Film("acros", "ACROS", "ACROS"),
        )
    }
}

data class LookChoice(val id: String, val name: String, val managed: Boolean, val available: Boolean = true) {
    companion object {
        val builtIns = Film.all.map { Film(it.id, it.name, it.file).toChoice() }

        private fun Film.toChoice() = LookChoice(id, name, managed = false)
    }
}
