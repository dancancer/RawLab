package com.rawlab.android.batch

import com.rawlab.android.batch.journal.BatchJournal
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.*
import java.io.File
import java.nio.file.Files
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

class BatchSelectionTest {
    @Test fun navigationSelectionAndSynchronizationAreIndependent() {
        val first = BatchTarget(PhotoIdentity("first"), File("first"), "same.jpg")
        val second = BatchTarget(PhotoIdentity("second"), File("second"), "same.jpg")
        val third = BatchTarget(PhotoIdentity("third"), File("third"), "other.jpg")
        var selection = BatchSelectionState().append(listOf(first, second, first, third))
        assertEquals(listOf("first", "second", "third"), selection.photos.map { it.id })
        selection = selection.select("third", false).beginEditing("second")
        assertEquals(1, selection.returnPosition)
        assertEquals("second", selection.currentID)
        assertEquals(listOf("second"), selection.synchronizationTargets("first").map { it.id })
        val sync = UUID.randomUUID()
        selection = selection.recordSynchronization(sync, true).returnToCollection()
        assertNull(selection.currentID)
        assertEquals(setOf("first", "second"), selection.selected)
        assertEquals(sync, selection.recordSynchronization(UUID.randomUUID(), false).lastSynchronization)
    }

    @Test fun reviewAndFreezeUseOwnCommittedRecordsAndKeepTaskOwnedInputs() {
        val root = Files.createTempDirectory("collection-freeze").toFile()
        try {
            val store = EditStore(File(root, "edits"))
            val photos = (0..2).map { i -> BatchTarget(PhotoIdentity("$i"), File(root, "$i.jpg").also { it.writeText("input $i") },
                "same.jpg", inputKind = PhotoInputKind.RASTER) }
            val selection = BatchSelectionState().append(photos)
            val look = File(root, "look.cube").also { it.writeText("original look") }
            photos.forEachIndexed { i, photo -> store.save(photo.identity, EditSettings(exposure = i.toFloat(), film = if (i == 1) "custom" else "neutral")) }
            val exporter = BatchSelectionExport(File(root, "jobs"), store::versionedState, { if (it.film == "custom") look else null })
            val draft: (String) -> Unit = { if (it == "1") error("Apply, discard or skip this draft") }
            val blocked = exporter.prepare(selection, emptySet(), ExportFormat.PNG, 1024, null, draft)
            assertFalse(blocked.ready)
            val skipped = exporter.prepare(selection, setOf("1"), ExportFormat.PNG, 1024, null, draft)
            assertTrue(skipped.ready)
            assertEquals(listOf("0", "2"), skipped.rows.map { it.target.id })
            assertEquals(3, selection.selected.size)
            assertFalse(exporter.prepare(selection, selection.selected, ExportFormat.PNG, null, null) {}.ready)
            val review = exporter.prepare(selection, emptySet(), ExportFormat.PNG, 1024, "output") {}
            store.save(photos[1].identity, EditSettings(exposure = 1.5f, film = "custom"))
            assertThrows(EditPersistenceConflict::class.java) { exporter.freeze(selection, review) {} }
            val refreshed = exporter.prepare(selection, emptySet(), ExportFormat.PNG, 1024, "output") {}
            assertThrows(IllegalStateException::class.java) { exporter.freeze(selection.select("0", false), refreshed) {} }
            assertThrows(IllegalStateException::class.java) { exporter.freeze(selection, refreshed) { if (it == "2") error("new draft") } }
            look.writeText("changed")
            assertThrows(IllegalStateException::class.java) { exporter.freeze(selection, refreshed) {} }
            val finalReview = exporter.prepare(selection, emptySet(), ExportFormat.PNG, 1024, "output") {}
            val job = exporter.freeze(selection, finalReview) {}
            assertEquals(BatchSettingsMode.PER_TARGET_FROZEN, job.settingsMode)
            photos.forEach { it.sourceFile.delete() }; look.delete()
            store.save(photos[1].identity, EditSettings(exposure = 4f))
            val restored = BatchJournal(File(root, "jobs")).load(job.id)!!
            val exposures = mutableListOf<Float>()
            val result = BatchRunner.run(restored, render = { _, settings -> exposures += settings.exposure }, write = { _, _, _ -> })
            assertEquals(listOf(0f, 1.5f, 2f), exposures)
            assertTrue(result.rows.all { it.status == BatchRowStatus.SUCCESS })
            assertEquals(3, job.rows.map { it.outputName }.distinct().size)
        } finally { root.deleteRecursively() }
    }

    @Test fun missingOrChangedInputIsMarkedPerPhotoAndFailedFreezeLeavesNoJob() {
        val root = Files.createTempDirectory("collection-missing").toFile()
        try {
            val store = EditStore(File(root, "edits"))
            val input = File(root, "photo.jpg").also { it.writeText("input") }
            val target = BatchTarget(PhotoIdentity("photo"), input, "photo.jpg")
            val exporter = BatchSelectionExport(File(root, "jobs"), store::versionedState, { null })
            val selection = BatchSelectionState().append(listOf(target))
            val review = exporter.prepare(selection, emptySet(), ExportFormat.JPEG, null, null) {}
            var validations = 0
            assertThrows(IllegalStateException::class.java) { exporter.freeze(selection, review) {
                validations++; if (validations > 1) error("late edit")
            } }
            assertTrue(File(root, "jobs").listFiles().orEmpty().isEmpty())
            input.delete()
            assertFalse(exporter.prepare(selection, emptySet(), ExportFormat.JPEG, null, null) {}.ready)
        } finally { root.deleteRecursively() }
    }
    @Test fun futureJournalCannotBeOverwrittenByAnOlderInMemoryJob() {
        val root = Files.createTempDirectory("future-collection").toFile()
        try {
            val job = BatchJob(BatchSourceSnapshot(PhotoIdentity("source"), File(root, "source.raw"), EditSettings()), emptyList())
            val journal = BatchJournal(root); journal.save(job)
            val file = File(root, "${job.id}.properties")
            val properties = java.util.Properties().also { file.inputStream().use(it::load) }
            properties.setProperty("journal.version", "999")
            file.outputStream().use { properties.store(it, null) }
            val bytes = file.readBytes()
            assertThrows(java.io.IOException::class.java) { journal.save(job) }
            assertArrayEquals(bytes, file.readBytes())
        } finally { root.deleteRecursively() }
    }

    @Test fun importFailuresKeepTheirOrderedRowsAndRetryDoesNotChangeSelection() {
        val missing = BatchTarget(PhotoIdentity("missing"), File("missing"), "same.raw")
        val good = BatchTarget(PhotoIdentity("good"), File("good"), "same.raw")
        val selection = BatchSelectionState().acceptImports(listOf(missing, good), mapOf("missing" to "permission denied"))
            .select("missing", false)
        assertEquals(listOf("missing", "good"), selection.photos.map { it.id })
        assertEquals("permission denied", selection.failures["missing"])
        val restored = selection.acceptImports(listOf(missing.copy(sourceFile = File("restored"))), emptyMap())
        assertTrue(restored.failures.isEmpty())
        assertEquals(setOf("good"), restored.selected)
        assertEquals(File("restored"), restored.photos.first().sourceFile)
    }

}
