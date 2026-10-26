package com.rawlab.android.editor.render

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class SerialWorkQueueTest {
    @Test fun writesAreFifoOffCallerThreadAndCloseDrainsAcceptedWork() {
        val caller = Thread.currentThread()
        val done = CountDownLatch(1)
        val started = CountDownLatch(1)
        val unblock = CountDownLatch(1)
        val order = java.util.Collections.synchronizedList(mutableListOf<Int>())
        val queue = SerialWorkQueue { order += 4; done.countDown() }
        queue.submit({ assertNotEquals(caller, Thread.currentThread()); started.countDown(); unblock.await(); order += 1 }, { it.getOrThrow() })
        assertTrue(started.await(5, TimeUnit.SECONDS))
        queue.submit({ order += 2 }, { it.getOrThrow() })
        queue.submit({ order += 3 }, { it.getOrThrow() })
        queue.close(); unblock.countDown()
        assertTrue(done.await(5, TimeUnit.SECONDS))
        assertEquals(listOf(1, 2, 3, 4), order)
    }
}
