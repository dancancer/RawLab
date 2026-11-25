package com.rawlab.android.editor.inspection

import com.rawlab.android.geometry.GeometrySettings
import java.util.Locale
import kotlin.math.max

enum class InspectionOverlayMode {
    NONE,
    SKETCH_LUMINANCE,
    WARM_COOL_BW,
    OVERSATURATION_HEATMAP,
    SKIN_HUE_AMPLIFICATION,
    NEUTRAL_GRAY_50;

    val isActive: Boolean get() = this != NONE
}

data class InspectionColorSample(
    val r: Int,
    val g: Int,
    val b: Int,
    val hueDeg: Double,
    val saturationPct: Double,
    val brightnessPct: Double,
    val luminance: Double,
) {
    val rgbText: String get() = "$r $g $b"
    val hsbText: String
        get() = String.format(
            Locale.US,
            "%.0f° %.0f%% %.0f%%",
            hueDeg,
            saturationPct,
            brightnessPct
        )
}

data class InspectionAnchor(
    val id: Long,
    val sourceX: Float,
    val sourceY: Float,
) {
    companion object {
        const val MAX_COUNT = 4
    }
}

data class InspectionSessionState(
    val monitorEnabled: Boolean = false,
    val liveOutputX: Float? = null,
    val liveOutputY: Float? = null,
    val anchors: List<InspectionAnchor> = emptyList(),
    val selectedAnchorId: Long? = null,
    val overlay: InspectionOverlayMode = InspectionOverlayMode.NONE,
    val lastNonGrayOverlay: InspectionOverlayMode = InspectionOverlayMode.NONE,
    val nextAnchorId: Long = 1L,
) {
    val canPinMore: Boolean get() = anchors.size < InspectionAnchor.MAX_COUNT

    fun selectOverlay(mode: InspectionOverlayMode): InspectionSessionState = copy(
        overlay = mode,
        lastNonGrayOverlay = if (mode != InspectionOverlayMode.NEUTRAL_GRAY_50) mode else lastNonGrayOverlay
    )

    fun toggleNeutralGray50(): InspectionSessionState =
        if (overlay == InspectionOverlayMode.NEUTRAL_GRAY_50) {
            val restored = if (lastNonGrayOverlay == InspectionOverlayMode.NEUTRAL_GRAY_50) {
                InspectionOverlayMode.NONE
            } else {
                lastNonGrayOverlay
            }
            copy(overlay = restored)
        } else {
            copy(lastNonGrayOverlay = overlay, overlay = InspectionOverlayMode.NEUTRAL_GRAY_50)
        }

    fun dismissOverlay(): InspectionSessionState = when (overlay) {
        InspectionOverlayMode.NONE -> this
        InspectionOverlayMode.NEUTRAL_GRAY_50 -> {
            val restored = if (lastNonGrayOverlay == InspectionOverlayMode.NEUTRAL_GRAY_50) {
                InspectionOverlayMode.NONE
            } else {
                lastNonGrayOverlay
            }
            copy(overlay = restored)
        }
        else -> copy(overlay = InspectionOverlayMode.NONE, lastNonGrayOverlay = InspectionOverlayMode.NONE)
    }

    fun pinAnchor(sourceX: Float, sourceY: Float): InspectionSessionState {
        if (!canPinMore) return this
        val anchor = InspectionAnchor(
            id = nextAnchorId,
            sourceX = sourceX.coerceIn(0f, 1f),
            sourceY = sourceY.coerceIn(0f, 1f)
        )
        return copy(
            anchors = anchors + anchor,
            selectedAnchorId = anchor.id,
            nextAnchorId = nextAnchorId + 1L
        )
    }

    fun removeAnchor(id: Long): InspectionSessionState {
        val next = anchors.filterNot { it.id == id }
        val nextSelected = if (selectedAnchorId == id) next.lastOrNull()?.id else selectedAnchorId
        return copy(anchors = next, selectedAnchorId = nextSelected)
    }

    fun clearAnchors(): InspectionSessionState = copy(anchors = emptyList(), selectedAnchorId = null)

    fun resetForNewSource(): InspectionSessionState = InspectionSessionState()

    fun saveToList(): List<Any?> = buildList {
        add(monitorEnabled)
        add(liveOutputX)
        add(liveOutputY)
        add(selectedAnchorId)
        add(overlay.ordinal)
        add(lastNonGrayOverlay.ordinal)
        add(nextAnchorId)
        add(anchors.size)
        for (anchor in anchors) {
            add(anchor.id)
            add(anchor.sourceX)
            add(anchor.sourceY)
        }
    }

    companion object {
        fun restoreFromList(raw: List<Any?>): InspectionSessionState {
            if (raw.size < 8) return InspectionSessionState()
            val monitor = raw[0] as? Boolean ?: false
            val liveX = (raw[1] as? Number)?.toFloat()
            val liveY = (raw[2] as? Number)?.toFloat()
            val selectedId = (raw[3] as? Number)?.toLong()
            val overlayOrdinal = (raw[4] as? Number)?.toInt() ?: 0
            val lastOrdinal = (raw[5] as? Number)?.toInt() ?: 0
            val nextId = (raw[6] as? Number)?.toLong() ?: 1L
            val anchorCount = (raw[7] as? Number)?.toInt() ?: 0
            val entries = InspectionOverlayMode.entries
            val overlayMode = entries.getOrElse(overlayOrdinal) { InspectionOverlayMode.NONE }
            val lastMode = entries.getOrElse(lastOrdinal) { InspectionOverlayMode.NONE }
            val restoredAnchors = buildList {
                var idx = 8
                for (i in 0 until anchorCount) {
                    if (idx + 2 >= raw.size) break
                    val id = (raw[idx] as? Number)?.toLong() ?: break
                    val sx = (raw[idx + 1] as? Number)?.toFloat() ?: break
                    val sy = (raw[idx + 2] as? Number)?.toFloat() ?: break
                    add(InspectionAnchor(id = id, sourceX = sx, sourceY = sy))
                    idx += 3
                }
            }
            return InspectionSessionState(
                monitorEnabled = monitor,
                liveOutputX = liveX,
                liveOutputY = liveY,
                anchors = restoredAnchors,
                selectedAnchorId = selectedId,
                overlay = overlayMode,
                lastNonGrayOverlay = lastMode,
                nextAnchorId = nextId,
            )
        }
    }
}

