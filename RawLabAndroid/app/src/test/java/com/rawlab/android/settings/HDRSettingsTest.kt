package com.rawlab.android.settings

import com.rawlab.android.geometry.GeometrySettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class HDRSettingsTest {
    @Test fun tombstoneWithoutSettingsStillUsesTheHdrSourceDefault() {
        assertTrue(sourceDefaultSettings(true).isHDREditing)
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
