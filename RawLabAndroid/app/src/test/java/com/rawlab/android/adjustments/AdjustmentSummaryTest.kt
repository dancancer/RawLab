package com.rawlab.android.adjustments

import com.rawlab.android.R
import com.rawlab.android.editor.ui.summaryGroupStringResources
import com.rawlab.android.editor.ui.summaryStringResources
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.ToneCurveChannel
import com.rawlab.android.settings.ToneCurveMode
import com.rawlab.android.settings.ToneCurvePoint
import com.rawlab.android.settings.ToneCurveSettings
import com.rawlab.android.settings.ToneCurveShape
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.Locale

class AdjustmentSummaryTest {
    @Test fun everySummaryBranchAndGroupResolvesThroughResourceMapping() {
        val resolvedKeys = mutableSetOf<String>()
        val resolver: (String) -> String = { key ->
            val resId = summaryStringResources[key] ?: fail("Unmapped adjustment summary key: $key")
            assertNotEquals("Resource id must be non-zero for $key", 0, resId)
            resolvedKeys += key
            key
        }

        fun look(kind: String, id: String?) = AdjustmentValue.Object(mapOf(
            "kind" to AdjustmentValue.Text(kind),
            "id" to (id?.let { AdjustmentValue.Text(it) } ?: AdjustmentValue.Null),
        ))
        fun hdrLook(name: String?) = if (name == null) AdjustmentValue.Null else AdjustmentValue.Object(mapOf(
            "name" to AdjustmentValue.Text(name),
            "sha256" to AdjustmentValue.Text("a".repeat(64)),
            "strength" to AdjustmentValue.Number(0.8),
        ))
        fun hdrCamera(customWb: Boolean, sensorExposure: Boolean, fbdd: Int) = AdjustmentValue.Object(mapOf(
            "version" to AdjustmentValue.Number(1.0),
            "white_balance_mode" to AdjustmentValue.Text(if (customWb) "temperature" else "as_shot"),
            "temperature" to AdjustmentValue.Number(if (customWb) 5600.0 else 0.0),
            "tint" to AdjustmentValue.Number(if (customWb) 12.0 else 0.0),
            "exposure_reference" to AdjustmentValue.Text(if (sensorExposure) "sensor" else "metadata"),
            "fbdd_level" to AdjustmentValue.Number(fbdd.toDouble()),
        ))
        fun wheel(hue: Double, sat: Double) = AdjustmentValue.Object(mapOf(
            "hue" to AdjustmentValue.Number(hue),
            "saturation" to AdjustmentValue.Number(sat),
        ))
        fun curve(custom: Boolean, redCustom: Boolean = false): AdjustmentValue {
            var settings = if (custom) ToneCurveSettings(ToneCurveMode.CUSTOM, listOf(
                ToneCurvePoint(0.0, 0.0), ToneCurvePoint(0.5, 0.7), ToneCurvePoint(1.0, 1.0),
            )) else ToneCurveSettings()
            if (redCustom) {
                settings = settings.replacing(ToneCurveChannel.RED, ToneCurveShape(ToneCurveMode.CUSTOM, listOf(
                    ToneCurvePoint(0.0, 0.0), ToneCurvePoint(0.4, 0.6), ToneCurvePoint(1.0, 1.0),
                )))
            }
            return AdjustmentPayload.curveValue(settings)
        }
        fun wavelet(enabled: Boolean, preset: String) = AdjustmentValue.Object(mapOf(
            "enabled" to AdjustmentValue.Boolean(enabled),
            "preset" to AdjustmentValue.Text(preset),
            "luma" to AdjustmentValue.Number(25.0),
            "chroma" to AdjustmentValue.Number(30.0),
            "coarse" to AdjustmentValue.Number(15.0),
        ))

        val payloads = listOf(
            AdjustmentPayload(
                AdjustmentSource("raw", true, 2, AdjustmentRecipeContext("r1", 0.5)),
                mapOf(
                    AdjustmentField.LOOK to look("neutral", null),
                    AdjustmentField.STRENGTH to AdjustmentValue.Number(0.5),
                    AdjustmentField.EXPOSURE_MODE to AdjustmentValue.Text("scene"),
                    AdjustmentField.WHITE_BALANCE_MODE to AdjustmentValue.Text("camera"),
                    AdjustmentField.TEMPERATURE to AdjustmentValue.Null,
                    AdjustmentField.TINT to AdjustmentValue.Number(5.0),
                    AdjustmentField.CURVE to curve(custom = false),
                    AdjustmentField.GRADING_SHADOWS to wheel(120.0, 20.0),
                    AdjustmentField.CHROMA_DENOISE to AdjustmentValue.Null,
                    AdjustmentField.WAVELET_DENOISE to AdjustmentValue.Null,
                    AdjustmentField.FLIP_HORIZONTAL to AdjustmentValue.Boolean(true),
                    AdjustmentField.LENS_AUTO_CROP to AdjustmentValue.Boolean(false),
                    AdjustmentField.LENS_PROFILE to AdjustmentValue.Null,
                ),
            ),
            AdjustmentPayload(
                AdjustmentSource("raw", true, 2),
                mapOf(
                    AdjustmentField.LOOK to look("builtin", "missing"),
                    AdjustmentField.EXPOSURE_MODE to AdjustmentValue.Text("preview"),
                    AdjustmentField.WHITE_BALANCE_MODE to AdjustmentValue.Text("temperature"),
                    AdjustmentField.TEMPERATURE to AdjustmentValue.Number(6500.0),
                    AdjustmentField.TINT to AdjustmentValue.Number(-3.0),
                    AdjustmentField.CURVE to curve(custom = true, redCustom = true),
                    AdjustmentField.CHROMA_DENOISE to AdjustmentValue.Number(0.0),
                    AdjustmentField.WAVELET_DENOISE to wavelet(true, "detail"),
                    AdjustmentField.LENS_PROFILE to AdjustmentValue.Text("__rawlab_manual_selection_required__"),
                ),
            ),
            AdjustmentPayload(
                AdjustmentSource("raster", false, 2),
                mapOf(
                    AdjustmentField.LOOK to look("managed", "m1"),
                    AdjustmentField.EXPOSURE_MODE to AdjustmentValue.Text("sensor"),
                    AdjustmentField.WHITE_BALANCE_MODE to AdjustmentValue.Text("none"),
                    AdjustmentField.TEMPERATURE to AdjustmentValue.Null,
                    AdjustmentField.CHROMA_DENOISE to AdjustmentValue.Number(1.0),
                    AdjustmentField.WAVELET_DENOISE to wavelet(false, "clean"),
                    AdjustmentField.LENS_PROFILE to AdjustmentValue.Text("Custom 50mm"),
                ),
            ),
            AdjustmentPayload(
                AdjustmentSource("raw", true, 2, AdjustmentRecipeContext("rec1", 1.0)),
                mapOf(
                    AdjustmentField.LOOK to look("recipe", "rec1"),
                    AdjustmentField.STRENGTH to AdjustmentValue.Number(1.0),
                    AdjustmentField.TINT to AdjustmentValue.Number(0.0),
                    AdjustmentField.CHROMA_DENOISE to AdjustmentValue.Number(2.0),
                    AdjustmentField.WAVELET_DENOISE to wavelet(true, "custom"),
                ),
            ),
            AdjustmentPayload(
                AdjustmentSource("raw", true, 2),
                mapOf(
                    AdjustmentField.LOOK to look("recipe_lut", "lut1"),
                ),
            ),
            AdjustmentPayload(
                AdjustmentSource("hdr-1", false, 2, hdrProcessingVersion = 8),
                mapOf(
                    AdjustmentField.HDR_LOOK to hdrLook(null),
                    AdjustmentField.HDR_CAMERA_DEVELOPMENT to hdrCamera(true, true, 0),
                    AdjustmentField.HDR_PEAK_LIMIT to AdjustmentValue.Number(0.0),
                    AdjustmentField.HDR_TEMPERATURE to AdjustmentValue.Number(5500.0),
                    AdjustmentField.HDR_TINT to AdjustmentValue.Number(5.0),
                ),
            ),
            AdjustmentPayload(
                AdjustmentSource("hdr-2", false, 2, hdrProcessingVersion = 8),
                mapOf(
                    AdjustmentField.HDR_LOOK to hdrLook("HDR Gold"),
                    AdjustmentField.HDR_CAMERA_DEVELOPMENT to hdrCamera(false, false, 2),
                    AdjustmentField.HDR_PEAK_LIMIT to AdjustmentValue.Number(2.0),
                ),
            ),
        )

        for (payload in payloads) {
            val summary = AdjustmentSummary(payload, Locale.SIMPLIFIED_CHINESE, resolver)
            summary.recipeNote
            for (field in payload.fields) {
                summary.valueText(field)
            }
        }

        assertEquals(summaryStringResources.keys, resolvedKeys)
        assertEquals(R.string.tint, summaryStringResources["色调"])
        assertEquals(R.string.disabled, summaryStringResources["关闭"])
        assertEquals(setOf("looks", "light", "color", "effects", "detail", "geometry"), summaryGroupStringResources.keys)
        assertTrue(summaryGroupStringResources.values.all { it != 0 })
    }

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
