package com.rawlab.android.editor

import kotlin.math.abs
import com.rawlab.android.geometry.GeometryCropMath
import com.rawlab.android.geometry.GeometryRatio
import com.rawlab.android.settings.EditSettings

// ============================================================================
//  几何与镜头的草稿：确认前只在草稿里改，取消即回到原参数
// ============================================================================

enum class AdjustmentGroup { GEOMETRY, LENS }

data class AdjustmentDraft(
    val group: AdjustmentGroup,
    val original: EditSettings,
    val value: EditSettings,
    val geometryRatio: GeometryRatio = GeometryRatio.FREE,
    val geometryPortrait: Boolean = false,
    val geometryOriginalAspect: Float = 1f,
    val geometryCanvasAspect: Float = 1f,
    val geometryLockedRatio: Float? = null,
    val geometryGrid: Boolean = true,
    val includesPair: Boolean = false,
) {
    val geometryAspect: Float? get() = geometryLockedRatio?.let { if (geometryPortrait) 1f / it else it }
        ?: geometryRatio.ratio(geometryOriginalAspect, geometryPortrait)
    val changed: Boolean get() = project(original) != original
    fun project(settings: EditSettings): EditSettings = if (includesPair)
        settings.copy(geometry = value.geometry, lens = value.lens)
    else when (group) {
        AdjustmentGroup.GEOMETRY -> settings.copy(geometry = value.geometry)
        AdjustmentGroup.LENS -> settings.copy(lens = value.lens)
    }
    fun update(settings: EditSettings): AdjustmentDraft {
        val next = when (group) {
            AdjustmentGroup.GEOMETRY -> value.copy(geometry = settings.geometry)
            AdjustmentGroup.LENS -> value.copy(lens = settings.lens)
        }
        val resized = next.geometry.cropWidth != value.geometry.cropWidth || next.geometry.cropHeight != value.geometry.cropHeight
        val breaksRatio = geometryAspect?.let { ratio ->
            abs(next.geometry.cropWidth * geometryCanvasAspect / next.geometry.cropHeight - ratio) > .0001f
        } ?: false
        val changedCanvas = next.geometry.quarterTurns != value.geometry.quarterTurns ||
            next.geometry.straightenDegrees != value.geometry.straightenDegrees
        val unlock = resized && breaksRatio && !changedCanvas
        val originalTurned = geometryRatio == GeometryRatio.ORIGINAL && geometryLockedRatio == null &&
            next.geometry.quarterTurns % 2 != value.geometry.quarterTurns % 2
        return copy(value = next, geometryRatio = if (unlock) GeometryRatio.FREE else geometryRatio,
            geometryLockedRatio = if (unlock) null else geometryLockedRatio,
            geometryPortrait = if (originalTurned) !geometryPortrait else geometryPortrait)
    }
    fun reset() = update(EditSettings()).copy(geometryRatio = GeometryRatio.FREE, geometryLockedRatio = null)

    internal fun resetPair(settings: EditSettings) = copy(
        value = value.copy(geometry = settings.geometry, lens = settings.lens),
        includesPair = true, geometryRatio = GeometryRatio.FREE, geometryLockedRatio = null)

    fun selectGeometryRatio(ratio: GeometryRatio, portrait: Boolean): AdjustmentDraft {
        if (group != AdjustmentGroup.GEOMETRY) return this
        val next = copy(geometryRatio = ratio, geometryPortrait = portrait, geometryLockedRatio = null)
        return next.copy(value = value.copy(geometry = GeometryCropMath.preset(value.geometry, next.geometryAspect, geometryCanvasAspect)))
    }

    fun toggleGeometryLock(): AdjustmentDraft {
        if (group != AdjustmentGroup.GEOMETRY) return this
        if (geometryAspect != null) return copy(geometryRatio = GeometryRatio.FREE, geometryLockedRatio = null, geometryPortrait = false)
        return copy(geometryRatio = GeometryRatio.FREE, geometryPortrait = false,
            geometryLockedRatio = value.geometry.cropWidth * geometryCanvasAspect / value.geometry.cropHeight)
    }

    fun swapGeometryRatio(): AdjustmentDraft {
        if (group != AdjustmentGroup.GEOMETRY || geometryAspect == null) return this
        val next = copy(geometryPortrait = !geometryPortrait)
        return next.copy(value = value.copy(geometry = GeometryCropMath.preset(value.geometry, next.geometryAspect, geometryCanvasAspect)))
    }

    fun acceptGeometryCanvas(canvasAspect: Float): AdjustmentDraft {
        if (group != AdjustmentGroup.GEOMETRY || canvasAspect == geometryCanvasAspect) return this
        return copy(geometryCanvasAspect = canvasAspect,
            value = value.copy(geometry = GeometryCropMath.refit(value.geometry, geometryAspect, canvasAspect)))
    }

    companion object {
        fun begin(group: AdjustmentGroup, settings: EditSettings, originalAspect: Float = 1f, canvasAspect: Float = 1f) =
            AdjustmentDraft(group, settings, settings,
                geometryPortrait = (originalAspect < 1f) != (settings.geometry.quarterTurns % 2 == 1),
                geometryOriginalAspect = originalAspect, geometryCanvasAspect = canvasAspect)
    }
}
