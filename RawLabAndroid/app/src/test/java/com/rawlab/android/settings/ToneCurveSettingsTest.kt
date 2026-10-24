package com.rawlab.android.settings

import com.rawlab.android.adjustments.*
import com.rawlab.android.editor.*
import com.rawlab.android.format.PhotoInputKind
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ToneCurveSettingsTest {
    private val curve = ToneCurveSettings.identity.inserting(.25, .125).inserting(.75, .875)

    @Test fun pointsAreImmutableOrderedAndBounded() {
        val points = mutableListOf(ToneCurvePoint(0.0, 0.0), ToneCurvePoint(1.0, 1.0))
        val frozen = ToneCurveSettings(ToneCurveMode.CUSTOM, points)
        points[1] = ToneCurvePoint(.5, .5)
        assertEquals(ToneCurveSettings.identity, frozen)
        assertEquals(curve, curve.moving(0, .1, .1))
        assertEquals(curve, curve.removing(3))
        val moved = curve.moving(1, 1.0, 1.0)
        assertTrue(moved.points[1].x < moved.points[2].x)
        assertEquals(.875, moved.points[1].y, 0.0)
        assertEquals(curve, curve.inserting(.25, .4))
        assertEquals(3, curve.removing(1).points.size)
        assertThrows(IllegalArgumentException::class.java) { ToneCurveSettings(ToneCurveMode.LEGACY, frozen.points) }
        assertThrows(IllegalArgumentException::class.java) { ToneCurveSettings(ToneCurveMode.CUSTOM,
            listOf(ToneCurvePoint(0.0, 0.0), ToneCurvePoint(.5, .6), ToneCurvePoint(.6, .5), ToneCurvePoint(1.0, 1.0))) }
    }

    @Test fun storageRetainsInactiveLegacyAndDoubleCoordinates() {
        val precise = curve.moving(1, .250000000000001, .125000000000001)
        val source = EditSettings(toneCurve = .65f, curve = precise)
        assertEquals(source, SettingsCodec.decode(SettingsCodec.encode(source)))
        assertEquals(0f, source.renderToneCurve)
        val old = JSONObject(SettingsCodec.encode(source).removePrefix("v2:"))
        old.getJSONObject("settings").remove("curve")
        val restored = SettingsCodec.decode("v2:$old")
        assertTrue(restored.curve.isDefault); assertEquals(.65f, restored.renderToneCurve)
        for (bad in listOf("""{"mode":"custom","points":[[0,0],[1,1,2]]}""",
            """{"mode":"custom","points":[[0,0],[0.5,0.6],[0.5,0.8],[1,1]]}""",
            """{"mode":"custom","points":[[0,0],[1,1]],"future":0}""")) {
            old.getJSONObject("settings").put("curve", JSONObject(bad))
            assertThrows(Exception::class.java) { SettingsCodec.decode("v2:$old") }
        }
    }

    @Test fun transferKeepsModeAndScalarIndependentlySelectable() {
        val context = AdjustmentTransferContext("curve", false)
        val source = EditSettings(toneCurve = .65f, curve = curve)
        val all = AdjustmentTransfer.capture(AdjustmentScope.Modified, source, context)
        assertEquals(setOf(AdjustmentField.S_CURVE, AdjustmentField.CURVE), all.fields)
        val target = EditSettings(toneCurve = -.25f)
        val partial = AdjustmentTransfer.capture(AdjustmentScope.Custom(setOf(AdjustmentField.CURVE)), source, context)
        val restored = AdjustmentTransfer.prepare(AdjustmentPayload.decode(partial.encode()), target, context)
        assertEquals(curve, restored.curve); assertEquals(-.25f, restored.toneCurve)
        val legacy = AdjustmentTransfer.capture(AdjustmentScope.Custom(setOf(AdjustmentField.S_CURVE)), source, context)
        assertEquals(curve, AdjustmentTransfer.prepare(legacy, restored, context).curve)
        assertEquals(.65f, AdjustmentTransfer.prepare(legacy, restored, context).toneCurve)
    }

    @Test fun recipeStrengthDoesNotChangeCurveAndResetIncludesMode() {
        val source = EditSettings(toneCurve = .65f, curve = curve)
        for (strength in listOf(0f, .5f, 1f, 2f)) {
            val recipe = source.copy(recipeID = "r", strength = strength)
            assertEquals(curve, recipe.curve); assertEquals(0f, recipe.renderToneCurve)
        }
        val context = EditorResetContext(PhotoInputKind.RASTER, EditSettings())
        for (scope in listOf(EditorResetScope.Tool(6), EditorResetScope.Group(EditorAdjustmentGroup.LIGHT))) {
            assertTrue(EditorAdjustmentRules.isModified(scope, source, context))
            val reset = EditorAdjustmentRules.prepareReset(scope, source, context) as EditorResetResult.Ready
            assertTrue(reset.candidate.curve.isDefault); assertEquals(0f, reset.candidate.toneCurve)
        }
        assertTrue(ToneCurveSettings.identity.isIdentity)
        assertFalse(ToneCurveSettings.identity.isDefault)
    }
}
