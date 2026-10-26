package com.rawlab.android.settings

import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.json.validateStrictJSON
import org.json.JSONArray
import org.json.JSONObject

/** 本端照片与 batch 各自标识格式；不复用选择性 transfer payload 的版本。 */
internal object StructuredSettingsCodec {
    fun encode(s: EditSettings, format: String): String {
        require(format in setOf("photo_edit", "batch_settings"))
        val value = JSONObject().put("film", s.film).put("strength", s.strength)
            .put("exposure", s.exposure).put("exposureMode", s.exposureMode)
            .put("highlights", s.highlights).put("shadows", s.shadows).put("contrast", s.contrast)
            .put("toneCurve", s.toneCurve).put("saturation", s.saturation).put("sharpening", s.sharpening)
            .put("curve", s.curve.json())
            .put("customWb", s.customWb).put("temperature", s.temperature).put("tint", s.tint)
            .put("recipeID", s.recipeID ?: JSONObject.NULL).put("displayChromaDenoise", s.displayChromaDenoise)
            .put("hsl", JSONArray(s.hsl.packed().toList()))
            .put("colorGrading", JSONObject().also { grading ->
                ColorGradingZone.entries.forEach { zone -> grading.put(zone.id,
                    JSONObject().put("hue", s.colorGrading[zone].hue).put("saturation", s.colorGrading[zone].saturation)) }
            })
            .put("tone", JSONObject().put("blackPoint", s.blackPoint).put("whitePoint", s.whitePoint).put("vibrance", s.vibrance))
            .put("denoise", JSONObject().put("enabled", s.denoise.enabled).put("luma", s.denoise.luma)
                .put("chroma", s.denoise.chroma).put("coarse", s.denoise.coarse))
            .put("effects", with(s.effects) { JSONObject().put("vignetteAmount", vignetteAmount)
                .put("vignetteMidpoint", vignetteMidpoint).put("vignetteRoundness", vignetteRoundness)
                .put("vignetteFeather", vignetteFeather).put("vignetteHighlights", vignetteHighlights)
                .put("grainAmount", grainAmount).put("grainSize", grainSize).put("grainRoughness", grainRoughness) })
            .put("lens", with(s.lens) { JSONObject().put("distortion", distortion).put("tca", tca)
                .put("autoCrop", autoCrop).put("manual", manual).put("profileId", profileId ?: JSONObject.NULL) })
            .put("geometry", with(s.geometry) { JSONObject().put("cropX", cropX).put("cropY", cropY)
                .put("cropWidth", cropWidth).put("cropHeight", cropHeight).put("quarterTurns", quarterTurns)
                .put("flipHorizontal", flipHorizontal).put("flipVertical", flipVertical)
                .put("straightenDegrees", straightenDegrees).put("perspectiveHorizontal", perspectiveHorizontal)
                .put("perspectiveVertical", perspectiveVertical) })
            .put("processing", JSONObject().put("family", s.processing.family).put("version", s.processing.version)
                .put("quality", s.processing.quality))
        if (s.clarity != 0f || s.dehaze != 0f) value.put("atmosphere",
            JSONObject().put("clarity", s.clarity).put("dehaze", s.dehaze))
        return "v2:" + JSONObject().put("format", format).put("version", 2).put("settings", value).toString()
    }

