package com.rawlab.android.settings

internal fun Float.canonicalZero(): Float = if (this == 0f) 0f else this
internal fun Double.canonicalZero(): Double = if (this == 0.0) 0.0 else this

// Android 与 JVM JSON 对负零的编码不同；编辑、传输和持久化入口统一为正零。
internal fun EditSettings.canonicalZeros(): EditSettings = copy(
    strength = strength.canonicalZero(), exposure = exposure.canonicalZero(),
    highlights = highlights.canonicalZero(), shadows = shadows.canonicalZero(), contrast = contrast.canonicalZero(),
    toneCurve = toneCurve.canonicalZero(), saturation = saturation.canonicalZero(), temperature = temperature.canonicalZero(),
    tint = tint.canonicalZero(), sharpening = sharpening.canonicalZero(), blackPoint = blackPoint.canonicalZero(),
    whitePoint = whitePoint.canonicalZero(), vibrance = vibrance.canonicalZero(), clarity = clarity.canonicalZero(), dehaze = dehaze.canonicalZero(),
    hsl = HslSettings(hsl.packed().map { it.canonicalZero() }),
    denoise = denoise.copy(luma = denoise.luma.canonicalZero(), chroma = denoise.chroma.canonicalZero(), coarse = denoise.coarse.canonicalZero()),
    effects = with(effects) { copy(vignetteAmount = vignetteAmount.canonicalZero(), vignetteMidpoint = vignetteMidpoint.canonicalZero(),
        vignetteRoundness = vignetteRoundness.canonicalZero(), vignetteFeather = vignetteFeather.canonicalZero(),
        vignetteHighlights = vignetteHighlights.canonicalZero(), grainAmount = grainAmount.canonicalZero(),
        grainSize = grainSize.canonicalZero(), grainRoughness = grainRoughness.canonicalZero()) },
    geometry = with(geometry) { copy(cropX = cropX.canonicalZero(), cropY = cropY.canonicalZero(),
        cropWidth = cropWidth.canonicalZero(), cropHeight = cropHeight.canonicalZero(), straightenDegrees = straightenDegrees.canonicalZero(),
        perspectiveHorizontal = perspectiveHorizontal.canonicalZero(), perspectiveVertical = perspectiveVertical.canonicalZero()) },
    colorGrading = ColorGradingZone.entries.fold(colorGrading) { value, zone ->
        value.with(zone, value[zone].let { it.copy(hue = it.hue.canonicalZero(), saturation = it.saturation.canonicalZero()) }) },
    curve = ToneCurveSettings(curve.mode, curve.points, curve.channels),
    hdr = hdr?.copy(exposure = hdr.exposure.canonicalZero(), temperature = hdr.temperature.canonicalZero(),
        tint = hdr.tint.canonicalZero(), contrast = hdr.contrast.canonicalZero(),
        highlights = hdr.highlights.canonicalZero(), shadows = hdr.shadows.canonicalZero(),
        saturation = hdr.saturation.canonicalZero(), tone = hdr.tone?.let {
            it.copy(blackPoint = it.blackPoint.canonicalZero(), whitePoint = it.whitePoint.canonicalZero(),
                curveStrength = it.curveStrength.canonicalZero())
        }, detail = hdr.detail?.let {
            it.copy(sharpening = it.sharpening.canonicalZero(), clarity = it.clarity.canonicalZero(),
                dehaze = it.dehaze.canonicalZero(), denoise = it.denoise.canonicalZero())
        }, look = hdr.look?.let { it.copy(strength = it.strength.canonicalZero()) },
        cameraDevelopment = hdr.cameraDevelopment?.let { it.copy(temperature = it.temperature.canonicalZero(), tint = it.tint.canonicalZero()) },
        geometry = with(hdr.geometry) {
            copy(cropX = cropX.canonicalZero(), cropY = cropY.canonicalZero(),
                cropWidth = cropWidth.canonicalZero(), cropHeight = cropHeight.canonicalZero(),
                straightenDegrees = straightenDegrees.canonicalZero(),
                perspectiveHorizontal = perspectiveHorizontal.canonicalZero(),
                perspectiveVertical = perspectiveVertical.canonicalZero())
        }),
)
