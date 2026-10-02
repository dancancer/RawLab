package com.rawlab.android

import org.junit.Assert.*
import org.junit.Test

class PhotoZoomTest {
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

    @Test fun resizeKeepsFitOrNativeScaleAndReclampsPan() {
        val landscape = PhotoViewport(2400f, 1600f, 1800f, 600f)
        assertEquals(PhotoZoom(.375f), PhotoZoom(.5f).resize(viewport, landscape))
        assertEquals(PhotoZoom(1f, 300f, 0f), PhotoZoom(1f, 600f, 0f).resize(viewport, landscape))
    }
}
