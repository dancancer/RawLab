package com.rawlab.android.editor

import android.graphics.Bitmap
import android.net.Uri
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.size
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.click
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.dp
import com.rawlab.android.RawLabTheme
import com.rawlab.android.editor.inspection.InspectionBitmap
import com.rawlab.android.editor.inspection.InspectionOverlayMode
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.editor.ui.EditorScreen
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.EditSettings
import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class InspectionOverlayMenuInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    private fun maxLumaInBitmap(bmp: Bitmap): Int {
        val pixels = IntArray(bmp.width * bmp.height)
        bmp.getPixels(pixels, 0, bmp.width, 0, 0, bmp.width, bmp.height)
        var peak = 0
        for (px in pixels) {
            val r = (px ushr 16) and 0xff
            val g = (px ushr 8) and 0xff
            val b = px and 0xff
            val m = maxOf(r, g, b)
            if (m > peak) peak = m
        }
        return peak
    }

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

    @Test fun sliderDragKeepsInspectionUnfadedAndMeasuredInsetTracksAnchorCollapse() {
        val bitmap = Bitmap.createBitmap(16, 16, Bitmap.Config.ARGB_8888).apply {
            eraseColor(android.graphics.Color.rgb(64, 64, 64))
        }
        val edits = EditSettings()
        val state = EditorState(
            photo = ImportedPhoto(Uri.parse("content://rawlab.test/inspection-drag-inset"), "fixture", File("fixture")),
            preview = PreviewPair(bitmap, bitmap, temperature = 6500f, tint = 0f),
            exact = true,
            edits = edits,
            draft = AdjustmentDraft(AdjustmentGroup.EXPOSURE, edits, edits.copy(exposure = 0.2f)),
            saveState = EditSaveState.FAILED,
            saveError = "Save failed",
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
                    )
                }
            }
        }
        compose.waitForIdle()

        // Enable overlay + sampling monitor and pin 2 anchors
        compose.onNodeWithTag("workspace-more").performClick()
        compose.onNodeWithTag("inspection-overlay-menu").performClick()
        compose.onNodeWithTag("inspection-overlay-item-warm_cool_bw").performClick()
        compose.onNodeWithTag("workspace-more").performClick()
        compose.onNodeWithTag("inspection-sampling-toggle").performClick()
        compose.onNodeWithTag("inspection-pin-anchor").performClick()
        compose.onNodeWithTag("inspection-pin-anchor").performClick()
        compose.waitForIdle()

        // 1. Measured onSizeChanged inset: save notice sits above expanded HUD and moves down when anchors collapse
        val expandedHudBounds = compose.onNodeWithTag("inspection-sampling-hud").fetchSemanticsNode().boundsInRoot
        val expandedNoticeBounds = compose.onNodeWithTag("edit-save-notice").assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        assertTrue(
            "Save notice (${expandedNoticeBounds.bottom}) must stay above expanded HUD (${expandedHudBounds.top})",
            expandedNoticeBounds.bottom <= expandedHudBounds.top + 1f,
        )

        compose.onNodeWithTag("inspection-anchors-collapse").performClick()
        compose.waitForIdle()
        val collapsedHudBounds = compose.onNodeWithTag("inspection-sampling-hud").fetchSemanticsNode().boundsInRoot
        val collapsedNoticeBounds = compose.onNodeWithTag("edit-save-notice").fetchSemanticsNode().boundsInRoot
        assertTrue(
            "Collapsing anchors must shrink measured inset and move save notice down (${collapsedNoticeBounds.bottom} > ${expandedNoticeBounds.bottom})",
            collapsedNoticeBounds.bottom > expandedNoticeBounds.bottom + 10f,
        )
        assertTrue(
            "Save notice (${collapsedNoticeBounds.bottom}) must remain above collapsed HUD (${collapsedHudBounds.top})",
            collapsedNoticeBounds.bottom <= collapsedHudBounds.top + 1f,
        )

        // 2. Dragging adjustment slider fades workspaceActions to 32% while keeping overlay pill & sampling card at 100%
        val barPeakBefore = maxLumaInBitmap(compose.onNodeWithTag("workspace-more").captureToImage().asAndroidBitmap())
        compose.onNodeWithTag("adjustment-slider").performTouchInput {
            down(center)
            moveBy(Offset(48f, 0f))
        }
        compose.mainClock.advanceTimeBy(300)
        compose.waitForIdle()

        val barPeakDuringDrag = maxLumaInBitmap(compose.onNodeWithTag("workspace-more").captureToImage().asAndroidBitmap())
        val pillPeakDuringDrag = maxLumaInBitmap(compose.onNodeWithTag("inspection-overlay-pill").captureToImage().asAndroidBitmap())
        val cardPeakDuringDrag = maxLumaInBitmap(compose.onNodeWithTag("inspection-sampling-card").captureToImage().asAndroidBitmap())

        compose.onNodeWithTag("adjustment-slider").performTouchInput { up() }
        compose.waitForIdle()

        assertTrue("Workspace action bar glyph starts bright ($barPeakBefore)", barPeakBefore > 200)
        assertTrue("Workspace action bar fades during slider drag ($barPeakDuringDrag < $barPeakBefore)", barPeakDuringDrag < 165)
        assertTrue("Overlay pill text remains crisp and unfaded during slider drag ($pillPeakDuringDrag)", pillPeakDuringDrag > 220)
        assertTrue("Sampling card text remains crisp and unfaded during slider drag ($cardPeakDuringDrag)", cardPeakDuringDrag > 220)
    }

    @Test fun rememberBitmapRecomputesWhenDistinctSourceInstancesSwap() {
        val darkBmp = Bitmap.createBitmap(4, 4, Bitmap.Config.ARGB_8888).apply {
            eraseColor(android.graphics.Color.rgb(20, 40, 200))
        }
        val warmBmp = Bitmap.createBitmap(4, 4, Bitmap.Config.ARGB_8888).apply {
            eraseColor(android.graphics.Color.rgb(220, 180, 40))
        }
        val activeSource = androidx.compose.runtime.mutableStateOf(darkBmp)
        var latestOut: Bitmap? = null
        compose.setContent {
            latestOut = InspectionBitmap.rememberBitmap(activeSource.value, InspectionOverlayMode.WARM_COOL_BW)
        }
        compose.waitForIdle()
        val firstRendered = latestOut!!
        val firstPx = firstRendered.getPixel(0, 0) and 0xff

        activeSource.value = warmBmp
        compose.waitForIdle()
        val secondRendered = latestOut!!
        val secondPx = secondRendered.getPixel(0, 0) and 0xff

        assertNotEquals("Swapping source Bitmap must recompute overlay output", firstPx, secondPx)
        assertTrue("Warm source produces brighter Warm-Cool BW output ($secondPx > $firstPx)", secondPx > firstPx)
    }
}
