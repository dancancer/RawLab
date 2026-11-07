package com.rawlab.android.settings

import com.rawlab.android.geometry.GeometrySettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class HDRSettingsTest {
    @Test fun cameraDevelopmentUsesIndependentRecordVersion() {
        val settings = EditSettings().withHDRMode(true,false,cameraRaw = true)
        val camera = HDRCameraDevelopmentSettings(true,8400f,24f,true,2)
        val edited = settings.copy(hdr = settings.hdr!!.withCameraDevelopment(camera))
        val restored = StructuredSettingsCodec.decode(StructuredSettingsCodec.encode(edited,"photo_edit"),"photo_edit")
        assertEquals(edited, restored)
        assertEquals(8, restored.hdr!!.recordVersion)
        assertEquals(1, restored.hdr.processingVersion)
        assertEquals(camera, restored.hdr.cameraSettings)
        assertEquals(8, restored.reset().hdr!!.recordVersion)
        assertTrue(restored.reset().hdr!!.cameraSettings.isDefault)
    }

    @Test fun hdrDetailRoundTripsAndPreservesOrdinarySettings() {
        val ordinary = EditSettings(sharpening = .25f, clarity = -20f, denoise = DenoiseSettings(enabled = true, luma = 20f))
        val neutral = ordinary.withHDRMode(true, false, cameraRaw = true)
        assertEquals(1, neutral.withHDRDenoise(0f).hdr!!.processingVersion)
        val edited = neutral.withEditingSharpening(1.25f).withEditingClarity(50f).withEditingDehaze(-40f).withHDRDenoise(.65f)
        val encoded = StructuredSettingsCodec.encode(edited, "photo_edit")
        val restored = StructuredSettingsCodec.decode(encoded, "photo_edit")
        assertEquals(edited, restored)
        assertEquals(6, restored.hdr!!.processingVersion)
        assertEquals(HDRDetailSettings(1.25f, .5f, -.4f, .65f), restored.hdr.detailSettings)
        val dormant = restored.withHDRMode(false, false, cameraRaw = true)
        assertEquals(ordinary.sharpening, dormant.sharpening)
        assertEquals(ordinary.clarity, dormant.clarity)
        assertEquals(ordinary.denoise, dormant.denoise)
        val reset = restored.reset()
        assertEquals(6, reset.hdr!!.processingVersion)
        assertTrue(reset.hdr.detailSettings.isDefault)
        assertEquals(restored.sdrSnapshot, reset.sdrSnapshot)
        val invalid = encoded.replace("\"hdr_processing_version\":6", "\"hdr_processing_version\":5")
        assertThrows(IllegalArgumentException::class.java) { StructuredSettingsCodec.decode(invalid, "photo_edit") }
    }

    @Test fun hdrColorRoundTripsWithoutOverwritingSdrColors() {
        val sdr = EditSettings(vibrance = -17f, hsl = HslSettings().withValue(0, 1, 4f))
        val hdr = sdr.withHDRMode(true, false, cameraRaw = true)
            .withEditingVibrance(35f).withEditingHsl(HslSettings().withValue(1, 5, -21.5f))
            .withEditingGrading(ColorGradingSettings(highlights = ColorGradingWheel(210f, 30f)))
        val encoded = StructuredSettingsCodec.encode(hdr, "photo_edit")
        val restored = StructuredSettingsCodec.decode(encoded, "photo_edit")
        assertEquals(hdr, restored)
        assertEquals(3, restored.hdr!!.processingVersion)
        assertTrue(restored.hdr.toneSettings.isDefault)
        val inactive = restored.withHDRMode(false, false, cameraRaw = true)
        assertEquals(sdr.hsl, inactive.editingHsl)
        assertEquals(sdr.vibrance, inactive.editingVibrance)
        assertEquals(sdr.colorGrading, inactive.editingGrading)
        val reset = restored.reset()
        assertEquals(3, reset.hdr!!.processingVersion)
        assertTrue(reset.hdr.colorSettings.isDefault)
        val mismatched = encoded.replace("\"hdr_processing_version\":3", "\"hdr_processing_version\":2")
        assertThrows(IllegalArgumentException::class.java) { StructuredSettingsCodec.decode(mismatched, "photo_edit") }
    }

    @Test fun hdrToneUpgradesAndRestoresBothIndependentRecords() {
        val sdr = EditSettings(blackPoint = -8f, whitePoint = 9f, toneCurve = .12f, curve = ToneCurveSettings.identity)
        val baseline = sdr.withHDRMode(true, false, cameraRaw = true)
        assertEquals(1, baseline.withEditingBlackPoint(0f).hdr!!.processingVersion)
        val curve = ToneCurveSettings.identity.inserting(.5, .625)
        val edited = baseline.withEditingBlackPoint(-25f).withEditingWhitePoint(50f)
            .withEditingCurveStrength(.3f).withEditingCurve(curve)
        assertEquals(2, edited.hdr!!.processingVersion)
        assertEquals(-25f, edited.editingBlackPoint)
        assertEquals(50f, edited.editingWhitePoint)
        assertEquals(.3f, edited.editingCurveStrength)
        assertEquals(curve, edited.editingCurve)
        val encoded = StructuredSettingsCodec.encode(edited, "photo_edit")
        val reopened = StructuredSettingsCodec.decode(encoded, "photo_edit")
        assertEquals(edited, reopened)
        val dormant = reopened.withHDRMode(false, false, cameraRaw = true)
        assertEquals(-8f, dormant.editingBlackPoint)
        assertEquals(9f, dormant.editingWhitePoint)
        assertEquals(.12f, dormant.editingCurveStrength)
        assertEquals(sdr.curve, dormant.editingCurve)
        val reset = reopened.reset()
        assertEquals(2, reset.hdr!!.processingVersion)
        assertTrue(reset.hdr.toneSettings.isDefault)
        assertEquals(edited.sdrSnapshot, reset.sdrSnapshot)
        val mismatched = encoded.replace("\"hdr_processing_version\":2", "\"hdr_processing_version\":1")
        assertThrows(IllegalArgumentException::class.java) { StructuredSettingsCodec.decode(mismatched, "photo_edit") }
    }

    @Test fun proRawHdrPinsItsDecoderWhilePreservingBothModeRecords() {
        val sdr = EditSettings(film = "velvia", exposure = -.5f)
        val hdr = sdr.withHDRMode(true, false, cameraRaw = true, proRAW = true)
            .copy(exposure = 1.5f).synchronizeHDR()
        assertEquals(2, hdr.proRAWDecodeVersion)
        val restored = hdr.withHDRMode(false, false, cameraRaw = true, proRAW = true)
        assertEquals(sdr.exposure, restored.exposure)
        assertEquals(sdr.film, restored.film)
        assertEquals(2, restored.proRAWDecodeVersion)
        assertEquals(2, restored.reset().proRAWDecodeVersion)
        assertEquals(1.5f, restored.withHDRMode(true, false, cameraRaw = true, proRAW = true).exposure)
    }

    @Test fun incompatibleProRawDecoderRemainsReadableButCannotEnterHdr() {
        for (version in listOf(1, 3, 99)) {
            val stored = EditSettings(proRAWDecodeVersion = version)
            val restored = SettingsCodec.decode(SettingsCodec.encode(stored))
            assertEquals(version, restored.proRAWDecodeVersion)
            assertThrows(HDRModeError.InvalidSettings::class.java) {
                restored.withHDRMode(true, false, cameraRaw = true, proRAW = true)
            }
            assertEquals(stored, restored)
        }
    }
    @Test fun proRawDecoderIdentitySurvivesStructuredSettingsRoundTrip() {
        val encoded = StructuredSettingsCodec.encode(EditSettings().withHDRMode(true, false, cameraRaw = true), "photo_edit")
        val document = org.json.JSONObject(encoded.removePrefix("v2:"))
        document.getJSONObject("settings").put("proRAWDecodeVersion", 2)
        val decoded = StructuredSettingsCodec.decode("v2:$document", "photo_edit")
        val saved = org.json.JSONObject(StructuredSettingsCodec.encode(decoded, "photo_edit").removePrefix("v2:"))
        assertEquals(2, saved.getJSONObject("settings").getInt("proRAWDecodeVersion"))
    }
    @Test fun tombstoneWithoutSettingsStillUsesTheHdrSourceDefault() {
        assertTrue(sourceDefaultSettings(true).isHDREditing)
    }

    @Test fun cameraRawCapabilityDoesNotAutoEnableHdr() {
        assertFalse(sourceDefaultSettings(true, cameraRaw = true).isHDREditing)
    }

    @Test fun cameraRawHdrKeepsAnIndependentSnapshotOfSdrOnlySettings() {
        val sdr = EditSettings(
            film = "velvia",
            exposure = 1f,
            customWb = true,
            temperature = 7200f,
            tint = -12f,
            denoise = DenoiseSettings(enabled = true, luma = 10f, chroma = 72f, coarse = 100f),
        )

        val hdr = sdr.withHDRMode(true, sourceIsHDR = false, hasLook = true, cameraRaw = true)

        assertTrue(hdr.isHDREditing)
        assertEquals(0f, hdr.exposure)
        assertEquals(6500f, hdr.temperature)
        assertEquals(sdr.exposure, hdr.sdrSnapshotSettings()!!.exposure)
        assertEquals(sdr.film, hdr.sdrSnapshotSettings()!!.film)
        assertEquals(sdr.temperature, hdr.sdrSnapshotSettings()!!.temperature)
        assertEquals(sdr.denoise, hdr.sdrSnapshotSettings()!!.denoise)

        val restored = hdr.withHDRMode(false, sourceIsHDR = false, hasLook = true, cameraRaw = true)
        assertFalse(restored.isHDREditing)
        assertEquals(sdr.exposure, restored.exposure)
        assertEquals(sdr.film, restored.film)
        assertEquals(sdr.temperature, restored.temperature)
        assertEquals(sdr.denoise, restored.denoise)
    }

    @Test fun cameraRawHdrModeAndBothSnapshotsRoundTripThroughTheEditRecord() {
        val camera = EditSettings(film = "velvia", exposure = 1f, temperature = 7200f)
            .withHDRMode(true, sourceIsHDR = false, hasLook = true, cameraRaw = true)
            .copy(exposure = 1.5f, highlights = -.4f).synchronizeHDR()

        val restored = StructuredSettingsCodec.decode(StructuredSettingsCodec.encode(camera, "photo_edit"), "photo_edit")

        assertEquals(camera, restored)
        assertTrue(restored.isHDREditing)
        assertEquals(1f, restored.sdrSnapshotSettings()!!.exposure)
        assertEquals(1.5f, restored.hdr!!.exposure)
    }

    @Test
    fun enablingAnHdrSourceKeepsIndependentSdrSnapshot() {
        val sdr = EditSettings(exposure = -1.25f, contrast = .2f, geometry = GeometrySettings(quarterTurns = 1))

        val hdr = sdr.withHDRMode(enabled = true, sourceIsHDR = true, hasLook = false)

        assertEquals(HDRMode.HDR, hdr.hdr?.mode)
        assertEquals(-1.25f, hdr.exposure)
        assertEquals(-1.25f, hdr.sdrSnapshotSettings()?.exposure)
        assertEquals(GeometrySettings(quarterTurns = 1), hdr.sdrSnapshotSettings()?.geometry)
    }

    @Test
    fun disablingHdrRestoresTheSdrSnapshotAndRetainsHdrEdits() {
        val original = EditSettings(exposure = -1.25f)
        val enabled = original.withHDRMode(true, sourceIsHDR = true, hasLook = false)
        val edited = enabled.copy(exposure = 1.5f).synchronizeHDR()

        val restored = edited.withHDRMode(false, sourceIsHDR = true, hasLook = false)

        assertNull(restored.sdrSnapshot)
        assertEquals(-1.25f, restored.exposure)
        assertEquals(HDRMode.SDR, restored.hdr?.mode)
        assertEquals(1.5f, restored.hdr?.exposure)
    }

    @Test
    fun laterSdrEditsDoNotOverwriteInactiveHdrSnapshot() {
        val enabled = EditSettings().withHDRMode(true, true).copy(exposure = 1.5f).synchronizeHDR()
        val sdr = enabled.withHDRMode(false, true).copy(exposure = -2f)
        val reenabled = sdr.withHDRMode(true, true)

        assertEquals(-2f, reenabled.sdrSnapshotSettings()?.exposure)
        assertEquals(1.5f, reenabled.hdr?.exposure)
    }

    @Test
    fun enablingRejectsUnsupportedSdrStateWithoutMutatingIt() {
        val source = EditSettings(film = "velvia", sharpening = .5f)

        assertThrows(HDRModeError.Conflicts::class.java) {
            source.withHDRMode(true, sourceIsHDR = true, hasLook = true)
        }
        assertEquals("velvia", source.film)
        assertEquals(.5f, source.sharpening)
    }

    @Test
    fun enablingRejectsNonNeutralWhiteBalanceAndAnyDenoiseState() {
        assertThrows(HDRModeError.Conflicts::class.java) {
            EditSettings(temperature = 7200f).withHDRMode(true, true)
        }
        assertThrows(HDRModeError.Conflicts::class.java) {
            EditSettings(denoise = DenoiseSettings(enabled = true)).withHDRMode(true, true)
        }
    }

    @Test
    fun oldEditWithoutHdrFieldRemainsSdr() {
        val old = EditSettings()

        assertEquals(false, old.isHDREditing)
        assertNull(old.hdr)
    }

    @Test
    fun structuredRecordUsesSharedSnakeCaseHdrContract() {
        val active = EditSettings(contrast = .25f).withHDRMode(true, true)

        val encoded = StructuredSettingsCodec.encode(active, "photo_edit")
        val decoded = StructuredSettingsCodec.decode(encoded, "photo_edit")

        assertTrue(encoded.contains("record_version"))
        assertTrue(encoded.contains("hdr_processing_version"))
        assertTrue(encoded.contains("relative_temperature"))
        assertEquals(active, decoded)
    }
}
