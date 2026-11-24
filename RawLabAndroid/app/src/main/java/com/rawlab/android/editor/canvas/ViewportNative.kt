package com.rawlab.android.editor.canvas

internal interface ViewportTilePlanner {
    fun pyramidLevel(zoomScale: Float, baseScale: Float): Int?

    fun pyramidTiles(
        visibleRect: NormalizedRect,
        fullNativeWidth: Int,
        fullNativeHeight: Int,
        zoomScale: Float,
        baseScale: Float,
        tileSize: Int = ViewportNative.DEFAULT_TILE_SIZE,
        overscanRing: Int = 0,
    ): List<DetailTileSpec>

    fun pyramidLevel0Grid(
        fullNativeWidth: Int,
        fullNativeHeight: Int,
        tileSize: Int = ViewportNative.DEFAULT_TILE_SIZE,
    ): List<DetailTileSpec>

    fun detailOverlayCovers(
        normalizedRect: NormalizedRect,
        pixelWidth: Int,
        pixelHeight: Int,
        fullNativeWidth: Int,
        fullNativeHeight: Int,
        visibleRect: NormalizedRect,
        requiredZoomScale: Float,
        maxOutputLongEdge: Int = 0,
    ): Boolean
}

internal object ViewportNative {
    const val DEFAULT_TILE_SIZE = 1024
    private const val TILE_STRIDE_DOUBLES = 8

    init {
        System.loadLibrary("rawlab-jni")
    }

    @JvmStatic
    external fun nativePyramidLevel(zoomScale: Double, baseScale: Double): Int

    @JvmStatic
    external fun nativePyramidTiles(
        fullWidth: Int,
        fullHeight: Int,
        tileSize: Int,
        overscanRing: Int,
        zoomScale: Double,
        baseScale: Double,
        visibleX0: Double,
        visibleY0: Double,
        visibleX1: Double,
        visibleY1: Double,
    ): DoubleArray?

    @JvmStatic
    external fun nativePyramidLevel0Grid(
        fullWidth: Int,
        fullHeight: Int,
        tileSize: Int,
    ): DoubleArray?

    @JvmStatic
    external fun nativeDetailOverlayCovers(
        tilePixelWidth: Int,
        tilePixelHeight: Int,
        fullWidth: Int,
        fullHeight: Int,
        maxOutputLongEdge: Int,
        tileNormX0: Double,
        tileNormY0: Double,
        tileNormX1: Double,
        tileNormY1: Double,
        visibleNormX0: Double,
        visibleNormY0: Double,
        visibleNormX1: Double,
        visibleNormY1: Double,
        requiredZoomScale: Double,
    ): Boolean

    fun pyramidLevel(zoomScale: Float, baseScale: Float): Int? {
        if (!zoomScale.isFinite() || !baseScale.isFinite() || zoomScale <= 0f || baseScale <= 0f) {
            return null
        }
        val level = nativePyramidLevel(zoomScale.toDouble(), baseScale.toDouble())
        return if (level >= 0) level else null
    }

    fun pyramidTiles(
        visibleRect: NormalizedRect,
        fullNativeWidth: Int,
        fullNativeHeight: Int,
        zoomScale: Float,
        baseScale: Float,
        tileSize: Int = DEFAULT_TILE_SIZE,
        overscanRing: Int = 0,
    ): List<DetailTileSpec> {
        if (tileSize <= 0 || overscanRing < 0 || fullNativeWidth <= 0 || fullNativeHeight <= 0 ||
            !zoomScale.isFinite() || !baseScale.isFinite() ||
            visibleRect.width <= 0f || visibleRect.height <= 0f
        ) {
            return emptyList()
        }
        val packed = nativePyramidTiles(
            fullNativeWidth,
            fullNativeHeight,
            tileSize,
            overscanRing,
            zoomScale.toDouble(),
            baseScale.toDouble(),
            visibleRect.x0.toDouble(),
            visibleRect.y0.toDouble(),
            visibleRect.x1.toDouble(),
            visibleRect.y1.toDouble(),
        ) ?: return emptyList()
        return unpackTiles(packed)
    }

