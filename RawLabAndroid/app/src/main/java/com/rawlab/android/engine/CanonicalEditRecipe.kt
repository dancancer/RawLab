package com.rawlab.android.engine

import com.rawlab.android.format.OutputSharpening
import com.rawlab.android.settings.ColorGradingWheel
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.HDRCameraDevelopmentSettings
import com.rawlab.android.settings.HDRSettings
import com.rawlab.android.settings.ToneCurveMode
import com.rawlab.android.settings.ToneCurveShape
import com.rawlab.android.settings.canonicalZero
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

internal object CanonicalEditRecipe {
    fun processingSessionStateJson(processingVersion: Int, exposureMode: String? = null): String {
        val root = JSONObject()
            .put("processing", JSONObject()
                .put("family", "rawlab")
                .put("version", processingVersion.coerceIn(1, 3))
                .put("quality", "standard"))
        if (exposureMode != null) {
            root.put("edits", JSONObject().put("exposure", JSONObject().put("mode", exposureMode)))
        }
        return root.toString()
    }

    fun compatibilityPreviewStateJson(
        processingVersion: Int,
        exposureMode: String,
        lutPath: String?,
        lutStrength: Double,
    ): String = JSONObject()
        .put("processing", JSONObject()
            .put("family", "rawlab")
            .put("version", processingVersion.coerceIn(1, 3))
            .put("quality", "standard"))
        .put("edits", JSONObject()
            .put("exposure", JSONObject()
                .put("mode", exposureMode)
                .put("ev", 0.0)
                .put("brightness", 1.0))
            .put("look", JSONObject()
                .put("path", lutPath ?: JSONObject.NULL)
                .put("strength", lutStrength)))
        .toString()
}

internal fun EditSettings.toCanonicalRecipeJson(
    isRaster: Boolean = false,
    includeDenoise: Boolean = true,
    outputSharpening: OutputSharpening = OutputSharpening.OFF,
): String = encodeSdrCore(
    isRaster = isRaster,
    lutPath = null,
    includeDenoise = includeDenoise,
    outputSharpening = outputSharpening,
    includeSessionState = false,
)

internal fun EditSettings.toSdrSessionStateJson(
    isRaster: Boolean = false,
    lutPath: String? = null,
    includeDenoise: Boolean = true,
    outputSharpening: OutputSharpening = OutputSharpening.OFF,
): String = encodeSdrCore(
    isRaster = isRaster,
    lutPath = lutPath,
    includeDenoise = includeDenoise,
    outputSharpening = outputSharpening,
    includeSessionState = true,
)

