package com.rawlab.android

data class EditSettings(
    val film: String = "neutral",
    val strength: Float = 1f,
    val exposure: Float = 0f,
    val customWb: Boolean = false,
    val temperature: Float = 6500f,
    val tint: Float = 0f,
) {
    init {
        require(strength.isFinite() && strength in 0f..2f)
        require(exposure.isFinite() && exposure in -5f..5f)
        require(temperature.isFinite() && temperature in 2000f..50000f)
        require(tint.isFinite() && tint in -150f..150f)
    }
    fun reset() = EditSettings(film = film)
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
