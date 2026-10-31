package com.rawlab.android.editor.controls

import android.graphics.Bitmap
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import com.rawlab.android.R
import com.rawlab.android.editor.panels.LensControls
import com.rawlab.android.engine.LensCandidate
import com.rawlab.android.engine.LensInfo
import com.rawlab.android.settings.LensSettings

class LensControlsTest {
    @get:Rule val compose = createComposeRule()

    @Test fun unavailableCorrectionExplainsWhyAndRetainedEnabledCanBeTurnedOff() {
        var value by mutableStateOf(LensSettings(distortion = true))
        val candidate = LensCandidate("missing-calibration", "Fixture", "24mm", false, false, true)
        val info = LensInfo(6, "24mm", "", false, false, 1f, listOf(candidate))
        compose.setContent { MaterialTheme { LensControls(value, info, true) { value = it } } }
        compose.onNodeWithTag("lens.tca").assertIsNotEnabled()
        compose.onNodeWithTag("lens.distortion").assertIsEnabled().performClick()
        compose.onNodeWithTag("lens.distortion").assertIsNotEnabled()
        assertFalse(value.distortion)
        val reason = InstrumentationRegistry.getInstrumentation().targetContext.getString(R.string.lens_tca_unavailable)
        assertTrue(compose.onNodeWithTag("lens.tca").fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsProperties.StateDescription].contains(reason))
    }

    @Test fun switchesManualSelectionSearchAndResetInCompactLayout() {
        var value by mutableStateOf(LensSettings())
        val candidate = LensCandidate("profile-id", "Fixture", "24mm", true, true, true)
        val info = LensInfo(0, "24mm", "", false, false, 1f, listOf(candidate))
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        compose.setContent { MaterialTheme { Box(Modifier.width(360.dp)) { LensControls(value, info, true) { value = it } } } }
        compose.onNodeWithTag("lens.distortion").performClick()
        compose.onNodeWithTag("lens.tca").performClick()
        compose.onNodeWithTag("lens.crop").performClick()
        compose.runOnIdle { assertTrue(value.distortion && value.tca); assertFalse(value.autoCrop) }
        compose.onNodeWithText(context.getString(R.string.lens_manual)).performClick()
        compose.onNodeWithTag("lens.profile").performClick()
        compose.onNodeWithTag("lens.search").performTextInput("not-a-profile")
        compose.onNodeWithText(context.getString(R.string.lens_none_found)).assertIsDisplayed()
        compose.onNodeWithTag("lens.search").performTextClearance()
        compose.onNodeWithTag("lens.candidate").performClick()
        compose.runOnIdle { assertTrue(value.manual); assertEquals(candidate.id, value.profileId) }
        val image = compose.onRoot().captureToImage().asAndroidBitmap()
        val directory = InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null)
        File(directory, "lens-controls-compact.png").outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
        compose.onNodeWithTag("lens.reset").performClick()
        compose.runOnIdle { assertEquals(LensSettings(), value) }
    }
}
