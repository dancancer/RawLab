package com.rawlab.android.settings

import org.junit.Assert.*
import org.junit.Test

class HslTargetAdjustmentTest {
    private val revision = HslTargetRevision(4, 9)
    private fun sample() = HslTargetSample(revision, HslTargetAvailability.AVAILABLE,
        listOf(1f, .25f, 0f), listOf(.5f, .5f, 0f, 0f, 0f, 0f, 0f, 0f), true)
    @Test fun weightedAxesStayFrozenAndRetainUnselectedValues() {
        val before = HslSettings().withValue(0, 0, 95.25f).withValue(0, 1, -12.5f).withValue(1, 4, 23.75f)
        for (axis in 0..2) {
            val drag = HslTargetDrag(before, axis, sample())
            val next = drag.value(20f)
            assertEquals(minOf(100f, before.value(axis, 0)+10), next.value(axis, 0), 0f)
            assertEquals(before.value(axis, 1)+10, next.value(axis, 1), 0f)
            assertEquals(next, drag.value(20f)); assertEquals(before, drag.value(0f))
            assertEquals(before.value(axis, 1)-10, drag.value(-20f).value(axis, 1), 0f)
            for (other in 0..2) for (channel in 0..7) if (other != axis || channel > 1)
                assertEquals(before.value(other, channel), next.value(other, channel), 0f)
            assertEquals(before, drag.value(Float.NaN))
        }
    }
    @Test fun pendingReleaseCancelAndStaleAnswersAreBoundToOriginalFrame() {
        val state = HslTargetInteraction(); val before = HslSettings(); val sample = sample()
        val old = state.begin(before, 0, revision)
        assertNull(state.move(20f))
        assertNull(state.accept(sample, old, HslTargetRevision(5, 9)))
        assertNull(state.accept(sample, old, revision))
        val token = state.begin(before, 1, revision); state.move(20f)
        assertEquals(10f, state.accept(sample, token, revision)!!.value(1, 0), 0f)
        assertTrue(state.dragging); assertEquals(before, state.cancel()); assertNull(state.selection)
        val released = state.begin(before, 2, revision); state.move(12f); state.end(); state.accumulateReleased(2f)
        assertEquals(7f, state.accept(sample, released, revision)!!.value(2, 1), 0f)
        assertFalse(state.dragging); assertSame(sample, state.selection)
        val cancelled = state.begin(before, 0, revision); state.cancel()
        assertNull(state.accept(sample, cancelled, revision))
    }
    @Test fun grayAndInvalidWeightsCannotSelectAColorRange() {
        val gray = HslTargetSample(revision, HslTargetAvailability.NEAR_GRAY, listOf(.5f,.5f,.5f), List(8){0f}, true)
        assertFalse(gray.usable); assertEquals(emptyList<Int>(), gray.channels)
        val weights = mutableListOf(.5f,.5f,0f,0f,0f,0f,0f,0f)
        val frozen = HslTargetSample(revision, HslTargetAvailability.AVAILABLE, listOf(1f,.25f,0f), weights, true)
        weights[0] = 0f
        assertTrue(frozen.usable); assertEquals(listOf(0,1), frozen.channels)
        assertFalse(HslTargetSample(revision, HslTargetAvailability.AVAILABLE, listOf(1f,0f,0f), listOf(1f,1f), true).usable)
    }
}
