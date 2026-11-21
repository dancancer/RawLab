package com.rawlab.android.settings

import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject

class LensMetadataSettingsTest {
    @Test fun manualMetadataSurvivesBothCodecsAndOldRecordsRemainReadable() {
        val lens = LensSettings(manual = true, profileId = "lens", focalLength = 35f, cropFactor = 1.5f, vignetting = true)
        assertEquals(lens, LensSettings.decode(lens.encode()))
        val encoded = StructuredSettingsCodec.encode(EditSettings(lens = lens), "photo_edit")
        assertEquals(lens, StructuredSettingsCodec.decode(encoded, "photo_edit").lens)
        val json = JSONObject(encoded.removePrefix("v2:"))
        json.getJSONObject("settings").getJSONObject("lens").apply { remove("focalLength"); remove("cropFactor") }
        assertEquals(lens.copy(focalLength = null, cropFactor = null), StructuredSettingsCodec.decode("v2:$json", "photo_edit").lens)
        assertEquals(LensSettings(), LensSettings.decode("0|0|1|0|"))
    }
    @Test fun rasterKeepsExplicitLensSettings() {
        val lens = LensSettings(distortion = true, focalLength = 50f, cropFactor = 1f)
        assertEquals(lens, EditSettings(lens = lens).effectiveFor(com.rawlab.android.format.PhotoInputKind.RASTER).lens)
    }
    @Test fun invalidManualMetadataIsRejected() {
        for (value in listOf(0f, -1f, Float.NaN, Float.POSITIVE_INFINITY)) {
            assertThrows(IllegalArgumentException::class.java) { LensSettings(focalLength = value) }
            assertThrows(IllegalArgumentException::class.java) { LensSettings(cropFactor = value) }
        }
    }
}
