package com.rawlab.android.adjustments

import com.rawlab.android.settings.EditSettings
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.Locale

class AdjustmentSummaryTest {
    @Test fun summaryMatchesSharedPayloadVectors() {
        val cases = JSONObject(File("../../Shared/fixtures/adjustment-summary-v1.json").readText()).getJSONArray("cases")
        for (index in 0 until cases.length()) {
            val row = cases.getJSONObject(index)
            val payload = AdjustmentPayload.decode(row.getJSONObject("payload").toString())
            val expected = row.getJSONObject("expected")
            val summary = AdjustmentSummary(payload, Locale.SIMPLIFIED_CHINESE)
            assertEquals(row.getString("id"), expected.getInt("count"), summary.count)
            assertEquals(expected.getBoolean("includes_geometry"), summary.includesGeometry)
            val groups = expected.getJSONArray("groups")
            assertEquals(groups.length(), summary.groups.size)
            for (groupIndex in 0 until groups.length()) {
                val group = groups.getJSONObject(groupIndex)
                assertEquals(group.getString("id"), summary.groups[groupIndex].id)
                val fields = group.getJSONArray("fields")
                assertEquals((0 until fields.length()).map { fields.getString(it) }, summary.groups[groupIndex].fields.map { it.id })
            }
            val values = expected.getJSONObject("values_zh")
            assertEquals(payload.fields.map { it.id }.toSet(), values.keys().asSequence().toSet())
            values.keys().forEach { id ->
                assertEquals("${row.getString("id")}: $id", values.getString(id),
                    summary.valueText(AdjustmentField.fromID(id)!!) { kind, look ->
                        when {
                            kind == "builtin" && look == "acros" -> "Acros"
                            kind == "recipe" && look == "recipe-v3" -> "Recipe V3"
                            kind == "recipe" && look == "recipe-v4" -> "Recipe V4"
                            else -> null
                        }
                    })
            }
            assertEquals(expected.optString("recipe_note").takeIf { expected.has("recipe_note") && !expected.isNull("recipe_note") }, summary.recipeNote)
        }
    }

    @Test fun previewCaptureIsReadOnlyAndRejectsUnsavedChanges() {
        val context = AdjustmentTransferContext("raw", true)
        val saved = EditSettings(exposure = 0.7f)
        val preview = AdjustmentTransfer.previewCapture(AdjustmentScope.Modified, saved, saved, context)
        assertEquals(setOf(AdjustmentField.EXPOSURE), preview.fields)
        assertEquals(0.7, preview[AdjustmentField.EXPOSURE]!!.number!!, 0.00001)
        val draft = assertThrows(AdjustmentTransferException::class.java) {
            AdjustmentTransfer.previewCapture(AdjustmentScope.All, saved.copy(exposure = 0.8f), saved, context)
        }
        assertEquals(AdjustmentFailure.DRAFT, draft.reason)
        val empty = assertThrows(AdjustmentTransferException::class.java) {
            AdjustmentTransfer.previewCapture(AdjustmentScope.Modified, EditSettings(), EditSettings(), context)
        }
        assertEquals(AdjustmentFailure.EMPTY_SCOPE, empty.reason)
        assertEquals(0.7f, saved.exposure)
    }

    @Test fun explicitLocaleControlsNumbersAndTextResolverControlsWords() {
        val payload = AdjustmentPayload(AdjustmentSource("raw", true, 2), mapOf(
            AdjustmentField.EXPOSURE to AdjustmentValue.Number(0.7),
            AdjustmentField.WHITE_BALANCE_MODE to AdjustmentValue.Text("camera")))
        val summary = AdjustmentSummary(payload, Locale.GERMANY) {
            if (it == "相机白平衡（按目标照片）") "Kameraweißabgleich (pro Zielfoto)" else it
        }
        assertEquals("+0,70 EV", summary.valueText(AdjustmentField.EXPOSURE))
        assertEquals("Kameraweißabgleich (pro Zielfoto)", summary.valueText(AdjustmentField.WHITE_BALANCE_MODE))
    }
}
