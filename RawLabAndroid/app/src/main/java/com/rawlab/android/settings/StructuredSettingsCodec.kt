package com.rawlab.android.settings

import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.json.parseStrictJSONObject
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
                .put("grainAmount", grainAmount).put("grainSize", grainSize).put("grainRoughness", grainRoughness)
                .apply {
                    if (grainToneCurve != GrainToneCurve.LEGACY) put("grainToneCurve", grainToneCurve.wireValue)
                    if (grainFormatPreset != GrainFormatPreset.CUSTOM) put("grainFormatPreset", grainFormatPreset.wireValue)
                } })
            .put("lens", with(s.lens) { JSONObject().put("distortion", distortion).put("tca", tca).put("vignetting", vignetting)
                .put("autoCrop", autoCrop).put("manual", manual).put("profileId", profileId ?: JSONObject.NULL)
                .apply {
                    focalLength?.let { put("focalLength", it) }
                    cropFactor?.let { put("cropFactor", it) }
                    if (hasDefringe) {
                        put("defringePurpleAmount", defringePurpleAmount).put("defringePurpleHue", defringePurpleHue)
                        put("defringeGreenAmount", defringeGreenAmount).put("defringeGreenHue", defringeGreenHue)
                    }
                } })
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
        if (s.clarity != 0f || s.dehaze != 0f || s.texture != 0f) value.put("atmosphere",
            JSONObject().put("clarity", s.clarity).put("dehaze", s.dehaze)
                .apply { if (s.texture != 0f) put("texture", s.texture) })
        if (!s.calibration.isDefault) value.put("cameraCalibration", with(s.calibration) {
            JSONObject().put("shadowTint", shadowTint).put("redHue", redHue).put("redSaturation", redSaturation)
                .put("greenHue", greenHue).put("greenSaturation", greenSaturation)
                .put("blueHue", blueHue).put("blueSaturation", blueSaturation)
        })
        if (!s.pointColor.isDefault) value.put("pointColor", JSONObject().put("swatches", JSONArray(s.pointColor.swatches.map { sw ->
            JSONObject().put("srcHue", sw.srcHue).put("srcSaturation", sw.srcSaturation).put("srcLuminance", sw.srcLuminance)
                .put("hueShift", sw.hueShift).put("saturationShift", sw.saturationShift).put("luminanceShift", sw.luminanceShift)
                .put("range", sw.range).put("hueRange", sw.hueRange).put("satRange", sw.satRange).put("lumRange", sw.lumRange)
                .put("variance", sw.variance).put("enabled", sw.enabled)
        })))
        if (!s.selectiveColor.isDefault) value.put("selectiveColor", JSONObject().put("method", s.selectiveColor.method.wireValue)
            .put("bands", JSONObject().apply {
                s.selectiveColor.bands.asMap().forEach { (name, b) ->
                    put(name, JSONObject().put("cyan", b.cyan).put("magenta", b.magenta).put("yellow", b.yellow).put("black", b.black))
                }
            }))
        if (!s.bwMixer.isDefault) value.put("bwMixer", JSONObject().put("enabled", s.bwMixer.enabled)
            .put("mixer", JSONObject().apply { s.bwMixer.mixer.asMap().forEach { (k, v) -> put(k, v) } }))
        if (!s.sharpenV2.isDefault) value.put("sharpenV2", with(s.sharpenV2) {
            JSONObject().put("luminanceV2", luminanceV2).put("radius", radius).put("detail", detail).put("masking", masking)
        })
        if (!s.filmOptics.isDefault) value.put("filmOptics", with(s.filmOptics) {
            JSONObject().put("halationAmount", halationAmount).put("halationThreshold", halationThreshold)
                .put("halationRadius", halationRadius).put("halationHue", halationHue)
                .put("bloomAmount", bloomAmount).put("bloomThreshold", bloomThreshold).put("bloomRadius", bloomRadius)
        })
        return "v3:" + JSONObject().put("format", format).put("version", 3).put("settings", value).toString()
    }

    fun decode(encoded: String, format: String): EditSettings {
        val version = when {
            encoded.startsWith("v3:") -> 3
            encoded.startsWith("v2:") -> 2
            else -> throw IllegalArgumentException("Unsupported settings encoding")
        }
        val json = encoded.removePrefix("v$version:")
        val root = parseStrictJSONObject(json, setOf("version", "masterRecipeSettingsVersion", "exposureMode", "displayChromaDenoise", "quarterTurns", "proRAWDecodeVersion"))
            .keysExactly("format", "version", "settings")
        require(root.string("format") == format && root.integer("version") == version) { "Unsupported settings format" }
        val s = root.getJSONObject("settings").keysWithOptional(
            setOf("colorGrading", "curve", "atmosphere", "masterRecipeSettingsVersion", "hdr", "sdrSnapshot", "x3fMode", "proRAWDecodeVersion",
                "cameraCalibration", "pointColor", "selectiveColor", "bwMixer", "sharpenV2", "filmOptics"),
            "film", "strength", "exposure", "exposureMode", "highlights",
            "shadows", "contrast", "toneCurve", "saturation", "sharpening", "customWb", "temperature", "tint",
            "recipeID", "displayChromaDenoise", "hsl", "tone", "denoise", "effects", "lens", "geometry", "processing")
        val atmosphere = if (s.has("atmosphere")) s.getJSONObject("atmosphere").keysWithOptional(setOf("texture"), "clarity", "dehaze") else null
        val tone = s.getJSONObject("tone").keysExactly("blackPoint", "whitePoint", "vibrance")
        val denoise = s.getJSONObject("denoise").keysExactly("enabled", "luma", "chroma", "coarse")
        val effects = s.getJSONObject("effects").keysWithOptional(setOf("grainToneCurve", "grainFormatPreset"),
            "vignetteAmount", "vignetteMidpoint", "vignetteRoundness",
            "vignetteFeather", "vignetteHighlights", "grainAmount", "grainSize", "grainRoughness")
        val lens = s.getJSONObject("lens").keysWithOptional(
            setOf("focalLength", "cropFactor", "vignetting",
                "defringePurpleAmount", "defringePurpleHue", "defringeGreenAmount", "defringeGreenHue"),
            "distortion", "tca", "autoCrop", "manual", "profileId")
        val geometry = s.getJSONObject("geometry").keysExactly("cropX", "cropY", "cropWidth", "cropHeight", "quarterTurns",
            "flipHorizontal", "flipVertical", "straightenDegrees", "perspectiveHorizontal", "perspectiveVertical")
        val processing = s.getJSONObject("processing").keysExactly("family", "version", "quality")
        val hdr = if (s.has("hdr")) decodeHDR(s.getJSONObject("hdr")) else null
        val sdrSnapshot = if (s.has("sdrSnapshot")) s.string("sdrSnapshot") else null
        val hsl = s.getJSONArray("hsl")
        require(hsl.length() == 24)
        return EditSettings(film = s.string("film"), strength = s.number("strength", 0.0..2.0), exposure = s.number("exposure", -5.0..5.0),
            x3fMode = if (s.has("x3fMode")) X3fMode.decode(s.string("x3fMode")) else X3fMode.LEGACY,
            exposureMode = s.integer("exposureMode"),
            highlights = if (version == 2) (-s.number("highlights", -1.0..1.0)).canonicalZero() else s.number("highlights", -1.0..1.0),
            shadows = s.number("shadows", -1.0..1.0),
            contrast = if (version == 2) 1f + s.number("contrast", -1.0..1.0) else s.number("contrast", 0.0..2.0),
            toneCurve = s.number("toneCurve", -1.0..1.0),
            saturation = if (version == 2) 1f + s.number("saturation", -1.0..1.0) else s.number("saturation", 0.0..2.0),
            sharpening = s.number("sharpening", 0.0..2.0), customWb = s.boolean("customWb"), temperature = s.number("temperature", 2000.0..50000.0),
            tint = s.number("tint", -150.0..150.0), recipeID = s.nullableString("recipeID"), displayChromaDenoise = s.integer("displayChromaDenoise"),
            masterRecipeSettingsVersion = if (s.has("masterRecipeSettingsVersion")) s.integer("masterRecipeSettingsVersion") else 3,
            blackPoint = tone.number("blackPoint", -100.0..100.0), whitePoint = tone.number("whitePoint", -100.0..100.0), vibrance = tone.number("vibrance", -100.0..100.0),
            clarity = atmosphere?.number("clarity", -100.0..100.0) ?: 0f, dehaze = atmosphere?.number("dehaze", -100.0..100.0) ?: 0f,
            texture = if (atmosphere?.has("texture") == true) atmosphere.number("texture", -100.0..100.0) else 0f,
            calibration = decodeCalibration(s),
            pointColor = decodePointColor(s),
            selectiveColor = decodeSelectiveColor(s),
            bwMixer = decodeBwMixer(s),
            sharpenV2 = decodeSharpenV2(s),
            filmOptics = decodeFilmOptics(s),
            colorGrading = if (s.has("colorGrading")) grading(s.getJSONObject("colorGrading")) else ColorGradingSettings(),
            curve = if (s.has("curve")) ToneCurveSettings.decode(s.getJSONObject("curve")) else ToneCurveSettings(),
            hsl = HslSettings((0 until hsl.length()).map { number(hsl.get(it), -100.0..100.0) }),
            denoise = DenoiseSettings(denoise.boolean("enabled"), denoise.number("luma", 0.0..100.0), denoise.number("chroma", 0.0..100.0), denoise.number("coarse", 0.0..100.0)),
            effects = PhotoEffectsSettings(effects.number("vignetteAmount", -100.0..100.0), effects.number("vignetteMidpoint", 0.0..100.0),
                effects.number("vignetteRoundness", -100.0..100.0), effects.number("vignetteFeather", 0.0..100.0), effects.number("vignetteHighlights", 0.0..100.0),
                effects.number("grainAmount", 0.0..100.0), effects.number("grainSize", 0.0..100.0), effects.number("grainRoughness", 0.0..100.0),
                grainToneCurve = if (effects.has("grainToneCurve")) GrainToneCurve.fromWire(effects.string("grainToneCurve")) else GrainToneCurve.LEGACY,
                grainFormatPreset = if (effects.has("grainFormatPreset")) GrainFormatPreset.fromWire(effects.string("grainFormatPreset")) else GrainFormatPreset.CUSTOM),
            lens = LensSettings(lens.boolean("distortion"), lens.boolean("tca"), lens.boolean("autoCrop"), lens.boolean("manual"),
                lens.nullableString("profileId"),
                if (lens.has("focalLength")) lens.number("focalLength", 0.1..10000.0) else null,
                if (lens.has("cropFactor")) lens.number("cropFactor", 0.1..100.0) else null,
                if (lens.has("vignetting")) lens.boolean("vignetting") else false,
                defringePurpleAmount = if (lens.has("defringePurpleAmount")) lens.number("defringePurpleAmount", 0.0..20.0) else 0f,
                defringePurpleHue = if (lens.has("defringePurpleHue")) lens.number("defringePurpleHue", 0.0..100.0) else 50f,
                defringeGreenAmount = if (lens.has("defringeGreenAmount")) lens.number("defringeGreenAmount", 0.0..20.0) else 0f,
                defringeGreenHue = if (lens.has("defringeGreenHue")) lens.number("defringeGreenHue", 0.0..100.0) else 50f),
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
            tone?.curve?.hasFreeEndpointX == true -> 10
            tone?.curve?.hasV2Extensions == true || color?.grading?.hasV2Extensions == true -> 9
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
        val expectedRecordVersion = when {
            version >= 9 -> version + 1
            version == 8 -> 9
            camera == null -> version
            else -> 8
        }
        require(value.integer("record_version") == expectedRecordVersion && value.integer("hdr_processing_version") == version) {
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

    private fun ColorGradingWheel.json() = JSONObject().put("hue", hue).put("saturation", saturation).also {
        if (luminance != 0f) it.put("luminance", luminance)
    }

    private fun ColorGradingSettings.json() = JSONObject().also { grading ->
        ColorGradingZone.entries.forEach { zone -> grading.put(zone.id, this[zone].json()) }
        if (!global.isDefault) grading.put("global", global.json())
        if (blending != 50f) grading.put("blending", blending)
        if (balance != 0f) grading.put("balance", balance)
    }

    private fun grading(json: JSONObject): ColorGradingSettings {
        json.keysWithOptional(setOf("global", "blending", "balance"), "shadows", "midtones", "highlights")
        fun decodeWheel(key: String): ColorGradingWheel {
            val wheel = json.getJSONObject(key).keysWithOptional(setOf("luminance"), "hue", "saturation")
            val hue = wheel.get("hue"); val saturation = wheel.get("saturation")
            require(hue is Number && saturation is Number)
            val luminance = if (wheel.has("luminance")) {
                val value = wheel.get("luminance")
                require(value is Number)
                value.toDouble()
            } else 0.0
            return ColorGradingWheel.fromNumbers(hue.toDouble(), saturation.toDouble(), luminance)
        }
        val base = ColorGradingZone.entries.fold(ColorGradingSettings()) { result, zone ->
            result.with(zone, decodeWheel(zone.id))
        }
        return base.copy(
            global = if (json.has("global")) decodeWheel("global") else ColorGradingWheel(),
            blending = if (json.has("blending")) json.number("blending", 0.0..100.0) else 50f,
            balance = if (json.has("balance")) json.number("balance", -100.0..100.0) else 0f,
        )
    }
    private fun decodeCalibration(s: JSONObject): CameraCalibrationSettings {
        if (!s.has("cameraCalibration")) return CameraCalibrationSettings()
        val o = s.getJSONObject("cameraCalibration").keysWithOptional(
            setOf("shadowTint", "redHue", "redSaturation", "greenHue", "greenSaturation", "blueHue", "blueSaturation")
        )
        return CameraCalibrationSettings(
            shadowTint = if (o.has("shadowTint")) o.number("shadowTint", -100.0..100.0) else 0f,
            redHue = if (o.has("redHue")) o.number("redHue", -100.0..100.0) else 0f,
            redSaturation = if (o.has("redSaturation")) o.number("redSaturation", -100.0..100.0) else 0f,
            greenHue = if (o.has("greenHue")) o.number("greenHue", -100.0..100.0) else 0f,
            greenSaturation = if (o.has("greenSaturation")) o.number("greenSaturation", -100.0..100.0) else 0f,
            blueHue = if (o.has("blueHue")) o.number("blueHue", -100.0..100.0) else 0f,
            blueSaturation = if (o.has("blueSaturation")) o.number("blueSaturation", -100.0..100.0) else 0f,
        )
    }

    private fun decodePointColor(s: JSONObject): PointColorSettings {
        if (!s.has("pointColor")) return PointColorSettings()
        val o = s.getJSONObject("pointColor").keysWithOptional(setOf("swatches"))
        if (!o.has("swatches")) return PointColorSettings()
        val arr = o.getJSONArray("swatches")
        val swatches = (0 until arr.length()).map { idx ->
            val sw = arr.getJSONObject(idx).keysWithOptional(
                setOf("srcHue", "srcSaturation", "srcLuminance", "hueShift", "saturationShift",
                    "luminanceShift", "range", "hueRange", "satRange", "lumRange", "variance", "enabled")
            )
            PointColorSwatch(
                srcHue = if (sw.has("srcHue")) number(sw.get("srcHue"), 0.0..360.0) else 0f,
                srcSaturation = if (sw.has("srcSaturation")) sw.number("srcSaturation", 0.0..1.0) else 0.5f,
                srcLuminance = if (sw.has("srcLuminance")) sw.number("srcLuminance", 0.0..1.0) else 0.5f,
                hueShift = if (sw.has("hueShift")) sw.number("hueShift", -100.0..100.0) else 0f,
                saturationShift = if (sw.has("saturationShift")) sw.number("saturationShift", -100.0..100.0) else 0f,
                luminanceShift = if (sw.has("luminanceShift")) sw.number("luminanceShift", -100.0..100.0) else 0f,
                range = if (sw.has("range")) sw.number("range", 0.0..100.0) else 50f,
                hueRange = if (sw.has("hueRange")) sw.number("hueRange", 0.0..100.0) else 50f,
                satRange = if (sw.has("satRange")) sw.number("satRange", 0.0..100.0) else 50f,
                lumRange = if (sw.has("lumRange")) sw.number("lumRange", 0.0..100.0) else 50f,
                variance = if (sw.has("variance")) sw.number("variance", -100.0..100.0) else 0f,
                enabled = if (sw.has("enabled")) sw.boolean("enabled") else true,
            )
        }
        return PointColorSettings(swatches)
    }

    private fun decodeSelectiveColor(s: JSONObject): SelectiveColorSettings {
        if (!s.has("selectiveColor")) return SelectiveColorSettings()
        val o = s.getJSONObject("selectiveColor").keysWithOptional(setOf("method", "bands"))
        val method = if (o.has("method")) SelectiveColorMethod.fromWire(o.string("method")) else SelectiveColorMethod.RELATIVE
        val bandsObj = if (o.has("bands")) o.getJSONObject("bands").keysWithOptional(
            setOf("reds", "yellows", "greens", "cyans", "blues", "magentas", "whites", "neutrals", "blacks")
        ) else JSONObject()
        fun band(name: String): SelectiveColorBand {
            if (!bandsObj.has(name)) return SelectiveColorBand()
            val b = bandsObj.getJSONObject(name).keysWithOptional(setOf("cyan", "magenta", "yellow", "black"))
            return SelectiveColorBand(
                cyan = if (b.has("cyan")) b.number("cyan", -100.0..100.0) else 0f,
                magenta = if (b.has("magenta")) b.number("magenta", -100.0..100.0) else 0f,
                yellow = if (b.has("yellow")) b.number("yellow", -100.0..100.0) else 0f,
                black = if (b.has("black")) b.number("black", -100.0..100.0) else 0f,
            )
        }
        return SelectiveColorSettings(method, SelectiveColorBands(
            reds = band("reds"), yellows = band("yellows"), greens = band("greens"),
            cyans = band("cyans"), blues = band("blues"), magentas = band("magentas"),
            whites = band("whites"), neutrals = band("neutrals"), blacks = band("blacks"),
        ))
    }

    private fun decodeBwMixer(s: JSONObject): BwMixerSettings {
        if (!s.has("bwMixer")) return BwMixerSettings()
        val o = s.getJSONObject("bwMixer").keysWithOptional(setOf("enabled", "mixer"))
        val enabled = if (o.has("enabled")) o.boolean("enabled") else false
        val m = if (o.has("mixer")) o.getJSONObject("mixer").keysWithOptional(
            setOf("red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta")
        ) else JSONObject()
        return BwMixerSettings(enabled, BwMixerWeights(
            red = if (m.has("red")) m.number("red", -100.0..100.0) else 0f,
            orange = if (m.has("orange")) m.number("orange", -100.0..100.0) else 0f,
            yellow = if (m.has("yellow")) m.number("yellow", -100.0..100.0) else 0f,
            green = if (m.has("green")) m.number("green", -100.0..100.0) else 0f,
            aqua = if (m.has("aqua")) m.number("aqua", -100.0..100.0) else 0f,
            blue = if (m.has("blue")) m.number("blue", -100.0..100.0) else 0f,
            purple = if (m.has("purple")) m.number("purple", -100.0..100.0) else 0f,
            magenta = if (m.has("magenta")) m.number("magenta", -100.0..100.0) else 0f,
        ))
    }

    private fun decodeSharpenV2(s: JSONObject): SharpenV2Settings {
        if (!s.has("sharpenV2")) return SharpenV2Settings()
        val o = s.getJSONObject("sharpenV2").keysWithOptional(setOf("luminanceV2", "radius", "detail", "masking"))
        return SharpenV2Settings(
            luminanceV2 = if (o.has("luminanceV2")) o.boolean("luminanceV2") else false,
            radius = if (o.has("radius")) o.number("radius", 0.5..3.0) else 1.0f,
            detail = if (o.has("detail")) o.number("detail", 0.0..100.0) else 25f,
            masking = if (o.has("masking")) o.number("masking", 0.0..100.0) else 0f,
        )
    }

    private fun decodeFilmOptics(s: JSONObject): FilmOpticsSettings {
        if (!s.has("filmOptics")) return FilmOpticsSettings()
        val o = s.getJSONObject("filmOptics").keysWithOptional(
            setOf("halationAmount", "halationThreshold", "halationRadius", "halationHue",
                "bloomAmount", "bloomThreshold", "bloomRadius")
        )
        return FilmOpticsSettings(
            halationAmount = if (o.has("halationAmount")) o.number("halationAmount", 0.0..100.0) else 0f,
            halationThreshold = if (o.has("halationThreshold")) o.number("halationThreshold", 0.0..100.0) else 75f,
            halationRadius = if (o.has("halationRadius")) o.number("halationRadius", 0.0..100.0) else 35f,
            halationHue = if (o.has("halationHue")) o.number("halationHue", -100.0..100.0) else 0f,
            bloomAmount = if (o.has("bloomAmount")) o.number("bloomAmount", 0.0..100.0) else 0f,
            bloomThreshold = if (o.has("bloomThreshold")) o.number("bloomThreshold", 0.0..100.0) else 70f,
            bloomRadius = if (o.has("bloomRadius")) o.number("bloomRadius", 0.0..100.0) else 40f,
        )
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
