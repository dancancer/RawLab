package com.rawlab.android.settings

internal fun Float.canonicalZero(): Float = if (this == 0f) 0f else this
internal fun Double.canonicalZero(): Double = if (this == 0.0) 0.0 else this

private fun ColorGradingWheel.canonicalZeros(): ColorGradingWheel =
    copy(hue = hue.canonicalZero(), saturation = saturation.canonicalZero(), luminance = luminance.canonicalZero())

private fun ColorGradingSettings.canonicalZeros(): ColorGradingSettings = copy(
    shadows = shadows.canonicalZeros(),
    midtones = midtones.canonicalZeros(),
    highlights = highlights.canonicalZeros(),
    global = global.canonicalZeros(),
    blending = blending.canonicalZero(),
    balance = balance.canonicalZero(),
)

private fun ToneCurveSettings.canonicalZeros(): ToneCurveSettings = ToneCurveSettings(
    mode, points, channels, applyToLuminosity,
    with(parametric) {
        ToneCurveParametric(
            highlights.canonicalZero(), lights.canonicalZero(), darks.canonicalZero(), shadows.canonicalZero(),
            splitShadow.canonicalZero(), splitMidtone.canonicalZero(), splitHighlight.canonicalZero(),
        )
    },
)

// Android 与 JVM JSON 对负零的编码不同；编辑、传输和持久化入口统一为正零。
internal fun EditSettings.canonicalZeros(): EditSettings = copy(
    strength = strength.canonicalZero(), exposure = exposure.canonicalZero(),
    highlights = highlights.canonicalZero(), shadows = shadows.canonicalZero(), contrast = contrast.canonicalZero(),
    toneCurve = toneCurve.canonicalZero(), saturation = saturation.canonicalZero(), temperature = temperature.canonicalZero(),
    tint = tint.canonicalZero(), sharpening = sharpening.canonicalZero(), blackPoint = blackPoint.canonicalZero(),
    whitePoint = whitePoint.canonicalZero(), vibrance = vibrance.canonicalZero(), clarity = clarity.canonicalZero(), dehaze = dehaze.canonicalZero(), texture = texture.canonicalZero(),
    hsl = HslSettings(hsl.packed().map { it.canonicalZero() }),
    denoise = denoise.copy(luma = denoise.luma.canonicalZero(), chroma = denoise.chroma.canonicalZero(), coarse = denoise.coarse.canonicalZero()),
    effects = with(effects) { copy(vignetteAmount = vignetteAmount.canonicalZero(), vignetteMidpoint = vignetteMidpoint.canonicalZero(),
        vignetteRoundness = vignetteRoundness.canonicalZero(), vignetteFeather = vignetteFeather.canonicalZero(),
        vignetteHighlights = vignetteHighlights.canonicalZero(), grainAmount = grainAmount.canonicalZero(),
        grainSize = grainSize.canonicalZero(), grainRoughness = grainRoughness.canonicalZero()) },
    lens = with(lens) { copy(defringePurpleAmount = defringePurpleAmount.canonicalZero(), defringePurpleHue = defringePurpleHue.canonicalZero(),
        defringeGreenAmount = defringeGreenAmount.canonicalZero(), defringeGreenHue = defringeGreenHue.canonicalZero()) },
    calibration = with(calibration) { copy(shadowTint = shadowTint.canonicalZero(), redHue = redHue.canonicalZero(),
        redSaturation = redSaturation.canonicalZero(), greenHue = greenHue.canonicalZero(),
        greenSaturation = greenSaturation.canonicalZero(), blueHue = blueHue.canonicalZero(), blueSaturation = blueSaturation.canonicalZero()) },
    pointColor = PointColorSettings(pointColor.swatches.map {
        it.copy(srcHue = it.srcHue.canonicalZero(), srcSaturation = it.srcSaturation.canonicalZero(), srcLuminance = it.srcLuminance.canonicalZero(),
            hueShift = it.hueShift.canonicalZero(), saturationShift = it.saturationShift.canonicalZero(), luminanceShift = it.luminanceShift.canonicalZero(),
            range = it.range.canonicalZero(), hueRange = it.hueRange.canonicalZero(), satRange = it.satRange.canonicalZero(),
            lumRange = it.lumRange.canonicalZero(), variance = it.variance.canonicalZero())
    }),
    selectiveColor = selectiveColor.copy(bands = with(selectiveColor.bands) {
        fun SelectiveColorBand.cz() = copy(cyan = cyan.canonicalZero(), magenta = magenta.canonicalZero(), yellow = yellow.canonicalZero(), black = black.canonicalZero())
        copy(reds = reds.cz(), yellows = yellows.cz(), greens = greens.cz(), cyans = cyans.cz(), blues = blues.cz(),
            magentas = magentas.cz(), whites = whites.cz(), neutrals = neutrals.cz(), blacks = blacks.cz())
    }),
    bwMixer = bwMixer.copy(mixer = with(bwMixer.mixer) { copy(red = red.canonicalZero(), orange = orange.canonicalZero(),
        yellow = yellow.canonicalZero(), green = green.canonicalZero(), aqua = aqua.canonicalZero(),
        blue = blue.canonicalZero(), purple = purple.canonicalZero(), magenta = magenta.canonicalZero()) }),
    sharpenV2 = sharpenV2.copy(radius = sharpenV2.radius.canonicalZero(), detail = sharpenV2.detail.canonicalZero(), masking = sharpenV2.masking.canonicalZero()),
    filmOptics = with(filmOptics) { copy(halationAmount = halationAmount.canonicalZero(), halationThreshold = halationThreshold.canonicalZero(),
        halationRadius = halationRadius.canonicalZero(), halationHue = halationHue.canonicalZero(),
        bloomAmount = bloomAmount.canonicalZero(), bloomThreshold = bloomThreshold.canonicalZero(), bloomRadius = bloomRadius.canonicalZero()) },
    geometry = with(geometry) { copy(cropX = cropX.canonicalZero(), cropY = cropY.canonicalZero(),
        cropWidth = cropWidth.canonicalZero(), cropHeight = cropHeight.canonicalZero(), straightenDegrees = straightenDegrees.canonicalZero(),
        perspectiveHorizontal = perspectiveHorizontal.canonicalZero(), perspectiveVertical = perspectiveVertical.canonicalZero()) },
    colorGrading = colorGrading.canonicalZeros(),
    curve = curve.canonicalZeros(),
    hdr = hdr?.copy(exposure = hdr.exposure.canonicalZero(), temperature = hdr.temperature.canonicalZero(),
        tint = hdr.tint.canonicalZero(), contrast = hdr.contrast.canonicalZero(),
        highlights = hdr.highlights.canonicalZero(), shadows = hdr.shadows.canonicalZero(),
        saturation = hdr.saturation.canonicalZero(), tone = hdr.tone?.let {
            it.copy(blackPoint = it.blackPoint.canonicalZero(), whitePoint = it.whitePoint.canonicalZero(),
                curveStrength = it.curveStrength.canonicalZero(), curve = it.curve.canonicalZeros())
        }, color = hdr.color?.let {
            it.copy(vibrance = it.vibrance.canonicalZero(), grading = it.grading.canonicalZeros())
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
