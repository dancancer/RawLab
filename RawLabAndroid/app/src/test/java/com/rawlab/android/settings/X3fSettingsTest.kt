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

    @Test fun selectX3fModeClearsLensFlagsOnNormalWithoutReopeningOnLegacy() {
        for ((distortion, tca, vignetting) in listOf(
            Triple(true, false, false),
            Triple(false, true, false),
            Triple(false, false, true),
            Triple(true, true, true),
        )) {
            val legacy = EditSettings(
                film = "provia",
                exposure = .25f,
                x3fMode = X3fMode.LEGACY,
                lens = LensSettings(
                    distortion = distortion,
                    tca = tca,
                    autoCrop = false,
                    manual = true,
                    profileId = "saved-lens-profile",
                    focalLength = 35f,
                    cropFactor = 1.5f,
                    vignetting = vignetting,
                ),
            )
            val normal = legacy.selectX3fMode(X3fMode.NORMAL)
            assertEquals(X3fMode.NORMAL, normal.x3fMode)
            assertFalse(normal.lens.distortion)
            assertFalse(normal.lens.tca)
            assertFalse(normal.lens.vignetting)
            assertFalse(normal.lens.enabled)
            assertFalse(normal.lens.autoCrop)
            assertTrue(normal.lens.manual)
            assertEquals("saved-lens-profile", normal.lens.profileId)
            assertEquals(35f, normal.lens.focalLength)
            assertEquals(1.5f, normal.lens.cropFactor)
            assertEquals(.25f, normal.exposure)
            assertEquals("provia", normal.film)
            assertEquals(normal, SettingsCodec.decode(SettingsCodec.encode(normal)))

            val backToLegacy = normal.selectX3fMode(X3fMode.LEGACY)
            assertEquals(X3fMode.LEGACY, backToLegacy.x3fMode)
            assertFalse(backToLegacy.lens.distortion)
            assertFalse(backToLegacy.lens.tca)
            assertFalse(backToLegacy.lens.vignetting)
            assertFalse(backToLegacy.lens.enabled)
        }
    }
}
