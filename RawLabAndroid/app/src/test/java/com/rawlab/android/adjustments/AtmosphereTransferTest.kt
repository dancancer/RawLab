package com.rawlab.android.adjustments

import com.rawlab.android.settings.*
import com.rawlab.android.editor.*
import com.rawlab.android.format.PhotoInputKind
import org.junit.Assert.*
import org.junit.Test

class AtmosphereTransferTest {
    private val fields = setOf(AdjustmentField.CLARITY, AdjustmentField.DEHAZE)
    private val context = AdjustmentTransferContext("atmosphere", true)
    private val source = EditSettings(clarity = -37.251234f, dehaze = 42.5f)

    @Test fun partialAndLegacyTransfersPreserveIndependentAtmosphere() {
        val modified = AdjustmentTransfer.capture(AdjustmentScope.Modified, source, context)
        assertEquals(fields, modified.fields)
        assertTrue(AdjustmentField.COMMON.containsAll(fields))
        assertTrue(fields.all { it.group == "effects" })
        assertEquals(source, AdjustmentTransfer.prepare(modified, EditSettings(), context))
        val partial = AdjustmentTransfer.capture(AdjustmentScope.Custom(setOf(AdjustmentField.DEHAZE)), source, context)
        val target = EditSettings(clarity = 71f, dehaze = -29f, effects = PhotoEffectsSettings(grainAmount = 13f))
        assertEquals(target.copy(dehaze = 42.5f), AdjustmentTransfer.prepare(partial, target, context))
        val old = AdjustmentTransfer.capture(AdjustmentScope.Custom(setOf(AdjustmentField.EXPOSURE)), EditSettings(), context)
        assertEquals(target, AdjustmentTransfer.prepare(old, target, context))
        val recipeSource = source.copy(recipeID = "recipe", strength = 0f)
        val recipeTarget = target.copy(recipeID = "recipe", strength = 0f)
        val copy = AdjustmentTransfer.capture(AdjustmentScope.Custom(fields), recipeSource, context)
        assertEquals(recipeTarget.copy(clarity = source.clarity, dehaze = source.dehaze), AdjustmentTransfer.prepare(copy, recipeTarget, context))
    }

    @Test fun effectsResetAndIndividualToolsIncludeAtmosphere() {
        val context = EditorResetContext(PhotoInputKind.RASTER, EditSettings())
        val state = source.copy(vibrance = 19f, effects = PhotoEffectsSettings(grainAmount = 13f))
        assertTrue(EditorAdjustmentRules.isModified(EditorResetScope.Tool(22), state, context))
        assertTrue(EditorAdjustmentRules.isModified(EditorResetScope.Tool(23), state, context))
        val group = EditorAdjustmentRules.prepareReset(EditorResetScope.Group(EditorAdjustmentGroup.EFFECTS), state, context) as EditorResetResult.Ready
        assertEquals(state.copy(clarity = 0f, dehaze = 0f, effects = PhotoEffectsSettings()), group.candidate)
        val tool = EditorAdjustmentRules.prepareReset(EditorResetScope.Tool(22), state, context) as EditorResetResult.Ready
        assertEquals(state.copy(clarity = 0f), tool.candidate)
    }
}
