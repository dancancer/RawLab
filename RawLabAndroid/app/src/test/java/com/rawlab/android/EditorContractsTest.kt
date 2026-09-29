package com.rawlab.android

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.Collections

class EditorContractsTest {
    @Test fun filmStrengthSupportsTwoHundredPercentWithNeutralDefault() {
        assertEquals(1f, EditSettings().strength)
        assertEquals(2f, EditSettings(strength = 2f).strength)
        assertEquals(1f, EditSettings(strength = 2f).reset().strength)
        for (bad in listOf(-.01f, 2.01f, Float.NaN, Float.POSITIVE_INFINITY)) {
            assertThrows(IllegalArgumentException::class.java) { EditSettings(strength = bad) }
        }
    }

    @Test fun resetRetainsFilmButRestoresCameraGains() {
        val edits = EditSettings(film = "velvia", exposure = 2f, customWb = true, temperature = 4200f, tint = 20f)
        assertEquals("velvia", edits.reset().film)
        assertFalse(edits.reset().customWb)
        assertEquals(0f, edits.reset().exposure)
        assertEquals(1f, edits.reset().strength)
    }

    @Test fun rejectsNonFiniteAndOutOfRangeEdits() {
        for (bad in listOf(Float.NaN, Float.POSITIVE_INFINITY, 6f, -6f)) {
            assertThrows(IllegalArgumentException::class.java) { EditSettings(exposure = bad) }
        }
        assertThrows(IllegalArgumentException::class.java) { EditSettings(temperature = 1000f) }
        assertThrows(IllegalArgumentException::class.java) { EditSettings(strength = -1f) }
    }

    @Test fun requestsOnlyPhotoPermissionsForEachPlatform() {
        assertEquals(listOf("android.permission.READ_EXTERNAL_STORAGE"), AlbumAccess.permissions(32))
        assertEquals(listOf("android.permission.READ_MEDIA_IMAGES"), AlbumAccess.permissions(33))
        assertEquals(listOf("android.permission.READ_MEDIA_IMAGES", "android.permission.READ_MEDIA_VISUAL_USER_SELECTED"), AlbumAccess.permissions(34))
        assertEquals(AlbumAccess.Level.PARTIAL, AlbumAccess.level(34, setOf("android.permission.READ_MEDIA_VISUAL_USER_SELECTED")))
        assertEquals(AlbumAccess.Level.NONE, AlbumAccess.level(33, emptySet()))
        assertEquals(AlbumAccess.Level.FULL, AlbumAccess.level(34, setOf("android.permission.READ_MEDIA_IMAGES")))
    }

    @Test fun onlyRawFilesAreOffered() {
        assertTrue(RawFiles.accepts("PHOTO.DNG", "application/octet-stream"))
        assertTrue(RawFiles.accepts("renamed", "image/x-sony-arw"))
        assertFalse(RawFiles.accepts("photo.jpg", "image/jpeg"))
        assertFalse(RawFiles.accepts("photo.dng.exe", "application/octet-stream"))
    }

    @Test fun replacesPendingRendersAndNeverPublishesStaleResult() {
        val started = CountDownLatch(1)
        val unblock = CountDownLatch(1)
        val completed = CountDownLatch(1)
        val released = CountDownLatch(1)
        val ran = Collections.synchronizedList(mutableListOf<Int>())
        val published = Collections.synchronizedList(mutableListOf<Int>())
        val queue = RenderQueue<Int, Int>({ value ->
            ran.add(value)
            if (value == 1) { started.countDown(); check(unblock.await(5, TimeUnit.SECONDS)) }
            value
        }, { _, result -> published.add(result.getOrThrow()); completed.countDown() }, { released.countDown() })
        queue.submit(1)
        assertTrue(started.await(5, TimeUnit.SECONDS))
        queue.submit(2)
        queue.submit(3)
        unblock.countDown()
        assertTrue(completed.await(5, TimeUnit.SECONDS))
        queue.close()
        assertTrue(released.await(5, TimeUnit.SECONDS))
        assertEquals(listOf(1, 3), ran)
        assertEquals(listOf(3), published)
    }

    @Test fun closeWaitsForNativeWorkAndDiscardsPendingTask() {
        val started = CountDownLatch(1)
        val unblock = CountDownLatch(1)
        val released = CountDownLatch(1)
        val ran = Collections.synchronizedList(mutableListOf<Int>())
        val queue = RenderQueue<Int, Int>({ n ->
            ran.add(n); started.countDown(); check(unblock.await(5, TimeUnit.SECONDS)); n
        }, { _, _ -> fail("Closed work must not publish") }, { released.countDown() })
        queue.submit(1)
        assertTrue(started.await(5, TimeUnit.SECONDS))
        queue.submit(2)
        queue.close()
        assertFalse(released.await(50, TimeUnit.MILLISECONDS))
        unblock.countDown()
        assertTrue(released.await(5, TimeUnit.SECONDS))
        assertEquals(listOf(1), ran)
        assertThrows(IllegalStateException::class.java) { queue.submit(3) }
    }
}
