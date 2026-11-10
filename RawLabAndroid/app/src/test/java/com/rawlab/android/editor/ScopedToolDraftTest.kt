package com.rawlab.android.editor

import com.rawlab.android.settings.*
import org.junit.Assert.*
import org.junit.Test

class ScopedToolDraftTest {
    @Test fun geometryHistoryRestoresRatioLockAndOrientationWithPixels() {
        val base = EditSettings()
        val initial = AdjustmentDraft.begin(AdjustmentGroup.GEOMETRY, base, originalAspect = 1.5f)
        val ratio = initial.selectGeometryRatio(com.rawlab.android.geometry.GeometryRatio.ORIGINAL, false)
        assertTrue(ratio.canUndo)
        assertEquals(initial.geometryRatio, ratio.undo().geometryRatio)
        val rotated = ratio.update(ratio.value.copy(geometry = ratio.value.geometry.copy(quarterTurns = 1)))
        assertNotEquals(ratio.geometryPortrait, rotated.geometryPortrait)
        assertEquals(ratio.geometryPortrait, rotated.undo().geometryPortrait)
        assertEquals(ratio.value, rotated.undo().value)
        assertEquals(rotated.geometryPortrait, rotated.undo().redo().geometryPortrait)
    }

    @Test fun hdrNoChangeDraftDoesNotUpgradeSettingsAndPairProjectionStaysSynchronized() {
        val settings = EditSettings(hdr = HDRSettings()).synchronizeHDR()
        assertFalse(AdjustmentDraft.begin(AdjustmentGroup.LOOK, settings).changed)
        val rotated = settings.copy(geometry = settings.geometry.copy(quarterTurns = 1)).synchronizeHDR()
        val draft = AdjustmentDraft.begin(AdjustmentGroup.GEOMETRY, rotated).resetPair(settings)
        assertEquals(draft.project(rotated).geometry, draft.project(rotated).hdr!!.geometry)
    }
    @Test fun scalarProjectionKeepsUnrelatedCommittedFields() {
        val base = EditSettings(exposure = 1f, saturation = .2f)
        val draft = AdjustmentDraft.begin(AdjustmentGroup.EXPOSURE, base)
            .update(base.copy(exposure = 2f, saturation = .9f))
        val committed = base.copy(saturation = .5f, strength = .7f)
        assertEquals(committed.copy(exposure = 2f), draft.project(committed))
        assertEquals(base.copy(exposure = 2f), draft.value)
        assertEquals(base, draft.undo().value)
        assertEquals(draft.value, draft.undo().redo().value)
    }

    @Test fun gestureCreatesOneLocalUndoStepAndNewEditClearsRedo() {
        val base = EditSettings()
        val draft = AdjustmentDraft.begin(AdjustmentGroup.SATURATION, base)
            .update(base.copy(saturation = .1f), interactive = true)
            .update(base.copy(saturation = .3f), interactive = true)
            .update(base.copy(saturation = .3f), interactive = false)
        assertEquals(1, draft.undoValues.size)
        assertEquals(base, draft.undo().value)
        assertFalse(draft.undo().update(base.copy(saturation = -.2f)).canRedo)
    }

    @Test fun hslDraftRetainsOtherChannelsAndIgnoresOtherTools() {
        val base = EditSettings()
        val hsl = HslSettings(List(24) { if (it == 9) 20f else 0f })
        val draft = AdjustmentDraft.begin(AdjustmentGroup.HSL, base).update(base.copy(hsl = hsl, exposure = 3f))
        assertEquals(base.copy(hsl = hsl), draft.project(base))
        assertFalse(AdjustmentDraft.begin(AdjustmentGroup.HSL, base).changed)
    }

    @Test fun lookConversionKeepsItsDependenciesButPreservesOtherTools() {
        val base = EditSettings(recipeID = "test", exposure = 1f, strength = .5f)
        val selected = base.selectFilm("neutral")
        val draft = AdjustmentDraft.begin(AdjustmentGroup.LOOK, base).update(selected)
        val current = base.copy(sharpening = .4f, lens = LensSettings(distortion = true))
        assertEquals(selected.copy(sharpening = .4f, lens = current.lens), draft.project(current))
        assertEquals(base, draft.undo().value)
    }

    @Test fun resetOnlyAcceptsActiveToolOrItsSubscope() {
        val base = EditSettings(exposure = 1f, saturation = .3f)
        val session = EditorResetSession(PhotoIdentity("photo"), "/photo", 1, 1, base,
            AdjustmentDraft.begin(AdjustmentGroup.EXPOSURE, base), 1,
            EditorResetContext(com.rawlab.android.format.PhotoInputKind.RAW, EditSettings()))
        assertTrue(EditorResetTransaction.prepare(EditorResetScope.Tool(2), session).result is EditorResetResult.Ready)
        assertTrue(EditorResetTransaction.prepare(EditorResetScope.Tool(7), session).result is EditorResetResult.Blocked)
    }
}
