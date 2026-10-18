package com.rawlab.android.geometry

import org.junit.Assert.*
import org.junit.Test
import com.rawlab.android.editor.AdjustmentDraft
import com.rawlab.android.editor.AdjustmentGroup
import com.rawlab.android.settings.EditSettings

class GeometryDraftTest {
    @Test fun originalRatioUsesSourceOrientationRatherThanEditedCanvas() {
        for (turns in 0..3) {
            val settings = EditSettings(geometry = GeometrySettings(quarterTurns = turns, cropWidth = .2f))
            val draft = AdjustmentDraft.begin(AdjustmentGroup.GEOMETRY, settings, 2f / 3f, .4f)
            assertEquals(turns % 2 == 0, draft.geometryPortrait)
            val original = draft.selectGeometryRatio(GeometryRatio.ORIGINAL, draft.geometryPortrait)
            assertEquals(if (turns % 2 == 0) 2f / 3f else 1.5f, original.geometryAspect!!, .00001f)
            val crop = original.value.geometry
            assertEquals(original.geometryAspect!!, crop.cropWidth * .4f / crop.cropHeight, .00001f)
        }
    }

    @Test fun currentCropRefitsAfterCanvasChangeWithoutEnlargementOrLosingEdits() {
        val settings = EditSettings(film = "velvia", exposure = .75f, geometry = GeometrySettings(perspectiveHorizontal = .3f))
        var draft = AdjustmentDraft.begin(AdjustmentGroup.GEOMETRY, settings, 1.5f, 1.5f)
            .selectGeometryRatio(GeometryRatio.FOUR_THREE, true)
        val resized = GeometryCropMath.resize(draft.value.geometry, GeometryCropCorner.BOTTOM_RIGHT, -.2f, -.2f,
            draft.geometryAspect, draft.geometryCanvasAspect)
        draft = draft.update(draft.value.copy(geometry = resized))
        assertEquals(GeometryRatio.FOUR_THREE, draft.geometryRatio)
        val refitted = draft.acceptGeometryCanvas(.6f)
        val crop = refitted.value.geometry
        assertEquals(.75f, crop.cropWidth * .6f / crop.cropHeight, .00001f)
        assertTrue(crop.cropWidth * crop.cropHeight <= resized.cropWidth * resized.cropHeight + .00001f)
        assertEquals(resized.cropX + resized.cropWidth / 2f, crop.cropX + crop.cropWidth / 2f, .00001f)
        assertEquals(resized.cropY + resized.cropHeight / 2f, crop.cropY + crop.cropHeight / 2f, .00001f)
        assertEquals(.3f, crop.perspectiveHorizontal, 0f)
        assertEquals(settings.exposure, refitted.project(settings).exposure, 0f)
        assertEquals(refitted, refitted.acceptGeometryCanvas(.6f))
    }

    @Test fun selectingOrientationTwiceDoesNotCumulativelyShrinkCrop() {
        val draft = AdjustmentDraft.begin(AdjustmentGroup.GEOMETRY, EditSettings(), 1.5f, 1.5f)
            .selectGeometryRatio(GeometryRatio.SIXTEEN_NINE, false)
        val flipped = draft.selectGeometryRatio(GeometryRatio.SIXTEEN_NINE, true)
        assertEquals(9f / 16f, flipped.geometryAspect!!, .00001f)
        assertEquals(draft.value.geometry, flipped.selectGeometryRatio(GeometryRatio.SIXTEEN_NINE, false).value.geometry)
        val free = flipped.selectGeometryRatio(GeometryRatio.FREE, true)
        assertEquals(flipped.value.geometry, free.value.geometry)
    }

    @Test fun numericSizeChangeUnlocksRatioButMovementDoesNot() {
        val settings = EditSettings(geometry = GeometrySettings(cropX = .1f, cropY = .1f, cropWidth = .6f, cropHeight = .6f))
        val draft = AdjustmentDraft.begin(AdjustmentGroup.GEOMETRY, settings).copy(geometryRatio = GeometryRatio.SQUARE)
        val moved = draft.update(settings.copy(geometry = settings.geometry.moveCrop(.1f, .1f)))
        assertEquals(GeometryRatio.SQUARE, moved.geometryRatio)
        val resized = moved.update(moved.value.copy(geometry = moved.value.geometry.copy(cropWidth = .4f)))
        assertEquals(GeometryRatio.FREE, resized.geometryRatio)
    }

    @Test fun resettingAnIdentitySquareStillClearsItsConstraint() {
        val draft = AdjustmentDraft.begin(AdjustmentGroup.GEOMETRY, EditSettings()).copy(geometryRatio = GeometryRatio.SQUARE)
        assertEquals(GeometryRatio.FREE, draft.reset().geometryRatio)
        assertEquals(GeometrySettings(), draft.reset().value.geometry)
    }
}
