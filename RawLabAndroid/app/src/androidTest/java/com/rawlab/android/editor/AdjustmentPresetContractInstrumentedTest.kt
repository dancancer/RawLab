package com.rawlab.android.editor

import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.adjustments.AdjustmentField
import com.rawlab.android.adjustments.AdjustmentPayload
import com.rawlab.android.adjustments.AdjustmentSource
import com.rawlab.android.adjustments.AdjustmentTransferException
import com.rawlab.android.adjustments.AdjustmentValue
import com.rawlab.android.presets.*
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.SettingsCodec
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class AdjustmentPresetContractInstrumentedTest {
    private fun samplePayload(exposure: Double = 1.25) = AdjustmentPayload(
        AdjustmentSource("/removed/original.ARW", true, 2),
        mapOf(AdjustmentField.EXPOSURE to AdjustmentValue.Number(exposure)),
    )

    @Test fun sharedVectorsUseTheRealAndroidJsonParserWithoutReplacingInvalidBytes() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val directory = File(instrumentation.targetContext.cacheDir, "preset-contract-${UUID.randomUUID()}").apply { mkdirs() }
        val registryFailures = setOf(
            "future-registry", "unknown-registry-field", "duplicate-id", "duplicate-name",
            "invalid-retired-id", "overlapping-retired-id", "duplicate-retired-id", "registry-decimal",
            "registry-exponent", "registry-rounded-fraction", "registry-boolean", "registry-string",
            "registry-null", "json-unquoted-metadata-key", "json-single-quoted-key",
            "json-trailing-document", "json-trailing-comma", "json-comment",
            "duplicate-root-key", "duplicate-escaped-root-key",
        )
        try {
            val vectors = JSONArray(instrumentation.context.assets.open("adjustment-presets-v1.json").bufferedReader().use { it.readText() })
            assertEquals(55, vectors.length())
            val store = AdjustmentPresetStore(directory)
            val file = File(directory, "presets.json")
            for (index in 0 until vectors.length()) {
                val vector = vectors.getJSONObject(index)
                val id = vector.getString("id")
                val json = if (vector.has("registry_json")) vector.getString("registry_json") else vector.getJSONObject("registry").toString()
                file.writeText(json); val bytes = file.readBytes()
                if (vector.getBoolean("valid")) {
                    val loaded = store.list()
                    assertEquals(id, 1, loaded.size)
                    assertEquals(id, 1.25, loaded[0].payload[AdjustmentField.EXPOSURE]?.number ?: Double.NaN, 0.0)
                    assertArrayEquals(id, bytes, file.readBytes())
                } else if (id in registryFailures) {
                    assertThrows(id, AdjustmentPresetException::class.java) { store.list() }
                    assertThrows(id, AdjustmentPresetException::class.java) { store.create("Blocked", samplePayload()) }
                    assertArrayEquals(id, bytes, file.readBytes())
                } else {
                    assertTrue(id, store.list().isEmpty())
                    val unreadable = store.listUnreadable()
                    assertEquals(id, 1, unreadable.size)
                    assertArrayEquals(id, bytes, file.readBytes())
                    store.create("Pass Through", samplePayload())
                    assertTrue(id, file.readText().contains(unreadable[0].raw))
                }
            }
        } finally { directory.deleteRecursively() }
    }

    @Test fun strictJsonRejectsDuplicateKeysCommentsAndTrailingCommasThatAndroidOrgJsonAccepts() {
        // Prove Android's built-in org.json is lenient on device (accepts comments, overwrites duplicate keys,
        // and turns array trailing commas into a silent trailing null) while StrictJSON-guarded codecs reject them.
        assertEquals(2, JSONObject("""{/*comment*/"a":1,"a":2}""").getInt("a"))
        assertEquals(3, JSONArray("""[1,2,]""").length())

        val encoded = SettingsCodec.encode(EditSettings(exposure = 0.5f))
        for (invalid in listOf(
            encoded.replaceFirst("v3:{", "v3:{/*comment*/"),
            encoded.replaceFirst("\"version\":3", "\"version\":1,\"version\":3"),
            encoded.replaceFirst("\"version\":3", "\"version\":3.0"),
            encoded.removeSuffix("}") + ",}",
        )) {
            assertThrows(invalid, IllegalArgumentException::class.java) { SettingsCodec.decode(invalid) }
        }

        val payloadJson = """{"payload_version":1,"scope_version":1,"source":{"identifier":"a","is_raw":true,"processing_version":2},"values":{"light.exposure":1.25}}"""
        for (invalid in listOf(
            payloadJson.replaceFirst("{", "{/*comment*/"),
            payloadJson.replaceFirst("\"light.exposure\":1.25", "\"light.exposure\":0.25,\"light.exposure\":1.25"),
            payloadJson.replaceFirst("\"payload_version\":1", "\"payload_version\":1.0"),
            payloadJson.removeSuffix("}") + ",}",
        )) {
            assertThrows(invalid, AdjustmentTransferException::class.java) { AdjustmentPayload.decode(invalid) }
        }
    }
}
