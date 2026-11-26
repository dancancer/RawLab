package com.rawlab.android.engine

enum class HDRPreviewMode { AUTOMATIC, SDR }

data class HDRDisplayParameters(val headroom: Float, val mode: HDRPreviewMode = HDRPreviewMode.AUTOMATIC,
    val falseColor: Boolean = false) {
    val safeHeadroom get() = if (headroom.isFinite()) headroom.coerceIn(1f, 65504f) else 1f
}

data class HDRStatistics(val bins: IntArray, val aboveWhite: Int, val headroom: Float, val pixels: Int) {
    companion object {
        /** 亮度直方图、参考白以上像素数与峰值由共享核心计算（sony2fuji_hdr_analyze_luminance）。 */
        fun analyze(values: FloatArray, width: Int, height: Int, stride: Int): HDRStatistics {
            val bins = IntArray(256)
            val peak = FloatArray(1)
            val above = NativeHDRBridge.analyzeLuminance(values, width, height, stride, bins, peak)
            return HDRStatistics(bins, above, peak[0], width * height)
        }
    }
}