object InspectionColorMath {
    internal fun fromNativeArray(arr: DoubleArray?): InspectionColorSample? {
        if (arr == null || arr.size < 7) return null
        return InspectionColorSample(
            r = arr[0].toInt(),
            g = arr[1].toInt(),
            b = arr[2].toInt(),
            hueDeg = arr[3],
            saturationPct = arr[4],
            brightnessPct = arr[5],
            luminance = arr[6],
        )
    }

    fun fromRgb(r: Int, g: Int, b: Int): InspectionColorSample {
        val arr = InspectionNative.nativeColorFromRgb(r.coerceIn(0, 255), g.coerceIn(0, 255), b.coerceIn(0, 255))
        return fromNativeArray(arr) ?: InspectionColorSample(
            r.coerceIn(0, 255), g.coerceIn(0, 255), b.coerceIn(0, 255), 0.0, 0.0, 0.0, 0.0
        )
    }

    fun applyOverlayPixel(r: Int, g: Int, b: Int, mode: InspectionOverlayMode): Int =
        InspectionNative.nativeOverlayPixel(r.coerceIn(0, 255), g.coerceIn(0, 255), b.coerceIn(0, 255), mode.ordinal)
}

object InspectionGeometryMapper {
    fun inferSourceSize(outputWidth: Int, outputHeight: Int, options: GeometrySettings): Pair<Int, Int> {
        val safeW = max(1, outputWidth)
        val safeH = max(1, outputHeight)
        val dims = InspectionNative.nativeInferSourceSize(
            safeW,
            safeH,
            options.cropX,
            options.cropY,
            options.cropWidth,
            options.cropHeight,
            options.quarterTurns,
            options.flipHorizontal,
            options.flipVertical,
            options.straightenDegrees,
            options.perspectiveHorizontal,
            options.perspectiveVertical,
        ) ?: return safeW to safeH
        return dims[0] to dims[1]
    }

    fun outputNormToSourceNorm(
        outX: Float,
        outY: Float,
        sourceWidth: Int,
        sourceHeight: Int,
        geometry: GeometrySettings,
    ): Pair<Float, Float>? {
        if (!outX.isFinite() || !outY.isFinite() || sourceWidth < 1 || sourceHeight < 1) return null
        val pt = InspectionNative.nativeOutputNormToSourceNorm(
            sourceWidth,
            sourceHeight,
            geometry.cropX,
            geometry.cropY,
            geometry.cropWidth,
            geometry.cropHeight,
            geometry.quarterTurns,
            geometry.flipHorizontal,
            geometry.flipVertical,
            geometry.straightenDegrees,
            geometry.perspectiveHorizontal,
            geometry.perspectiveVertical,
            outX.toDouble(),
            outY.toDouble(),
        ) ?: return null
        return pt[0] to pt[1]
    }

    fun sourceNormToOutputNorm(
        srcX: Float,
        srcY: Float,
        sourceWidth: Int,
        sourceHeight: Int,
        geometry: GeometrySettings,
    ): Pair<Float, Float>? {
        if (!srcX.isFinite() || !srcY.isFinite() || sourceWidth < 1 || sourceHeight < 1) return null
        val pt = InspectionNative.nativeSourceNormToOutputNorm(
            sourceWidth,
            sourceHeight,
            geometry.cropX,
            geometry.cropY,
            geometry.cropWidth,
            geometry.cropHeight,
            geometry.quarterTurns,
            geometry.flipHorizontal,
            geometry.flipVertical,
            geometry.straightenDegrees,
            geometry.perspectiveHorizontal,
            geometry.perspectiveVertical,
            srcX.toDouble(),
            srcY.toDouble(),
        ) ?: return null
        return pt[0] to pt[1]
    }
}
