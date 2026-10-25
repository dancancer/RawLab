package com.rawlab.android.settings

import com.rawlab.android.adjustments.*
import com.rawlab.android.editor.*
import com.rawlab.android.format.PhotoInputKind
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ColorGradingSettingsTest {
    private val grading = ColorGradingSettings(ColorGradingWheel(231.25f, 0f),
        ColorGradingWheel(110.125f, 32.375f), ColorGradingWheel(359.5f, 99.5f))
    private val context = AdjustmentTransferContext("grading", false)
    private val fields = setOf(AdjustmentField.GRADING_SHADOWS, AdjustmentField.GRADING_MIDTONES, AdjustmentField.GRADING_HIGHLIGHTS)

    @Test fun settingsAndBatchRoundTripAndOldObjectsRemainDefault() {
        val settings = EditSettings(colorGrading = grading)
        for (format in listOf("photo_edit", "batch_settings")) {
            val encoded = StructuredSettingsCodec.encode(settings, format)
            assertEquals(settings, StructuredSettingsCodec.decode(encoded, format))
            val old = JSONObject(encoded.removePrefix("v2:"))
            old.getJSONObject("settings").remove("colorGrading")
            assertTrue(StructuredSettingsCodec.decode("v2:$old", format).colorGrading.isDefault)
        }
        assertEquals(settings, SettingsCodec.decode(SettingsCodec.encode(settings)))
        assertTrue(grading.shadows.isIdentity); assertFalse(grading.shadows.isDefault)
        assertEquals(grading.shadows, grading.shadows.moving(0f, 0f))
        assertEquals(0f, ColorGradingWheel.inputHue(360f)); assertNull(ColorGradingWheel.inputHue(-1f))
        assertNull(ColorGradingWheel.inputHue(361f))
        assertEquals(0f, ColorGradingWheel.fromNumbers(359.999999, 100.0).hue)
        val fine = ColorGradingDrag(ColorGradingWheel(0f, 20f), .8f, .4f, true)
        assertEquals(fine.initial, fine.value(.8f, .4f))
        assertEquals(30f, fine.value(1.2f, .4f).saturation, .0001f)
        assertEquals(0f, grading.shadows.moving(1f, -Float.MIN_VALUE).hue)
        assertEquals(270f, grading.shadows.moving(0f, -1f).hue)
        assertEquals(100f, grading.shadows.moving(3f, 0f).saturation)
    }

    @Test fun persistedObjectsRejectLossyShapesAndInvalidSourceNumbersBeforeFloatRounding() {
        val encoded = SettingsCodec.encode(EditSettings(colorGrading = grading))
        for (wheel in listOf("""{"hue":-0.01,"saturation":0}""", """{"hue":360,"saturation":0}""",
            """{"hue":360.000001,"saturation":0}""", """{"hue":0,"saturation":100.000001}""",
            """{"hue":0}""", """{"hue":0,"saturation":0,"lightness":0}""", "null")) {
            val json = JSONObject(encoded.removePrefix("v2:"))
            json.getJSONObject("settings").getJSONObject("colorGrading").put("shadows", if (wheel == "null") JSONObject.NULL else JSONObject(wheel))
            assertThrows(Exception::class.java) { SettingsCodec.decode("v2:$json") }
        }
        for (zone in listOf("shadows", "midtones", "highlights")) {
            val json = JSONObject(encoded.removePrefix("v2:"))
            json.getJSONObject("settings").getJSONObject("colorGrading").remove(zone)
            assertThrows(Exception::class.java) { SettingsCodec.decode("v2:$json") }
        }
    }

    @Test fun wholeZoneCopyPreservesSiblingsAndDoesNotScaleWithRecipe() {
        val source = EditSettings(colorGrading = grading)
        val payload = AdjustmentTransfer.capture(AdjustmentScope.Modified, source, context)
        assertEquals(fields, payload.fields)
        assertTrue(AdjustmentField.COMMON.containsAll(fields))
        assertEquals(grading, AdjustmentTransfer.prepare(AdjustmentPayload.decode(payload.encode()), EditSettings(), context).colorGrading)
        val target = EditSettings(colorGrading = ColorGradingSettings(ColorGradingWheel(80f, 75f), highlights = ColorGradingWheel(50f, 15.125f)))
        val partial = AdjustmentTransfer.capture(AdjustmentScope.Custom(setOf(AdjustmentField.GRADING_MIDTONES)), source, context)
        assertEquals(target.colorGrading.copy(midtones = grading.midtones), AdjustmentTransfer.prepare(partial, target, context).colorGrading)
        val old = AdjustmentTransfer.capture(AdjustmentScope.Custom(setOf(AdjustmentField.EXPOSURE)), EditSettings(), context)
        assertEquals(target.colorGrading, AdjustmentTransfer.prepare(old, target, context).colorGrading)
        val recipe = AdjustmentTransfer.capture(AdjustmentScope.Custom(fields), source.copy(recipeID = "recipe", strength = 0f), context)
        assertEquals(grading, AdjustmentTransfer.prepare(recipe, target.copy(recipeID = "recipe", strength = 0f), context).colorGrading)
    }

    @Test fun resetZoneToolAndColorGroupPreserveTheRestOfTheEdit() {
        val source = EditSettings(colorGrading = grading, blackPoint = 23.5f)
        val ctx = EditorResetContext(PhotoInputKind.RASTER, EditSettings())
        fun reset(scope: EditorResetScope) = (EditorAdjustmentRules.prepareReset(scope, source, ctx) as EditorResetResult.Ready).candidate
        assertEquals(grading.copy(midtones = ColorGradingWheel()), reset(EditorResetScope.GradingZone(ColorGradingZone.MIDTONES)).colorGrading)
        for (scope in listOf(EditorResetScope.AllGrading, EditorResetScope.Tool(21), EditorResetScope.Group(EditorAdjustmentGroup.COLOR))) {
            assertTrue(reset(scope).colorGrading.isDefault)
            assertEquals(23.5f, reset(scope).blackPoint)
        }
        assertTrue(EditorAdjustmentRules.isModified(EditorResetScope.GradingZone(ColorGradingZone.SHADOWS), source, ctx))
    }
}
