package com.rawlab.android.camera

import org.junit.Assert.*
import org.junit.Test

class CameraParameterDisplayTest {
    @Test fun shootingLabelsUseTheActualPtpProperties() {
        assertEquals(0xd20d, CameraShootingParameter.SHUTTER.code)
        assertEquals(0xd21e, CameraShootingParameter.ISO.code)
        assertEquals(0x5005, CameraShootingParameter.WHITE_BALANCE.code)
        assertEquals(0x500a, CameraShootingParameter.FOCUS.code)
        assertEquals("1/125 s", formatCameraParameter(0xd20d, 0x0001007d))
        assertEquals("30 s", formatCameraParameter(0xd20d, (300L shl 16) or 10))
        assertEquals("f/5.6", formatCameraParameter(0x5007, 560))
        assertEquals("-0.3 EV", formatCameraParameter(0x5010, -333))
        assertEquals("800", formatCameraParameter(0xd21e, 800))
        assertEquals("50", formatCameraParameter(0xd21e, 0x10000032))
        assertEquals("Auto · MFNR+", formatCameraParameter(0xd21e, 0x02ffffff))
        assertEquals("0x8002", formatCameraParameter(0x500a, 0x8002))
        assertEquals(0xd22c, CameraShootingParameter.FOCUS_AREA.code)
        assertEquals("Wide", formatCameraParameter(0xd22c, 0x0001))
        assertEquals("Spot M", formatCameraParameter(0xd22c, 0x0102))
        assertEquals("Tracking: Zone", formatCameraParameter(0xd22c, 0x0202))
        assertEquals("0x0105", formatCameraParameter(0xd22c, 0x0105))
    }

    @Test fun viewfinderTapMapsAspectFitGridAndRejectsBarsOrInvalidSizes() {
        val quarter = mapViewfinderTapToCameraGrid(300f, 150f, 1200f, 600f, 6000, 4000)
        // 6000x4000 inside 1200x600 is height-limited: rendered rect is 900x600 centered at x=[150, 1050], y=[0, 600].
        // Tap (300, 150) -> u = (300-150)/900 = 1/6? Wait: let's test an exact 16:9 letterbox/pillarbox or 3:2!
        assertNotNull(quarter)
        assertEquals(107, quarter!!.x)
        assertEquals(120, quarter.y)

        // Exact 4:3 image inside 1200x600 container -> rendered rect is 800x600 at x=[200, 1000], y=[0, 600].
        val pillarQuarter = mapViewfinderTapToCameraGrid(400f, 150f, 1200f, 600f, 4000, 3000)
        assertEquals(160, pillarQuarter?.x)
        assertEquals(120, pillarQuarter?.y)
        assertNull(mapViewfinderTapToCameraGrid(100f, 300f, 1200f, 600f, 4000, 3000))
        assertNull(mapViewfinderTapToCameraGrid(1100f, 300f, 1200f, 600f, 4000, 3000))

        // Letterboxed 3:2 image inside 600x900 container -> rendered rect is 600x400 at x=[0, 600], y=[250, 650].
        assertNull(mapViewfinderTapToCameraGrid(300f, 100f, 600f, 900f, 600, 400))
        val topLeft = mapViewfinderTapToCameraGrid(0f, 250f, 600f, 900f, 600, 400)
        assertEquals(0, topLeft?.x)
        assertEquals(0, topLeft?.y)
        val bottomRight = mapViewfinderTapToCameraGrid(600f, 650f, 600f, 900f, 600, 400)
        assertEquals(639, bottomRight?.x)
        assertEquals(479, bottomRight?.y)

        assertNull(mapViewfinderTapToCameraGrid(10f, 10f, 0f, 100f, 640, 480))
        assertNull(mapViewfinderTapToCameraGrid(10f, 10f, 100f, 100f, 0, 480))
        assertNull(mapViewfinderTapToCameraGrid(Float.NaN, 10f, 100f, 100f, 640, 480))
    }
}
