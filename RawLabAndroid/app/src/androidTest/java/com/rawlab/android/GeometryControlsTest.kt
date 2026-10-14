package com.rawlab.android

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class GeometryControlsTest {
    @get:Rule val compose = createComposeRule()

    @Test fun cropActionsCorrectionAndDisclosureKeepDraftUntilApply() {
        var value by mutableStateOf(GeometrySettings())
        var correct by mutableStateOf(false)
        var ratio by mutableStateOf(GeometryRatio.FREE)
        var applied = false
        var cancelled = false
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        compose.setContent {
            MaterialTheme {
                GeometryControls(value, true, ratio, false, correct, true,
                    onRatio = { ratio = it }, onPortrait = {}, onCorrect = { correct = it }, onGrid = {},
                    onApply = { applied = true }, onCancel = { cancelled = true }, onReset = { value = GeometrySettings() },
                    onChange = { next, _ -> value = next }, modifier = Modifier.width(360.dp).height(640.dp))
            }
        }
        compose.onNodeWithTag("geometry.rotate-right").performClick()
        compose.onNodeWithTag("geometry.flip-horizontal").performClick()
        compose.runOnIdle { assertEquals(1, value.quarterTurns); assertTrue(value.flipHorizontal); assertFalse(applied) }
        compose.onNodeWithTag("geometry.correct-mode").performClick()
        compose.onNodeWithContentDescription(context.getString(R.string.geometry_perspective_horizontal))
            .performScrollTo().performSemanticsAction(SemanticsActions.SetProgress) { it(35f) }
        compose.runOnIdle { assertEquals(.35f, value.perspectiveHorizontal) }
        compose.onNodeWithTag("geometry.crop-mode").performScrollTo().performClick()
        compose.onNodeWithTag("geometry.precise").performScrollTo().performClick()
        compose.onNodeWithTag("geometry.crop-2").performScrollTo().performTextReplacement("110")
        compose.onNodeWithTag("geometry.apply-crop").performScrollTo().assertIsNotEnabled()
        compose.onNodeWithTag("geometry.crop-2").performScrollTo().performTextReplacement("75")
        compose.onNodeWithTag("geometry.crop-0").performScrollTo().performTextReplacement("20")
        compose.onNodeWithTag("geometry.apply-crop").performScrollTo().performClick()
        compose.runOnIdle { assertEquals(.2f, value.cropX); assertEquals(.75f, value.cropWidth); assertFalse(applied) }
        compose.onNodeWithTag("geometry.reset").performClick()
        compose.runOnIdle { assertEquals(GeometrySettings(), value) }
        compose.onNodeWithTag("geometry.apply").performClick()
        compose.runOnIdle { assertTrue(applied) }
        compose.onNodeWithTag("geometry.cancel").performClick()
        compose.runOnIdle { assertTrue(cancelled) }
    }


    @Test fun pendingTransformDisablesApplyAndPresetsWithoutStoppingCorrectionControls() {
        var rotated = false
        compose.setContent {
            MaterialTheme {
                GeometryControls(GeometrySettings(), true, GeometryRatio.SQUARE, false, false, true,
                    onRatio = { fail("Pending preview allowed preset") }, onPortrait = {}, onCorrect = {}, onGrid = {},
                    onApply = { fail("Pending preview applied") }, onCancel = {}, onReset = {},
                    onChange = { _, _ -> rotated = true }, modifier = Modifier.width(360.dp).height(400.dp),
                    cropEnabled = false, applyEnabled = false)
            }
        }
        compose.onNodeWithTag("geometry.apply").assertIsNotEnabled()
        compose.onNodeWithTag("geometry.ratio-SQUARE").performScrollTo().assertIsNotEnabled()
        compose.onNodeWithTag("geometry.swap-ratio").performScrollTo().assertIsNotEnabled()
        compose.onNodeWithTag("geometry.rotate-right").performScrollTo().assertIsEnabled().performClick()
        compose.runOnIdle { assertTrue(rotated) }
    }

    @Test fun disabledDraftStillAllowsCancel() {
        var cancelled = false
        compose.setContent {
            MaterialTheme {
                GeometryControls(GeometrySettings(), false, GeometryRatio.FREE, false, false, true,
                    onRatio = { fail("Disabled ratio changed") }, onPortrait = {}, onCorrect = {}, onGrid = {},
                    onApply = { fail("Disabled apply ran") }, onCancel = { cancelled = true }, onReset = {},
                    onChange = { _, _ -> fail("Disabled draft changed") }, modifier = Modifier.width(360.dp).height(400.dp))
            }
        }
        compose.onNodeWithTag("geometry.apply").assertIsNotEnabled()
        compose.onNodeWithTag("geometry.rotate-right").performScrollTo().assertIsNotEnabled()
        compose.onNodeWithTag("geometry.cancel").performClick()
        compose.runOnIdle { assertTrue(cancelled) }
    }
}
