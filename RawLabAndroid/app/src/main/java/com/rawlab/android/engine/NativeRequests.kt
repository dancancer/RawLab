package com.rawlab.android.engine

internal data class NativeRoiBounds(
    val x0: Int,
    val y0: Int,
    val x1: Int,
    val y1: Int,
    val fullWidth: Int,
    val fullHeight: Int,
)

internal class NativeRoiFrame(
    val frame: NativeFrame,
    val bounds: NativeRoiBounds,
)

internal data class NativeWbProbeResult(
    val availability: Int,
    val temperature: Float,
    val tint: Float,
    val validPixelCount: Int,
    val rejectedOverexposedCount: Int,
)

internal class NativeHslProbeResult(
    val availability: Int,
    val previewQuality: Boolean,
    val rgb: FloatArray,
    val weights: FloatArray,
)

internal data class NativeMigrationResult(
    val sourceVersion: Int,
    val targetVersion: Int,
    val disposition: Int,
    val evaluationCount: Int,
    val exposureEv: Float,
    val contrast: Float,
    val highlights: Float,
    val shadows: Float,
    val saturation: Float,
    val blackPoint: Float,
    val whitePoint: Float,
    val vibrance: Float,
    val clarity: Float,
    val dehaze: Float,
    val rgbRmse: Float,
    val p99Error: Float,
    val worstTileRmse: Float,
    val detailRmse: Float,
)

internal data class NativeLensReport(
    val state: Int,
    val detectedLens: String,
    val selectedLens: String,
    val appliedDistortion: Boolean,
    val appliedTca: Boolean,
    val cropScale: Float,
    val appliedVignetting: Boolean,
)

internal data class NativeLensInspection(
    val appliedDistortion: Boolean,
    val appliedTca: Boolean,
    val appliedVignetting: Boolean,
)

internal data class NativeLookValidation(
    val format: Int,
    val version: Int,
    val colorState: Int,
)

internal data class NativeCameraWhiteBalance(
    val temperature: Float,
    val tint: Float,
)

internal data class NativeHDRPairInfo(
    val width: Int,
    val height: Int,
    val nativeWidth: Int,
    val nativeHeight: Int,
    val outputNativeWidth: Int,
    val outputNativeHeight: Int,
    val contentHeadroom: Float,
    val sourceHeadroom: Float,
)

internal data class NativeHDRRoiPair(
    val handle: Long,
    val bounds: NativeRoiBounds,
)
