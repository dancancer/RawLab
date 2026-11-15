package com.rawlab.android.photo

import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.*
import com.rawlab.android.geometry.GeometrySettings
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class EditedPhotoPreviewTest {
    @Test fun savedDefaultsAndResetHaveNoMarker() {
        assertFalse(EditedPhotoPreviewKey.isEdited(null, PhotoInputKind.RAW))
        assertFalse(EditedPhotoPreviewKey.isEdited(EditSettings(), PhotoInputKind.RAW))
        assertFalse(EditedPhotoPreviewKey.isEdited(EditSettings(exposureMode = 2), PhotoInputKind.RASTER))
        assertTrue(EditedPhotoPreviewKey.isEdited(EditSettings(exposure = .5f), PhotoInputKind.RAW))
        assertTrue(EditedPhotoPreviewKey.isEdited(EditSettings(geometry = GeometrySettings(quarterTurns = 1)), PhotoInputKind.RAW))
        assertTrue(PhotoEditFilter.EDITED.includes(true))
        assertFalse(PhotoEditFilter.UNEDITED.includes(null))
        assertTrue(PhotoEditFilter.ALL.includes(null))
    }
    @Test fun cacheUsesSourceSettingsResourcesAndSize() {
        val settings = EditSettings(exposure = .5f)
        val key = EditedPhotoPreviewKey.create("source-a", settings, "look-a")
        assertEquals(key, EditedPhotoPreviewKey.create("source-a", settings.copy(), "look-a"))
        assertNotEquals(key, EditedPhotoPreviewKey.create("source-b", settings, "look-a"))
        assertNotEquals(key, EditedPhotoPreviewKey.create("source-a", settings.copy(exposure = 1f), "look-a"))
        assertNotEquals(key, EditedPhotoPreviewKey.create("source-a", settings, "look-b"))
        assertNotEquals(key, EditedPhotoPreviewKey.create("source-a", settings, "look-a", edge = 128))
        val root = Files.createTempDirectory("rawlab-preview-cache").toFile()
        try {
            val cache = EditedPhotoPreviewCache(root, maximumEntries = 2, maximumBytes = 5)
            cache.write(key, byteArrayOf(1, 2, 3))
            assertArrayEquals(byteArrayOf(1, 2, 3), EditedPhotoPreviewCache(root).read(key))
            val next = EditedPhotoPreviewKey.create("source-b", settings, "look-a")
            cache.write(next, byteArrayOf(4, 5, 6))
            assertNull(cache.read(key)); assertNotNull(cache.read(next))
            cache.write(key, ByteArray(10)); assertNull(cache.read(key))
        } finally { root.deleteRecursively() }
    }
    @Test fun cacheUsesLruIndexWithoutReEnumeratingDirectory() {
        val root = Files.createTempDirectory("rawlab-preview-lru").toFile()
        try {
            var listCalls = 0
            var readCalls = 0
            val storage = HashMap<String, ByteArray>()
            val fakeFs = object : PreviewCacheFileSystem {
                override fun listEntries(directory: File): List<PreviewCacheEntry> {
                    listCalls++
                    return emptyList()
                }
                override fun readBytes(file: File): ByteArray? {
                    readCalls++
                    return storage[file.name]
                }
                override fun writeAtomic(directory: File, target: File, data: ByteArray) {
                    storage[target.name] = data
                }
                override fun delete(file: File): Boolean = storage.remove(file.name) != null
            }
            val settings = EditSettings(exposure = .5f)
            val keyA = EditedPhotoPreviewKey.create("source-a", settings, "look-a")
            val keyB = EditedPhotoPreviewKey.create("source-b", settings, "look-a")
            val keyC = EditedPhotoPreviewKey.create("source-c", settings, "look-a")
            val cache = EditedPhotoPreviewCache(root, maximumEntries = 2, maximumBytes = 1024, fileSystem = fakeFs)
            cache.write(keyA, byteArrayOf(1))
            cache.write(keyB, byteArrayOf(2))
            assertEquals(1, listCalls)
            assertArrayEquals(byteArrayOf(1), cache.read(keyA)) // touch keyA -> keyB becomes LRU
            assertEquals(1, readCalls)
            assertNull(cache.read(keyC)) // miss should not stat/read disk
            assertEquals(1, readCalls)
            cache.write(keyC, byteArrayOf(3)) // evicts keyB without re-listing directory
            assertEquals(1, listCalls)
            assertNotNull(cache.read(keyA))
            assertNull(cache.read(keyB))
            assertNotNull(cache.read(keyC))
        } finally { root.deleteRecursively() }
    }
    @Test fun successfulSaveAndResetNotifyAllStoreInstances() = runBlocking {
        val root = Files.createTempDirectory("rawlab-preview-events").toFile()
        try {
            val store = EditStore(root)
            val changes = async(start = CoroutineStart.UNDISPATCHED) {
                EditStore.changes.filter { it.directory == root.canonicalPath }.take(2).toList()
            }
            val id = PhotoIdentity("photo")
            store.save(id, EditSettings(exposure = 1f))
            EditStore(root).reset(id)
            val result = withTimeout(2000) { changes.await() }
            assertEquals(1f, result[0].state.settings?.exposure)
            assertNull(result[1].state.settings)
        } finally { root.deleteRecursively() }
    }
}
