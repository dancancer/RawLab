package com.rawlab.android.ui

import org.junit.Assert.*
import org.junit.Test
import com.rawlab.android.editor.canvas.DetailTileKey
import com.rawlab.android.editor.canvas.NormalizedRect
import com.rawlab.android.editor.canvas.PhotoViewport
import com.rawlab.android.editor.canvas.PhotoZoom
import com.rawlab.android.editor.canvas.detailOverlayCovers
import com.rawlab.android.editor.canvas.detailTileLevel
import com.rawlab.android.editor.canvas.detailTileSpecs
import kotlin.math.hypot

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

    @Test fun detailRequestThresholdOverscanAndCoverageWorkTogether() {
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

        // Small pan within overscan is covered when tile density matches 1:1.
        assertTrue(
            detailOverlayCovers(
                normalizedRect = req.overscanRect,
                pixelWidth = 1440,
                pixelHeight = 2160,
                fullNativeWidth = 6000,
                fullNativeHeight = 4000,
                visibleRect = NormalizedRect(0.385f, 0.235f, 0.585f, 0.685f),
                requiredZoomScale = 1f,
            ),
        )
        // Panning outside overscan requires a new ROI render.
        assertFalse(
            detailOverlayCovers(
                normalizedRect = req.overscanRect,
                pixelWidth = 1440,
                pixelHeight = 2160,
                fullNativeWidth = 6000,
                fullNativeHeight = 4000,
                visibleRect = NormalizedRect(0.35f, 0.235f, 0.55f, 0.685f),
                requiredZoomScale = 1f,
            ),
        )
        // Zooming deeper past tile density invalidates coverage.
        assertFalse(
            detailOverlayCovers(
                normalizedRect = req.overscanRect,
                pixelWidth = 720,
                pixelHeight = 1080,
                fullNativeWidth = 6000,
                fullNativeHeight = 4000,
                visibleRect = req.visibleRect,
                requiredZoomScale = 1f,
            ),
        )
        // Capped maxOutputLongEdge keeps wide HDR tiles valid without endless re-render loops.
        assertTrue(
            detailOverlayCovers(
                normalizedRect = NormalizedRect(0.2f, 0.2f, 0.6f, 0.6f),
                pixelWidth = 1280,
                pixelHeight = 853,
                fullNativeWidth = 6000,
                fullNativeHeight = 4000,
                visibleRect = NormalizedRect(0.25f, 0.25f, 0.55f, 0.55f),
                requiredZoomScale = 1f,
                maxOutputLongEdge = 1280,
            ),
        )
    }

    @Test fun detailTilePyramidSelectsLevelsClampsEdgeTilesAndOrdersCenterFirst() {
        val baseScale = 1600f / 6000f
        assertNull(detailTileLevel(baseScale * 1.04f, baseScale))
        assertEquals(1, detailTileLevel(0.45f, baseScale))
        assertEquals(0, detailTileLevel(1.0f, baseScale))

        val center = NormalizedRect(0.40f, 0.35f, 0.60f, 0.65f)
        val specs = detailTileSpecs(center, 6000, 4000, 1.0f, baseScale)
        assertTrue(specs.isNotEmpty())
        assertTrue(specs.all { it.key.level == 0 && it.maxOutputLongEdge == 1024 })
        val firstDist = hypot(((specs[0].rect.x0 + specs[0].rect.x1) * 0.5f - 0.5f).toDouble(),
                              ((specs[0].rect.y0 + specs[0].rect.y1) * 0.5f - 0.5f).toDouble())
        val lastDist = hypot(((specs.last().rect.x0 + specs.last().rect.x1) * 0.5f - 0.5f).toDouble(),
                             ((specs.last().rect.y0 + specs.last().rect.y1) * 0.5f - 0.5f).toDouble())
        assertTrue(firstDist <= lastDist + 1e-5)

        val edgeSpecs = detailTileSpecs(NormalizedRect(0.90f, 0.85f, 1.0f, 1.0f), 6000, 4000, 1.0f, baseScale)
        assertEquals(1, edgeSpecs.size)
        assertEquals(DetailTileKey(0, 5, 3), edgeSpecs[0].key)
        assertEquals(928, edgeSpecs[0].maxOutputLongEdge)

        // Overscan ring appends unique neighbor tiles strictly after visible tiles.
        val visibleOnly = detailTileSpecs(center, 6000, 4000, 1.0f, baseScale, overscanRing = 0)
        val withRing = detailTileSpecs(center, 6000, 4000, 1.0f, baseScale, overscanRing = 1)
        assertTrue(withRing.size > visibleOnly.size)
        assertEquals(visibleOnly, withRing.take(visibleOnly.size))
        assertEquals(withRing.size, withRing.map { it.key }.distinct().size)

        // 48MP backing jumps directly to level 0 without intermediate level 1 tiles.
        assertEquals(0, detailTileLevel(0.5f, 3072f / 8064f))

        // Active detail request hysteresis keeps request alive down to 0.85 * baseScale.
        val large = PhotoViewport(6000f, 4000f, 1200f, 1800f)
        val hysteresisScale = (1600f / 6000f) * 0.92f
        assertNull(large.detailRequest(PhotoZoom(hysteresisScale), 1600, active = false))
        assertNotNull(large.detailRequest(PhotoZoom(hysteresisScale), 1600, active = true))
    }
}
