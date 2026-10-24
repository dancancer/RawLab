package com.rawlab.android.adjustments

import com.rawlab.android.settings.EditSettings
import com.rawlab.android.editor.*
import com.rawlab.android.format.PhotoInputKind
import org.junit.Assert.*
import org.junit.Test

class ToneControlsTransferTest {
    private val fields = setOf(AdjustmentField.BLACK_POINT, AdjustmentField.WHITE_POINT, AdjustmentField.VIBRANCE)
    private val context = AdjustmentTransferContext("tone", true)
    private val source = EditSettings(blackPoint = -37.25f, whitePoint = 42.5f, vibrance = 18.125f)

    @Test fun scopesAndRecipeStrengthKeepIndependentToneValues() {
        val modified = AdjustmentTransfer.capture(AdjustmentScope.Modified, source, context)
        assertEquals(fields, modified.fields)
        assertTrue(AdjustmentField.COMMON.containsAll(fields))
        assertEquals(source, AdjustmentTransfer.prepare(modified, EditSettings(), context))
        val partial = AdjustmentTransfer.capture(AdjustmentScope.Custom(setOf(AdjustmentField.WHITE_POINT)), source, context)
        val target = EditSettings(blackPoint = 71f, whitePoint = -29f, vibrance = -63f)
        assertEquals(target.copy(whitePoint = 42.5f), AdjustmentTransfer.prepare(partial, target, context))
        val old = AdjustmentTransfer.capture(AdjustmentScope.Custom(setOf(AdjustmentField.EXPOSURE)), EditSettings(), context)
        assertEquals(target, AdjustmentTransfer.prepare(old, target, context))
        val recipeSource = source.copy(recipeID = "recipe", strength = 0f)
        val recipeTarget = target.copy(recipeID = "recipe", strength = 0f)
        val copy = AdjustmentTransfer.capture(AdjustmentScope.Custom(fields), recipeSource, context)
        assertEquals(recipeSource, AdjustmentTransfer.prepare(copy, recipeTarget, context))
    }

    @Test fun groupAndToolResetsIncludeToneWithoutTouchingOtherGroups() {
        val context = EditorResetContext(PhotoInputKind.RASTER, EditSettings())
        assertTrue(EditorAdjustmentRules.isModified(EditorResetScope.Tool(18), source, context))
        assertTrue(EditorAdjustmentRules.isModified(EditorResetScope.Tool(19), source, context))
        assertTrue(EditorAdjustmentRules.isModified(EditorResetScope.Tool(20), source, context))
        val light = EditorAdjustmentRules.prepareReset(EditorResetScope.Group(EditorAdjustmentGroup.LIGHT), source, context) as EditorResetResult.Ready
        assertEquals(source.copy(blackPoint = 0f, whitePoint = 0f, exposureMode = 2), light.candidate)
        val color = EditorAdjustmentRules.prepareReset(EditorResetScope.Group(EditorAdjustmentGroup.COLOR), source, context) as EditorResetResult.Ready
        assertEquals(source.copy(vibrance = 0f), color.candidate)
    }
}
