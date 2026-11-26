package com.rawlab.android.editor

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import com.rawlab.android.R
import com.rawlab.android.editor.ui.editorToolOrder
import com.rawlab.android.editor.ui.editorToolTitles
import com.rawlab.android.editor.ui.whiteBalanceChanged
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.FilmOpticsSettings
import com.rawlab.android.settings.GrainFormatPreset
import com.rawlab.android.settings.GrainToneCurve
import com.rawlab.android.settings.PhotoEffectParameter
import com.rawlab.android.settings.editingEffects
import com.rawlab.android.settings.withEditingEffects
import com.rawlab.android.editor.ui.editorToolIcons

class EditorToolGroupingTest {
    @Test fun everyGroupStartsAtItsDesignatedTool() {
        assertEquals(listOf(0, 2, 8, 22, 11, 17, 24), EditorAdjustmentGroup.entries.map(EditorAdjustmentRules::defaultTool))
        assertEquals(listOf(0, 2, 8, 22, 11, 17), EditorAdjustmentRules.visibleGroups(false).map(EditorAdjustmentRules::defaultTool))
        assertEquals(listOf(0, 2, 8, 22, 11, 17, 24), EditorAdjustmentRules.visibleGroups(true).map(EditorAdjustmentRules::defaultTool))
    }

    @Test fun busyDoesNotHideStoredLegacyAuxiliaryObjectMarkers() {
        val state = EditorState(edits = EditSettings(displayChromaDenoise = 2), rendering = true)
        assertTrue(EditorAdjustmentRules.isModified(EditorResetScope.Tool(11), state.visibleEdits, state.resetContext()))
        assertTrue(EditorAdjustmentRules.isModified(EditorResetScope.Group(EditorAdjustmentGroup.DETAIL), state.visibleEdits, state.resetContext()))
    }

    @Test fun toolsFollowTheSevenWorkspaceGroupsWithStableIds() {
        assertEquals(listOf(0, 15, 1, 2, 3, 4, 18, 19, 5, 6, 8, 7, 20, 14, 29, 30, 31, 21, 32, 22, 23, 28, 12, 13, 11, 10, 17, 16, 24, 25, 26, 27), editorToolOrder)
        assertEquals(listOf(24, 25, 26, 27), EditorAdjustmentRules.tools(EditorAdjustmentGroup.HDR_RENDITION))
        assertTrue((24..27).all(EditorAdjustmentRules::supportsHDR))
        assertTrue((28..32).none(EditorAdjustmentRules::supportsHDR))
    }

    @Test fun whiteBalanceUsesOneToolEntryWithTheCombinedTitle() {
        assertEquals(1, editorToolOrder.count { it == 8 || it == 9 })
        assertTrue(editorToolOrder.contains(8))
        assertFalse(editorToolOrder.contains(9))
        assertEquals(R.string.white_balance, editorToolTitles[8])
    }

    @Test fun whiteBalanceChangedIndicatorCoversTemperatureAndTint() {
        assertFalse(whiteBalanceChanged(EditSettings(), 6500f, 0f))
        assertTrue(whiteBalanceChanged(EditSettings(customWb = true, temperature = 7000f), 6500f, 0f))
        assertTrue(whiteBalanceChanged(EditSettings(customWb = true, tint = 12f), 6500f, 0f))
    }

    @Test fun whiteBalanceGroupResetRestoresBothAxesWithoutChangingRecipeFormat() {
        val edited = EditSettings(film = "velvia", customWb = true, temperature = 8000f, tint = 22f)
        val reset = edited.resetWhiteBalance(5200f, -3f)
        assertFalse(reset.customWb)
        assertEquals(5200f, reset.temperature)
        assertEquals(-3f, reset.tint)
        assertEquals("velvia", reset.film)

        val recipeReset = edited.copy(recipeID = "recipe").resetWhiteBalance(5200f, -3f)
        assertEquals("recipe", recipeReset.recipeID)
        assertEquals(0f, recipeReset.tint)
    }

    // 工具条上每个可见工具都有自己的图标（“强度”和“HSL”曾共用同一个滑杆图标）
    @Test fun everyVisibleToolHasItsOwnIcon() {
        val icons = editorToolOrder.map { editorToolIcons[it] }
        assertEquals(editorToolOrder.filterIndexed { i, _ -> icons.indexOf(icons[i]) != i }.toString(), icons.size, icons.toSet().size)
    }

    @Test fun grainPresetsAndFilmOpticsSurviveDraftProjection() {
        val fx135 = EditSettings().editingEffects.applyGrainFormatPreset(GrainFormatPreset.FILM_135)
        assertEquals(18f, fx135.grainSize)
        assertEquals(65f, fx135.grainRoughness)
        val fxCustom = fx135.withGrainEffect(PhotoEffectParameter.GRAIN_SIZE, 29f)
        assertEquals(GrainFormatPreset.CUSTOM, fxCustom.grainFormatPreset)
        assertEquals(29f, fxCustom.grainSize)

        val base = EditSettings().withEditingEffects(EditSettings().editingEffects.copy(vignetteAmount = -30f))
        val edited = base.withEditingEffects(
            base.editingEffects.copy(grainToneCurve = GrainToneCurve.NEGATIVE_ASYMMETRIC, grainFormatPreset = GrainFormatPreset.FILM_120)
        ).copy(filmOptics = FilmOpticsSettings(halationAmount = 50f, bloomAmount = 25f))
        val projected = AdjustmentGroup.GRAIN.project(edited, base, base)
        assertEquals(-30f, projected.editingEffects.vignetteAmount)
        assertEquals(GrainToneCurve.NEGATIVE_ASYMMETRIC, projected.editingEffects.grainToneCurve)
        assertEquals(GrainFormatPreset.FILM_120, projected.editingEffects.grainFormatPreset)
        assertEquals(50f, projected.filmOptics.halationAmount)
        assertEquals(25f, projected.filmOptics.bloomAmount)
    }

    @Test fun sharpenV2AutoEnablesOnNewEditsWhilePreservingLegacy() {
        val untouchedLegacy = EditSettings(sharpening = 0.5f)
        val adjustedLegacy = untouchedLegacy.applySharpenV2Edit(amount = 0.7f)
        assertEquals(0.7f, adjustedLegacy.sharpening)
        assertFalse(adjustedLegacy.sharpenV2.luminanceV2)

        val freshV2 = EditSettings().applySharpenV2Edit(amount = 0.5f)
        assertTrue(freshV2.sharpenV2.luminanceV2)

        val v2Radius = untouchedLegacy.applySharpenV2Edit(radius = 1.8f)
        assertTrue(v2Radius.sharpenV2.luminanceV2)
        assertEquals(1.8f, v2Radius.sharpenV2.radius)
    }
}
