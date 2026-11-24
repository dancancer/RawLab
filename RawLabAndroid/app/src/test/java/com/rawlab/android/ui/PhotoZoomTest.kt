package com.rawlab.android.ui

import org.junit.Assert.*
import org.junit.Test
import com.rawlab.android.editor.canvas.NormalizedRect
import com.rawlab.android.editor.canvas.PhotoImageRect
import com.rawlab.android.editor.canvas.PhotoViewport
import com.rawlab.android.editor.canvas.PhotoZoom
import com.rawlab.android.editor.canvas.detailTileDstRect
import com.rawlab.android.editor.canvas.photoFullImageRect
import com.rawlab.android.editor.canvas.photoImageRect

class PhotoZoomTest {
    @Test fun previewSizeUsesViewportAndZoomWithoutUpsampling() {
        val area = PhotoViewport(2400f, 1600f, 1200f, 1800f)
        assertEquals(1216, area.previewLongEdge(area.fitScale))
        assertEquals(1600, area.previewLongEdge(1f))
        val small = PhotoViewport(300f, 200f, 1200f, 1800f)
        assertEquals(300, small.previewLongEdge(small.fitScale))
        val landscape = PhotoViewport(2400f, 1600f, 1800f, 600f)
        assertEquals(960, landscape.previewLongEdge(landscape.fitScale))
    }
    private val viewport = PhotoViewport(2400f, 1600f, 1200f, 1800f)

    @Test fun doubleTapUsesOneImagePixelPerDisplayPixel() {
        val fit = PhotoZoom(viewport.fitScale)
        val actual = fit.doubleTap(viewport, 600f, 900f)
        assertEquals(1f, actual.scale, .0001f)
        assertEquals(.5f, actual.doubleTap(viewport, 600f, 900f).scale, .0001f)
        assertEquals(.5f, PhotoZoom(2f).doubleTap(viewport, 600f, 900f).scale, .0001f)
    }

    @Test fun nativePixelsCanBeSmallerThanFit() {
        val small = PhotoViewport(300f, 200f, 1200f, 1800f)
        assertEquals(4f, small.fitScale, .0001f)
        assertEquals(1f, PhotoZoom(4f).doubleTap(small, 600f, 900f).scale, .0001f)
        assertEquals(4f, PhotoZoom(1f).doubleTap(small, 600f, 900f).scale, .0001f)
    }

    @Test fun pinchKeepsItsFocalPointAndClampsPanToImageEdges() {
        val zoom = PhotoZoom(.5f).transform(viewport, 2f, 0f, 0f, 900f, 900f)
        assertEquals(1f, zoom.scale, .0001f)
        assertEquals(-300f, zoom.x, .0001f)
        assertEquals(0f, zoom.y, .0001f)
        val dragged = zoom.transform(viewport, 1f, 9000f, -9000f, 600f, 900f)
        assertEquals(600f, dragged.x, .0001f)
        assertEquals(0f, dragged.y, .0001f)
        val fit = dragged.transform(viewport, .01f, 0f, 0f, 600f, 900f)
        assertEquals(PhotoZoom(.5f), fit)
    }

    @Test fun pinchStopsAtEightTimesFitWithoutLosingNativePixelAccess() {
        assertEquals(4f, PhotoZoom(.5f).transform(viewport, 100f, 0f, 0f, 600f, 900f).scale, .0001f)
        val huge = PhotoViewport(24000f, 16000f, 1200f, 1800f)
        assertEquals(1f, PhotoZoom(huge.fitScale).doubleTap(huge, 600f, 900f).scale, .0001f)
    }

    @Test fun resizeKeepsRelativeFitAndReclampsTheProjectedPhotoFocus() {
        val landscape = PhotoViewport(2400f, 1600f, 1800f, 600f)
        assertEquals(PhotoZoom(.375f), PhotoZoom(.5f).resize(viewport, landscape))
        assertEquals(PhotoZoom(.75f), PhotoZoom(1f, 600f, 0f).resize(viewport, landscape))
    }

