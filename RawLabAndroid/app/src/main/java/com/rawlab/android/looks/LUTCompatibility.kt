package com.rawlab.android.looks

import org.json.JSONObject

data class LUTCompatibility(
    val sourceHash: String, val inputSpace: String, val inputReference: String, val inputRange: String,
    val outputSpace: String, val outputReference: String, val outputRange: String,
    val interpolation: String, val base: String, val fixedContract: Boolean, val photoStyle: String,
    val extremeValues: Boolean, val hasHints: Boolean, val confirmedExtremeValues: Boolean = false,
    val candidates: List<LUTCompatibilityCandidate> = emptyList(),
) : java.io.Serializable {
    val canImport get() = hasCompleteContract && (!extremeValues || confirmedExtremeValues)
    val hasCompleteContract get() = inputSpace.isNotEmpty() && outputSpace.isNotEmpty() &&
        !(inputReference == "display" && outputReference == "scene") &&
        (photoStyle != "std" || inputReference == "display") &&
        (photoStyle != "vlog" || inputSpace == "vlog-vgamut")
    fun withInput(space: String) = copy(inputSpace = space, inputReference = reference(space),
        base = if (reference(space) == "scene") "none" else "rawlab-neutral-v1")
    fun withOutput(space: String) = copy(outputSpace = space, outputReference = reference(space))
    fun supportsPreview(displayInput: Boolean) = hasCompleteContract &&
        if (displayInput) inputReference == "display" && base == "source-display" else base != "source-display"
    fun applying(candidate: LUTCompatibilityCandidate, displayInput: Boolean): LUTCompatibility? {
        val value = JSONObject(candidate.contract)
        val input = value.getJSONObject("input"); val output = value.getJSONObject("output")
        var chosen = copy(inputSpace = input.getString("space"), inputReference = input.getString("reference"), inputRange = input.getString("range"),
            outputSpace = output.getString("space"), outputReference = output.getString("reference"), outputRange = output.getString("range"),
            interpolation = value.getString("interpolation"), base = value.getString("base_rendering"))
        if (displayInput) {
            if (chosen.inputReference != "display" || (fixedContract && chosen.base != "source-display")) return null
            chosen = chosen.copy(base = "source-display")
        } else if (chosen.base == "source-display") return null
        return chosen
    }
    fun contractJSON(): JSONObject = JSONObject().put("version", 1).put("input", signal(inputSpace, inputReference, inputRange))
        .put("output", signal(outputSpace, outputReference, outputRange)).put("interpolation", interpolation).put("base_rendering", base)
    fun previewRequest(): String = JSONObject().put("source_sha256", sourceHash).put("contract", contractJSON()).toString()
    fun previewKey(): String = listOf(inputSpace, inputReference, inputRange, outputSpace, outputReference, outputRange, interpolation, base).joinToString("|")
    fun request(): String {
        require(canImport)
        return JSONObject().put("source_sha256", sourceHash).put("confirmed", true)
            .put("confirmed_extreme_values", confirmedExtremeValues).put("contract", contractJSON()).toString()
    }
    companion object {
        val spaces = listOf("srgb", "rec709-gamma24", "vlog-vgamut", "slog3-sgamut3", "slog3-sgamut3-cine", "linear-srgb")
        private fun reference(space: String) = if (space in listOf("srgb", "rec709-gamma24")) "display" else "scene"
        private fun signal(space: String, reference: String, range: String) = JSONObject().put("space", space).put("reference", reference).put("range", range)
        fun parse(text: String): LUTCompatibility? {
            val info = JSONObject(text)
            if (!info.optBoolean("eligible")) return null
            val contract = info.getJSONObject("contract")
            val input = contract.getJSONObject("input"); val output = contract.getJSONObject("output")
            return LUTCompatibility(info.getString("source_sha256"), input.getString("space"), input.getString("reference"), input.getString("range"),
                output.getString("space"), output.getString("reference"), output.getString("range"), contract.getString("interpolation"),
                contract.getString("base_rendering"), info.getBoolean("fixed_contract"), info.getString("photo_style"),
                info.getBoolean("extreme_values"), info.getJSONArray("hints").length() > 0,
                candidates = info.optJSONArray("candidates")?.let { list -> (0 until list.length()).map { index ->
                    val candidate = list.getJSONObject(index)
                    val assumptions = candidate.optJSONArray("assumptions")
                    LUTCompatibilityCandidate(candidate.getString("id"), candidate.getString("basis"), candidate.getJSONObject("contract").toString(),
                        assumptions?.let { (0 until it.length()).map(it::getString) } ?: emptyList())
                } } ?: emptyList())
        }
    }
}

data class LUTCompatibilityCandidate(val id: String, val basis: String, val contract: String, val assumptions: List<String> = emptyList()) : java.io.Serializable

internal data class LUTPreviewComparison(val mean: Double, val maximum: Double, val candidateBoundary: Double, val referenceBoundary: Double)

data class LUTReferenceConditions(val sameSource: Boolean = false, val sameGeometry: Boolean = false,
    val sameProcessing: Boolean = false, val knownSRGB: Boolean = false, val referenceSource: String = "") : java.io.Serializable {
    val canCompare get() = sameSource && sameGeometry && sameProcessing && knownSRGB &&
        referenceSource.isNotBlank() && referenceSource.toByteArray(Charsets.UTF_8).size <= 2048
    fun json(): String = JSONObject().put("same_source", sameSource).put("same_geometry", sameGeometry)
        .put("same_processing", sameProcessing).put("known_srgb", knownSRGB).put("reference_source", referenceSource).toString()
}
