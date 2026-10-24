package com.rawlab.android.editor

import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.presets.*
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class AdjustmentPresetContractInstrumentedTest {
    @Test fun sharedVectorsUseTheRealAndroidJsonParserWithoutReplacingInvalidBytes() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val directory = File(instrumentation.targetContext.cacheDir, "preset-contract-${UUID.randomUUID()}").apply { mkdirs() }
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
                if (vector.getBoolean("valid")) assertEquals(id, 1, store.list().size)
                else assertTrue(id, runCatching { store.list() }.exceptionOrNull() is AdjustmentPresetException)
                assertArrayEquals(id, bytes, file.readBytes())
            }
        } finally { directory.deleteRecursively() }
    }
}
