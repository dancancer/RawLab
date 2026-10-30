package com.rawlab.android.settings

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class X3fSettingsTest {
    private fun json(settings: EditSettings) = JSONObject(SettingsCodec.encode(settings).removePrefix("v2:"))
    private fun mode(settings: EditSettings) = json(settings).getJSONObject("settings").getString("x3fMode")

    @Test fun freshEditsUseNormalAndOldRecordsKeepLegacy() {
        assertEquals("normal-v1", mode(EditSettings()))
        val old = json(EditSettings(exposure = .75f))
        old.getJSONObject("settings").remove("x3fMode")
        val legacy = SettingsCodec.decode("v2:$old")
        assertEquals("legacy", mode(legacy))
        assertEquals("legacy", mode(legacy.reset()))
        assertEquals(.75f, legacy.exposure)
        val directory = Files.createTempDirectory("rawlab-x3f-edit").toFile()
        try {
            val identity = PhotoIdentity("x3f")
            EditStore(directory).save(identity, legacy)
            assertEquals(legacy, EditStore(directory).load(identity))
        } finally { directory.deleteRecursively() }
    }

    @Test fun malformedModesRejectWithoutUpgrading() {
        for (mode in listOf(JSONObject.NULL, "future", 1, true)) {
            val invalid = json(EditSettings())
            invalid.getJSONObject("settings").put("x3fMode", mode)
            assertThrows(Exception::class.java) { SettingsCodec.decode("v2:$invalid") }
        }
    }
}
