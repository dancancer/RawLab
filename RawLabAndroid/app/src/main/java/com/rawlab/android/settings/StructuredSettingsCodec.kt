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
            .put("x3fMode", s.x3fMode.id)
            .put("exposure", s.exposure).put("exposureMode", s.exposureMode)
            .put("highlights", s.highlights).put("shadows", s.shadows).put("contrast", s.contrast)
            .put("toneCurve", s.toneCurve).put("saturation", s.saturation).put("sharpening", s.sharpening)
            .put("curve", s.curve.json())
            .put("customWb", s.customWb).put("temperature", s.temperature).put("tint", s.tint)
            .put("recipeID", s.recipeID ?: JSONObject.NULL).put("displayChromaDenoise", s.displayChromaDenoise)
            .put("masterRecipeSettingsVersion", s.masterRecipeSettingsVersion)
            .put("hsl", JSONArray(s.hsl.packed().toList()))
            .put("colorGrading", s.colorGrading.json())
            .put("tone", JSONObject().put("blackPoint", s.blackPoint).put("whitePoint", s.whitePoint).put("vibrance", s.vibrance))
            .put("denoise", JSONObject().put("enabled", s.denoise.enabled).put("luma", s.denoise.luma)
                .put("chroma", s.denoise.chroma).put("coarse", s.denoise.coarse))
            .put("effects", with(s.effects) { JSONObject().put("vignetteAmount", vignetteAmount)
                .put("vignetteMidpoint", vignetteMidpoint).put("vignetteRoundness", vignetteRoundness)
                .put("vignetteFeather", vignetteFeather).put("vignetteHighlights", vignetteHighlights)
                .put("grainAmount", grainAmount).put("grainSize", grainSize).put("grainRoughness", grainRoughness) })
            .put("lens", with(s.lens) { JSONObject().put("distortion", distortion).put("tca", tca).put("vignetting", vignetting)
                .put("autoCrop", autoCrop).put("manual", manual).put("profileId", profileId ?: JSONObject.NULL)
                .apply { focalLength?.let { put("focalLength", it) }; cropFactor?.let { put("cropFactor", it) } } })
            .put("geometry", with(s.geometry) { JSONObject().put("cropX", cropX).put("cropY", cropY)
                .put("cropWidth", cropWidth).put("cropHeight", cropHeight).put("quarterTurns", quarterTurns)
                .put("flipHorizontal", flipHorizontal).put("flipVertical", flipVertical)
                .put("straightenDegrees", straightenDegrees).put("perspectiveHorizontal", perspectiveHorizontal)
                .put("perspectiveVertical", perspectiveVertical) })
            .put("processing", JSONObject().put("family", s.processing.family).put("version", s.processing.version)
                .put("quality", s.processing.quality))
        s.hdr?.let { value.put("hdr", hdrJSON(it)) }
        s.sdrSnapshot?.let { value.put("sdrSnapshot", it) }
        s.proRAWDecodeVersion?.let { value.put("proRAWDecodeVersion", it) }
        if (s.clarity != 0f || s.dehaze != 0f) value.put("atmosphere",
            JSONObject().put("clarity", s.clarity).put("dehaze", s.dehaze))
        return "v2:" + JSONObject().put("format", format).put("version", 2).put("settings", value).toString()
    }

    fun decode(encoded: String, format: String): EditSettings {
        require(encoded.startsWith("v2:")) { "Unsupported settings encoding" }
        val json = encoded.removePrefix("v2:")
        validateStrictJSON(json, setOf("version", "masterRecipeSettingsVersion", "exposureMode", "displayChromaDenoise", "quarterTurns", "proRAWDecodeVersion"))
        val root = JSONObject(json).keysExactly("format", "version", "settings")
        require(root.string("format") == format && root.integer("version") == 2) { "Unsupported settings format" }
        val s = root.getJSONObject("settings").keysWithOptional(setOf("colorGrading", "curve", "atmosphere", "masterRecipeSettingsVersion", "hdr", "sdrSnapshot", "x3fMode", "proRAWDecodeVersion"), "film", "strength", "exposure", "exposureMode", "highlights",
            "shadows", "contrast", "toneCurve", "saturation", "sharpening", "customWb", "temperature", "tint",
            "recipeID", "displayChromaDenoise", "hsl", "tone", "denoise", "effects", "lens", "geometry", "processing")
        val atmosphere = if (s.has("atmosphere")) s.getJSONObject("atmosphere").keysExactly("clarity", "dehaze") else null
        val tone = s.getJSONObject("tone").keysExactly("blackPoint", "whitePoint", "vibrance")
        val denoise = s.getJSONObject("denoise").keysExactly("enabled", "luma", "chroma", "coarse")
        val effects = s.getJSONObject("effects").keysExactly("vignetteAmount", "vignetteMidpoint", "vignetteRoundness",
            "vignetteFeather", "vignetteHighlights", "grainAmount", "grainSize", "grainRoughness")
        val lens = s.getJSONObject("lens").keysWithOptional(setOf("focalLength", "cropFactor", "vignetting"), "distortion", "tca", "autoCrop", "manual", "profileId")
        val geometry = s.getJSONObject("geometry").keysExactly("cropX", "cropY", "cropWidth", "cropHeight", "quarterTurns",
            "flipHorizontal", "flipVertical", "straightenDegrees", "perspectiveHorizontal", "perspectiveVertical")
        val processing = s.getJSONObject("processing").keysExactly("family", "version", "quality")
        val hdr = if (s.has("hdr")) decodeHDR(s.getJSONObject("hdr")) else null
        val sdrSnapshot = if (s.has("sdrSnapshot")) s.string("sdrSnapshot") else null
        val hsl = s.getJSONArray("hsl")
        require(hsl.length() == 24)
        return EditSettings(film = s.string("film"), strength = s.number("strength", 0.0..2.0), exposure = s.number("exposure", -5.0..5.0),
            x3fMode = if (s.has("x3fMode")) X3fMode.decode(s.string("x3fMode")) else X3fMode.LEGACY,
            exposureMode = s.integer("exposureMode"), highlights = s.number("highlights", -1.0..1.0), shadows = s.number("shadows", -1.0..1.0),
            contrast = s.number("contrast", -1.0..1.0), toneCurve = s.number("toneCurve", -1.0..1.0), saturation = s.number("saturation", -1.0..1.0),
            sharpening = s.number("sharpening", 0.0..2.0), customWb = s.boolean("customWb"), temperature = s.number("temperature", 2000.0..50000.0),
            tint = s.number("tint", -150.0..150.0), recipeID = s.nullableString("recipeID"), displayChromaDenoise = s.integer("displayChromaDenoise"),
            masterRecipeSettingsVersion = if (s.has("masterRecipeSettingsVersion")) s.integer("masterRecipeSettingsVersion") else 3,
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
                lens.nullableString("profileId"),
                if (lens.has("focalLength")) lens.number("focalLength", 0.1..10000.0) else null,
                if (lens.has("cropFactor")) lens.number("cropFactor", 0.1..100.0) else null,
                if (lens.has("vignetting")) lens.boolean("vignetting") else false),
            geometry = GeometrySettings(geometry.number("cropX", 0.0..1.0), geometry.number("cropY", 0.0..1.0), geometry.number("cropWidth", 0.0..1.0),
                geometry.number("cropHeight", 0.0..1.0), geometry.integer("quarterTurns"), geometry.boolean("flipHorizontal"),
                geometry.boolean("flipVertical"), geometry.number("straightenDegrees", -45.0..45.0), geometry.number("perspectiveHorizontal", -1.0..1.0),
                geometry.number("perspectiveVertical", -1.0..1.0)),
            processing = ProcessingIdentity(processing.string("family"), processing.integer("version"), processing.string("quality")),
            hdr = hdr, sdrSnapshot = sdrSnapshot,
            proRAWDecodeVersion = if (s.has("proRAWDecodeVersion")) s.integer("proRAWDecodeVersion") else null)
    }

    private fun hdrJSON(value: HDRSettings): JSONObject = JSONObject()
        .put("mode", value.mode.name.lowercase())
        .put("record_version", value.recordVersion)
        .put("hdr_processing_version", value.processingVersion)
        .put("exposure_ev", value.exposure).put("relative_temperature", value.temperature).put("relative_tint", value.tint)
        .put("contrast", value.contrast).put("highlights", value.highlights).put("shadows", value.shadows)
        .put("saturation", value.saturation)
        .put("geometry", with(value.geometry) { JSONObject().put("cropX", cropX).put("cropY", cropY)
            .put("cropWidth", cropWidth).put("cropHeight", cropHeight).put("quarterTurns", quarterTurns)
            .put("flipHorizontal", flipHorizontal).put("flipVertical", flipVertical)
            .put("straightenDegrees", straightenDegrees).put("perspectiveHorizontal", perspectiveHorizontal)
            .put("perspectiveVertical", perspectiveVertical) })
        .apply { value.tone?.let { tone ->
            put("tone", JSONObject().put("black_point", tone.blackPoint).put("white_point", tone.whitePoint)
                .put("curve_strength", tone.curveStrength).put("curve", tone.curve.json()))
        } }
        .apply { value.color?.let { color ->
            val hsl = color.hsl.packed()
            put("color", JSONObject().put("vibrance", color.vibrance)
                .put("hsl", JSONObject().put("hue", JSONArray(hsl.slice(0..7)))
                    .put("saturation", JSONArray(hsl.slice(8..15))).put("lightness", JSONArray(hsl.slice(16..23))))
                .put("grading", color.grading.json()))
        } }
        .apply { value.rendition?.let { rendition ->
            put("rendition", JSONObject().put("peak_limit_ev", rendition.peakLimitEV)
                .put("sdr_exposure_ev", rendition.sdrExposureEV).put("sdr_contrast", rendition.sdrContrast)
                .put("sdr_saturation", rendition.sdrSaturation))
        } }
        .apply { value.effects?.let { fx ->
            put("effects", JSONObject().put("vignette_amount", fx.vignetteAmount).put("vignette_midpoint", fx.vignetteMidpoint)
                .put("vignette_roundness", fx.vignetteRoundness).put("vignette_feather", fx.vignetteFeather)
                .put("vignette_highlights", fx.vignetteHighlights).put("grain_amount", fx.grainAmount)
                .put("grain_size", fx.grainSize).put("grain_roughness", fx.grainRoughness))
        } }
        .apply { value.detail?.let { detail ->
            put("detail", JSONObject().put("sharpening", detail.sharpening).put("clarity", detail.clarity)
                .put("dehaze", detail.dehaze).put("denoise", detail.denoise))
        } }
        .apply { value.look?.let { look ->
            put("look", JSONObject().put("sha256", look.sha256 ?: JSONObject.NULL)
                .put("name", look.name ?: JSONObject.NULL).put("strength", look.strength))
        } }
        .apply { value.cameraDevelopment?.let { camera ->
            put("camera_development", JSONObject().put("version", 1)
                .put("white_balance_mode", if (camera.customWhiteBalance) "temperature" else "as_shot")
                .put("temperature", camera.temperature).put("tint", camera.tint)
                .put("exposure_reference", if (camera.sensorExposure) "sensor" else "metadata")
                .put("fbdd_level", camera.fbddLevel).put("lens_distortion", camera.lensDistortion)
                .put("lens_tca", camera.lensTca).put("lens_vignetting", camera.lensVignetting).put("lens_auto_crop", camera.lensAutoCrop)
                .put("lens_profile", camera.lensProfile)
                .put("camera_profile", camera.cameraProfile?.let {
                    JSONObject().put("sha256", it.sha256).put("name", it.name)
                }))
        } }

    private fun decodeHDR(value: JSONObject): HDRSettings {
        value.keysWithOptional(setOf("tone", "color", "rendition", "effects", "detail", "look", "camera_development"), "record_version", "hdr_processing_version", "mode", "exposure_ev",
            "relative_temperature", "relative_tint", "contrast", "highlights", "shadows", "saturation", "geometry")
        val tone = if (value.has("tone")) {
            val fields = value.getJSONObject("tone").keysExactly("black_point", "white_point", "curve_strength", "curve")
            HDRToneSettings(fields.number("black_point", -100.0..100.0), fields.number("white_point", -100.0..100.0),
                fields.number("curve_strength", -100.0..100.0), ToneCurveSettings.decode(fields.getJSONObject("curve")))
        } else null
        val color = if (value.has("color")) {
            require(tone != null)
            val fields = value.getJSONObject("color").keysExactly("vibrance", "hsl", "grading")
            val hsl = fields.getJSONObject("hsl").keysExactly("hue", "saturation", "lightness")
            val channels = listOf("hue", "saturation", "lightness").flatMap { name ->
                val axis = hsl.getJSONArray(name)
                require(axis.length() == 8)
                List(8) { number(axis.get(it), -100.0..100.0) }
            }
            HDRColorSettings(fields.number("vibrance", -100.0..100.0), HslSettings(channels),
                grading(fields.getJSONObject("grading")))
        } else null
        val rendition = if (value.has("rendition")) {
            require(color != null)
            val fields = value.getJSONObject("rendition")
                .keysExactly("peak_limit_ev", "sdr_exposure_ev", "sdr_contrast", "sdr_saturation")
            HDRRenditionSettings(fields.number("peak_limit_ev", 0.0..6.0), fields.number("sdr_exposure_ev", -4.0..4.0),
                fields.number("sdr_contrast", -100.0..100.0), fields.number("sdr_saturation", -100.0..100.0))
        } else null
        val effects = if (value.has("effects")) {
            require(rendition != null)
            val fields = value.getJSONObject("effects").keysExactly("vignette_amount", "vignette_midpoint",
                "vignette_roundness", "vignette_feather", "vignette_highlights", "grain_amount", "grain_size", "grain_roughness")
            PhotoEffectsSettings(fields.number("vignette_amount", -100.0..100.0), fields.number("vignette_midpoint", 0.0..100.0),
                fields.number("vignette_roundness", -100.0..100.0), fields.number("vignette_feather", 0.0..100.0),
                fields.number("vignette_highlights", 0.0..100.0), fields.number("grain_amount", 0.0..100.0),
                fields.number("grain_size", 0.0..100.0), fields.number("grain_roughness", 0.0..100.0))
        } else null
        val version = when {
            tone?.curve?.hasChannelCurves == true -> 8
            value.has("look") -> 7
            value.has("detail") -> 6
            effects != null -> 5
            rendition != null -> 4
            color != null -> 3
            tone != null -> 2
            else -> 1
        }
        val detail = if (version >= 6) {
            require(effects != null)
            val fields = value.getJSONObject("detail").keysExactly("sharpening", "clarity", "dehaze", "denoise")
            HDRDetailSettings(fields.number("sharpening", 0.0..2.0), fields.number("clarity", -1.0..1.0),
                fields.number("dehaze", -1.0..1.0), fields.number("denoise", 0.0..1.0))
        } else null
        val look = if (version >= 7) {
            val fields = value.getJSONObject("look").keysExactly("sha256", "name", "strength")
            HDRLookSettings(if (fields.isNull("sha256")) null else fields.string("sha256"),
                if (fields.isNull("name")) null else fields.string("name"), fields.number("strength", 0.0..2.0))
        } else null
        val camera = if (value.has("camera_development")) decodeHDRCamera(value.getJSONObject("camera_development")) else null
        require(value.integer("record_version") == (if (version == 8) 9 else if (camera == null) version else 8) && value.integer("hdr_processing_version") == version) {
            "Unsupported HDR settings version"
        }
        val geometry = value.getJSONObject("geometry").keysExactly("cropX", "cropY", "cropWidth", "cropHeight", "quarterTurns",
            "flipHorizontal", "flipVertical", "straightenDegrees", "perspectiveHorizontal", "perspectiveVertical")
        val mode = when (value.string("mode")) {
            "hdr" -> HDRMode.HDR
            "sdr" -> HDRMode.SDR
            else -> throw IllegalArgumentException("Unsupported HDR mode")
        }
        return HDRSettings(mode = mode, tone = tone, color = color, rendition = rendition, effects = effects, detail = detail, look = look,
            cameraDevelopment = camera,
            exposure = value.number("exposure_ev", -4.0..4.0), temperature = value.number("relative_temperature", 2000.0..50000.0),
            tint = value.number("relative_tint", -150.0..150.0), contrast = value.number("contrast", -100.0..100.0),
            highlights = value.number("highlights", -100.0..100.0), shadows = value.number("shadows", -100.0..100.0),
            saturation = value.number("saturation", -100.0..100.0), geometry = GeometrySettings(
                geometry.number("cropX", 0.0..1.0), geometry.number("cropY", 0.0..1.0), geometry.number("cropWidth", 0.0..1.0),
                geometry.number("cropHeight", 0.0..1.0), geometry.integer("quarterTurns"), geometry.boolean("flipHorizontal"),
                geometry.boolean("flipVertical"), geometry.number("straightenDegrees", -45.0..45.0),
                geometry.number("perspectiveHorizontal", -1.0..1.0), geometry.number("perspectiveVertical", -1.0..1.0)))
    }

    private fun decodeHDRCamera(value: JSONObject): HDRCameraDevelopmentSettings {
        value.keysWithOptional(setOf("lens_profile", "camera_profile", "lens_vignetting"), "version", "white_balance_mode", "temperature", "tint",
            "exposure_reference", "fbdd_level", "lens_distortion", "lens_tca", "lens_auto_crop")
        require(value.integer("version") == 1)
        val custom = when (value.string("white_balance_mode")) {
            "as_shot" -> false
            "temperature" -> true
            else -> error("Unknown camera RAW white balance")
        }
        val sensor = when (value.string("exposure_reference")) {
            "metadata" -> false
            "sensor" -> true
            else -> error("Unknown camera RAW exposure reference")
        }
        val profile = if (value.has("camera_profile")) value.getJSONObject("camera_profile").let {
            it.keysExactly("sha256", "name")
            HDRCameraProfile(it.string("sha256"), it.string("name"))
        } else null
        return HDRCameraDevelopmentSettings(custom, value.number("temperature", 0.0..50000.0),
            value.number("tint", -150.0..150.0), sensor, value.integer("fbdd_level"),
            value.boolean("lens_distortion"), value.boolean("lens_tca"), value.boolean("lens_auto_crop"),
            if (value.isNull("lens_profile")) null else value.string("lens_profile"), profile,
            if (value.has("lens_vignetting")) value.boolean("lens_vignetting") else false)
    }

    private fun ColorGradingSettings.json() = JSONObject().also { grading ->
        ColorGradingZone.entries.forEach { zone ->
            grading.put(zone.id, JSONObject().put("hue", this[zone].hue).put("saturation", this[zone].saturation))
        }
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
