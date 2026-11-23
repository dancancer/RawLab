package com.rawlab.android.engine

import android.graphics.Bitmap
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.OutputSharpening
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.raster.DecodedRaster
import com.rawlab.android.settings.ColorGradingSettings
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.HDRColorSettings
import com.rawlab.android.settings.HDRDetailSettings
import com.rawlab.android.settings.HDRLookSettings
import com.rawlab.android.settings.HDRRenditionSettings
import com.rawlab.android.settings.HDRSettings
import com.rawlab.android.settings.HDRToneSettings
import com.rawlab.android.settings.HslTargetRevision
import com.rawlab.android.settings.PhotoEffectsSettings
import com.rawlab.android.settings.ToneCurveParametric
import com.rawlab.android.settings.ToneCurveShape
import com.rawlab.android.settings.canonicalZero
import java.io.File

internal data class NativeGeometry(
    val cropX: Float = 0f,
    val cropY: Float = 0f,
    val cropWidth: Float = 1f,
    val cropHeight: Float = 1f,
    val quarterTurns: Int = 0,
    val flipHorizontal: Boolean = false,
    val flipVertical: Boolean = false,
    val straightenDegrees: Float = 0f,
    val perspectiveHorizontal: Float = 0f,
    val perspectiveVertical: Float = 0f,
)

internal data class NativeToneCurve(
    val mode: Int = 0,
    val points: DoubleArray = DoubleArray(0),
) {
    override fun equals(other: Any?): Boolean =
        this === other || (other is NativeToneCurve && mode == other.mode && points.contentEquals(other.points))

    override fun hashCode(): Int = 31 * mode + points.contentHashCode()
}

internal data class NativeColorGrading(
    val shadowsHue: Float = 0f,
    val shadowsSaturation: Float = 0f,
    val shadowsLuminance: Float = 0f,
    val midtonesHue: Float = 0f,
    val midtonesSaturation: Float = 0f,
    val midtonesLuminance: Float = 0f,
    val highlightsHue: Float = 0f,
    val highlightsSaturation: Float = 0f,
    val highlightsLuminance: Float = 0f,
    val globalHue: Float = 0f,
    val globalSaturation: Float = 0f,
    val globalLuminance: Float = 0f,
    val blending: Float = 50f,
    val balance: Float = 0f,
)

internal data class NativeToneCurveParametric(
    val highlights: Float = 0f,
    val lights: Float = 0f,
    val darks: Float = 0f,
    val shadows: Float = 0f,
    val splitShadow: Float = 0.25f,
    val splitMidtone: Float = 0.50f,
    val splitHighlight: Float = 0.75f,
)

internal data class NativeColorGradingV2(
    val shadowsHue: Float = 0f,
    val shadowsSaturation: Float = 0f,
    val shadowsLuminance: Float = 0f,
    val midtonesHue: Float = 0f,
    val midtonesSaturation: Float = 0f,
    val midtonesLuminance: Float = 0f,
    val highlightsHue: Float = 0f,
    val highlightsSaturation: Float = 0f,
    val highlightsLuminance: Float = 0f,
    val globalHue: Float = 0f,
    val globalSaturation: Float = 0f,
    val globalLuminance: Float = 0f,
    val blending: Float = 50f,
    val balance: Float = 0f,
)

internal data class NativePhotoEffectsConfig(
    val vignetteAmount: Float = 0f,
    val vignetteMidpoint: Float = 50f,
    val vignetteRoundness: Float = 0f,
    val vignetteFeather: Float = 50f,
    val vignetteHighlights: Float = 0f,
    val grainAmount: Float = 0f,
    val grainSize: Float = 25f,
    val grainRoughness: Float = 50f,
)

internal data class NativeDenoiseConfig(
    val enabled: Boolean = false,
    val luma: Float = 0f,
    val chroma: Float = 46f,
    val coarse: Float = 50f,
    val displayChroma: Int = 0,
)

internal data class NativeProcessInput(
    val path: String,
    val pixels: Any? = null,
    val width: Int = 0,
    val height: Int = 0,
    val pixelFormat: Int = 0,
)

internal data class NativeProcessOutput(
    val path: String? = null,
    val format: Int = ExportFormat.JPEG.nativeValue,
    val edge: Int = 0,
    val longEdge: Int = 0,
    val interactive: Boolean = false,
    val viewportPreview: Boolean = false,
    val reusableBitmap: Bitmap? = null,
)

internal data class NativeProcessWhiteBalance(
    val custom: Boolean = false,
    val temperature: Float = 6500f,
    val tint: Float = 0f,
    val recipeActive: Boolean = false,
    val recipeStrength: Float = 1f,
)