    fun decode(encoded: String, format: String): EditSettings {
        require(encoded.startsWith("v2:")) { "Unsupported settings encoding" }
        val json = encoded.removePrefix("v2:")
        validateStrictJSON(json, setOf("version", "exposureMode", "displayChromaDenoise", "quarterTurns"))
        val root = JSONObject(json).keysExactly("format", "version", "settings")
        require(root.string("format") == format && root.integer("version") == 2) { "Unsupported settings format" }
        val s = root.getJSONObject("settings").keysWithOptional(setOf("colorGrading", "curve", "atmosphere"), "film", "strength", "exposure", "exposureMode", "highlights",
            "shadows", "contrast", "toneCurve", "saturation", "sharpening", "customWb", "temperature", "tint",
            "recipeID", "displayChromaDenoise", "hsl", "tone", "denoise", "effects", "lens", "geometry", "processing")
        val atmosphere = if (s.has("atmosphere")) s.getJSONObject("atmosphere").keysExactly("clarity", "dehaze") else null
        val tone = s.getJSONObject("tone").keysExactly("blackPoint", "whitePoint", "vibrance")
        val denoise = s.getJSONObject("denoise").keysExactly("enabled", "luma", "chroma", "coarse")
        val effects = s.getJSONObject("effects").keysExactly("vignetteAmount", "vignetteMidpoint", "vignetteRoundness",
            "vignetteFeather", "vignetteHighlights", "grainAmount", "grainSize", "grainRoughness")
        val lens = s.getJSONObject("lens").keysExactly("distortion", "tca", "autoCrop", "manual", "profileId")
        val geometry = s.getJSONObject("geometry").keysExactly("cropX", "cropY", "cropWidth", "cropHeight", "quarterTurns",
            "flipHorizontal", "flipVertical", "straightenDegrees", "perspectiveHorizontal", "perspectiveVertical")
        val processing = s.getJSONObject("processing").keysExactly("family", "version", "quality")
        val hsl = s.getJSONArray("hsl")
        require(hsl.length() == 24)
        return EditSettings(film = s.string("film"), strength = s.number("strength", 0.0..2.0), exposure = s.number("exposure", -4.0..4.0),
            exposureMode = s.integer("exposureMode"), highlights = s.number("highlights", -1.0..1.0), shadows = s.number("shadows", -1.0..1.0),
            contrast = s.number("contrast", -1.0..1.0), toneCurve = s.number("toneCurve", -1.0..1.0), saturation = s.number("saturation", -1.0..1.0),
            sharpening = s.number("sharpening", 0.0..2.0), customWb = s.boolean("customWb"), temperature = s.number("temperature", 2000.0..50000.0),
            tint = s.number("tint", -150.0..150.0), recipeID = s.nullableString("recipeID"), displayChromaDenoise = s.integer("displayChromaDenoise"),
            blackPoint = tone.number("blackPoint", -100.0..100.0), whitePoint = tone.number("whitePoint", -100.0..100.0), vibrance = tone.number("vibrance", -100.0..100.0),
            clarity = atmosphere?.number("clarity", -100.0..100.0) ?: 0f, dehaze = atmosphere?.number("dehaze", -100.0..100.0) ?: 0f,
            colorGrading = if (s.has("colorGrading")) grading(s.getJSONObject("colorGrading")) else ColorGradingSettings(),
            curve = if (s.has("curve")) ToneCurveSettings.decode(s.getJSONObject("curve")) else ToneCurveSettings(),
            hsl = HslSettings((0 until hsl.length()).map { number(hsl.get(it), -100.0..100.0) }),
            denoise = DenoiseSettings(denoise.boolean("enabled"), denoise.number("luma", 0.0..100.0), denoise.number("chroma", 0.0..100.0), denoise.number("coarse", 0.0..100.0)),
            effects = PhotoEffectsSettings(effects.number("vignetteAmount", -100.0..100.0), effects.number("vignetteMidpoint", 0.0..100.0),
                effects.number("vignetteRoundness", -100.0..100.0), effects.number("vignetteFeather", 0.0..100.0), effects.number("vignetteHighlights", 0.0..100.0),
                effects.number("grainAmount", 0.0..100.0), effects.number("grainSize", 0.0..100.0), effects.number("grainRoughness", 0.0..100.0)),
            lens = LensSettings(lens.boolean("distortion"), lens.boolean("tca"), lens.boolean("autoCrop"), lens.boolean("manual"),
                lens.nullableString("profileId")),
            geometry = GeometrySettings(geometry.number("cropX", 0.0..1.0), geometry.number("cropY", 0.0..1.0), geometry.number("cropWidth", 0.0..1.0),
                geometry.number("cropHeight", 0.0..1.0), geometry.integer("quarterTurns"), geometry.boolean("flipHorizontal"),
                geometry.boolean("flipVertical"), geometry.number("straightenDegrees", -45.0..45.0), geometry.number("perspectiveHorizontal", -1.0..1.0),
                geometry.number("perspectiveVertical", -1.0..1.0)),
            processing = ProcessingIdentity(processing.string("family"), processing.integer("version"), processing.string("quality")))
    }

    private fun grading(json: JSONObject): ColorGradingSettings {
        json.keysExactly("shadows", "midtones", "highlights")
        return ColorGradingZone.entries.fold(ColorGradingSettings()) { result, zone ->
            val wheel = json.getJSONObject(zone.id).keysExactly("hue", "saturation")
            val hue = wheel.get("hue"); val saturation = wheel.get("saturation")
            require(hue is Number && saturation is Number)
            result.with(zone, ColorGradingWheel.fromNumbers(hue.toDouble(), saturation.toDouble()))
        }
    }
    private fun JSONObject.keysWithOptional(optional: Set<String>, vararg required: String): JSONObject = apply {
        val actual = keys().asSequence().toSet()
        require(actual.containsAll(required.toSet()) && (required.toSet() + optional).containsAll(actual)) { "Unknown or missing settings field" }
    }
    private fun JSONObject.keysExactly(vararg expected: String): JSONObject = apply {
        require(keys().asSequence().toSet() == expected.toSet()) { "Unknown or missing settings field" }
    }
    private fun JSONObject.string(key: String) = get(key).also { require(it is String) } as String
    private fun JSONObject.nullableString(key: String): String? = if (isNull(key)) null else string(key)
    private fun JSONObject.boolean(key: String) = get(key).also { require(it is Boolean) } as Boolean
    private fun JSONObject.number(key: String, range: ClosedFloatingPointRange<Double>) = number(get(key), range)
    private fun number(value: Any, range: ClosedFloatingPointRange<Double>): Float {
        require(value is Number && value.toDouble().isFinite() && value.toDouble() in range)
        return value.toFloat().canonicalZero().also { require(it.isFinite()) }
    }
    private fun JSONObject.integer(key: String): Int {
        val value = get(key)
        require(value is Number && value.toDouble().isFinite() && value.toDouble() == value.toInt().toDouble())
        return value.toInt()
    }
}
