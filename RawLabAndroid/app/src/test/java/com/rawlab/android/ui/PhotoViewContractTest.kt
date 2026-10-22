package com.rawlab.android.ui

import com.rawlab.android.editor.canvas.PhotoViewport
import com.rawlab.android.editor.canvas.PhotoZoom
import com.rawlab.android.editor.canvas.*
import org.junit.Assert.*
import org.junit.Test

class PhotoViewContractTest {
    @Test fun halfSizeComparisonPanePreservesFitMagnificationAndPhotoFocus() {
        val full = PhotoViewport(2400f, 1600f, 1200f, 800f)
        val pane = PhotoViewport(2400f, 1600f, 600f, 400f)
        val projected = PhotoZoom(1f, 300f, 200f).resize(full, pane)
        assertEquals("Both panes use twice their own fit scale", pane.fitScale * 2f, projected.scale, .0001f)
        assertEquals("Horizontal pan projects the same photo focal point", 150f, projected.x, .0001f)
        assertEquals("Vertical pan projects the same photo focal point", 100f, projected.y, .0001f)
    }

    @Test fun paneProjectionRoundTripRestoresTheOriginalPhotoView() {
        val full = PhotoViewport(2400f, 1600f, 1200f, 800f)
        val pane = PhotoViewport(2400f, 1600f, 600f, 400f)
        val start = PhotoZoom(1f, 300f, 200f)
        val projected = start.resize(full, pane)
        assertEquals(.5f, projected.scale, .0001f)
        assertEquals(start, projected.resize(pane, full))
    }

    @Test fun comparisonOffAndPhotoChangeRetainTheChosenModeButClearTemporaryView() {
        val chosen = PhotoViewOptions().selectComparison(ComparisonMode.WIPE)
        val closed = chosen.toggleComparison()
        assertFalse(closed.comparisonEnabled)
        assertEquals(ComparisonMode.WIPE, closed.preferredMode)
        assertEquals(ComparisonMode.WIPE, closed.toggleComparison().preferredMode)
        val switched = closed.copy(holdingBefore = true, purePreview = true, infoMode = 2).forNewPhoto()
        assertFalse(switched.holdingBefore)
        assertFalse(switched.purePreview)
        assertEquals(0, switched.infoMode)
        assertEquals(ComparisonMode.WIPE, switched.preferredMode)
    }

    @Test fun draftsAndPermanentComparisonBlockHoldAndDraftsBlockPurePreview() {
        assertFalse(PhotoViewOptions().beginHold(false).holdingBefore)
        assertFalse(PhotoViewOptions().selectComparison(ComparisonMode.SIDE_BY_SIDE).beginHold(true).holdingBefore)
        assertTrue(PhotoViewOptions().beginHold(true).holdingBefore)
        assertFalse(PhotoViewOptions().beginHold(true).cancelHold().holdingBefore)
        assertFalse(PhotoViewOptions().enterPure(false).purePreview)
        assertTrue(PhotoViewOptions().enterPure(true).purePreview)
    }

    @Test fun wipeCoordinatesUseTheVisiblePhotoInsteadOfItsLetterbox() {
        val viewport = PhotoViewport(2400f, 1600f, 600f, 600f)
        val rect = photoImageRect(viewport, PhotoZoom(.25f))
        assertEquals(PhotoImageRect(0f, 100f, 600f, 500f), rect)
        assertEquals(300f, rect.splitX(.5f), .001f)
        assertEquals(0f, rect.splitAt(-20f), .001f)
        assertEquals(1f, rect.splitAt(700f), .001f)
    }
}