internal data class NativeProcessTone(
    val exposureEv: Float = 0f,
    val contrast: Float = 1f,
    val highlights: Float = 0f,
    val shadows: Float = 0f,
    val toneCurve: Float = 0f,
    val saturation: Float = 1f,
    val sharpening: Float = 0f,
)

internal data class NativeHslProbeTarget(
    val sourceRevision: Long = 0L,
    val requestRevision: Long = 0L,
    val output: FloatArray,
) {
    override fun equals(other: Any?): Boolean =
        this === other || (other is NativeHslProbeTarget && sourceRevision == other.sourceRevision &&
            requestRevision == other.requestRevision && output.contentEquals(other.output))

    override fun hashCode(): Int {
        var result = sourceRevision.hashCode()
        result = 31 * result + requestRevision.hashCode()
        result = 31 * result + output.contentHashCode()
        return result
    }
}

internal data class NativeProcessRequest(
    val input: NativeProcessInput,
    val output: NativeProcessOutput,
    val lutPath: String? = null,
    val lutStrength: Float = 0f,
    val whiteBalance: NativeProcessWhiteBalance = NativeProcessWhiteBalance(),
    val tone: NativeProcessTone = NativeProcessTone(),
    val exposureMode: Int = 1,
    val processingVersion: Int = 3,
    val x3fMode: Int = 1,
    val cancellationGeneration: Long = -1L,
    val backendOut: IntArray? = null,
    val hslProbe: NativeHslProbeTarget? = null,
    val migrationOut: FloatArray? = null,
) {
    override fun equals(other: Any?): Boolean =
        this === other || (other is NativeProcessRequest &&
            input == other.input && output == other.output &&
            lutPath == other.lutPath && lutStrength == other.lutStrength &&
            whiteBalance == other.whiteBalance && tone == other.tone &&
            exposureMode == other.exposureMode &&
            processingVersion == other.processingVersion && x3fMode == other.x3fMode &&
            cancellationGeneration == other.cancellationGeneration &&
            backendOut.contentEqualsOrNull(other.backendOut) &&
            hslProbe == other.hslProbe &&
            migrationOut.contentEqualsOrNull(other.migrationOut))

    override fun hashCode(): Int {
        var result = input.hashCode()
        result = 31 * result + output.hashCode()
        result = 31 * result + (lutPath?.hashCode() ?: 0)
        result = 31 * result + lutStrength.hashCode()
        result = 31 * result + whiteBalance.hashCode()
        result = 31 * result + tone.hashCode()
        result = 31 * result + exposureMode
        result = 31 * result + processingVersion
        result = 31 * result + x3fMode
        result = 31 * result + cancellationGeneration.hashCode()
        result = 31 * result + (backendOut?.contentHashCode() ?: 0)
        result = 31 * result + (hslProbe?.hashCode() ?: 0)
        result = 31 * result + (migrationOut?.contentHashCode() ?: 0)
        return result
    }
}

internal data class NativeHDRTone(
    val blackPoint: Float = 0f,
    val whitePoint: Float = 0f,
    val curveStrength: Float = 0f,
    val curve: NativeToneCurve = NativeToneCurve(),
    val applyToLuminosity: Boolean = false,
    val parametric: NativeToneCurveParametric? = null,
)

internal data class NativeHDRColor(
    val vibrance: Float = 0f,
    val hsl: FloatArray = FloatArray(24),
    val grading: NativeColorGrading = NativeColorGrading(),
) {
    override fun equals(other: Any?): Boolean =
        this === other || (other is NativeHDRColor && vibrance == other.vibrance &&
            hsl.contentEquals(other.hsl) && grading == other.grading)

    override fun hashCode(): Int {
        var result = vibrance.hashCode()
        result = 31 * result + hsl.contentHashCode()
        result = 31 * result + grading.hashCode()
        return result
    }
}

internal data class NativeHDRRendition(
    val peakLimitEv: Float = 0f,
    val sdrExposureEv: Float = 0f,
    val sdrContrast: Float = 0f,
    val sdrSaturation: Float = 0f,
)

internal data class NativeHDRDetail(
    val sharpening: Float = 0f,
    val clarity: Float = 0f,
    val dehaze: Float = 0f,
    val denoise: Float = 0f,
)

internal data class NativeHDRLook(
    val path: String? = null,
    val sha256: String? = null,
    val strength: Float = 0f,
)

internal data class NativeHDRChannelCurves(
    val red: NativeToneCurve = NativeToneCurve(),
    val green: NativeToneCurve = NativeToneCurve(),
    val blue: NativeToneCurve = NativeToneCurve(),
)