    @Test fun largeRawAllowsNativeOneToOneZoomAndTracksVisibleNormalizedRect() {
        val large = PhotoViewport(6000f, 4000f, 1200f, 1800f)
        assertEquals(0.2f, large.fitScale, 0.0001f)
        assertEquals(4f, large.maximumScale, 0.0001f)
        assertEquals(1f, PhotoZoom(large.fitScale).doubleTap(large, 600f, 900f).scale, 0.0001f)
        assertEquals(4f, PhotoZoom(large.fitScale).transform(large, 100f, 0f, 0f, 600f, 900f).scale, 0.0001f)

        val fitRect = large.visibleNormalizedRect(PhotoZoom(large.fitScale))!!
        assertEquals(0f, fitRect.x0, 0.001f)
        assertEquals(0f, fitRect.y0, 0.001f)
        assertEquals(1f, fitRect.x1, 0.001f)
        assertEquals(1f, fitRect.y1, 0.001f)

        val oneToOneRect = large.visibleNormalizedRect(PhotoZoom(1f))!!
        assertEquals(0.4f, oneToOneRect.x0, 0.001f)
        assertEquals(0.6f, oneToOneRect.x1, 0.001f)
        assertEquals(0.275f, oneToOneRect.y0, 0.001f)
        assertEquals(0.725f, oneToOneRect.y1, 0.001f)
    }

    @Test fun detailRequestThresholdOverscanAndHysteresisWorkTogether() {
        val large = PhotoViewport(6000f, 4000f, 1200f, 1800f)
        val baseLongEdge = 1600
        val baseScale = 1600f / 6000f

        assertNull(large.detailRequest(PhotoZoom(large.fitScale), baseLongEdge))
        assertNull(large.detailRequest(PhotoZoom(baseScale * 1.04f), baseLongEdge))
        assertNull(large.detailRequest(PhotoZoom(1f), baseLongEdge = 6000))

        val req = large.detailRequest(PhotoZoom(1f), baseLongEdge)!!
        assertEquals(0.4f, req.visibleRect.x0, 0.001f)
        assertEquals(0.6f, req.visibleRect.x1, 0.001f)
        assertEquals(0.38f, req.overscanRect.x0, 0.001f)
        assertEquals(0.62f, req.overscanRect.x1, 0.001f)
        assertEquals(0.23f, req.overscanRect.y0, 0.001f)
        assertEquals(0.77f, req.overscanRect.y1, 0.001f)

        // Active detail request hysteresis keeps request alive down to 0.85 * baseScale.
        val hysteresisScale = baseScale * 0.92f
        assertNull(large.detailRequest(PhotoZoom(hysteresisScale), baseLongEdge, active = false))
        assertNotNull(large.detailRequest(PhotoZoom(hysteresisScale), baseLongEdge, active = true))
    }

    @Test fun detailTileDstRectUsesUnclippedFullImageGeometryAndPreservesAspectRatio() {
        val portrait = PhotoViewport(6000f, 4000f, 1080f, 2000f)

        // Partial zoom: horizontally overflows viewport while vertically letterboxed.
        val partialZoom = PhotoZoom(0.35f)
        val partialFull = photoFullImageRect(portrait, partialZoom)
        assertEquals(PhotoImageRect(-510f, 300f, 1590f, 1700f), partialFull)
        assertEquals(2100f, partialFull.width, 0.001f)
        assertEquals(1400f, partialFull.height, 0.001f)
        val partialClipped = photoImageRect(portrait, partialZoom)
        assertEquals(PhotoImageRect(0f, 300f, 1080f, 1700f), partialClipped)

        val tile00 = NormalizedRect(0f, 0f, 2048f / 6000f, 2048f / 4000f)
        val tile10 = NormalizedRect(2048f / 6000f, 0f, 4096f / 6000f, 2048f / 4000f)
        val dst00 = detailTileDstRect(partialFull, tile00, portrait.width, portrait.height)!!
        val dst10 = detailTileDstRect(partialFull, tile10, portrait.width, portrait.height)!!
        assertEquals(-510, dst00.left)
        assertEquals(300, dst00.top)
        assertEquals(717, dst00.width)
        assertEquals(717, dst00.height)
        assertEquals(dst00.right, dst10.left)
        assertEquals(717, dst10.width)
        assertEquals(717, dst10.height)

        // 100% zoom with pan: both axes overflow viewport.
        val pannedZoom = PhotoZoom(1.0f, 120f, -80f)
        val pannedFull = photoFullImageRect(portrait, pannedZoom)
        assertEquals(6000f, pannedFull.width, 0.001f)
        assertEquals(4000f, pannedFull.height, 0.001f)
        val centerTile = NormalizedRect(2048f / 6000f, 1024f / 4000f, 3072f / 6000f, 2048f / 4000f)
        val centerDst = detailTileDstRect(pannedFull, centerTile, portrait.width, portrait.height)!!
        assertEquals(-292, centerDst.left)
        assertEquals(-56, centerDst.top)
        assertEquals(1024, centerDst.width)
        assertEquals(1024, centerDst.height)

        // Off-screen tile returns null.
        val offscreenTile = NormalizedRect(0f, 0f, 1024f / 6000f, 1024f / 4000f)
        assertNull(detailTileDstRect(pannedFull, offscreenTile, portrait.width, portrait.height))
    }
}
