package com.rawlab.android

import org.junit.Assert.*
import org.junit.Test

class AlbumLayoutTest {
    @Test fun mediaDimensionsRespectDisplayRotation() {
        assertEquals(1.5f, albumAspectRatio(6000, 4000, 0)!!, .0001f)
        assertEquals(2f / 3f, albumAspectRatio(6000, 4000, 90)!!, .0001f)
        assertEquals(1.5f, albumAspectRatio(6000, 4000, 180)!!, .0001f)
        assertEquals(2f / 3f, albumAspectRatio(6000, 4000, 270)!!, .0001f)
        assertEquals(.5f, albumAspectRatio(3000, 6000, 0)!!, .0001f)
    }

    @Test fun missingDimensionsLeaveRatioForThumbnailFallback() {
        assertNull(albumAspectRatio(0, 4000, 90))
        assertNull(albumAspectRatio(6000, 0, 0))
        assertNull(albumAspectRatio(-1, 4000, 0))
    }
}
