package com.rawlab.android.engine

import com.rawlab.android.format.OutputSharpening
import com.rawlab.android.settings.ColorGradingWheel
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.ToneCurveShape
import org.json.JSONArray
import org.json.JSONObject

internal object CanonicalEditRecipe {
    fun processingOnlyJson(processingVersion: Int, exposureMode: String = "scene"): String {
        val root = JSONObject()
            .put("schema_version", 5)
            .put("processing", JSONObject()
                .put("family", "rawlab")
                .put("version", processingVersion.coerceIn(1, 3))
                .put("quality", "standard"))
            .put("input", JSONObject()
                .put("path", "session.raw")
                .put("type", "raw"))
            .put("edits", JSONObject()
                .put("exposure", JSONObject()
                    .put("mode", exposureMode)
                    .put("ev", 0.0)
                    .put("brightness", 1.0))
                .put("white_balance", JSONObject().put("mode", "camera"))
                .put("look", JSONObject().put("path", JSONObject.NULL).put("strength", 1.0))
                .put("detail", JSONObject().put("sharpening", 0.0)))
            .put("output", JSONObject()
                .put("path", "session.png")
                .put("format", "png")
                .put("size", JSONObject().put("mode", "native")))
        return root.toString()
    }
}

internal fun EditSettings.toCanonicalRecipeJson(
    isRaster: Boolean = false,
    includeDenoise: Boolean = true,
    outputSharpening: OutputSharpening = OutputSharpening.OFF,
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
    fun wheelJson(wheel: ColorGradingWheel): JSONObject = JSONObject()
        .put("hue", wheel.hue.toDouble())
        .put("saturation", wheel.saturation.toDouble())
        .also { if (wheel.luminance != 0f) it.put("luminance", wheel.luminance.toDouble()) }

    val colorGradingObj = JSONObject()
        .put("shadows", wheelJson(grading.shadows))
        .put("midtones", wheelJson(grading.midtones))
        .put("highlights", wheelJson(grading.highlights))
    if (!grading.global.isDefault) {
        colorGradingObj.put("global", wheelJson(grading.global))
    }
    if (grading.blending != 50f) {
        colorGradingObj.put("blending", grading.blending.toDouble())
    }
    if (grading.balance != 0f) {
        colorGradingObj.put("balance", grading.balance.toDouble())
    }

    val lensObj = JSONObject()
        .put("distortion", lens.distortion)
        .put("tca", lens.tca)
        .put("vignetting", lens.vignetting)
        .put("auto_crop", lens.autoCrop)
    if (lens.coreProfileId.isNotEmpty()) {
        lensObj.put("profile_id", lens.coreProfileId)
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

    val edits = JSONObject()
        .put("exposure", JSONObject()
            .put("mode", exposureString)
            .put("ev", 0.0)
            .put("brightness", 1.0))
        .put("white_balance", JSONObject().put("mode", if (isRaster) "none" else "camera"))
        .put("look", JSONObject().put("path", JSONObject.NULL).put("strength", 1.0))
        .put("geometry", JSONObject()
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
                .put("vertical", geometry.perspectiveVertical.toDouble())))
        .put("tone", JSONObject()
            .put("contrast", 1.0)
            .put("saturation", 1.0)
            .put("highlights", 0.0)
            .put("shadows", 0.0)
            .put("s_curve", 0.0)
            .put("black_point", renderBlackPoint.toDouble() / 100.0)
            .put("white_point", renderWhitePoint.toDouble() / 100.0)
            .put("curve", curveObject))
        .put("color", JSONObject().put("vibrance", renderVibrance.toDouble() / 100.0))
        .put("color_grading", colorGradingObj)
        .put("detail", JSONObject().put("sharpening", 0.0))
        .put("hsl", JSONObject()
            .put("hue", hslAxisJson(0))
            .put("saturation", hslAxisJson(8))
            .put("lightness", hslAxisJson(16)))
        .put("effects", JSONObject()
            .put("vignette_amount", effects.vignetteAmount.toDouble())
            .put("vignette_midpoint", effects.vignetteMidpoint.toDouble())
            .put("vignette_roundness", effects.vignetteRoundness.toDouble())
            .put("vignette_feather", effects.vignetteFeather.toDouble())
            .put("vignette_highlights", effects.vignetteHighlights.toDouble())
            .put("grain_amount", effects.grainAmount.toDouble())
            .put("grain_size", effects.grainSize.toDouble())
            .put("grain_roughness", effects.grainRoughness.toDouble())
            .put("clarity", renderClarity.toDouble() / 100.0)
            .put("dehaze", renderDehaze.toDouble() / 100.0))
        .put("denoise", denoiseObj)
        .put("lens_correction", lensObj)

    val activeV012 = renderCurve.hasV2Extensions || grading.hasV2Extensions || outputSharpening != OutputSharpening.OFF
    val outputObj = JSONObject()
        .put("path", "session.png")
        .put("format", "png")
        .put("size", JSONObject().put("mode", "native"))
    if (outputSharpening != OutputSharpening.OFF) {
        outputObj.put("sharpening", outputSharpening.wireValue)
    }

    val root = JSONObject()
        .put("schema_version", if (activeV012) 17 else if (isRaster) 5 else 7)
        .put("processing", JSONObject()
            .put("family", processing.family)
            .put("version", processing.version)
            .put("quality", processing.quality))
        .put("input", JSONObject()
            .put("path", if (isRaster) "session.png" else "session.raw")
            .put("type", if (isRaster) "raster" else "raw"))
        .put("edits", edits)
        .put("output", outputObj)
    if (!isRaster) {
        root.put("x3f_mode", x3fMode.id)
    }
    return root.toString()
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