private fun EditSettings.encodeSdrCore(
    isRaster: Boolean,
    lutPath: String?,
    includeDenoise: Boolean,
    outputSharpening: OutputSharpening,
    includeSessionState: Boolean,
): String {
    val exposureString = if (isRaster) {
        "sensor"
    } else {
        when (exposureMode) {
            0 -> "scene"
            2 -> "sensor"
            else -> "preview"
        }
    }

    val curveObject = curveShapeJson(renderCurve.master)
    if (renderCurve.hasChannelCurves) {
        curveObject.put("channels", JSONObject()
            .put("red", curveShapeJson(renderCurve.channels.red))
            .put("green", curveShapeJson(renderCurve.channels.green))
            .put("blue", curveShapeJson(renderCurve.channels.blue)))
    }
    if (renderCurve.applyToLuminosity) {
        curveObject.put("apply_to_luminosity", true)
    }
    if (!renderCurve.parametric.isDefault) {
        curveObject.put("parametric", renderCurve.parametric.json())
    }

    val hslValues = renderHsl.packed()
    fun hslAxisJson(offset: Int): JSONArray {
        val arr = JSONArray()
        for (i in 0 until 8) arr.put(hslValues[offset + i].toDouble())
        return arr
    }

    val grading = renderColorGrading
    val colorGradingObj = colorGradingJson(grading, allowV2 = true)

    val lensObj = JSONObject()
        .put("distortion", lens.distortion)
        .put("tca", lens.tca)
        .put("vignetting", lens.vignetting)
        .put("auto_crop", lens.autoCrop)
    if (lens.coreProfileId.isNotEmpty()) {
        lensObj.put("profile_id", lens.coreProfileId)
    }
    if (lens.hasDefringe) {
        lensObj.put("defringe_purple_amount", lens.defringePurpleAmount.toDouble())
        lensObj.put("defringe_purple_hue", lens.defringePurpleHue.toDouble())
        lensObj.put("defringe_green_amount", lens.defringeGreenAmount.toDouble())
        lensObj.put("defringe_green_hue", lens.defringeGreenHue.toDouble())
    }

    val denoiseObj = JSONObject()
        .put("raw_level", 0)
        .put("chroma_mode", if (includeDenoise) displayChromaDenoise else 0)
    if (includeDenoise) {
        denoiseObj.put("wavelet", JSONObject()
            .put("enabled", denoise.enabled)
            .put("luma", denoise.luma.toDouble())
            .put("chroma", denoise.chroma.toDouble())
            .put("coarse", denoise.coarse.toDouble()))
    }

    val rasterRelativeWb = isRaster && recipeID == null && (temperature != 6500f || tint != 0f)
    if (rasterRelativeWb) {
        require(temperature.isFinite() && temperature in 2000f..50000f && tint.isFinite() && tint in -150f..150f) {
            "Invalid raster relative white balance"
        }
    }
    val scale = recipeScale
    val clampedStrength = strength.coerceIn(0f, 2f)
    var masterRecipeObj: JSONObject? = null
    val wbObj = when {
        rasterRelativeWb -> JSONObject()
            .put("mode", "relative")
            .put("relative_temperature", temperature.toDouble())
            .put("relative_tint", tint.toDouble())
        isRaster -> JSONObject().put("mode", "none")
        includeSessionState && recipeID != null -> {
            val effectiveTemp = if (customWb) temperature else 6500f
            val effectiveTint = if (!customWb && (clampedStrength == 0f || tint == 0f)) 0f else tint
            masterRecipeObj = JSONObject()
                .put("active", true)
                .put("strength", clampedStrength.toDouble())
                .put("custom_wb", customWb)
                .put("temperature_kelvin", effectiveTemp.toDouble())
                .put("tint", effectiveTint.toDouble())
                .put("uncalibrated_fallback", "error")
            JSONObject().put("mode", "camera")
        }
        includeSessionState && customWb -> JSONObject()
            .put("mode", "temperature")
            .put("temperature_kelvin", temperature.toDouble())
            .put("tint", tint.toDouble())
        else -> JSONObject().put("mode", "camera")
    }

    val hasLut = includeSessionState && !lutPath.isNullOrEmpty()
    val lookObj = JSONObject()
        .put("path", if (hasLut) lutPath else JSONObject.NULL)
        .put("strength", if (includeSessionState) (if (hasLut) clampedStrength.toDouble() else 0.0) else 1.0)

    val contrastVal = if (includeSessionState) {
        (if (scale == 1f) contrast else 1f + (contrast - 1f) * scale).coerceIn(0f, 2f).toDouble()
    } else 1.0
    val saturationVal = if (includeSessionState) {
        (if (scale == 1f) saturation else 1f + (saturation - 1f) * scale).coerceIn(0f, 2f).toDouble()
    } else 1.0
    val highlightsVal = if (includeSessionState) {
        (highlights * scale).canonicalZero().coerceIn(-1f, 1f).toDouble()
    } else 0.0
    val shadowsVal = if (includeSessionState) {
        (shadows * scale).coerceIn(-1f, 1f).toDouble()
    } else 0.0

    val edits = JSONObject()
        .put("exposure", JSONObject()
            .put("mode", exposureString)
            .put("ev", if (includeSessionState) (exposure * scale).coerceIn(-20f, 20f).toDouble() else 0.0)
            .put("brightness", 1.0))
        .put("white_balance", wbObj)
        .put("look", lookObj)
        .put("geometry", geometryJson(geometry))
        .put("tone", JSONObject()
            .put("contrast", contrastVal)
            .put("saturation", saturationVal)
            .put("highlights", highlightsVal)
            .put("shadows", shadowsVal)
            .put("s_curve", if (includeSessionState) renderToneCurve.toDouble() else 0.0)
            .put("black_point", renderBlackPoint.toDouble() / 100.0)
            .put("white_point", renderWhitePoint.toDouble() / 100.0)
            .put("curve", curveObject))
        .put("color", JSONObject().put("vibrance", renderVibrance.toDouble() / 100.0).apply {
            if (!calibration.isDefault) {
                put("calibration", with(calibration) {
                    JSONObject().put("shadow_tint", shadowTint.toDouble())
                        .put("red_hue", redHue.toDouble()).put("red_saturation", redSaturation.toDouble())
                        .put("green_hue", greenHue.toDouble()).put("green_saturation", greenSaturation.toDouble())
                        .put("blue_hue", blueHue.toDouble()).put("blue_saturation", blueSaturation.toDouble())
                })
            }
            if (!pointColor.isDefault) {
                put("point_color", JSONObject().put("swatches", JSONArray(pointColor.swatches.map { sw ->
                    JSONObject().put("src_hue", sw.srcHue.toDouble())
                        .put("src_saturation", sw.srcSaturation.toDouble())
                        .put("src_luminance", sw.srcLuminance.toDouble())
                        .put("hue_shift", sw.hueShift.toDouble())
                        .put("saturation_shift", sw.saturationShift.toDouble())
                        .put("luminance_shift", sw.luminanceShift.toDouble())
                        .put("range", sw.range.toDouble()).put("hue_range", sw.hueRange.toDouble())
                        .put("sat_range", sw.satRange.toDouble()).put("lum_range", sw.lumRange.toDouble())
                        .put("variance", sw.variance.toDouble()).put("enabled", sw.enabled)
                })))
            }
            if (!selectiveColor.isDefault) {
                put("selective_color", JSONObject().put("method", selectiveColor.method.wireValue)
                    .put("bands", JSONObject().apply {
                        selectiveColor.bands.asMap().forEach { (k, b) ->
                            put(k, JSONObject().put("cyan", b.cyan.toDouble()).put("magenta", b.magenta.toDouble())
                                .put("yellow", b.yellow.toDouble()).put("black", b.black.toDouble()))
                        }
                    }))
            }
            if (!bwMixer.isDefault) {
                put("bw", JSONObject().put("enabled", bwMixer.enabled).put("mixer", JSONObject().apply {
                    bwMixer.mixer.asMap().forEach { (k, v) -> put(k, v.toDouble()) }
                }))
            }
        })
        .put("color_grading", colorGradingObj)
        .put("detail", JSONObject().put("sharpening", if (includeSessionState) sharpening.coerceIn(0f, 2f).toDouble() else 0.0).apply {
            if (!sharpenV2.isDefault) {
                put("luminance_v2", sharpenV2.luminanceV2)
                put("sharpening_radius", sharpenV2.radius.toDouble())
                put("sharpening_detail", sharpenV2.detail.toDouble())
                put("sharpening_masking", sharpenV2.masking.toDouble())
            }
        })
        .put("hsl", JSONObject()
            .put("hue", hslAxisJson(0))
            .put("saturation", hslAxisJson(8))
            .put("lightness", hslAxisJson(16)))
        .put("effects", effectsJson(effects)
            .put("clarity", renderClarity.toDouble() / 100.0)
            .put("dehaze", renderDehaze.toDouble() / 100.0).apply {
                if (texture != 0f) put("texture", texture.toDouble() / 100.0)
                if (effects.grainToneCurve != com.rawlab.android.settings.GrainToneCurve.LEGACY) {
                    put("grain_tone_curve", effects.grainToneCurve.wireValue)
                }
                if (effects.grainFormatPreset != com.rawlab.android.settings.GrainFormatPreset.CUSTOM) {
                    put("grain_format_preset", effects.grainFormatPreset.wireValue)
                }
                val hasHalation = filmOptics.halationAmount != 0f || filmOptics.halationThreshold != 75f ||
                    filmOptics.halationRadius != 35f || filmOptics.halationHue != 0f
                if (hasHalation) {
                    put("halation", JSONObject().put("amount", filmOptics.halationAmount.toDouble())
                        .put("threshold", filmOptics.halationThreshold.toDouble())
                        .put("radius", filmOptics.halationRadius.toDouble())
                        .put("hue", filmOptics.halationHue.toDouble()))
                }
                val hasBloom = filmOptics.bloomAmount != 0f || filmOptics.bloomThreshold != 70f ||
                    filmOptics.bloomRadius != 40f
                if (hasBloom) {
                    put("bloom", JSONObject().put("amount", filmOptics.bloomAmount.toDouble())
                        .put("threshold", filmOptics.bloomThreshold.toDouble())
                        .put("radius", filmOptics.bloomRadius.toDouble()))
                }
            })
        .put("denoise", denoiseObj)
        .put("lens_correction", lensObj)
    if (masterRecipeObj != null) {
        edits.put("master_recipe", masterRecipeObj)
    }

    val activeV14 = !calibration.isDefault || !pointColor.isDefault || !selectiveColor.isDefault ||
        !bwMixer.isDefault || texture != 0f || !sharpenV2.isDefault || lens.hasDefringe ||
        !filmOptics.isDefault ||
        effects.grainToneCurve != com.rawlab.android.settings.GrainToneCurve.LEGACY ||
        effects.grainFormatPreset != com.rawlab.android.settings.GrainFormatPreset.CUSTOM
    val activeV012 = includeSessionState || renderCurve.hasV2Extensions || grading.hasV2Extensions ||
        rasterRelativeWb || outputSharpening != OutputSharpening.OFF
    val root = JSONObject()
        .put("schema_version", if (activeV14) 20 else if (renderCurve.hasFreeEndpointX) 18 else if (activeV012) 17 else if (isRaster) 5 else 7)
        .put("processing", JSONObject()
            .put("family", processing.family)
            .put("version", processing.version)
            .put("quality", processing.quality))
        .put("input", JSONObject().put("type", if (isRaster) "raster" else "raw"))
        .put("edits", edits)
    if (outputSharpening != OutputSharpening.OFF) {
        root.put("output", JSONObject().put("output_sharpening", outputSharpening.wireValue))
    }
    if (!isRaster) {
        root.put("x3f_mode", x3fMode.id)
    }
    return root.toString()
}

