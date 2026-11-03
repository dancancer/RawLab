package com.rawlab.android.settings

import com.rawlab.android.geometry.GeometrySettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class HDRSettingsTest {
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
