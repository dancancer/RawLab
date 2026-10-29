package com.rawlab.android.editor.render

import org.junit.Assert.assertEquals
import org.junit.Test

class InteractivePreviewSizeTest {
    @Test fun rapidInputUsesAQuickProxyAndReleaseRestoresTheRequestedViewport() {
        val sizing = InteractivePreviewSize()
        assertEquals(1000, sizing.edge(1600, true, 100))
        assertEquals(480, sizing.edge(1600, true, 116))
        assertEquals(480, sizing.edge(1600, true, 132))
        assertEquals(1000, sizing.edge(1600, true, 232))
        assertEquals(1600, sizing.edge(1600, false, 248))
        assertEquals(1000, sizing.edge(1600, true, 260))
    }

    @Test fun smallViewportsAreNeverUpscaledForInteraction() {
        val sizing = InteractivePreviewSize()
        assertEquals(320, sizing.edge(320, true, 100))
        assertEquals(320, sizing.edge(320, true, 116))
        assertEquals(320, sizing.edge(320, false, 132))
    }
}
