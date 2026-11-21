package com.rawlab.android.editor

import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.PhotoIdentity
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class EditorDraftStoreTest {
    @Test fun restoresOnlyMatchingSourceAndCommittedSettings() {
        val directory = Files.createTempDirectory("tool-draft").toFile()
        try {
            val identity = PhotoIdentity("content://photos/1")
            val base = EditSettings(exposure = .5f)
            val draft = AdjustmentDraft.begin(AdjustmentGroup.EXPOSURE, base).update(base.copy(exposure = 1.5f))
            EditorDraftStore(directory).save(identity, "bytes-1", draft)
            val reopened = EditorDraftStore(directory)
            assertEquals(draft, reopened.load(identity, "bytes-1", base))
            assertNull(reopened.load(PhotoIdentity("content://photos/2"), "bytes-1", base))
            assertNull(reopened.load(identity, "bytes-2", base))
            assertNull(reopened.load(identity, "bytes-1", base.copy(saturation = .3f)))
            reopened.clear(PhotoIdentity("content://photos/2"))
            assertNotNull(reopened.load(identity, "bytes-1", base))
            reopened.clear(identity)
            assertNull(reopened.load(identity, "bytes-1", base))
        } finally { directory.deleteRecursively() }
    }

    @Test fun replacementIsCompleteAndCorruptDataNeverBecomesACommittedEdit() {
        val directory = Files.createTempDirectory("tool-draft").toFile()
        try {
            val store = EditorDraftStore(directory)
            val identity = PhotoIdentity("content://photos/1")
            val base = EditSettings()
            val first = AdjustmentDraft.begin(AdjustmentGroup.SATURATION, base).update(base.copy(saturation = .2f))
            store.save(identity, "bytes", first)
            val next = first.update(base.copy(saturation = .8f))
            store.save(identity, "bytes", next)
            assertEquals(next, store.load(identity, "bytes", base))
            directory.resolve("active.properties").writeText("version=999\nidentity=content://photos/1")
            assertTrue(runCatching { store.load(identity, "bytes", base) }.isFailure)
            assertEquals(0f, base.saturation)
        } finally { directory.deleteRecursively() }
    }
}
