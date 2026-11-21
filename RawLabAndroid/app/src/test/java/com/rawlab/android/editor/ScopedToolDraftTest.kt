package com.rawlab.android.editor

import com.rawlab.android.settings.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

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

    @Test fun effectsDraftPreservesUntouchedDecimalsInSdrAndHdrAcrossStoreReload() {
        val fx = PhotoEffectsSettings(
            vignetteAmount = -12.3f,
            vignetteMidpoint = 37.7f,
            vignetteRoundness = -12.5f,
            vignetteFeather = 50.3f,
            vignetteHighlights = 12.1f,
            grainAmount = 14.3f,
            grainSize = 25.9f,
            grainRoughness = 15.7f,
        )
        val sdrBase = EditSettings(effects = fx)
        assertFalse(AdjustmentDraft.begin(AdjustmentGroup.VIGNETTE, sdrBase).changed)
        assertFalse(AdjustmentDraft.begin(AdjustmentGroup.GRAIN, sdrBase).changed)

        val vigEdited = sdrBase.copy(effects = sdrBase.effects.withEffect(PhotoEffectParameter.VIGNETTE_AMOUNT, -10.3f))
        val vigDraft = AdjustmentDraft.begin(AdjustmentGroup.VIGNETTE, sdrBase).update(vigEdited)
        val grainEdited = sdrBase.copy(effects = sdrBase.effects.withEffect(PhotoEffectParameter.GRAIN_AMOUNT, 15.2f))
        val grainDraft = AdjustmentDraft.begin(AdjustmentGroup.GRAIN, sdrBase).update(grainEdited)

        val dir = Files.createTempDirectory("effects-decimal-draft").toFile()
        try {
            val store = EditorDraftStore(dir)
            val id = PhotoIdentity("content://photos/effects-decimal")
            store.save(id, "sdr-bytes", vigDraft)
            val restoredVig = requireNotNull(EditorDraftStore(dir).load(id, "sdr-bytes", sdrBase))
            val projectedVig = restoredVig.project(sdrBase)
            assertEquals(-10f, projectedVig.effects.vignetteAmount, 0f)
            assertEquals(fx.vignetteMidpoint, projectedVig.effects.vignetteMidpoint, 0f)
            assertEquals(fx.vignetteRoundness, projectedVig.effects.vignetteRoundness, 0f)
            assertEquals(fx.vignetteFeather, projectedVig.effects.vignetteFeather, 0f)
            assertEquals(fx.vignetteHighlights, projectedVig.effects.vignetteHighlights, 0f)
            assertEquals(fx, projectedVig.effects.copy(vignetteAmount = fx.vignetteAmount))

            store.save(id, "sdr-grain-bytes", grainDraft)
            val restoredGrain = requireNotNull(EditorDraftStore(dir).load(id, "sdr-grain-bytes", sdrBase))
            val projectedGrain = restoredGrain.project(sdrBase)
            assertEquals(15f, projectedGrain.effects.grainAmount, 0f)
            assertEquals(fx.grainSize, projectedGrain.effects.grainSize, 0f)
            assertEquals(fx.grainRoughness, projectedGrain.effects.grainRoughness, 0f)

            val hdrBase = EditSettings(hdr = HDRSettings().withEffects(fx)).synchronizeHDR()
            val hdrVigEdited = hdrBase.withEditingEffects(hdrBase.editingEffects.withEffect(PhotoEffectParameter.VIGNETTE_AMOUNT, -10.3f))
            val hdrVigDraft = AdjustmentDraft.begin(AdjustmentGroup.VIGNETTE, hdrBase).update(hdrVigEdited)
            store.save(id, "hdr-bytes", hdrVigDraft)
            val restoredHdrVig = requireNotNull(EditorDraftStore(dir).load(id, "hdr-bytes", hdrBase))
            val projectedHdrVig = restoredHdrVig.project(hdrBase)
            assertEquals(-10f, projectedHdrVig.editingEffects.vignetteAmount, 0f)
            assertEquals(fx.vignetteMidpoint, projectedHdrVig.editingEffects.vignetteMidpoint, 0f)
            assertEquals(fx.vignetteRoundness, projectedHdrVig.editingEffects.vignetteRoundness, 0f)
            assertEquals(fx.vignetteFeather, projectedHdrVig.editingEffects.vignetteFeather, 0f)
            assertEquals(fx.vignetteHighlights, projectedHdrVig.editingEffects.vignetteHighlights, 0f)
            assertEquals(fx.grainAmount, projectedHdrVig.editingEffects.grainAmount, 0f)
            assertEquals(fx.grainSize, projectedHdrVig.editingEffects.grainSize, 0f)
            assertEquals(fx.grainRoughness, projectedHdrVig.editingEffects.grainRoughness, 0f)
        } finally {
            dir.deleteRecursively()
        }
    }
}