internal data class NativeHDRRenderRequest(
    val exposureEv: Float = 0f,
    val temperature: Float = 6500f,
    val tint: Float = 0f,
    val contrast: Float = 0f,
    val highlights: Float = 0f,
    val shadows: Float = 0f,
    val saturation: Float = 0f,
    val geometry: NativeGeometry = NativeGeometry(),
    val longEdge: Int = 0,
    val tone: NativeHDRTone? = null,
    val color: NativeHDRColor? = null,
    val rendition: NativeHDRRendition? = null,
    val effects: NativePhotoEffectsConfig? = null,
    val detail: NativeHDRDetail? = null,
    val look: NativeHDRLook? = null,
    val channelCurves: NativeHDRChannelCurves? = null,
    val outputSharpening: Int = 0,
    val gradingV2: NativeColorGradingV2? = null,
)

private fun IntArray?.contentEqualsOrNull(other: IntArray?): Boolean = when {
    this == null -> other == null
    other == null -> false
    else -> this.contentEquals(other)
}

private fun FloatArray?.contentEqualsOrNull(other: FloatArray?): Boolean = when {
    this == null -> other == null
    other == null -> false
    else -> this.contentEquals(other)
}

internal fun GeometrySettings.toNativeGeometry(): NativeGeometry = NativeGeometry(
    cropX = cropX,
    cropY = cropY,
    cropWidth = cropWidth,
    cropHeight = cropHeight,
    quarterTurns = quarterTurns,
    flipHorizontal = flipHorizontal,
    flipVertical = flipVertical,
    straightenDegrees = straightenDegrees,
    perspectiveHorizontal = perspectiveHorizontal,
    perspectiveVertical = perspectiveVertical,
)

internal fun ToneCurveShape.toNativeCurve(): NativeToneCurve = NativeToneCurve(
    mode = mode.nativeValue,
    points = packed(),
)

internal fun ColorGradingSettings.toNativeColorGrading(): NativeColorGrading = NativeColorGrading(
    shadowsHue = shadows.hue,
    shadowsSaturation = shadows.saturation,
    shadowsLuminance = shadows.luminance,
    midtonesHue = midtones.hue,
    midtonesSaturation = midtones.saturation,
    midtonesLuminance = midtones.luminance,
    highlightsHue = highlights.hue,
    highlightsSaturation = highlights.saturation,
    highlightsLuminance = highlights.luminance,
    globalHue = global.hue,
    globalSaturation = global.saturation,
    globalLuminance = global.luminance,
    blending = blending,
    balance = balance,
)

internal fun ToneCurveParametric.toNativeParametric(): NativeToneCurveParametric = NativeToneCurveParametric(
    highlights = highlights.toFloat(),
    lights = lights.toFloat(),
    darks = darks.toFloat(),
    shadows = shadows.toFloat(),
    splitShadow = splitShadow.toFloat(),
    splitMidtone = splitMidtone.toFloat(),
    splitHighlight = splitHighlight.toFloat(),
)

internal fun ColorGradingSettings.toNativeColorGradingV2(): NativeColorGradingV2 = NativeColorGradingV2(
    shadowsHue = shadows.hue,
    shadowsSaturation = shadows.saturation,
    shadowsLuminance = shadows.luminance,
    midtonesHue = midtones.hue,
    midtonesSaturation = midtones.saturation,
    midtonesLuminance = midtones.luminance,
    highlightsHue = highlights.hue,
    highlightsSaturation = highlights.saturation,
    highlightsLuminance = highlights.luminance,
    globalHue = global.hue,
    globalSaturation = global.saturation,
    globalLuminance = global.luminance,
    blending = blending,
    balance = balance,
)

internal fun PhotoEffectsSettings.toNativePhotoEffects(): NativePhotoEffectsConfig = NativePhotoEffectsConfig(
    vignetteAmount = vignetteAmount,
    vignetteMidpoint = vignetteMidpoint,
    vignetteRoundness = vignetteRoundness,
    vignetteFeather = vignetteFeather,
    vignetteHighlights = vignetteHighlights,
    grainAmount = grainAmount,
    grainSize = grainSize,
    grainRoughness = grainRoughness,
)

