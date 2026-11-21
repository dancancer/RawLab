package com.rawlab.android.editor

import com.rawlab.android.settings.*

/** 与导航工具 ID 对应；每个工作区只投影自己的字段。 */
enum class AdjustmentGroup(val tool: Int) {
    LOOK(0), STRENGTH(1), EXPOSURE(2), HIGHLIGHTS(3), SHADOWS(4), CONTRAST(5), CURVE(6),
    SATURATION(7), WHITE_BALANCE(8), SHARPENING(10), DENOISE(11), VIGNETTE(12), GRAIN(13),
    HSL(14), RECIPE(15), LENS(16), GEOMETRY(17), BLACK_POINT(18), WHITE_POINT(19),
    VIBRANCE(20), GRADING(21), CLARITY(22), DEHAZE(23),
    HDR_PEAK_LIMIT(24), HDR_SDR_EXPOSURE(25), HDR_SDR_CONTRAST(26), HDR_SDR_SATURATION(27);

    companion object {
        fun forTool(tool: Int): AdjustmentGroup = entries.first { it.tool == if (tool == 9) 8 else tool }
    }
}

internal fun AdjustmentGroup.project(value: EditSettings, original: EditSettings, current: EditSettings): EditSettings {
    val result = when (this) {
        AdjustmentGroup.LOOK, AdjustmentGroup.RECIPE -> projectLook(value, original, current)
        AdjustmentGroup.STRENGTH -> current.copy(strength = value.strength)
        AdjustmentGroup.EXPOSURE -> current.copy(exposure = value.exposure, exposureMode = value.exposureMode)
        AdjustmentGroup.HIGHLIGHTS -> current.copy(highlights = value.highlights)
        AdjustmentGroup.SHADOWS -> current.copy(shadows = value.shadows)
        AdjustmentGroup.CONTRAST -> current.copy(contrast = value.contrast)
        AdjustmentGroup.CURVE -> current.withEditingCurve(value.editingCurve).withEditingCurveStrength(value.editingCurveStrength)
        AdjustmentGroup.SATURATION -> current.copy(saturation = value.saturation)
        AdjustmentGroup.WHITE_BALANCE -> current.copy(customWb = value.customWb, temperature = value.temperature, tint = value.tint)
        AdjustmentGroup.SHARPENING -> current.withEditingSharpening(value.editingSharpening)
        AdjustmentGroup.DENOISE -> if (current.isHDREditing) current.withHDRDenoise(value.hdr!!.detailSettings.denoise)
            else current.copy(denoise = value.denoise, displayChromaDenoise = value.displayChromaDenoise)
        AdjustmentGroup.VIGNETTE -> current.withEditingEffects(value.editingEffects.copy(
            grainAmount = current.editingEffects.grainAmount, grainSize = current.editingEffects.grainSize,
            grainRoughness = current.editingEffects.grainRoughness))
        AdjustmentGroup.GRAIN -> current.withEditingEffects(current.editingEffects.copy(
            grainAmount = value.editingEffects.grainAmount, grainSize = value.editingEffects.grainSize,
            grainRoughness = value.editingEffects.grainRoughness))
        AdjustmentGroup.HSL -> current.withEditingHsl(value.editingHsl)
        AdjustmentGroup.LENS -> current.copy(lens = value.lens)
        AdjustmentGroup.GEOMETRY -> current.copy(geometry = value.geometry)
        AdjustmentGroup.BLACK_POINT -> current.withEditingBlackPoint(value.editingBlackPoint)
        AdjustmentGroup.WHITE_POINT -> current.withEditingWhitePoint(value.editingWhitePoint)
        AdjustmentGroup.VIBRANCE -> current.withEditingVibrance(value.editingVibrance)
        AdjustmentGroup.GRADING -> current.withEditingGrading(value.editingGrading)
        AdjustmentGroup.CLARITY -> current.withEditingClarity(value.editingClarity)
        AdjustmentGroup.DEHAZE -> current.withEditingDehaze(value.editingDehaze)
        AdjustmentGroup.HDR_PEAK_LIMIT -> if (current.isHDREditing) current.copy(hdr = current.hdr!!.withRendition(current.hdr.renditionSettings.copy(peakLimitEV = value.hdr!!.renditionSettings.peakLimitEV))) else current
        AdjustmentGroup.HDR_SDR_EXPOSURE -> if (current.isHDREditing) current.copy(hdr = current.hdr!!.withRendition(current.hdr.renditionSettings.copy(sdrExposureEV = value.hdr!!.renditionSettings.sdrExposureEV))) else current
        AdjustmentGroup.HDR_SDR_CONTRAST -> if (current.isHDREditing) current.copy(hdr = current.hdr!!.withRendition(current.hdr.renditionSettings.copy(sdrContrast = value.hdr!!.renditionSettings.sdrContrast))) else current
        AdjustmentGroup.HDR_SDR_SATURATION -> if (current.isHDREditing) current.copy(hdr = current.hdr!!.withRendition(current.hdr.renditionSettings.copy(sdrSaturation = value.hdr!!.renditionSettings.sdrSaturation))) else current
    }
    return result.canonicalZeros().synchronizeHDR()
}

private fun projectLook(value: EditSettings, original: EditSettings, current: EditSettings): EditSettings {
    // 配方转独立外观时会换算参数；仅这些实际变化的依赖随外观一起提交。
    fun <T> changed(before: T, after: T, committed: T): T = if (before != after) after else committed
    var result = current.copy(film = value.film, recipeID = value.recipeID, strength = value.strength,
        masterRecipeSettingsVersion = value.masterRecipeSettingsVersion,
        exposure = changed(original.exposure, value.exposure, current.exposure),
        highlights = changed(original.highlights, value.highlights, current.highlights),
        shadows = changed(original.shadows, value.shadows, current.shadows),
        contrast = changed(original.contrast, value.contrast, current.contrast),
        saturation = changed(original.saturation, value.saturation, current.saturation),
        customWb = changed(original.customWb, value.customWb, current.customWb),
        temperature = changed(original.temperature, value.temperature, current.temperature),
        tint = changed(original.tint, value.tint, current.tint),
        toneCurve = changed(original.toneCurve, value.toneCurve, current.toneCurve),
        hsl = changed(original.hsl, value.hsl, current.hsl),
        blackPoint = changed(original.blackPoint, value.blackPoint, current.blackPoint),
        whitePoint = changed(original.whitePoint, value.whitePoint, current.whitePoint),
        vibrance = changed(original.vibrance, value.vibrance, current.vibrance),
        clarity = changed(original.clarity, value.clarity, current.clarity),
        dehaze = changed(original.dehaze, value.dehaze, current.dehaze),
        colorGrading = changed(original.colorGrading, value.colorGrading, current.colorGrading),
        curve = changed(original.curve, value.curve, current.curve))
    if (current.isHDREditing && value.isHDREditing && original.isHDREditing && value.hdr != original.hdr) {
        val before = original.hdr!!; val after = value.hdr!!; val committed = current.hdr!!
        result = result.copy(hdr = committed.withLook(after.lookSettings)
            .withTone(changed(before.toneSettings, after.toneSettings, committed.toneSettings))
            .withColor(changed(before.colorSettings, after.colorSettings, committed.colorSettings))
            .withEffects(changed(before.effectSettings, after.effectSettings, committed.effectSettings))
            .withDetail(changed(before.detailSettings, after.detailSettings, committed.detailSettings)))
    }
    return result
}
