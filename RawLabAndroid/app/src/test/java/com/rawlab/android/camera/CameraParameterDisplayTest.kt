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
    }
}
