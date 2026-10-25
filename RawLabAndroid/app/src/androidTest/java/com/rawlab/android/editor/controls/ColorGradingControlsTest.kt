package com.rawlab.android.editor.controls

import androidx.compose.runtime.*
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import com.rawlab.android.R
import com.rawlab.android.RawLabTheme
import com.rawlab.android.settings.*
import com.rawlab.android.testing.LanguageTestRule
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain

@OptIn(ExperimentalTestApi::class)
class ColorGradingControlsTest {
    private val compose = createComposeRule()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule()).around(compose)

    @Test fun zoneSelectionPendingHueAndEndpointUseIndependentStoredValues() {
        var settings by mutableStateOf(ColorGradingSettings(shadows = ColorGradingWheel(231.2f, 0f)))
        var zone by mutableStateOf(ColorGradingZone.SHADOWS)
        var writes = 0
        compose.setContent { RawLabTheme {
            ColorGradingControls(settings, true, zone, { zone = it }, { next, _ -> settings = next; writes++ })
        } }
        compose.onNodeWithTag("grading-zone-midtones").performClick()
        compose.runOnIdle { assertEquals(0, writes); assertEquals(231.2f, settings.shadows.hue, 0f) }
        compose.onNodeWithTag("grading-zone-shadows").performClick()
        compose.onNodeWithTag("adjustment-value-${R.string.hsl_hue}").performClick()
        for (bad in listOf("-1", "361", "360.0000001")) {
            compose.onNodeWithTag("adjustment-input").performTextReplacement(bad)
            compose.onNodeWithTag("adjustment-input-apply").assertIsNotEnabled()
        }
        compose.onNodeWithTag("adjustment-input").performTextReplacement("360")
        compose.onNodeWithTag("adjustment-input-apply").performClick()
        compose.runOnIdle { assertEquals(1, writes); assertEquals(ColorGradingSettings(), settings) }
        compose.onNodeWithTag("grading-wheel").performSemanticsAction(SemanticsActions.SetProgress) { it(40f) }
        compose.runOnIdle { assertEquals(40f, settings.shadows.saturation, 0f); assertTrue(settings.midtones.isDefault) }
    }

    @Test fun wheelRecompositionCommitsOnceAndFineChangeCancelsAtStart() {
        var settings by mutableStateOf(ColorGradingSettings())
        var fine by mutableStateOf(false)
        var commits = 0
        var cancellations = 0
        val updates = mutableListOf<ColorGradingSettings>()
        compose.setContent { RawLabTheme {
            CompositionLocalProvider(LocalAdjustmentFine provides fine,
                LocalAdjustmentCancellation provides { restore -> cancellations++; restore() }) {
                ColorGradingControls(settings, true, ColorGradingZone.SHADOWS, {}, { next, dragging ->
                    settings = next; if (dragging) updates += next else commits++
                })
            }
        } }
        val wheel = compose.onNodeWithTag("grading-wheel")
        wheel.performSemanticsAction(SemanticsActions.RequestFocus) { it() }
        wheel.performTouchInput { down(center); moveBy(Offset(20f, 0f)) }
        compose.runOnIdle { assertFalse(settings.isDefault) }
        wheel.performKeyInput { keyDown(Key.DirectionRight); keyUp(Key.DirectionRight) }
        compose.runOnIdle { assertEquals("Keyboard input cannot commit an active pointer transaction", 0, commits) }
        wheel.performTouchInput { moveBy(Offset(20f, 0f)); up() }
        compose.runOnIdle { assertTrue(updates.size >= 2); assertEquals(1, commits) }
        val before = settings
        wheel.performTouchInput { down(center); moveBy(Offset(0f, 30f)) }
        compose.runOnIdle { fine = true }
        compose.waitForIdle()
        compose.runOnIdle { assertEquals(1, cancellations); assertEquals(before, settings) }
        wheel.performTouchInput { up() }
    }
}