internal fun HDRCameraDevelopmentSettings.toCameraDevelopmentJson(
    processingVersion: Int,
    profileDirectory: File? = null,
    useAi: Boolean = false,
): String = JSONObject()
    .put("camera_development", toCameraDevelopmentObject(processingVersion, profileDirectory, useAi))
    .toString()

internal fun HDRSettings.toHdrSessionStateJson(
    lookDirectory: File? = null,
    outputSharpening: OutputSharpening = OutputSharpening.OFF,
    camera: HDRCameraDevelopmentSettings? = null,
    profileDirectory: File? = null,
    cameraProcessingVersion: Int? = null,
    useCameraAi: Boolean = false,
): String {
    val effectiveVersion = maxOf(processingVersion, if (outputSharpening != OutputSharpening.OFF) 9 else 1)
    val schemaVersion = when (effectiveVersion) {
        10 -> 19
        9 -> 16
        8 -> 15
        1 -> 6
        else -> effectiveVersion + 6
    }

    val toneObj = JSONObject()
        .put("contrast", 1.0 + contrast.toDouble() / 100.0)
        .put("saturation", 1.0 + saturation.toDouble() / 100.0)
        .put("highlights", -highlights.toDouble() / 100.0)
        .put("shadows", shadows.toDouble() / 100.0)
    if (effectiveVersion >= 2) {
        val current = toneSettings
        val curveObj = curveShapeJson(current.curve.master)
        if (effectiveVersion >= 8 && current.curve.hasChannelCurves) {
            curveObj.put("channels", JSONObject()
                .put("red", curveShapeJson(current.curve.channels.red))
                .put("green", curveShapeJson(current.curve.channels.green))
                .put("blue", curveShapeJson(current.curve.channels.blue)))
        }
        if (effectiveVersion >= 9 && current.curve.applyToLuminosity) {
            curveObj.put("apply_to_luminosity", true)
        }
        if (effectiveVersion >= 9 && !current.curve.parametric.isDefault) {
            curveObj.put("parametric", current.curve.parametric.json())
        }
        toneObj
            .put("black_point", current.blackPoint.toDouble() / 100.0)
            .put("white_point", current.whitePoint.toDouble() / 100.0)
            .put("s_curve", if (current.curve.mode == ToneCurveMode.CUSTOM) 0.0 else current.curveStrength.toDouble() / 100.0)
            .put("curve", curveObj)
    }

    val edits = JSONObject()
        .put("exposure", JSONObject().put("ev", exposure.toDouble()))
        .put("white_balance", JSONObject()
            .put("mode", "relative")
            .put("relative_temperature", temperature.toDouble())
            .put("relative_tint", tint.toDouble()))
        .put("tone", toneObj)
        .put("geometry", geometryJson(geometry))

    if (effectiveVersion >= 3) {
        val c = colorSettings
        val hslValues = c.hsl.packed()
        fun hslAxis(offset: Int): JSONArray = JSONArray().apply {
            for (i in 0 until 8) put(hslValues[offset + i].toDouble())
        }
        edits.put("color", JSONObject().put("vibrance", c.vibrance.toDouble() / 100.0))
        edits.put("hsl", JSONObject()
            .put("hue", hslAxis(0))
            .put("saturation", hslAxis(8))
            .put("lightness", hslAxis(16)))
        edits.put("color_grading", colorGradingJson(c.grading, allowV2 = effectiveVersion >= 9))
    }
    if (effectiveVersion >= 4) {
        val r = renditionSettings
        edits.put("rendition", JSONObject()
            .put("peak_limit_ev", r.peakLimitEV.toDouble())
            .put("sdr_exposure_ev", r.sdrExposureEV.toDouble())
            .put("sdr_contrast", r.sdrContrast.toDouble() / 100.0)
            .put("sdr_saturation", r.sdrSaturation.toDouble() / 100.0))
    }
    if (effectiveVersion >= 5) {
        edits.put("effects", effectsJson(effectSettings))
    }
    if (effectiveVersion >= 6) {
        val d = detailSettings
        edits.put("detail", JSONObject()
            .put("sharpening", d.sharpening.toDouble())
            .put("clarity", d.clarity.toDouble())
            .put("dehaze", d.dehaze.toDouble())
            .put("denoise", d.denoise.toDouble()))
    }
    if (effectiveVersion >= 7) {
        val l = lookSettings
        val lookObj = JSONObject().put("strength", l.strength.toDouble())
        l.asset(lookDirectory)?.absolutePath?.let { lookObj.put("path", it) }
        l.sha256?.let { lookObj.put("sha256", it) }
        edits.put("look", lookObj)
    }

    val root = JSONObject()
        .put("schema_version", schemaVersion)
        .put("processing", JSONObject()
            .put("family", "rawlab_hdr")
            .put("version", effectiveVersion)
            .put("quality", "standard"))
        .put("edits", edits)
    if (outputSharpening != OutputSharpening.OFF) {
        root.put("output", JSONObject().put("output_sharpening", outputSharpening.wireValue))
    }
    if (camera != null) {
        root.put("camera_development",
            camera.toCameraDevelopmentObject(cameraProcessingVersion ?: 3, profileDirectory, useCameraAi))
    }
    return root.toString()
}