internal fun EditSettings.toNativeProcessRequest(
    inputPath: String,
    pixels: DecodedRaster?,
    lutPath: String?,
    outputPath: String? = null,
    edge: Int = 0,
    interactive: Boolean = false,
    format: ExportFormat = ExportFormat.JPEG,
    longEdge: Int = 0,
    backendOut: IntArray? = null,
    revision: HslTargetRevision? = null,
    probe: FloatArray? = null,
    cancellationGeneration: Long = -1L,
    migrationOut: FloatArray? = null,
    reusableBitmap: Bitmap? = null,
): NativeProcessRequest {
    val isExport = outputPath != null
    val scale = recipeScale
    val whiteBalance = if (pixels != null) {
        NativeProcessWhiteBalance()
    } else {
        NativeProcessWhiteBalance(
            custom = customWb,
            temperature = temperature,
            tint = tint,
            recipeActive = recipeID != null,
            recipeStrength = strength,
        )
    }
    return NativeProcessRequest(
        input = NativeProcessInput(
            path = inputPath,
            pixels = pixels?.pixels,
            width = pixels?.width ?: 0,
            height = pixels?.height ?: 0,
            pixelFormat = pixels?.pixelFormat ?: 0,
        ),
        output = NativeProcessOutput(
            path = outputPath,
            format = format.nativeValue,
            edge = if (isExport || migrationOut != null) 0 else edge,
            longEdge = if (isExport) longEdge else 0,
            interactive = interactive && !isExport && migrationOut == null,
            viewportPreview = !isExport && migrationOut == null && edge > 0,
            reusableBitmap = if (!isExport && migrationOut == null) reusableBitmap else null,
        ),
        lutPath = lutPath,
        lutStrength = if (!lutPath.isNullOrEmpty()) strength else 0f,
        whiteBalance = whiteBalance,
        tone = NativeProcessTone(
            exposureEv = exposure * scale,
            contrast = if (scale == 1f) contrast else 1f + (contrast - 1f) * scale,
            highlights = (highlights * scale).canonicalZero(),
            shadows = shadows * scale,
            toneCurve = renderToneCurve,
            saturation = if (scale == 1f) saturation else 1f + (saturation - 1f) * scale,
            sharpening = sharpening,
        ),
        exposureMode = exposureMode,
        processingVersion = processing.version,
        x3fMode = x3fMode.nativeValue,
        cancellationGeneration = cancellationGeneration,
        backendOut = backendOut,
        hslProbe = probe?.let {
            NativeHslProbeTarget(
                sourceRevision = revision?.source ?: 0L,
                requestRevision = revision?.request ?: 0L,
                output = it,
            )
        },
        migrationOut = migrationOut,
    )
}

internal fun HDRToneSettings.toNativeTone(): NativeHDRTone = NativeHDRTone(
    blackPoint = blackPoint,
    whitePoint = whitePoint,
    curveStrength = curveStrength,
    curve = curve.master.toNativeCurve(),
    applyToLuminosity = curve.applyToLuminosity,
    parametric = curve.parametric.takeUnless { it.isDefault }?.toNativeParametric(),
)

internal fun HDRColorSettings.toNativeColor(): NativeHDRColor = NativeHDRColor(
    vibrance = vibrance,
    hsl = hsl.packed(),
    grading = grading.toNativeColorGrading(),
)

internal fun HDRRenditionSettings.toNativeRendition(): NativeHDRRendition = NativeHDRRendition(
    peakLimitEv = peakLimitEV,
    sdrExposureEv = sdrExposureEV,
    sdrContrast = sdrContrast,
    sdrSaturation = sdrSaturation,
)

internal fun HDRDetailSettings.toNativeDetail(): NativeHDRDetail = NativeHDRDetail(
    sharpening = sharpening,
    clarity = clarity,
    dehaze = dehaze,
    denoise = denoise,
)

internal fun HDRLookSettings.toNativeLook(lookDirectory: File?): NativeHDRLook = NativeHDRLook(
    path = asset(lookDirectory)?.absolutePath,
    sha256 = sha256,
    strength = strength,
)

internal fun HDRSettings.toNativeRequest(
    longEdge: Int = 0,
    lookDirectory: File? = null,
    outputSharpening: OutputSharpening = OutputSharpening.OFF,
): NativeHDRRenderRequest {
    val curve = tone?.curve
    val needsV9 = curve?.hasV2Extensions == true || color?.grading?.hasV2Extensions == true
    return NativeHDRRenderRequest(
        exposureEv = exposure,
        temperature = temperature,
        tint = tint,
        contrast = contrast,
        highlights = highlights,
        shadows = shadows,
        saturation = saturation,
        geometry = geometry.toNativeGeometry(),
        longEdge = longEdge,
        tone = tone?.toNativeTone(),
        color = color?.toNativeColor(),
        rendition = rendition?.toNativeRendition(),
        effects = effects?.toNativePhotoEffects(),
        detail = detail?.toNativeDetail(),
        look = look?.toNativeLook(lookDirectory),
        channelCurves = if (curve?.hasChannelCurves == true || needsV9) {
            val ch = curve?.channels
            NativeHDRChannelCurves(
                red = (ch?.red ?: ToneCurveShape()).toNativeCurve(),
                green = (ch?.green ?: ToneCurveShape()).toNativeCurve(),
                blue = (ch?.blue ?: ToneCurveShape()).toNativeCurve(),
            )
        } else null,
        outputSharpening = outputSharpening.nativeValue,
        gradingV2 = if (needsV9) {
            (color?.grading ?: ColorGradingSettings()).toNativeColorGradingV2()
        } else null,
    )
}
