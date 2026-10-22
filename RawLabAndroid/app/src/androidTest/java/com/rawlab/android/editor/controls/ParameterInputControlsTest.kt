package com.rawlab.android.editor.controls

import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import com.rawlab.android.R
import com.rawlab.android.RawLabTheme
import com.rawlab.android.settings.HslSettings
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import com.rawlab.android.testing.LanguageTestRule
import org.junit.rules.RuleChain
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.dp

class ParameterInputControlsTest {
    private val compose = createComposeRule()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule()).around(compose)

    @Test fun oldHalfValueAndEquivalentTextApplyWithoutCallingSetter() {
        var writes = 0
        compose.setContent { RawLabTheme {
            NumericControl(R.string.hsl_hue, .5f, -100f..100f, "", true, { _, _ -> writes++ }, {})
        } }
        compose.onNodeWithTag("adjustment-value-${R.string.hsl_hue}").assertTextContains("0.5").performClick()
        compose.onNodeWithTag("adjustment-input").assertTextContains("0.5").performTextReplacement("0.50")
        compose.onNodeWithTag("adjustment-input-apply").performClick()
        compose.onNodeWithTag("adjustment-input").assertDoesNotExist()
        compose.runOnIdle { assertEquals(0, writes) }
    }

    @Test fun invalidNewInputStaysOpenAndLegalNewInputCallsSetterOnce() {
        val writes = mutableListOf<Float>()
        compose.setContent { RawLabTheme {
            NumericControl(R.string.hsl_hue, 0f, -100f..100f, "", true, { value, _ -> writes += value }, {})
        } }
        compose.onNodeWithTag("adjustment-value-${R.string.hsl_hue}").performClick()
        listOf("", "NaN", "Infinity", "101", "0.5").forEach { input ->
            compose.onNodeWithTag("adjustment-input").performTextReplacement(input)
            compose.onNodeWithTag("adjustment-input-apply").assertIsNotEnabled()
            compose.onNodeWithTag("adjustment-input").assertExists()
            compose.runOnIdle { assertTrue(writes.isEmpty()) }
        }
        compose.onNodeWithTag("adjustment-input").performTextReplacement("1")
        compose.onNodeWithTag("adjustment-input-apply").performClick()
        compose.runOnIdle { assertEquals(listOf(1f), writes) }
    }

    @Test fun sameValueInAnotherSourceOrToolCancelsTheOldInput() {
        var scope by mutableStateOf("source-a" to 14)
        var writes = 0
        compose.setContent { RawLabTheme {
            CompositionLocalProvider(LocalAdjustmentSession provides scope) {
                NumericControl(R.string.hsl_hue, .5f, -100f..100f, "", true, { _, _ -> writes++ }, {})
            }
        } }
        for (next in listOf("source-b" to 14, "source-b" to 7)) {
            compose.onNodeWithTag("adjustment-value-${R.string.hsl_hue}").performClick()
            compose.onNodeWithTag("adjustment-input").performTextReplacement("25")
            compose.runOnIdle { scope = next }
            compose.onNodeWithTag("adjustment-input").assertDoesNotExist()
            compose.runOnIdle { assertEquals(0, writes) }
        }
    }

    @Test fun semanticResetUsesEffectiveDefaultWithoutEditingNumericText() {
        var resets = 0
        compose.setContent { RawLabTheme {
            NumericControl(R.string.temperature, 6500f, 2000f..50000f, "K", true,
                { _, _ -> fail("Reset must reuse the supplied effective-default action") }, { resets++ }, reciprocal = true, defaultValue = 5237f)
        } }
        compose.onNodeWithTag("adjustment-slider").fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsActions.CustomActions].single().action()
        compose.runOnIdle { assertEquals(1, resets) }
    }

    @Test fun fineOnlyQuartersDragAndNeverChangesExactInputOrValueOnToggle() {
        var fine by mutableStateOf(false)
        var value by mutableFloatStateOf(0f)
        var calls = 0
        compose.setContent { RawLabTheme {
            CompositionLocalProvider(LocalAdjustmentFine provides fine) {
                NumericControl(R.string.exposure, value, -4f..4f, "EV", true,
                    { next, _ -> value = next; calls++ }, { value = 0f })
            }
        } }
        fun drag() = compose.onNodeWithTag("adjustment-slider").performTouchInput {
            down(center); moveBy(Offset(-32.dp.toPx(), 0f)); up()
        }
        drag()
        compose.runOnIdle { assertEquals(.2f, value, .00001f); value = 0f; fine = true; calls = 0 }
        compose.waitForIdle()
        compose.runOnIdle { assertEquals(0f, value, 0f); assertEquals(0, calls) }
        drag()
        compose.runOnIdle { assertEquals(.05f, value, .00001f) }
        compose.onNodeWithTag("adjustment-value-${R.string.exposure}").performClick()
        compose.onNodeWithTag("adjustment-input").performTextReplacement("1")
        compose.onNodeWithTag("adjustment-input-apply").performClick()
        compose.runOnIdle { assertEquals(1f, value, 0f) }
    }

    @Test fun hslChangedMarkerIsBelowTheColorAndSeparateFromSelectionRing() {
        compose.setContent { RawLabTheme {
            HslControls(HslSettings().withValue(0, 0, .5f), true, 0, {}, {}, { _, _ -> })
        } }
        for (index in 0..1) {
            val item = compose.onNodeWithTag("hsl-channel-$index").fetchSemanticsNode().boundsInRoot
            val color = compose.onNodeWithTag("hsl-color-$index", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
            val marker = compose.onNodeWithTag("hsl-marker-$index", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
            val density = compose.density.density
            assertEquals(48f * density, item.height, 1f)
            assertEquals(24f * density, color.height, 1f)
            assertTrue("Changed marker has an independent slot below the color/selection ring", marker.top >= color.bottom + 2f * density && marker.bottom <= item.bottom)
        }
    }

    @Test fun hslAccessibilityCurrentValueRoundTripDoesNotCallSetter() = progressRoundTrip(R.string.hsl_hue, .5f, -100f..100f)
    @Test fun cameraTemperatureAccessibilityCurrentValueRoundTripDoesNotCallSetter() = progressRoundTrip(R.string.temperature, 5237f, 2000f..50000f)
    private fun progressRoundTrip(label: Int, original: Float, range: ClosedFloatingPointRange<Float>) {
        val calls = mutableListOf<Float>()
        compose.setContent { RawLabTheme {
            NumericControl(label, original, range, "", true, { next, _ -> calls += next }, {}, reciprocal = label == R.string.temperature)
        } }
        val track = compose.onNodeWithTag("adjustment-slider")
        val current = track.fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsProperties.ProgressBarRangeInfo].current
        track.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.SetProgress) { assertTrue(it(current)) }
        compose.runOnIdle { assertTrue("Accessibility read/write roundtrip must preserve $original without setter: $calls", calls.isEmpty()) }
    }

    @Test fun modifiedValueDragContinuesAcrossRecomposition() = continuousDrag(.5f)
    @Test fun firstModificationDoesNotCancelTheActiveDrag() = continuousDrag(0f)
    private fun continuousDrag(original: Float) {
        var value by mutableFloatStateOf(original)
        val calls = mutableListOf<Pair<Float, Boolean>>()
        compose.setContent { RawLabTheme {
            NumericControl(R.string.exposure, value, -4f..4f, "EV", true,
                { next, interactive -> value = next; calls += next to interactive }, {})
        } }
        val track = compose.onNodeWithTag("adjustment-slider")
        track.performTouchInput { down(center); moveBy(Offset(-32.dp.toPx(), 0f)) }
        compose.runOnIdle { assertEquals(original + .2f, value, .00001f) }
        track.performTouchInput { moveBy(Offset(-32.dp.toPx(), 0f)); up() }
        compose.runOnIdle {
            assertEquals("The second move must update after the first move recomposed the row", original + .4f, value, .00001f)
            assertEquals(false, calls.last().second)
        }
    }

    @Test fun dragReturningToOriginalStillFinishesTheInteractiveTransaction() {
        var value by mutableFloatStateOf(0f)
        val calls = mutableListOf<Pair<Float, Boolean>>()
        compose.setContent { RawLabTheme {
            NumericControl(R.string.exposure, value, -4f..4f, "EV", true,
                { next, interactive -> value = next; calls += next to interactive }, {})
        } }
        compose.onNodeWithTag("adjustment-slider").performTouchInput {
            down(center); moveBy(Offset(-32.dp.toPx(), 0f)); moveBy(Offset(32.dp.toPx(), 0f)); up()
        }
        compose.runOnIdle {
            assertTrue("The drag crossed an actual numeric grid step", calls.any { it.first != 0f && it.second })
            assertEquals(0f, value, 0f)
            assertEquals("A real edit must finish even after returning to the starting value", 0f to false, calls.last())
        }
    }

    @Test fun channelChangeCancelsOldNumericDraftBeforeRebindingAxis() {
        var channel by mutableIntStateOf(0)
        var writes = 0
        compose.setContent { RawLabTheme {
            HslControls(HslSettings().withValue(0, 0, .5f), true, channel, { channel = it }, {}, { _, _ -> writes++ })
        } }
        compose.onNodeWithTag("adjustment-value-${R.string.hsl_hue}").performClick()
        compose.onNodeWithTag("adjustment-input").performTextReplacement("25")
        compose.runOnIdle { channel = 1 }
        compose.onNodeWithTag("adjustment-input").assertDoesNotExist()
        compose.runOnIdle { assertEquals(0, writes) }
    }
}
