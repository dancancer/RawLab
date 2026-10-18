package com.rawlab.android.photo

import android.net.Uri
import android.provider.MediaStore
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID
import com.rawlab.android.format.ExportFormat

class PhotoStorageTest {
    @Test fun failedAlbumCopyDoesNotLeavePendingMedia() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val collection = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        fun count() = context.contentResolver.query(collection, arrayOf(MediaStore.Images.Media._ID),
            "${MediaStore.Images.Media.DISPLAY_NAME} LIKE ?", arrayOf("RawLab-%"), null)?.use { it.count } ?: 0
        PhotoStorage(context).use { storage ->
            val before = count()
            assertThrows(Exception::class.java) { storage.saveAlbum(File(context.cacheDir, UUID.randomUUID().toString()), ExportFormat.PNG) }
            assertEquals(before, count())
        }
    }

    @Test fun publishesCompleteMediaAndNeverOverwritesInput() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val file = File.createTempFile("storage-test", ".png", context.cacheDir)
        val bytes = byteArrayOf(1, 2, 3, 4)
        file.writeBytes(bytes)
        try {
            PhotoStorage(context).use { storage ->
                assertThrows(IllegalArgumentException::class.java) { storage.saveDocument(file, Uri.fromFile(file), Uri.fromFile(file)) }
                assertArrayEquals(bytes, file.readBytes())
                val uri = storage.saveAlbum(file, ExportFormat.PNG)
                try {
                    assertArrayEquals(bytes, context.contentResolver.openInputStream(uri)!!.use { it.readBytes() })
                    context.contentResolver.query(uri, arrayOf(MediaStore.Images.Media.IS_PENDING), null, null, null)!!.use {
                        assertTrue(it.moveToFirst()); assertEquals(0, it.getInt(0))
                    }
                } finally { context.contentResolver.delete(uri, null, null) }
            }
        } finally { file.delete() }
    }
}
