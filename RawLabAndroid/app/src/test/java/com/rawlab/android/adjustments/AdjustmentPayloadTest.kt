package com.rawlab.android.adjustments

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class AdjustmentPayloadTest {
    @Test fun curvePayloadRejectsLooseJSONAndDuplicateKeys() {
        val json = """{"payload_version":1,"scope_version":1,"source":{"identifier":"a","is_raw":true,"processing_version":2},"values":{"light.curve":{"mode":"custom","points":[[0,0],[1,1]]}}}"""
        for (invalid in listOf(json + " trailing", json.replace("\"mode\":\"custom\"", "\"mode\":\"legacy\",\"mode\":\"custom\""),
            json.replace("\"custom\"", "'custom'")))
            assertThrows(AdjustmentTransferException::class.java) { AdjustmentPayload.decode(invalid) }
    }
    @Test fun sharedPayloadVectorsHaveTheSameAcceptanceAndRoundTrip() {
        val fixture = JSONObject(resolveSharedFixture("adjustment-transfer-v1.json").readText())
        assertEquals(1, fixture.getInt("fixture_version"))
        val vectors = fixture.getJSONArray("vectors")
        assertTrue(vectors.length() > 0)
        val seen = linkedSetOf<String>()
        for (index in 0 until vectors.length()) {
            val vector = vectors.getJSONObject(index)
            val id = vector.getString("id")
            assertTrue("Duplicate vector ID: $id", seen.add(id))
            val json = vector.getJSONObject("payload").toString()
            if (vector.getBoolean("valid")) {
                val payload = AdjustmentPayload.decode(json)
                assertEquals(id, payload, AdjustmentPayload.decode(payload.encode()))
            } else assertThrows(id, Exception::class.java) { AdjustmentPayload.decode(json) }
        }
        assertEquals(vectors.length(), seen.size)
    }

    @Test fun unknownFieldsWrongTypesAndFutureVersionsAreRejected() {
        val valid = """{"payload_version":1,"scope_version":1,"source":{"identifier":"a","is_raw":true,"processing_version":2},"values":{"light.exposure":1.25}}"""
        for (json in listOf(
            valid.replace("1.25", "true"), valid.replace("1.25", "\"1.25\""),
            valid.replace("\"is_raw\":true", "\"is_raw\":1"),
            valid.replace("\"source\":", "\"unknown\":0,\"source\":"),
            valid.replace("\"scope_version\":1", "\"scope_version\":2"),
            valid.replace("\"processing_version\":2", "\"processing_version\":2.5"),
        )) assertThrows(AdjustmentTransferException::class.java) { AdjustmentPayload.decode(json) }
    }

    @Test fun captureValuesAreDeeplyFrozenAndPostRGBStaysIndependent() {
        val look = mutableMapOf("kind" to AdjustmentValue.Text("neutral"), "id" to AdjustmentValue.Null)
        val values = mutableMapOf<AdjustmentField, AdjustmentValue>(
            AdjustmentField.LOOK to AdjustmentValue.Object(look),
            AdjustmentField.POST_RGB_DENOISE to AdjustmentValue.Number(.4))
        val payload = AdjustmentPayload(AdjustmentSource("source", true, 2), values)
        values.clear(); look["kind"] = AdjustmentValue.Text("invalid")
        assertEquals(setOf(AdjustmentField.LOOK, AdjustmentField.POST_RGB_DENOISE), payload.fields)
        assertEquals(payload, AdjustmentPayload.decode(payload.encode()))
        assertFalse(AdjustmentField.COMMON.any { it.group == "geometry" })
        assertTrue(AdjustmentField.entries.filter { it.hslLocation != null }.size == 24)
    }

    @Test fun lightCurveTransferRejectsNestedV2FieldsAndKeepsThemSeparate() {
        val base = """{"payload_version":1,"scope_version":1,"source":{"identifier":"a","is_raw":true,"processing_version":3},"values":{"light.curve":"""
        val withLuminosity = """$base{"mode":"custom","points":[[0,0],[1,1]],"apply_to_luminosity":true}}}"""
        val withParametric = """$base{"mode":"custom","points":[[0,0],[1,1]],"parametric":{"highlights":10,"lights":0,"darks":0,"shadows":0,"split_shadow":0.25,"split_midtone":0.5,"split_highlight":0.75}}}}"""
        assertThrows(AdjustmentTransferException::class.java) { AdjustmentPayload.decode(withLuminosity) }
        assertThrows(AdjustmentTransferException::class.java) { AdjustmentPayload.decode(withParametric) }

        val settings = com.rawlab.android.settings.EditSettings(
            curve = com.rawlab.android.settings.ToneCurveSettings(
                mode = com.rawlab.android.settings.ToneCurveMode.CUSTOM,
                points = listOf(com.rawlab.android.settings.ToneCurvePoint(0.0, 0.1), com.rawlab.android.settings.ToneCurvePoint(1.0, 0.9)),
                applyToLuminosity = true,
                parametric = com.rawlab.android.settings.ToneCurveParametric(highlights = 12.0),
            ),
        )
        val captured = AdjustmentTransfer.capture(AdjustmentScope.Modified, settings, AdjustmentTransferContext("a", true))
        val curveObj = captured[AdjustmentField.CURVE]?.objectValue!!
        assertEquals(setOf("mode", "points"), curveObj.keys)
        assertEquals(AdjustmentValue.Boolean(true), captured[AdjustmentField.CURVE_APPLY_TO_LUMINOSITY])
        assertEquals(12.0, captured[AdjustmentField.CURVE_PARAMETRIC]?.objectValue?.get("highlights")?.number!!, 0.0)
    }
}

internal fun resolveSharedPath(relativePath: String): File {
    val direct = listOf(File(relativePath), File("../../$relativePath")).firstOrNull { it.isFile }
    if (direct != null) return direct
    var dir: File? = File("").absoluteFile
    while (dir != null) {
        val candidate = File(dir, relativePath)
        if (candidate.isFile) return candidate
        dir = dir.parentFile
    }
    error("Shared file not found: $relativePath")
}

internal fun resolveSharedFixture(name: String): File = resolveSharedPath("Shared/fixtures/$name")
