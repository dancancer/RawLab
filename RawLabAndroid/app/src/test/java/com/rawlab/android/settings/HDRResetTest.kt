package com.rawlab.android.settings

import com.rawlab.android.editor.*
import com.rawlab.android.format.PhotoInputKind
import org.junit.Assert.*
import org.junit.Test

class HDRResetTest {
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
}
