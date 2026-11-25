package com.rawlab.android.editor

import android.graphics.Bitmap
import android.net.Uri
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.size
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotDisplayed
import androidx.compose.ui.test.click
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.dp
import com.rawlab.android.RawLabTheme
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.editor.ui.EditorScreen
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.EditSettings
import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class InspectionOverlayMenuInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun workspaceOverlaySubmenuOpensAndSelectsOverlayWhileToolIsOpen() {
        val bitmap = Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888)
        val edits = EditSettings()
        val state = EditorState(
            photo = ImportedPhoto(Uri.parse("content://rawlab.test/inspection-menu"), "fixture", File("fixture")),
            preview = PreviewPair(bitmap, bitmap, temperature = 6500f, tint = 0f),
            exact = true,
            edits = edits,
            draft = AdjustmentDraft(AdjustmentGroup.EXPOSURE, edits, edits),
        )
        compose.setContent {
            RawLabTheme {
                EditorScreen(
                    state = state,
                    onAlbum = {},
                    onFile = {},
                    onEdit = { _, _ -> },
                    onRetry = {},
                    onExport = {},
                    onMessageDismiss = {},
                    onLicenses = {},
                    onGpuChange = {},
                )
            }
        }
        compose.waitForIdle()
        compose.onNodeWithTag("workspace-more").assertIsDisplayed().performTouchInput { click() }
        compose.onNodeWithTag("inspection-gray50-menu").assertIsDisplayed()
        compose.onNodeWithTag("inspection-overlay-menu").assertIsDisplayed().performClick()
        compose.onNodeWithTag("inspection-overlay-item-sketch_luminance").assertIsDisplayed().performClick()
        compose.onNodeWithTag("inspection-overlay-pill").assertIsDisplayed()
        compose.onNodeWithTag("workspace-more").assertIsDisplayed()

        val pillBounds = compose.onNodeWithTag("inspection-overlay-pill").fetchSemanticsNode().boundsInRoot
        val undoBounds = compose.onNodeWithTag("workspace-undo").fetchSemanticsNode().boundsInRoot
        assertFalse("Inspection overlay pill must not overlap undo action", pillBounds.overlaps(undoBounds))
        assertTrue(
            "Inspection overlay pill (${pillBounds.bottom}) must stay above undo action (${undoBounds.top})",
            pillBounds.bottom <= undoBounds.top,
        )
    }

    @Test fun portraitOverviewOverlayPillStaysAboveUndoAndSupportsInlineSwitchAndClear() {
        val bitmap = Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888)
        val edits = EditSettings()
        val state = EditorState(
            photo = ImportedPhoto(Uri.parse("content://rawlab.test/inspection-portrait"), "IMG_20260629.DNG", File("fixture")),
            preview = PreviewPair(bitmap, bitmap, temperature = 6500f, tint = 0f),
            exact = true,
            edits = edits,
        )
        compose.setContent {
            RawLabTheme {
                androidx.compose.foundation.layout.Box(Modifier.size(width = 390.dp, height = 844.dp)) {
                    EditorScreen(
                        state = state,
                        onAlbum = {},
                        onFile = {},
                        onEdit = { _, _ -> },
                        onRetry = {},
                        onExport = {},
                        onMessageDismiss = {},
                        onLicenses = {},
                        onGpuChange = {},
                        canUndoAdjustment = true,
                    )
                }
            }
        }
        compose.waitForIdle()

        // Open Warm-Cool BW overlay from the overview top bar menu (matching user's screenshot flow)
        compose.onNodeWithTag("editor-menu").assertIsDisplayed().performClick()
        compose.onNodeWithTag("inspection-overlay-menu").assertIsDisplayed().performClick()
        compose.onNodeWithTag("inspection-overlay-item-warm_cool_bw").assertIsDisplayed().performClick()
        compose.waitForIdle()

        val pillBounds = compose.onNodeWithTag("inspection-overlay-pill").assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        val switcherBounds = compose.onNodeWithTag("inspection-overlay-switcher").assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        val clearBounds = compose.onNodeWithTag("inspection-overlay-clear").assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        val undoBounds = compose.onNodeWithTag("workspace-undo").assertIsDisplayed().fetchSemanticsNode().boundsInRoot

        assertFalse("Overlay pill must not overlap workspace undo button", pillBounds.overlaps(undoBounds))
        assertTrue(
            "Overlay pill bottom (${pillBounds.bottom}) must sit cleanly above undo top (${undoBounds.top})",
            pillBounds.bottom <= undoBounds.top,
        )
        val minTouchPx = with(compose.density) { 47.5.dp.toPx() }
        assertTrue("Switcher height >= 48dp", switcherBounds.height >= minTouchPx)
        assertTrue("Clear button >= 48x48dp", clearBounds.width >= minTouchPx && clearBounds.height >= minTouchPx)

        // Also enable Sampling Monitor and verify combined stack still never overlaps undo
        compose.onNodeWithTag("editor-menu").performClick()
        compose.onNodeWithTag("inspection-sampling-toggle").assertIsDisplayed().performClick()
        compose.waitForIdle()

        val hudBounds = compose.onNodeWithTag("inspection-sampling-hud").assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        val undoBoundsWithHud = compose.onNodeWithTag("workspace-undo").fetchSemanticsNode().boundsInRoot
        assertFalse("Combined inspection HUD must not overlap undo button", hudBounds.overlaps(undoBoundsWithHud))
        assertTrue(
            "Combined inspection HUD bottom (${hudBounds.bottom}) must sit above undo top (${undoBoundsWithHud.top})",
            hudBounds.bottom <= undoBoundsWithHud.top,
        )

        // Switch overlay directly from the canvas pill without reopening the top menu
        compose.onNodeWithTag("inspection-overlay-switcher").performClick()
        compose.onNodeWithTag("inspection-overlay-item-sketch_luminance").assertIsDisplayed().performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("inspection-overlay-pill").assertIsDisplayed()

        // Clear overlay in 1 tap via the pill's close button
        compose.onNodeWithTag("inspection-overlay-clear").performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("inspection-overlay-pill").assertIsNotDisplayed()
    }
}
