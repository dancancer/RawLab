package com.rawlab.android

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class GeometryControlsTest {
    @get:Rule val compose = createComposeRule()

    @Test fun compactControlsValidateCropRotateFlipAndReset() {
        var value by mutableStateOf(GeometrySettings())
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        compose.setContent {
            MaterialTheme {
                Column(Modifier.width(360.dp).verticalScroll(rememberScrollState())) {
                    GeometryControls(value, true) { next, _ -> value = next }
                }
            }
        }
        compose.onNodeWithTag("geometry.rotate-right").performScrollTo().performClick()
        compose.onNodeWithTag("geometry.flip-horizontal").performScrollTo().performClick()
        compose.runOnIdle { assertEquals(1, value.quarterTurns); assertTrue(value.flipHorizontal) }
        compose.onNodeWithTag("adjustment-value-${R.string.geometry_crop_width}").performScrollTo().performClick()
        compose.onNodeWithTag("adjustment-input").performTextReplacement("110")
        compose.onNodeWithTag("adjustment-input-apply").assertIsNotEnabled()
        compose.onNodeWithTag("adjustment-input").performTextReplacement("75")
        compose.onNodeWithTag("adjustment-input-apply").performClick()
        compose.onNodeWithTag("adjustment-value-${R.string.geometry_crop_x}").performScrollTo().performClick()
        compose.onNodeWithTag("adjustment-input").performTextReplacement("20")
        compose.onNodeWithTag("adjustment-input-apply").performClick()
        compose.runOnIdle { assertEquals(.2f, value.cropX); assertEquals(.75f, value.cropWidth) }
        compose.onNodeWithContentDescription(context.getString(R.string.geometry_reset)).performScrollTo().performClick()
        compose.runOnIdle { assertEquals(GeometrySettings(), value) }
    }
}
