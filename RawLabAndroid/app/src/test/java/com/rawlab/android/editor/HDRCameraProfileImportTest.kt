package com.rawlab.android.editor

import com.rawlab.android.settings.AdjustmentOperationExpiredException
import com.rawlab.android.settings.HDRCameraProfile
import com.rawlab.android.settings.HDRCameraDevelopmentSettings
import com.rawlab.android.settings.PhotoIdentity
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class HDRCameraProfileImportTest {
    private val profile = HDRCameraProfile("a".repeat(64), "D65")

    @Test fun importReturnsTheProfileWithoutCommittingCameraSettings() = runBlocking {
        assertEquals(profile, readHDRCameraProfile({ profile }, { true }).getOrThrow())
    }

    @Test fun aRevisionChangeDuringImportIsReportedAsAConflict() = runBlocking {
        var current = true
        val result = readHDRCameraProfile({ current = false; profile }, { current })
        assertTrue(result.exceptionOrNull() is AdjustmentOperationExpiredException)
    }

    @Test fun cancellationIsRethrownInsteadOfBecomingAnImportError() {
        val cancelled = CancellationException("Editor closed")
        val failure = assertThrows(CancellationException::class.java) {
            runBlocking { readHDRCameraProfile({ throw cancelled }, { true }) }
        }
        assertSame(cancelled, failure)
    }

    @Test fun invalidProfilesRemainRecoverableImportErrors() = runBlocking {
        val invalid = java.io.IOException("Invalid profile")
        assertSame(invalid, readHDRCameraProfile({ throw invalid }, { true }).exceptionOrNull())
    }

    @Test fun panelDraftSurvivesUiRecreationAndCannotLeakToAnotherSourceOrCommittedState() {
        val source = PhotoIdentity("source")
        val baseline = HDRCameraDevelopmentSettings()
        val settings = baseline.copy(customWhiteBalance = true, temperature = 7200f, sensorExposure = true, fbddLevel = 2)
        val panel = HDRCameraPanelDraft(source, baseline, settings).withProfile(profile)
        assertEquals(settings.copy(cameraProfile = profile), panel.valueFor(source, baseline))
        assertEquals(baseline, panel.valueFor(PhotoIdentity("other-source"), baseline))
        val committed = baseline.copy(fbddLevel = 1)
        assertEquals(committed, panel.valueFor(source, committed))
        assertNull(panel.retainedFor(committed))
        assertSame(panel, panel.retainedFor(baseline))
    }
}
