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
