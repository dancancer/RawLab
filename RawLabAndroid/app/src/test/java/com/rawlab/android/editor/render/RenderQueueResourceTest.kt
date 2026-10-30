package com.rawlab.android.editor.render

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class RenderQueueResourceTest {
    @Test fun replacedAndClosedPendingInputsAreReleasedWithoutRendering() {
        val started = CountDownLatch(1); val resume = CountDownLatch(1); val released = CountDownLatch(1)
        val discarded = java.util.Collections.synchronizedList(mutableListOf<Int>())
        val rendered = java.util.Collections.synchronizedList(mutableListOf<Int>())
        val queue = RenderQueue<Int, Int>({ value ->
            rendered += value; started.countDown(); resume.await(); value
        }, { _, _ -> fail("Closed queue must not publish") }, { released.countDown() },
            discardPending = { discarded += it })
        queue.submit(1); assertTrue(started.await(5, TimeUnit.SECONDS))
        queue.submit(2); queue.submit(3); queue.close(); resume.countDown()
        assertTrue(released.await(5, TimeUnit.SECONDS))
        assertEquals(listOf(2, 3), discarded)
        assertEquals(listOf(1), rendered)
    }

    @Test fun newerRequestCancelsRunningWorkBeforeItCompletes() {
        val started = CountDownLatch(1); val cancelled = CountDownLatch(1)
        val finished = CountDownLatch(1)
        val published = java.util.Collections.synchronizedList(mutableListOf<Int>())
        val queue = RenderQueue<Int, Int>({ value, token ->
            if (value == 1) {
                token.onCancel { cancelled.countDown() }
                started.countDown()
                assertTrue("A newer request must interrupt the running computation", cancelled.await(2, TimeUnit.SECONDS))
                token.check()
                fail("Cancelled work must not finish its computation")
            }
            value
        }, { _, result -> published += result.getOrThrow(); finished.countDown() }, {})
        try {
            queue.submit(1); assertTrue(started.await(5, TimeUnit.SECONDS))
            queue.submit(2)
            assertTrue(finished.await(5, TimeUnit.SECONDS))
            assertEquals(listOf(2), published)
            assertEquals(0L, cancelled.count)
        } finally { queue.close() }
    }

    @Test fun cancellationBeforeNativeListenerRegistrationIsNotLost() {
        val token = RenderCancellation()
        token.cancel()
        var notified = false
        token.onCancel { notified = true }
        assertTrue(notified)
        assertThrows(java.util.concurrent.CancellationException::class.java) { token.check() }
    }

    @Test fun closingCancelsRunningWorkBeforeReleasingResources() {
        val started = CountDownLatch(1); val cancelled = CountDownLatch(1); val closed = CountDownLatch(1)
        val queue = RenderQueue<Int, Int>({ value, token ->
            token.onCancel { cancelled.countDown() }; started.countDown()
            assertTrue(cancelled.await(2, TimeUnit.SECONDS)); token.check(); value
        }, { _, _ -> fail("Closed queue must not publish") }, { closed.countDown() })
        queue.submit(1); assertTrue(started.await(5, TimeUnit.SECONDS)); queue.close()
        assertTrue(closed.await(5, TimeUnit.SECONDS)); assertEquals(0L, cancelled.count)
    }
    @Test fun lifecycleWorkDrainsBeforeResourceCloseAndCannotBeCoalesced() {
        val started = CountDownLatch(1); val resume = CountDownLatch(1); val closed = CountDownLatch(1)
        val order = java.util.Collections.synchronizedList(mutableListOf<Int>())
        val queue = RenderQueue<Int, Int>({ started.countDown(); resume.await(); order += 1; it }, { _, _ -> },
            { order += 3; closed.countDown() })
        queue.submit(1); assertTrue(started.await(5, TimeUnit.SECONDS))
        queue.performAfterPending { order += 2 }
        queue.close(); resume.countDown()
        assertTrue(closed.await(5, TimeUnit.SECONDS)); assertEquals(listOf(1, 2, 3), order)
    }
    @Test fun supersededResultIsDisposedAndOnlyLatestResultIsPublished() {
        val started = CountDownLatch(1); val resume = CountDownLatch(1)
        val discarded = CountDownLatch(1); val published = CountDownLatch(1); val closed = CountDownLatch(1)
        val queue = RenderQueue<Int, Int>({ value -> if (value == 1) { started.countDown(); resume.await() }; value },
            { _, result -> assertEquals(2, result.getOrThrow()); published.countDown() },
            { closed.countDown() }, { value -> assertEquals(1, value); discarded.countDown() })
        queue.submit(1); assertTrue(started.await(5, TimeUnit.SECONDS)); queue.submit(2); resume.countDown()
        assertTrue(discarded.await(5, TimeUnit.SECONDS)); assertTrue(published.await(5, TimeUnit.SECONDS))
        queue.close(); assertTrue(closed.await(5, TimeUnit.SECONDS))
    }
    @Test fun closingDuringWorkDisposesCompletedResultBeforeReleasingResources() {
        val started = CountDownLatch(1); val resume = CountDownLatch(1); val closed = CountDownLatch(1)
        var discarded = false
        val queue = RenderQueue<Int, Int>({ started.countDown(); resume.await(); it },
            { _, _ -> fail("Closed queue must not publish") },
            { assertTrue(discarded); closed.countDown() }, { discarded = true })
        queue.submit(1); assertTrue(started.await(5, TimeUnit.SECONDS)); queue.close(); resume.countDown()
        assertTrue(closed.await(5, TimeUnit.SECONDS))
    }
}
