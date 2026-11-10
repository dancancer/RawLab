package com.rawlab.android.editor

import kotlin.math.abs
import com.rawlab.android.geometry.GeometryCropMath
import com.rawlab.android.geometry.GeometryRatio
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.synchronizeHDR

data class AdjustmentDraftStep(
    val value: EditSettings,
    val ratio: GeometryRatio,
    val portrait: Boolean,
    val lockedRatio: Float?,
    val grid: Boolean,
    val includesPair: Boolean,
)

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
    val undoSteps: List<AdjustmentDraftStep> = emptyList(),
    val redoSteps: List<AdjustmentDraftStep> = emptyList(),
    val interacting: Boolean = false,
) {
    val geometryAspect: Float? get() = geometryLockedRatio?.let { if (geometryPortrait) 1f / it else it }
        ?: geometryRatio.ratio(geometryOriginalAspect, geometryPortrait)
    val changed: Boolean get() = project(original) != original
    fun project(settings: EditSettings): EditSettings = if (value == original) settings else if (includesPair)
        settings.copy(geometry = value.geometry, lens = value.lens).synchronizeHDR()
    else group.project(value, original, settings)
    val undoValues get() = undoSteps.map { it.value }
    val canUndo get() = undoSteps.isNotEmpty()
    val canRedo get() = redoSteps.isNotEmpty()
    private fun step() = AdjustmentDraftStep(value, geometryRatio, geometryPortrait, geometryLockedRatio, geometryGrid, includesPair)
    private fun restoring(step: AdjustmentDraftStep) = copy(value = step.value, geometryRatio = step.ratio,
        geometryPortrait = step.portrait, geometryLockedRatio = step.lockedRatio, geometryGrid = step.grid, includesPair = step.includesPair)
    fun undo(): AdjustmentDraft = undoSteps.lastOrNull()?.let {
        restoring(it).copy(undoSteps = undoSteps.dropLast(1), redoSteps = redoSteps + step(), interacting = false)
    } ?: this
    fun redo(): AdjustmentDraft = redoSteps.lastOrNull()?.let {
        restoring(it).copy(undoSteps = undoSteps + step(), redoSteps = redoSteps.dropLast(1), interacting = false)
    } ?: this
    private fun recording(next: AdjustmentDraft, interactive: Boolean = false): AdjustmentDraft {
        val changed = step() != next.step()
        var history = if (changed && !interacting) (undoSteps + step()).takeLast(100) else undoSteps
        if (!interactive && interacting && history.lastOrNull() == next.step()) history = history.dropLast(1)
        return next.copy(undoSteps = history, redoSteps = if (changed) emptyList() else redoSteps, interacting = interactive)
    }
    fun update(settings: EditSettings, interactive: Boolean = false): AdjustmentDraft {
        val next = group.project(settings, original, value)
        val resized = next.geometry.cropWidth != value.geometry.cropWidth || next.geometry.cropHeight != value.geometry.cropHeight
        val breaksRatio = geometryAspect?.let { ratio ->
            abs(next.geometry.cropWidth * geometryCanvasAspect / next.geometry.cropHeight - ratio) > .0001f
        } ?: false
        val changedCanvas = next.geometry.quarterTurns != value.geometry.quarterTurns ||
            next.geometry.straightenDegrees != value.geometry.straightenDegrees
        val unlock = resized && breaksRatio && !changedCanvas
        val originalTurned = geometryRatio == GeometryRatio.ORIGINAL && geometryLockedRatio == null &&
            next.geometry.quarterTurns % 2 != value.geometry.quarterTurns % 2
        return recording(copy(value = next, geometryRatio = if (unlock) GeometryRatio.FREE else geometryRatio,
            geometryLockedRatio = if (unlock) null else geometryLockedRatio,
            geometryPortrait = if (originalTurned) !geometryPortrait else geometryPortrait), interactive)
    }
    fun reset() = update(EditSettings()).copy(geometryRatio = GeometryRatio.FREE, geometryLockedRatio = null)

    internal fun resetPair(settings: EditSettings) = recording(copy(
        value = value.copy(geometry = settings.geometry, lens = settings.lens),
        includesPair = true, geometryRatio = GeometryRatio.FREE, geometryLockedRatio = null))

    fun selectGeometryRatio(ratio: GeometryRatio, portrait: Boolean): AdjustmentDraft {
        if (group != AdjustmentGroup.GEOMETRY) return this
        val next = copy(geometryRatio = ratio, geometryPortrait = portrait, geometryLockedRatio = null)
        return recording(next.copy(value = value.copy(geometry = GeometryCropMath.preset(value.geometry, next.geometryAspect, geometryCanvasAspect))))
    }

    fun toggleGeometryLock(): AdjustmentDraft {
        if (group != AdjustmentGroup.GEOMETRY) return this
        if (geometryAspect != null) return recording(copy(geometryRatio = GeometryRatio.FREE, geometryLockedRatio = null, geometryPortrait = false))
        return recording(copy(geometryRatio = GeometryRatio.FREE, geometryPortrait = false,
            geometryLockedRatio = value.geometry.cropWidth * geometryCanvasAspect / value.geometry.cropHeight))
    }

    fun swapGeometryRatio(): AdjustmentDraft {
        if (group != AdjustmentGroup.GEOMETRY || geometryAspect == null) return this
        val next = copy(geometryPortrait = !geometryPortrait)
        return recording(next.copy(value = value.copy(geometry = GeometryCropMath.preset(value.geometry, next.geometryAspect, geometryCanvasAspect))))
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
