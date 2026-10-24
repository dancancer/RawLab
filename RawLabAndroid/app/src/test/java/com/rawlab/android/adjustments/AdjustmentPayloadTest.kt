package com.rawlab.android.adjustments

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class AdjustmentPayloadTest {
    @Test fun sharedPayloadVectorsHaveTheSameAcceptanceAndRoundTrip() {
        val fixture = JSONObject(File("../../Shared/fixtures/adjustment-transfer-v1.json").readText())
        val vectors = fixture.getJSONArray("vectors")
        assertEquals(35, vectors.length())
        for (index in 0 until vectors.length()) {
            val vector = vectors.getJSONObject(index)
            val json = vector.getJSONObject("payload").toString()
            if (vector.getBoolean("valid")) {
                val payload = AdjustmentPayload.decode(json)
                assertEquals(vector.getString("id"), payload, AdjustmentPayload.decode(payload.encode()))
            } else assertThrows(vector.getString("id"), Exception::class.java) { AdjustmentPayload.decode(json) }
        }
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
}
