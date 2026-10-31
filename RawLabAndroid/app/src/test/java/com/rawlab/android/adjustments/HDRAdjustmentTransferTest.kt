package com.rawlab.android.adjustments

import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.HDRMode
import com.rawlab.android.settings.withHDRMode
import com.rawlab.android.settings.synchronizeHDR
import com.rawlab.android.settings.sdrSnapshotSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HDRAdjustmentTransferTest {
    @Test fun sdrLogicalScalarsReachHdrAndUnsupportedFieldsAreRejectedAsAWhole() {
        val context=AdjustmentTransferContext("hdr",false)
        val target=EditSettings().withHDRMode(true,true)
        val payload=AdjustmentPayload(AdjustmentSource("sdr",false,2),mapOf(AdjustmentField.EXPOSURE to AdjustmentValue.Number(.5)))
        val edited=AdjustmentTransfer.prepare(payload,target,context)
        assertEquals(.5f,edited.hdr!!.exposure)
        assertEquals(0f,edited.sdrSnapshotSettings()!!.exposure)
        org.junit.Assert.assertThrows(AdjustmentTransferException::class.java) {
            AdjustmentTransfer.prepare(AdjustmentPayload(payload.source,payload.values+
                (AdjustmentField.STRENGTH to AdjustmentValue.Number(1.0))),target,context)
        }
    }
    @Test fun modifiedHdrScopeDoesNotIncludeGeometryAndHdrDraftsCannotBeApplied() {
        val target=EditSettings().withHDRMode(true,true).copy(exposure=.5f,
            geometry=com.rawlab.android.geometry.GeometrySettings(quarterTurns=1)).synchronizeHDR()
        val payload=AdjustmentTransfer.capture(AdjustmentScope.Modified,target,AdjustmentTransferContext("hdr",false))
        assertTrue(payload.fields.none {it in AdjustmentField.HDR_GEOMETRY})
        org.junit.Assert.assertThrows(AdjustmentTransferException::class.java) {
            AdjustmentTransfer.prepare(payload,target,AdjustmentTransferContext("hdr",false,hasUncommittedDraft=true))
        }
    }
    @Test
    fun hdrCaptureUsesVersionTwoAndRelativeWhiteBalanceFields() {
        val settings = EditSettings().withHDRMode(true, true)
            .copy(temperature = 7200f, tint = -12f)
            .copy(exposure = 1.25f).synchronizeHDR()

        val payload = AdjustmentTransfer.capture(AdjustmentScope.All, settings,
            AdjustmentTransferContext("hdr-source", isRaw = false))

        assertEquals(2, payload.payloadVersion)
        assertEquals(1, payload.source.hdrProcessingVersion)
        assertTrue(payload.fields.contains(AdjustmentField.HDR_TEMPERATURE))
        assertTrue(payload.fields.contains(AdjustmentField.HDR_TINT))
        assertTrue(!payload.fields.contains(AdjustmentField.TEMPERATURE))
    }

    @Test
    fun hdrPayloadAppliesOnlyToHdrTargetWithoutChangingSdrFields() {
        val source = EditSettings(exposure = 1f).withHDRMode(true, true)
            .copy(temperature = 7200f, tint = -12f).synchronizeHDR()
        val target = EditSettings(exposure = -2f, temperature = 6500f).withHDRMode(true, true)
        val payload = AdjustmentTransfer.capture(AdjustmentScope.All, source,
            AdjustmentTransferContext("hdr-source", isRaw = false))

        val prepared = AdjustmentTransfer.prepare(payload, target,
            AdjustmentTransferContext("hdr-target", isRaw = false))

        assertEquals(HDRMode.HDR, prepared.hdr?.mode)
        assertEquals(1f, prepared.exposure)
        assertEquals(7200f, prepared.temperature)
        assertEquals(-12f, prepared.tint)
        assertEquals(-2f, prepared.sdrSnapshotSettings()?.exposure)
    }
}
