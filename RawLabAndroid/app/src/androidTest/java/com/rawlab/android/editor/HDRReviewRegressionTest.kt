package com.rawlab.android.editor

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import com.rawlab.android.adjustments.*
import com.rawlab.android.editor.ui.AdjustmentSummaryContent
import com.rawlab.android.editor.ui.HDRCameraDevelopmentRows
import com.rawlab.android.settings.HDRCameraDevelopmentSettings
import com.rawlab.android.settings.HDRCameraProfile
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.withHDRMode
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.settings.VersionedPhotoEdit
import com.rawlab.android.batch.BatchSelectionState
import com.rawlab.android.batch.BatchTarget
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.ui.ExportFormatControls
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

class HDRReviewRegressionTest {
    @get:Rule val compose = createComposeRule()

    @Test fun hdrRawSummaryComposesWithCustomWhiteBalanceAndDisabledFbdd() {
        val camera = HDRCameraDevelopmentSettings(customWhiteBalance = true, temperature = 6500f, tint = 12f)
        val baseline = EditSettings().withHDRMode(true, false, cameraRaw = true)
        val payload = AdjustmentTransfer.capture(AdjustmentScope.Custom(setOf(AdjustmentField.HDR_CAMERA_DEVELOPMENT)),
            baseline.copy(hdr = baseline.hdr!!.withCameraDevelopment(camera)),
            AdjustmentTransferContext("raw", true, sourceSupportsCameraHDR = true))
        compose.setContent { MaterialTheme { AdjustmentSummaryContent(payload, { _, _ -> null }) } }
        compose.onNodeWithTag("adjustment-summary-group-detail").performClick()
        compose.onNodeWithTag("adjustment-summary-value-hdr.camera_development").assertExists()
    }

    @Test fun profileImportPreservesTheDraftAndWaitsForApplyWhileThePanelIsBusy() {
        val settings = HDRCameraDevelopmentSettings()
        val profile = HDRCameraProfile("a".repeat(64), "D65 test profile")
        var busy by mutableStateOf(false)
        var showPanel by mutableStateOf(true)
        var panel by mutableStateOf(HDRCameraPanelDraft(PhotoIdentity("source"), settings, settings))
        var applied: HDRCameraDevelopmentSettings? = null
        compose.setContent {
            MaterialTheme {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    if (showPanel) HDRCameraDevelopmentRows(settings, !busy, true, { applied = it }, { busy = true },
                        panel.settings, { panel = panel.copy(settings = it) })
                }
            }
        }
        compose.onNodeWithTag("hdr-camera-wb").performScrollTo().performClick()
        compose.onNodeWithTag("hdr-camera-sensor").performScrollTo().performClick()
        compose.onNodeWithTag("hdr-camera-fbdd-2").performScrollTo().performClick()
        compose.onNodeWithTag("hdr-camera-profile-import").performScrollTo().performClick()
        compose.onNodeWithTag("hdr-camera-profile-import").assertIsNotEnabled()
        compose.onNodeWithTag("hdr-camera-wb").assertIsNotEnabled()
        compose.onNodeWithTag("hdr-camera-apply").assertIsNotEnabled()
        compose.runOnIdle { showPanel = false }
        compose.waitForIdle()
        compose.runOnIdle { showPanel = true }
        compose.runOnIdle { panel = panel.withProfile(profile); busy = false }
        compose.onNodeWithTag("hdr-camera-profile-name").assertTextEquals(profile.name)
        assertNull("Import only updates the panel draft", applied)
        compose.onNodeWithTag("hdr-camera-apply").performScrollTo().assertIsEnabled().performClick()
        assertEquals(settings.copy(customWhiteBalance = true, temperature = 6500f,
            sensorExposure = true, fbddLevel = 2, cameraProfile = profile), applied)
    }

    @Test fun collectionFormatsFollowTheSavedHdrMode() {
        val photo = BatchTarget(PhotoIdentity("raw"), File("photo.dng"), "photo.dng", sourceIsHDR = true)
        val selection = BatchSelectionState().append(listOf(photo))
        var saved by mutableStateOf<EditSettings?>(null)
        compose.setContent {
            MaterialTheme {
                ExportFormatControls(ExportFormat.JPEG, {}, hdrEditing = selection.supportsHDRExport(
                    { VersionedPhotoEdit(it, saved, "revision") }))
            }
        }
        compose.onNodeWithTag("export-format-HDR_JPEG").assertDoesNotExist()
        compose.runOnIdle { saved = EditSettings().withHDRMode(true, false, cameraRaw = true) }
        compose.onNodeWithTag("export-format-HDR_JPEG").assertExists()
        compose.runOnIdle { saved = EditSettings() }
        compose.onNodeWithTag("export-format-HDR_JPEG").assertDoesNotExist()
    }
}
