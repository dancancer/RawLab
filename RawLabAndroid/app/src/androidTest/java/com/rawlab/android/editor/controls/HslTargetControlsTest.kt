package com.rawlab.android.editor.controls

import android.graphics.Bitmap
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import com.rawlab.android.editor.canvas.PhotoCanvas
import com.rawlab.android.editor.canvas.PhotoCanvasState
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.settings.HslTargetState
import com.rawlab.android.testing.LanguageTestRule
import com.rawlab.android.testing.setChineseContent
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain

class HslTargetControlsTest {
    private val compose = createComposeRule()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule()).around(compose)

    @Test fun selectingModeAndAxisDoesNotIssuePhotoEdits() {
        var state by mutableStateOf(HslTargetState())
        var sampled = 0
        compose.setChineseContent { MaterialTheme {
            HslTargetControls(HslTargetActions(state, enabled = { state = state.copy(enabled = it) },
                axis = { state = state.copy(axis = it) }, begin = { _, _ -> sampled++ }), true)
        } }
        compose.onNodeWithTag("hsl-target").performClick()
        compose.onNodeWithTag("hsl-target-axis-2").performClick().assertIsSelected()
        compose.runOnIdle { assertTrue(state.enabled); assertEquals(2, state.axis); assertEquals(0, sampled) }
        compose.onNodeWithTag("hsl-target").performClick()
        compose.onNodeWithTag("hsl-target-axis-2").assertDoesNotExist()
    }

    @Test fun collapsedTargetShowsAxisAndExit() {
        var state by mutableStateOf(HslTargetState(enabled = true, axis = 2))
        compose.setChineseContent { MaterialTheme {
            if (state.enabled) HslTargetCanvasControls(HslTargetActions(state, enabled = { state = state.copy(enabled = it) }))
        } }
        compose.onNodeWithText("目标调整：明度").assertIsDisplayed()
        compose.onNodeWithTag("hsl-target-exit").performClick()
        compose.onNodeWithTag("hsl-target-canvas").assertDoesNotExist()
    }

    @Test fun canvasUsesOneFixedSampleAndCancelsWhenSecondFingerArrives() {
        val bitmap = Bitmap.createBitmap(600, 400, Bitmap.Config.ARGB_8888).apply { eraseColor(0xffcc6633.toInt()) }
        val points = mutableListOf<Pair<Float, Float>>()
        val moves = mutableListOf<Float>()
        var ended = 0; var cancelled = 0
        compose.setChineseContent { MaterialTheme {
            val canvas = remember { PhotoCanvasState() }
            PhotoCanvas(PreviewPair(bitmap, bitmap, 6500f, 0f), false, "target.png", canvas,
                hslTarget = HslTargetActions(HslTargetState(enabled = true), begin = { x, y -> points += x to y },
                    move = { moves += it }, end = { ended++ }, cancel = { cancelled++ }))
        } }
        val canvas = compose.onNodeWithTag("photo-canvas")
        canvas.performTouchInput { down(center); moveBy(Offset(0f, -40f)); moveBy(Offset(0f, -20f)); up() }
        compose.runOnIdle {
            assertEquals(1, points.size); assertEquals(.5f, points.single().first, .01f)
            assertEquals(.5f, points.single().second, .01f); assertTrue(moves.last() > 0); assertEquals(1, ended)
        }
        val before = cancelled
        canvas.performTouchInput {
            down(0, center); moveBy(Offset(0f, -15f)); down(1, center + Offset(50f, 0f));
            moveBy(1, Offset(15f, 0f)); up(1); up(0)
        }
        compose.runOnIdle { assertTrue(cancelled > before); assertEquals(1, ended) }
    }
}