private fun HDRCameraDevelopmentSettings.toCameraDevelopmentObject(
    processingVersion: Int,
    profileDirectory: File?,
    useAi: Boolean,
): JSONObject {
    val obj = JSONObject()
        .put("version", 1)
        .put("wb_mode", if (customWhiteBalance) "temperature" else "as_shot")
        .put("temperature", if (customWhiteBalance) temperature.toDouble() else 0.0)
        .put("tint", if (customWhiteBalance) tint.toDouble() else 0.0)
        .put("exposure_reference", if (sensorExposure) "sensor" else "metadata")
        .put("fbdd_level", fbddLevel)
        .put("lens_distortion", lensDistortion)
        .put("lens_tca", lensTca)
        .put("lens_vignetting", lensVignetting)
        .put("lens_auto_crop", lensAutoCrop)
        .put("use_ai", useAi)
        .put("processing_version", processingVersion.coerceIn(1, 3))
    lensProfile?.let { obj.put("lens_profile_id", it) }
    cameraProfile?.let { profile ->
        obj.put("camera_profile", JSONObject()
            .put("path", profile.requireAsset(profileDirectory).absolutePath)
            .put("sha256", profile.sha256))
    }
    return obj
}

private fun geometryJson(geometry: com.rawlab.android.geometry.GeometrySettings): JSONObject = JSONObject()
    .put("crop", JSONObject()
        .put("x", geometry.cropX.toDouble())
        .put("y", geometry.cropY.toDouble())
        .put("width", geometry.cropWidth.toDouble())
        .put("height", geometry.cropHeight.toDouble()))
    .put("quarter_turns", geometry.quarterTurns)
    .put("flip_horizontal", geometry.flipHorizontal)
    .put("flip_vertical", geometry.flipVertical)
    .put("straighten_degrees", geometry.straightenDegrees.toDouble())
    .put("perspective", JSONObject()
        .put("horizontal", geometry.perspectiveHorizontal.toDouble())
        .put("vertical", geometry.perspectiveVertical.toDouble()))

