package com.rawlab.android.editor

import org.junit.Assert.*
import org.junit.Test

class SystemPhotoRequestQueueTest {
    @Test fun independentRequestsWithTheSameUriSurviveSeparateConsumptionAndRecreation() {
        val queue = SystemPhotoRequestQueue()
        assertTrue(queue.enqueue("first", listOf("content://photos/same")))
        assertTrue(queue.enqueue("second", listOf("content://photos/same")))
        assertFalse(queue.enqueue("first", listOf("content://photos/other")))

        assertTrue(queue.replace("first", listOf("file:///private/first.jpg")))
        assertTrue(queue.consume("first"))
        val restored = SystemPhotoRequestQueue(queue.pending(), queue.processed())

        assertEquals(listOf("content://photos/same"), restored.uris("second"))
        assertFalse(restored.enqueue("first", listOf("content://photos/same")))
        assertTrue(restored.consume("second"))
        assertTrue(restored.isProcessed("second"))
    }
}
