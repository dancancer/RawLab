package com.rawlab.android.settings

import com.rawlab.android.editor.*
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.photo.EditedPhotoPreviewKey
import org.junit.Assert.*
import org.junit.Test

class HDRResetTest {
    @Test fun lightResetClearsOnlyActiveTone() {
        val hdr = EditSettings(blackPoint = -8f, whitePoint = 9f, toneCurve = .12f, curve = ToneCurveSettings.identity)
            .withHDRMode(true, false, cameraRaw = true).withEditingBlackPoint(-25f).withEditingWhitePoint(50f)
            .withEditingCurveStrength(.3f).withEditingCurve(ToneCurveSettings.identity.inserting(.5, .625))
        val result = EditorAdjustmentRules.prepareReset(EditorResetScope.Group(EditorAdjustmentGroup.LIGHT), hdr,
            EditorResetContext(PhotoInputKind.RAW, EditSettings())) as EditorResetResult.Ready
        assertEquals(2, result.candidate.hdr!!.processingVersion)
        assertTrue(result.candidate.hdr.toneSettings.isDefault)
        assertEquals(hdr.blackPoint, result.candidate.blackPoint)
        assertEquals(hdr.curve, result.candidate.curve)
        assertEquals(hdr.sdrSnapshot, result.candidate.sdrSnapshot)
    }

    @Test fun fullResetRetainsHdrModeAndInactiveSdrValues() {
        val hdr = EditSettings(exposure = -1f).withHDRMode(true, true)
            .copy(exposure = 2f, temperature = 10000f, tint = 42f).synchronizeHDR()
        val result = EditorAdjustmentRules.prepareReset(EditorResetScope.All, hdr,
            EditorResetContext(PhotoInputKind.RASTER, EditSettings()))
        val reset = (result as EditorResetResult.Ready).candidate.synchronizeHDR()
        assertTrue(reset.isHDREditing)
        assertEquals(6500f, reset.temperature)
        assertEquals(0f, reset.exposure)
        assertEquals(-1f, reset.withHDRMode(false, true).exposure)
    }

    @Test fun relativeWhiteBalanceIsModifiedForHdrRaster() {
        val hdr = EditSettings().withHDRMode(true, true).copy(temperature = 10000f).synchronizeHDR()
        assertTrue(EditorAdjustmentRules.isModified(EditorResetScope.Tool(8), hdr,
            EditorResetContext(PhotoInputKind.RASTER, EditSettings())))
    }

    private val rawContext = EditorResetContext(PhotoInputKind.RAW, EditSettings())
    private val rendition = HDRRenditionSettings(peakLimitEV = 2f, sdrExposureEV = -1f, sdrContrast = 20f, sdrSaturation = -10f)
    private fun proRawHdr(sdr: EditSettings = EditSettings(film = "velvia", exposure = -.5f)): EditSettings = sdr
        .withHDRMode(true, false, cameraRaw = true, proRAW = true).copy(exposure = 1.5f).synchronizeHDR()
        .let { it.copy(hdr = it.hdr!!.withRendition(rendition)) }

    @Test fun sdrResetAllKeepsDormantHdrAndProRawDecoder() {
        val context = rawContext.copy(asShot = AsShotWhiteBalance(5200f, 8f))
        val sdr = proRawHdr().withHDRMode(false, false, cameraRaw = true, proRAW = true)
            .copy(contrast = .3f, customWb = true, temperature = 7000f, tint = -12f)
        val reset = (EditorAdjustmentRules.prepareReset(EditorResetScope.All, sdr, context) as EditorResetResult.Ready).candidate
        assertEquals(0f, reset.contrast); assertEquals("neutral", reset.film); assertEquals(0f, reset.exposure)
        assertFalse(reset.customWb); assertEquals(5200f, reset.temperature); assertEquals(8f, reset.tint)
        assertEquals(sdr.hdr, reset.hdr)
        assertEquals(2, reset.proRAWDecodeVersion)
        assertFalse(EditorAdjustmentRules.isModified(EditorResetScope.All, reset, context))
        assertEquals(EditorResetResult.NoChange, EditorAdjustmentRules.prepareReset(EditorResetScope.All, reset, context))
        assertFalse(EditedPhotoPreviewKey.isEdited(reset, PhotoInputKind.RAW))
        val back = reset.withHDRMode(true, false, cameraRaw = true, proRAW = true)
        assertEquals(1.5f, back.exposure)
        assertEquals(rendition, back.hdr!!.renditionSettings)
    }

