package com.rawlab.android.editor

import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import com.rawlab.android.R
import com.rawlab.android.RawLabTheme
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.editor.ui.EditorScreen
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.testing.ForegroundTestRule
import com.rawlab.android.testing.LanguageTestRule
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File

class MobileWorkspaceUITest {
    private val compose = createComposeRule()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule()).around(ForegroundTestRule()).around(compose)
    private var state by mutableStateOf(EditorState(
        photo = ImportedPhoto(Uri.parse("content://rawlab.test/mobile-workspace"), "preview.RAW", File("preview.RAW")),
        preview = Bitmap.createBitmap(120, 160, Bitmap.Config.ARGB_8888).let { PreviewPair(it, it, temperature = 5200f, tint = 8f) },
        exact = true))
    private var applied = 0

    private fun show(scale: Float = 1f, width: Int = 390, height: Int = 800) {
        compose.setContent {
            CompositionLocalProvider(LocalDensity provides Density(1f, scale)) {
                Box(Modifier.size(width.dp, height.dp).consumeWindowInsets(WindowInsets.safeDrawing).testTag("workspace-fixture")) {
                    RawLabTheme {
                        EditorScreen(state, {}, {}, { edits, dragging -> state = state.copy(draft = state.draft!!.update(edits, dragging)) },
                            {}, {}, {}, {}, {}, onBeginDraft = { state = state.copy(draft = AdjustmentDraft.begin(it, state.edits)) },
                            onDiscardDraft = { state = state.copy(draft = null) },
                            onUndoDraft = { state = state.copy(draft = state.draft?.undo()) },
                            onRedoDraft = { state = state.copy(draft = state.draft?.redo()) },
                            onApplyDraft = { complete ->
                                val draft = state.draft!!
                                if (draft.changed) applied += 1
                                state = state.copy(edits = draft.project(state.edits), draft = null)
                                complete(true)
                            })
                    }
                }
            }
        }
    }
    private fun group(id: String) {
        compose.onNodeWithTag("editor-groups").performScrollToNode(hasTestTag("editor-group-$id"))
        compose.onNodeWithTag("editor-group-$id").performClick()
    }
    private fun bounds(tag: String) = compose.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot

    @Test fun homeUsesFourColumnsAndHslUsesOneRowPerAxis() {
        show(); compose.onNodeWithTag("editor-camera").assertIsDisplayed(); group("light")
        val first = bounds("editor-tool-2")
        for (id in listOf(5, 3, 4)) assertEquals(first.top, bounds("editor-tool-$id").top, 1f)
        assertTrue(bounds("editor-tool-19").top >= first.bottom)
        compose.onNodeWithTag("editor-parameters").assertDoesNotExist()
        group("color"); compose.onNodeWithTag("editor-tool-14").performClick()
        compose.onNodeWithTag("editor-groups").assertDoesNotExist()
        compose.onNodeWithTag("photo-info-button").assertDoesNotExist()
        compose.onNodeWithTag("rgb-histogram-toggle").assertDoesNotExist()
        compose.onNodeWithTag("workspace-more").performTouchInput { click() }
        compose.onNodeWithTag("workspace-histogram").performClick()
        compose.onNodeWithTag("rgb-histogram-popup").assertIsDisplayed()
        compose.onNodeWithTag("rgb-histogram-close").performClick()
        compose.onNodeWithTag("draft.cancel").assertIsDisplayed()
        compose.onNodeWithTag("draft.apply").assertIsDisplayed()
        for (label in listOf(R.string.hsl_hue, R.string.saturation, R.string.hsl_lightness))
            assertTrue("HSL uses compact single rows", bounds("adjustment-row-$label").height <= 56f)
        assertTrue("Photo canvas retains most of the screen", bounds("editor-canvas").height > 430f)
        val hue = compose.onNode(hasTestTag("adjustment-slider") and hasAnyAncestor(hasTestTag("adjustment-row-${R.string.hsl_hue}")))
        hue.performTouchInput { swipe(center, androidx.compose.ui.geometry.Offset(width * .85f, centerY), 240) }
        compose.runOnIdle { assertTrue("Compact track increases toward the right", state.visibleEdits.hsl.value(0, 0) > 0f) }
        compose.onNodeWithTag("draft.cancel").performClick()
        compose.onNodeWithTag("editor-groups").assertIsDisplayed()
        assertEquals(0, applied)
    }

    @Test fun preciseValueChangesOnlyDraftAndCancelApplyHaveDistinctResults() {
        show(); group("light"); compose.onNodeWithTag("editor-tool-2").performClick()
        compose.onNodeWithTag("adjustment-value-${R.string.exposure}").performClick()
        compose.onNodeWithTag("adjustment-input").performTextReplacement("1.25")
        compose.onNodeWithTag("adjustment-input-apply").performClick()
        compose.runOnIdle { assertEquals(0f, state.edits.exposure); assertEquals(1.25f, state.visibleEdits.exposure) }
        compose.onNodeWithTag("draft.cancel").performClick()
        compose.runOnIdle { assertEquals(0f, state.edits.exposure) }
        compose.onNodeWithTag("editor-tool-2").performClick()
        compose.onNodeWithTag("adjustment-value-${R.string.exposure}").performClick()
        compose.onNodeWithTag("adjustment-input").performTextReplacement("0.75")
        compose.onNodeWithTag("adjustment-input-apply").performClick()
        compose.onNodeWithTag("draft.apply").performClick()
        compose.runOnIdle { assertEquals(.75f, state.edits.exposure); assertEquals(1, applied) }
        compose.onNodeWithTag("editor-tool-2").performClick()
        compose.onNodeWithTag("draft.apply").performClick()
        compose.runOnIdle { assertEquals(1, applied) }
    }

    @Test fun largeTextAndShortWindowKeepFooterReachable() {
        show(scale = 1.6f, width = 360, height = 640)
        group("color"); compose.onNodeWithTag("editor-tool-14").performScrollTo().performClick()
        compose.onNodeWithTag("draft.cancel").assertIsDisplayed()
        compose.onNodeWithTag("draft.apply").assertIsDisplayed()
        compose.onNodeWithTag("adjustment-value-${R.string.hsl_lightness}").performScrollTo().assertIsDisplayed()
        assertTrue(bounds("editor-canvas").height >= 96f)
    }
}
