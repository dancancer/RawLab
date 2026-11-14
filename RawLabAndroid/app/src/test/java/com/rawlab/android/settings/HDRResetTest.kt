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

    @Test fun hdrRenditionGroupVisibilityNormalizationAndSingleToolResetWorkIndependently() {
        assertEquals(listOf(24, 25, 26, 27), EditorAdjustmentRules.tools(EditorAdjustmentGroup.HDR_RENDITION))
        assertEquals(24, EditorAdjustmentRules.defaultTool(EditorAdjustmentGroup.HDR_RENDITION))
        assertFalse(EditorAdjustmentRules.visibleGroups(false).contains(EditorAdjustmentGroup.HDR_RENDITION))
        assertEquals(listOf(0, 2, 8, 22, 11, 17), EditorAdjustmentRules.visibleGroups(false).map(EditorAdjustmentRules::defaultTool))
        assertTrue(EditorAdjustmentRules.visibleGroups(true).contains(EditorAdjustmentGroup.HDR_RENDITION))
        for (tool in listOf(24, 25, 26, 27)) {
            assertEquals(tool, EditorAdjustmentRules.normalizeTool(tool, isHDREditing = true))
            assertEquals(2, EditorAdjustmentRules.normalizeTool(tool, isHDREditing = false))
            assertNotEquals(EditorAdjustmentGroup.HDR_RENDITION, EditorAdjustmentRules.groupFor(EditorAdjustmentRules.normalizeTool(tool, isHDREditing = false)))
        }

        val sdrBase = EditSettings(film = "velvia", exposure = -.5f, contrast = .25f)
        var renditionHdr = sdrBase.withHDRMode(true, false, cameraRaw = true, proRAW = false)
            .copy(exposure = 1.5f).synchronizeHDR()
        renditionHdr = renditionHdr.copy(hdr = renditionHdr.hdr!!.withCameraDevelopment(HDRCameraDevelopmentSettings(fbddLevel = 2)))
        assertFalse(EditorAdjustmentRules.isModified(EditorResetScope.Group(EditorAdjustmentGroup.HDR_RENDITION), renditionHdr, rawContext))
        for (tool in listOf(24, 25, 26, 27)) {
            assertFalse(EditorAdjustmentRules.isModified(EditorResetScope.Tool(tool), renditionHdr, rawContext))
        }
        assertEquals(EditorResetResult.NoChange, EditorAdjustmentRules.prepareReset(EditorResetScope.Group(EditorAdjustmentGroup.HDR_RENDITION), renditionHdr, rawContext))
        assertEquals(1, renditionHdr.hdr!!.processingVersion)

        val fullRendition = HDRRenditionSettings(peakLimitEV = 2.4f, sdrExposureEV = -1.2f, sdrContrast = 35f, sdrSaturation = -25f)
        val editedHdr = renditionHdr.copy(hdr = renditionHdr.hdr!!.withRendition(fullRendition))
        assertEquals(4, editedHdr.hdr!!.processingVersion)
        assertTrue(EditorAdjustmentRules.isModified(EditorResetScope.Group(EditorAdjustmentGroup.HDR_RENDITION), editedHdr, rawContext))
        for (tool in listOf(24, 25, 26, 27)) {
            assertTrue(EditorAdjustmentRules.isModified(EditorResetScope.Tool(tool), editedHdr, rawContext))
            val expected = when (tool) {
                24 -> fullRendition.copy(peakLimitEV = 0f)
                25 -> fullRendition.copy(sdrExposureEV = 0f)
                26 -> fullRendition.copy(sdrContrast = 0f)
                else -> fullRendition.copy(sdrSaturation = 0f)
            }
            val single = (EditorAdjustmentRules.prepareReset(EditorResetScope.Tool(tool), editedHdr, rawContext) as EditorResetResult.Ready).candidate
            assertEquals(expected, single.hdr!!.renditionSettings)
            assertFalse(EditorAdjustmentRules.isModified(EditorResetScope.Tool(tool), single, rawContext))
            assertTrue(EditorAdjustmentRules.isModified(EditorResetScope.Group(EditorAdjustmentGroup.HDR_RENDITION), single, rawContext))
            assertEquals(1.5f, single.hdr!!.exposure)
            assertEquals(1.5f, single.exposure)
            assertEquals(2, single.hdr!!.cameraSettings.fbddLevel)
            assertEquals(sdrBase.exposure, single.sdrSnapshotSettings()!!.exposure)
            assertEquals("velvia", single.film)
            assertEquals(EditorResetResult.NoChange, EditorAdjustmentRules.prepareReset(EditorResetScope.Tool(tool), single, rawContext))
        }

        val groupReset = (EditorAdjustmentRules.prepareReset(EditorResetScope.Group(EditorAdjustmentGroup.HDR_RENDITION), editedHdr, rawContext) as EditorResetResult.Ready).candidate
        assertEquals(HDRRenditionSettings(), groupReset.hdr!!.renditionSettings)
        assertTrue(groupReset.hdr!!.renditionSettings.isDefault)
        assertEquals(4, groupReset.hdr!!.processingVersion)
        assertEquals(1.5f, groupReset.hdr!!.exposure)
        assertEquals(1.5f, groupReset.exposure)
        assertEquals(2, groupReset.hdr!!.cameraSettings.fbddLevel)
        assertEquals(sdrBase.exposure, groupReset.sdrSnapshotSettings()!!.exposure)
        assertEquals(sdrBase.contrast, groupReset.sdrSnapshotSettings()!!.contrast)
        assertEquals("velvia", groupReset.film)
        assertFalse(EditorAdjustmentRules.isModified(EditorResetScope.Group(EditorAdjustmentGroup.HDR_RENDITION), groupReset, rawContext))
        assertEquals(EditorResetResult.NoChange, EditorAdjustmentRules.prepareReset(EditorResetScope.Group(EditorAdjustmentGroup.HDR_RENDITION), groupReset, rawContext))

        val dormantSdr = editedHdr.withHDRMode(false, false, cameraRaw = true, proRAW = false)
        assertFalse(EditorAdjustmentRules.isModified(EditorResetScope.Group(EditorAdjustmentGroup.HDR_RENDITION), dormantSdr, rawContext))
        assertEquals(EditorResetResult.NoChange, EditorAdjustmentRules.prepareReset(EditorResetScope.Group(EditorAdjustmentGroup.HDR_RENDITION), dormantSdr, rawContext))
        for (tool in listOf(24, 25, 26, 27)) {
            assertFalse(EditorAdjustmentRules.isModified(EditorResetScope.Tool(tool), dormantSdr, rawContext))
            assertEquals(EditorResetResult.NoChange, EditorAdjustmentRules.prepareReset(EditorResetScope.Tool(tool), dormantSdr, rawContext))
        }
        val sdrResetAll = (EditorAdjustmentRules.prepareReset(EditorResetScope.All, dormantSdr, rawContext) as EditorResetResult.Ready).candidate
        assertEquals(fullRendition, sdrResetAll.hdr!!.renditionSettings)
        assertEquals(2, sdrResetAll.hdr!!.cameraSettings.fbddLevel)
        assertFalse(sdrResetAll.isHDREditing)
        assertEquals(0f, sdrResetAll.exposure)

        val hdrResetAll = (EditorAdjustmentRules.prepareReset(EditorResetScope.All, editedHdr, rawContext) as EditorResetResult.Ready).candidate
        assertTrue(hdrResetAll.isHDREditing)
        assertTrue(hdrResetAll.hdr!!.renditionSettings.isDefault)
        assertTrue(hdrResetAll.hdr!!.isIdentity)
        assertEquals(0f, hdrResetAll.exposure)
        assertEquals(sdrBase.exposure, hdrResetAll.sdrSnapshotSettings()!!.exposure)
        assertEquals("velvia", hdrResetAll.film)
    }
}
