package com.rawlab.android.editor.render

import org.junit.Assert.*
import org.junit.Test
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class RenderQueueProgressTest {
    @Test fun continuousRequestsCompleteTheRunningFrameAndOnlyRenderTheLatestPendingValue() {
        val started = CountDownLatch(1)
        val finishFirst = CountDownLatch(1)
        val latestStarted = CountDownLatch(1)
        val finishLatest = CountDownLatch(1)
        val published = CountDownLatch(2)
        val frames = Collections.synchronizedList(mutableListOf<Int>())
        val rendered = Collections.synchronizedList(mutableListOf<Int>())
        val dropped = Collections.synchronizedList(mutableListOf<Int>())
        val queue = RenderQueue<Int, Int>({ value, token ->
            rendered += value
            if (value == 1) { started.countDown(); assertTrue(finishFirst.await(5, TimeUnit.SECONDS)) }
            else { latestStarted.countDown(); assertTrue(finishLatest.await(5, TimeUnit.SECONDS)) }
            token.check()
            value
        }, { _, result -> frames += result.getOrThrow(); published.countDown() }, {},
            discardPending = { dropped += it }, canFinishInFlight = { _, _ -> true })
        try {
            queue.submit(1)
            assertTrue(started.await(5, TimeUnit.SECONDS))
            for (value in 2..180) queue.submit(value)
            finishFirst.countDown()
            assertTrue(latestStarted.await(5, TimeUnit.SECONDS))
            assertEquals("A slow frame must be visible before the pending frame finishes", listOf(1), frames)
            assertEquals(listOf(1, 180), rendered)
            assertEquals((2..179).toList(), dropped)
            finishLatest.countDown()
            assertTrue(published.await(5, TimeUnit.SECONDS))
            assertEquals(listOf(1, 180), frames)
        } finally { finishFirst.countDown(); finishLatest.countDown(); queue.close() }
    }

    @Test fun incompatibleReplacementStillCancelsAProgressiveFrame() {
        val started = CountDownLatch(1)
        val cancelled = CountDownLatch(1)
        val published = CountDownLatch(1)
        val frames = Collections.synchronizedList(mutableListOf<Int>())
        val queue = RenderQueue<Int, Int>({ value, token ->
            if (value == 1) {
                token.onCancel { cancelled.countDown() }; started.countDown()
                assertTrue(cancelled.await(5, TimeUnit.SECONDS)); token.check()
            }
            value
        }, { _, result -> frames += result.getOrThrow(); published.countDown() }, {},
            canFinishInFlight = { previous, next -> previous > 0 && next > 0 })
        try {
            queue.submit(1); assertTrue(started.await(5, TimeUnit.SECONDS))
            queue.submit(2); queue.submit(-1)
            assertTrue(published.await(5, TimeUnit.SECONDS))
            assertEquals(listOf(-1), frames)
        } finally { queue.close() }
    }

    @Test fun invalidationCannotBeUndoneByAnotherCompatibleRequest() {
        val started = CountDownLatch(1)
        val resume = CountDownLatch(1)
        val published = CountDownLatch(1)
        val frames = Collections.synchronizedList(mutableListOf<Int>())
        val queue = RenderQueue<Int, Int>({ value, token ->
            if (value == 1) { started.countDown(); assertTrue(resume.await(5, TimeUnit.SECONDS)); token.check() }
            value
        }, { _, result -> frames += result.getOrThrow(); published.countDown() }, {},
            canFinishInFlight = { _, _ -> true })
        try {
            queue.submit(1); assertTrue(started.await(5, TimeUnit.SECONDS))
            queue.submit(2); queue.invalidate(); queue.submit(3); resume.countDown()
            assertTrue(published.await(5, TimeUnit.SECONDS))
            assertEquals(listOf(3), frames)
        } finally { resume.countDown(); queue.close() }
    }

    @Test fun invalidatedPixelsAreDiscardedEvenWhenTheRendererFinishesNormally() {
        val started = CountDownLatch(1)
        val resume = CountDownLatch(1)
        val finished = CountDownLatch(1)
        val frames = Collections.synchronizedList(mutableListOf<Int>())
        val discarded = Collections.synchronizedList(mutableListOf<Int>())
        val queue = RenderQueue<Int, Int>({ value, _ ->
            if (value == 1) { started.countDown(); assertTrue(resume.await(5, TimeUnit.SECONDS)) }
            value
        }, { _, result ->
            val value = result.getOrThrow()
            frames += value
            if (value == 3) finished.countDown()
        }, {}, discard = { discarded += it }, canFinishInFlight = { _, _ -> true })
        try {
            queue.submit(1); assertTrue(started.await(5, TimeUnit.SECONDS))
            queue.submit(2); queue.invalidate(); queue.submit(3); resume.countDown()
            assertTrue(finished.await(5, TimeUnit.SECONDS))
            assertEquals(listOf(3), frames)
            assertEquals(listOf(1), discarded)
        } finally { resume.countDown(); queue.close() }
    }
}