private fun effectsJson(effects: com.rawlab.android.settings.PhotoEffectsSettings): JSONObject = JSONObject()
    .put("vignette_amount", effects.vignetteAmount.toDouble())
    .put("vignette_midpoint", effects.vignetteMidpoint.toDouble())
    .put("vignette_roundness", effects.vignetteRoundness.toDouble())
    .put("vignette_feather", effects.vignetteFeather.toDouble())
    .put("vignette_highlights", effects.vignetteHighlights.toDouble())
    .put("grain_amount", effects.grainAmount.toDouble())
    .put("grain_size", effects.grainSize.toDouble())
    .put("grain_roughness", effects.grainRoughness.toDouble())

private fun colorGradingJson(
    grading: com.rawlab.android.settings.ColorGradingSettings,
    allowV2: Boolean,
): JSONObject {
    fun wheelJson(wheel: ColorGradingWheel): JSONObject = JSONObject()
        .put("hue", wheel.hue.toDouble())
        .put("saturation", wheel.saturation.toDouble())
        .also { if (allowV2 && wheel.luminance != 0f) it.put("luminance", wheel.luminance.toDouble()) }
    val obj = JSONObject()
        .put("shadows", wheelJson(grading.shadows))
        .put("midtones", wheelJson(grading.midtones))
        .put("highlights", wheelJson(grading.highlights))
    if (allowV2) {
        if (!grading.global.isDefault) obj.put("global", wheelJson(grading.global))
        if (grading.blending != 50f) obj.put("blending", grading.blending.toDouble())
        if (grading.balance != 0f) obj.put("balance", grading.balance.toDouble())
    }
    return obj
}

private fun curveShapeJson(shape: ToneCurveShape): JSONObject {
    val points = JSONArray()
    for (point in shape.points) {
        points.put(JSONArray().put(point.x).put(point.y))
    }
    return JSONObject()
        .put("mode", shape.mode.id)
        .put("points", points)
}
