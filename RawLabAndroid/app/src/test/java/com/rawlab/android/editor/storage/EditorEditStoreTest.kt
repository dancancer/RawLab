package com.rawlab.android.editor.storage

import com.rawlab.android.editor.EditSaveState
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.PhotoIdentity
import java.io.File
import java.io.IOException
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class EditorEditStoreTest {
    @Test fun readFailureKeepsItsCauseAndCanBeRetriedWithoutOverwritingTheRecord() {
        val root = Files.createTempDirectory("rawlab-edit-read").toFile()
        val record = File(root, "edits.properties").apply { writeText("record.YQ.values=broken") }
        val original = record.readBytes()
        try {
            val store = EditorEditStore(root)
            assertEquals(EditSaveState.FAILED, store.initialResult.state)
            assertTrue(store.initialResult.reading)
            assertFalse(store.initialResult.detail.isNullOrBlank())
            assertArrayEquals(original, record.readBytes())
            record.delete()
            assertEquals(EditSaveState.NONE, store.reopen().state)
            assertTrue(store.available)
        } finally { root.deleteRecursively() }
    }

    @Test fun saveFailureRetainsWriteDetailAndRetryClearsItWithoutChangingSettings() {
        val root = Files.createTempDirectory("rawlab-edit-write").toFile()
        val identity = PhotoIdentity("content://test/photo")
        val original = EditSettings(exposure = .5f)
        val changed = original.copy(exposure = 1f)
        try {
            val store = EditorEditStore(root)
            assertEquals(EditSaveState.SAVED, store.save(identity, original).state)
            val record = File(root, "edits.properties")
            record.delete(); record.mkdir()
            File(record, "occupied").writeText("keep")
            val failed = store.save(identity, changed)
            assertEquals(EditSaveState.FAILED, failed.state)
            assertFalse(failed.reading)
            assertTrue(failed.error is IOException)
            assertFalse(failed.detail.isNullOrBlank())
            assertEquals(original, store.load(identity))
            record.deleteRecursively()
            val retry = store.save(identity, changed)
            assertEquals(EditSaveState.SAVED, retry.state)
            assertNull(retry.error)
            assertNull(retry.detail)
            assertEquals(changed, store.load(identity))
        } finally { root.deleteRecursively() }
    }

    @Test fun blankErrorDetailFallsBackToTheExceptionClass() {
        assertEquals("IOException", EditSaveResult(EditSaveState.FAILED, IOException("  ")).detail)
        assertEquals("IOException", EditSaveResult(EditSaveState.FAILED, IOException()).detail)
    }
}
