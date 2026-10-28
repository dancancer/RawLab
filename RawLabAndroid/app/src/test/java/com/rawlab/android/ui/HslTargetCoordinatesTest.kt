package com.rawlab.android.ui

import com.rawlab.android.editor.canvas.*
import org.junit.Assert.*
import org.junit.Test

class HslTargetCoordinatesTest {
    @Test fun fullProjectedImageOwnsCoordinatesEvenWhenMostOfItIsClipped() {
        val viewport = PhotoViewport(2000f, 1000f, 400f, 300f)
        val fit = PhotoZoom(.2f)
        assertEquals(.5f, hslTargetCoordinates(viewport, fit, 200f, 150f)!!.first, .000001f)
        assertNull(hslTargetCoordinates(viewport, fit, 200f, 20f))
        val zoom = PhotoZoom(.4f, -60f, 30f)
        val point = hslTargetCoordinates(viewport, zoom, 200f, 150f)!!
        assertEquals(.575f, point.first, .000001f); assertEquals(.425f, point.second, .000001f)
        assertNull(hslTargetCoordinates(viewport, zoom, 401f, 150f))
        assertNull(hslTargetCoordinates(viewport, zoom, Float.NaN, 100f))
    }
    @Test fun wipeUsesItsDisplayedVisibleSplitAndRejectsReferenceAndHandle() {
        val viewport = PhotoViewport(2000f, 1000f, 400f, 300f)
        val zoom = PhotoZoom(.4f, -60f, 30f)
        assertNull(hslTargetCoordinates(viewport, zoom, 180f, 100f, .5f, 24f))
        assertNull(hslTargetCoordinates(viewport, zoom, 220f, 100f, .5f, 24f))
        val point = hslTargetCoordinates(viewport, zoom, 250f, 100f, .5f, 24f)!!
        assertEquals(.6375f, point.first, .000001f); assertEquals(.3f, point.second, .000001f)
    }
}
