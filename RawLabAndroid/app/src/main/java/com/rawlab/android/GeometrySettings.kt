package com.rawlab.android

/** Crop is normalized in the canvas after clockwise rotation, flips and centered straightening. */
data class GeometrySettings(
    val cropX: Float = 0f,
    val cropY: Float = 0f,
    val cropWidth: Float = 1f,
    val cropHeight: Float = 1f,
    val quarterTurns: Int = 0,
    val flipHorizontal: Boolean = false,
    val flipVertical: Boolean = false,
    val straightenDegrees: Float = 0f,
) {
    init {
        require(listOf(cropX, cropY, cropWidth, cropHeight, straightenDegrees).all(Float::isFinite))
        require(cropX >= 0f && cropX < 1f && cropY >= 0f && cropY < 1f)
        require(cropWidth > 0f && cropHeight > 0f && cropWidth <= 1f && cropHeight <= 1f)
        require(cropX.toDouble() + cropWidth <= 1.000001 && cropY.toDouble() + cropHeight <= 1.000001)
        require(quarterTurns in 0..3)
        require(straightenDegrees in -45f..45f)
    }

    val isIdentity: Boolean get() = this == GeometrySettings()
    fun rotated(clockwise: Boolean) = copy(quarterTurns = (quarterTurns + if (clockwise) 1 else 3) % 4)

    fun encode(): String = listOf(1, cropX, cropY, cropWidth, cropHeight, quarterTurns,
        if (flipHorizontal) 1 else 0, if (flipVertical) 1 else 0, straightenDegrees).joinToString(",")

    companion object {
        fun decode(value: String?): GeometrySettings {
            if (value == null) return GeometrySettings()
            val fields = value.split(',')
            require(fields.size == 9 && fields[0] == "1") { "Unsupported geometry record" }
            require(fields[6] in listOf("0", "1") && fields[7] in listOf("0", "1"))
            return GeometrySettings(fields[1].toFloat(), fields[2].toFloat(), fields[3].toFloat(),
                fields[4].toFloat(), fields[5].toInt(), fields[6] == "1", fields[7] == "1", fields[8].toFloat())
        }
    }
}

/** A transformed comparison must never reuse the uncropped original or another viewport. */
internal data class ComparisonPreviewKey(val inputPath: String, val geometry: GeometrySettings,
    val lens: LensSettings, val edge: Int, val interactive: Boolean)

/** Mobile 100% remains the fixed comparison-preview pixels, independent of current render demand. */
internal fun comparisonDimensions(width: Int, height: Int): Pair<Float, Float> {
    require(width > 0 && height > 0)
    val scale = minOf(1f, 1600f / maxOf(width, height))
    return width * scale to height * scale
}