    fun pyramidLevel0Grid(
        fullNativeWidth: Int,
        fullNativeHeight: Int,
        tileSize: Int = DEFAULT_TILE_SIZE,
    ): List<DetailTileSpec> {
        if (tileSize <= 0 || fullNativeWidth <= 0 || fullNativeHeight <= 0) {
            return emptyList()
        }
        val packed = nativePyramidLevel0Grid(fullNativeWidth, fullNativeHeight, tileSize) ?: return emptyList()
        return unpackTiles(packed)
    }

    fun detailOverlayCovers(
        normalizedRect: NormalizedRect,
        pixelWidth: Int,
        pixelHeight: Int,
        fullNativeWidth: Int,
        fullNativeHeight: Int,
        visibleRect: NormalizedRect,
        requiredZoomScale: Float,
        maxOutputLongEdge: Int = 0,
    ): Boolean {
        if (pixelWidth <= 0 || pixelHeight <= 0 || fullNativeWidth <= 0 || fullNativeHeight <= 0 ||
            maxOutputLongEdge < 0 || !requiredZoomScale.isFinite() ||
            normalizedRect.width <= 0f || normalizedRect.height <= 0f
        ) {
            return false
        }
        return nativeDetailOverlayCovers(
            pixelWidth,
            pixelHeight,
            fullNativeWidth,
            fullNativeHeight,
            maxOutputLongEdge,
            normalizedRect.x0.toDouble(),
            normalizedRect.y0.toDouble(),
            normalizedRect.x1.toDouble(),
            normalizedRect.y1.toDouble(),
            visibleRect.x0.toDouble(),
            visibleRect.y0.toDouble(),
            visibleRect.x1.toDouble(),
            visibleRect.y1.toDouble(),
            requiredZoomScale.toDouble(),
        )
    }

    private fun unpackTiles(packed: DoubleArray): List<DetailTileSpec> {
        if (packed.size < TILE_STRIDE_DOUBLES) return emptyList()
        val count = packed.size / TILE_STRIDE_DOUBLES
        val specs = ArrayList<DetailTileSpec>(count)
        for (i in 0 until count) {
            val base = i * TILE_STRIDE_DOUBLES
            specs += DetailTileSpec(
                key = DetailTileKey(
                    level = packed[base].toInt(),
                    col = packed[base + 1].toInt(),
                    row = packed[base + 2].toInt(),
                ),
                rect = NormalizedRect(
                    x0 = packed[base + 4].toFloat(),
                    y0 = packed[base + 5].toFloat(),
                    x1 = packed[base + 6].toFloat(),
                    y1 = packed[base + 7].toFloat(),
                ),
                maxOutputLongEdge = packed[base + 3].toInt(),
            )
        }
        return specs
    }
}

internal object NativeViewportTilePlanner : ViewportTilePlanner {
    override fun pyramidLevel(zoomScale: Float, baseScale: Float): Int? =
        ViewportNative.pyramidLevel(zoomScale, baseScale)

    override fun pyramidTiles(
        visibleRect: NormalizedRect,
        fullNativeWidth: Int,
        fullNativeHeight: Int,
        zoomScale: Float,
        baseScale: Float,
        tileSize: Int,
        overscanRing: Int,
    ): List<DetailTileSpec> = ViewportNative.pyramidTiles(
        visibleRect, fullNativeWidth, fullNativeHeight, zoomScale, baseScale, tileSize, overscanRing,
    )

    override fun pyramidLevel0Grid(
        fullNativeWidth: Int,
        fullNativeHeight: Int,
        tileSize: Int,
    ): List<DetailTileSpec> = ViewportNative.pyramidLevel0Grid(fullNativeWidth, fullNativeHeight, tileSize)

    override fun detailOverlayCovers(
        normalizedRect: NormalizedRect,
        pixelWidth: Int,
        pixelHeight: Int,
        fullNativeWidth: Int,
        fullNativeHeight: Int,
        visibleRect: NormalizedRect,
        requiredZoomScale: Float,
        maxOutputLongEdge: Int,
    ): Boolean = ViewportNative.detailOverlayCovers(
        normalizedRect, pixelWidth, pixelHeight, fullNativeWidth, fullNativeHeight,
        visibleRect, requiredZoomScale, maxOutputLongEdge,
    )
}
