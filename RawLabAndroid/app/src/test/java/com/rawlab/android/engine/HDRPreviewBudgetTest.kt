package com.rawlab.android.engine

import org.junit.Assert.*
import org.junit.Test

class HDRPreviewBudgetTest {
    @Test fun smallJavaHeapLeavesRoomForModeSwitchAndTwoPublishedFrames() {
        val edge=HDRPreviewBudget.edge(4080,3072,1600,192L*1024*1024)
        assertTrue(edge in 512..1024)
        assertEquals(64,HDRPreviewBudget.edge(4080,3072,64,192L*1024*1024))
        assertTrue(HDRPreviewBudget.edge(4080,3072,1600,1024L*1024*1024)>=edge)
    }
    @Test fun tinyInputAndPortraitPreserveTheSameBudget() {
        assertEquals(32,HDRPreviewBudget.edge(32,16,1600,192L*1024*1024))
        assertEquals(HDRPreviewBudget.edge(4080,3072,1600,192L*1024*1024),
            HDRPreviewBudget.edge(3072,4080,1600,192L*1024*1024))
    }
}
