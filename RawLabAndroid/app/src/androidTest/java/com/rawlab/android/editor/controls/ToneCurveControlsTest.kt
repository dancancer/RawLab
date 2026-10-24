package com.rawlab.android.editor.controls

import androidx.compose.runtime.*
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import com.rawlab.android.RawLabTheme
import com.rawlab.android.settings.*
import com.rawlab.android.testing.LanguageTestRule
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain

@OptIn(ExperimentalTestApi::class)
class ToneCurveControlsTest {
    private val compose = createComposeRule()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule()).around(compose)

    @Test fun confirmedModePreciseCoordinateAndFixedEndpoints() {
        var curve by mutableStateOf(ToneCurveSettings())
        var legacy = .65f
        compose.setContent { RawLabTheme { ToneCurveControls(curve, legacy, true,
            { next, _ -> curve = next }, { next, _ -> legacy = next }) } }
        compose.onNodeWithTag("curve-switch").performClick()
        compose.runOnIdle { assertTrue(curve.isDefault) }
        compose.onNodeWithTag("curve-switch-confirm").performClick()
        compose.onNodeWithTag("curve-x").assertIsNotEnabled()
        compose.onNodeWithTag("curve-remove").assertIsNotEnabled()
        compose.onNodeWithTag("curve-add").performClick()
        compose.onNodeWithTag("curve-x").performClick()
        compose.onNodeWithTag("curve-coordinate-input").performTextReplacement("0.250000000000001")
        compose.onNodeWithTag("curve-coordinate-apply").performClick()
        compose.runOnIdle { assertEquals(.250000000000001, curve.points[1].x, 0.0); assertEquals(.65f, legacy, 0f) }
        compose.onNodeWithTag("curve-point-0").performClick()
        compose.onNodeWithTag("curve-x").assertIsNotEnabled()
        compose.onNodeWithTag("curve-remove").assertIsNotEnabled()
        compose.onNodeWithTag("curve-switch").performClick()
        compose.onNodeWithTag("curve-switch-confirm").performClick()
        compose.runOnIdle { assertTrue(curve.isDefault); assertEquals(.65f, legacy, 0f) }
    }

    @Test fun pointerCommitsOnceAndFineModeCancellationRestoresStart() {
        var curve by mutableStateOf(ToneCurveSettings.identity.inserting(.5, .5))
        var fine by mutableStateOf(false)
        var commits = 0; var cancellations = 0
        compose.setContent { RawLabTheme {
            CompositionLocalProvider(LocalAdjustmentFine provides fine,
                LocalAdjustmentCancellation provides { restore -> cancellations++; restore() }) {
                ToneCurveControls(curve, 0f, true, { next, dragging -> curve = next; if (!dragging) commits++ }, { _, _ -> })
            }
        } }
        val canvas = compose.onNodeWithTag("curve-canvas")
        canvas.performSemanticsAction(SemanticsActions.RequestFocus) { it() }
        canvas.performTouchInput { down(center); moveBy(Offset(20f, -20f)) }
        canvas.performKeyInput { keyDown(Key.DirectionRight); keyUp(Key.DirectionRight) }
        compose.runOnIdle { assertEquals(0, commits); assertTrue(curve.points[1].y > .5) }
        canvas.performTouchInput { moveBy(Offset(10f, -10f)); up() }
        compose.runOnIdle { assertEquals(1, commits) }
        val before = curve
        canvas.performTouchInput { down(center); moveBy(Offset(-20f, 20f)) }
        compose.runOnIdle { fine = true }
        compose.waitForIdle()
        compose.runOnIdle { assertEquals(1, cancellations); assertEquals(before, curve) }
        canvas.performTouchInput { up() }
    }
}