    @Test fun hdrResetAllKeepsSdrSnapshotAndProRawDecoder() {
        val hdr = proRawHdr()
        val reset = (EditorAdjustmentRules.prepareReset(EditorResetScope.All, hdr, rawContext) as EditorResetResult.Ready).candidate
        assertEquals(0f, reset.exposure)
        assertTrue(reset.hdr!!.renditionSettings.isDefault)
        assertEquals(hdr.sdrSnapshot, reset.sdrSnapshot)
        assertEquals(2, reset.proRAWDecodeVersion)
        assertFalse(EditorAdjustmentRules.isModified(EditorResetScope.All, reset, rawContext))
        assertEquals(EditorResetResult.NoChange, EditorAdjustmentRules.prepareReset(EditorResetScope.All, reset, rawContext))
        val sdr = reset.withHDRMode(false, false, cameraRaw = true, proRAW = true)
        assertEquals("velvia", sdr.film); assertEquals(-.5f, sdr.exposure)
        assertEquals(2, sdr.proRAWDecodeVersion)
    }

    @Test fun modifiedAllIgnoresDormantModeAndIsIdempotent() {
        val dormant = EditSettings().withHDRMode(true, false, cameraRaw = true)
            .withHDRMode(false, false, cameraRaw = true)
        assertNotNull(dormant.hdr)
        assertFalse(EditorAdjustmentRules.isModified(EditorResetScope.All, dormant, rawContext))
        val edited = proRawHdr(EditSettings()).withHDRMode(false, false, cameraRaw = true, proRAW = true)
        assertFalse(EditorAdjustmentRules.isModified(EditorResetScope.All, edited, rawContext))
        assertFalse(EditedPhotoPreviewKey.isEdited(edited, PhotoInputKind.RAW))
        val sdrEdited = edited.copy(exposure = 1f)
        assertTrue(EditorAdjustmentRules.isModified(EditorResetScope.All, sdrEdited, rawContext))
        val reset = (EditorAdjustmentRules.prepareReset(EditorResetScope.All, sdrEdited, rawContext) as EditorResetResult.Ready).candidate
        assertFalse(EditorAdjustmentRules.isModified(EditorResetScope.All, reset, rawContext))
        val hdrWithDormantSdr = EditSettings(film = "velvia", exposure = -.5f)
            .withHDRMode(true, false, cameraRaw = true, proRAW = true)
        assertFalse(EditorAdjustmentRules.isModified(EditorResetScope.All, hdrWithDormantSdr, rawContext))
        assertFalse(EditedPhotoPreviewKey.isEdited(hdrWithDormantSdr, PhotoInputKind.RAW))
        val mapped = hdrWithDormantSdr.copy(hdr = hdrWithDormantSdr.hdr!!.withRendition(HDRRenditionSettings(peakLimitEV = 1f)))
        assertTrue(EditorAdjustmentRules.isModified(EditorResetScope.All, mapped, rawContext))
        assertTrue(EditedPhotoPreviewKey.isEdited(mapped, PhotoInputKind.RAW))
        val hdrReset = (EditorAdjustmentRules.prepareReset(EditorResetScope.All, mapped, rawContext) as EditorResetResult.Ready).candidate
        assertFalse(EditorAdjustmentRules.isModified(EditorResetScope.All, hdrReset, rawContext))
        assertFalse(EditedPhotoPreviewKey.isEdited(hdrReset, PhotoInputKind.RAW))
    }
}
