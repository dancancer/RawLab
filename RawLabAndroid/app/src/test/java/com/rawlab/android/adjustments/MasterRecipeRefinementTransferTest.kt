package com.rawlab.android.adjustments

import com.rawlab.android.looks.MasterRecipe
import com.rawlab.android.looks.applyRecipe
import com.rawlab.android.settings.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class MasterRecipeRefinementTransferTest {
    private val recipe = MasterRecipe.decode(JSONObject(File("../../Shared/fixtures/master-recipe-v4.json").readText()))
    private val context = AdjustmentTransferContext("source", true, setOf("recipe:${recipe.id}"), cameraTemperature = 5200f, cameraTint = 10f)
    private val fields = setOf(AdjustmentField.BLACK_POINT, AdjustmentField.WHITE_POINT, AdjustmentField.VIBRANCE,
        AdjustmentField.CLARITY, AdjustmentField.DEHAZE, AdjustmentField.CURVE, AdjustmentField.S_CURVE,
        AdjustmentField.GRADING_SHADOWS, AdjustmentField.GRADING_MIDTONES, AdjustmentField.GRADING_HIGHLIGHTS)

    @Test fun fullAndPartialTransfersRespectVersionFour() {
        for (strength in listOf(0f, .5f, 1f, 2f)) {
            val source = EditSettings().applyRecipe(recipe).copy(strength = strength)
            val partial = AdjustmentTransfer.capture(AdjustmentScope.Custom(fields), source, context)
            val plain = AdjustmentTransfer.prepare(partial, EditSettings(), context)
            assertNull(plain.recipeID)
            assertEquals(source.renderBlackPoint, plain.blackPoint); assertEquals(source.renderWhitePoint, plain.whitePoint)
            assertEquals(source.renderVibrance, plain.vibrance); assertEquals(source.renderClarity, plain.clarity)
            assertEquals(source.renderDehaze, plain.dehaze); assertEquals(source.renderCurve, plain.curve)
            assertEquals(source.renderColorGrading, plain.colorGrading)
            val full = AdjustmentTransfer.capture(AdjustmentScope.All, source, context)
            val copied = AdjustmentTransfer.prepare(full, EditSettings(), context)
            assertEquals(4, copied.masterRecipeSettingsVersion); assertEquals(source.recipeID, copied.recipeID)
            assertEquals(source.blackPoint, copied.blackPoint); assertEquals(source.curve, copied.curve)
            assertEquals(source.colorGrading, copied.colorGrading); assertEquals(strength, copied.strength)
        }
    }

    @Test fun oldDependencySelectionDetachesAndStrengthOnlyPreservesUnselectedEffects() {
        val source = EditSettings().applyRecipe(recipe).copy(strength = .5f)
        val incomplete = AdjustmentTransfer.capture(AdjustmentScope.Custom(AdjustmentField.RECIPE_DEPENDENCIES), source, context)
        val separate = AdjustmentTransfer.prepare(incomplete, EditSettings(), context)
        assertNull(separate.recipeID); assertEquals("recipe-lut:${recipe.id}", separate.film)
        val target = source.copy(tint = 0f)
        val strength = AdjustmentTransfer.capture(AdjustmentScope.Custom(setOf(AdjustmentField.STRENGTH)), source.copy(strength = 1f), context)
        val changed = AdjustmentTransfer.prepare(strength, target, context)
        assertEquals(target.renderBlackPoint, changed.renderBlackPoint); assertEquals(target.renderWhitePoint, changed.renderWhitePoint)
        assertEquals(target.renderVibrance, changed.renderVibrance); assertEquals(target.renderClarity, changed.renderClarity)
        assertEquals(target.renderDehaze, changed.renderDehaze); assertEquals(target.renderColorGrading, changed.renderColorGrading)
        assertEquals(target.renderCurve, changed.renderCurve)
    }
}
