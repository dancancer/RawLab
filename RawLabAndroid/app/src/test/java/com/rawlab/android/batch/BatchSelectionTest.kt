package com.rawlab.android.batch

import com.rawlab.android.batch.journal.BatchJournal
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import java.io.File
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class BatchSelectionTest {
    @Test fun hdrExportUsesEachSavedModeRatherThanRawDecodeCapability() {
        val raw = BatchTarget(PhotoIdentity("raw"), File("photo.dng"), "photo.dng", sourceIsHDR = true)
        val gainMap = BatchTarget(PhotoIdentity("gain-map"), File("photo.jpg"), "photo.jpg",
            inputKind = PhotoInputKind.RASTER, sourceIsHDR = true)
        val records = mutableMapOf<PhotoIdentity, EditSettings>()
        val read = { identity: PhotoIdentity -> PhotoEditState(identity, records[identity]) }
        var selection = BatchSelectionState().append(listOf(raw, gainMap))
        assertFalse("Unedited camera RAW starts in SDR", selection.supportsHDRExport(read))
        records[raw.identity] = EditSettings().withHDRMode(true, false, cameraRaw = true)
        assertTrue("Unedited gain maps default to HDR", selection.supportsHDRExport(read))
        assertFalse(BatchSelectionState().append(listOf(raw.copy(sourceIsHDR = false))).supportsHDRExport(read))
        records[gainMap.identity] = EditSettings()
        assertFalse("An explicit saved SDR mode overrides source defaults", selection.supportsHDRExport(read))
        assertTrue(selection.supportsHDRExport(read, skipping = setOf(gainMap.id)))
        records[raw.identity] = records.getValue(raw.identity).withHDRMode(false, false, cameraRaw = true)
        assertFalse(selection.supportsHDRExport(read, skipping = setOf(gainMap.id)))
        selection = selection.select(raw.id, false)
        assertFalse(selection.supportsHDRExport(read))
        assertFalse(selection.supportsHDRExport(read, skipping = setOf(gainMap.id)))
        assertFalse(BatchSelectionState().supportsHDRExport(read))
        assertFalse(selection.supportsHDRExport({ throw java.io.IOException("Unreadable saved record") }))
    }

    @Test fun noRecordRasterCollectionUsesSourceDefaultsWithoutSaving() {
        val root = Files.createTempDirectory("collection-defaults").toFile()
        try {
            val store = EditStore(File(root, "edits"))
            val input = File(root, "photo.png").also { it.writeText("input") }
            val photo = BatchTarget(PhotoIdentity("photo"), input, "photo.png", inputKind = PhotoInputKind.RASTER)
            val exporter = BatchSelectionExport(File(root, "jobs"), store::readState, { null })
            val review = exporter.prepare(BatchSelectionState().append(listOf(photo)), emptySet(), ExportFormat.PNG, null, null) {}
            assertTrue(review.ready)
            assertEquals(2, review.rows.single().settings!!.exposureMode)
            assertNull(store.readState(photo.identity).settings)
        } finally { root.deleteRecursively() }
    }

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
            val exporter = BatchSelectionExport(File(root, "jobs"), store::readState, { if (it.film == "custom") look else null })
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
            val frozenBeforeDiskChange = exporter.freeze(selection, review) {}
            assertEquals(1f, frozenBeforeDiskChange.settingsFor(frozenBeforeDiskChange.rows[1].target).exposure)
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

    @Test fun collectionFreezeStoresOneContentAddressedCopyPerLook() {
        val root = Files.createTempDirectory("collection-look-dedupe").toFile()
        try {
            val store = EditStore(File(root, "edits"))
            val photos = (0..1).map { i -> BatchTarget(PhotoIdentity("$i"), File(root, "$i.jpg").also { it.writeText("input $i") },
                "same.jpg", inputKind = PhotoInputKind.RASTER) }
            val selection = BatchSelectionState().append(photos)
            val look = File(root, "shared.cube").also { it.writeText("shared look") }
            photos.forEach { store.save(it.identity, EditSettings(film = "custom")) }
            val exporter = BatchSelectionExport(File(root, "jobs"), store::readState, { if (it.film == "custom") look else null })
            val review = exporter.prepare(selection, emptySet(), ExportFormat.PNG, 1024, "output") {}
            val job = exporter.freeze(selection, review) {}
            val lookFiles = File(File(root, "jobs"), job.id).listFiles()!!.filter { it.extension == "cube" }
            assertEquals(1, lookFiles.size)
            assertEquals(1, job.rows.map { it.target.frozen!!.lookFile!!.path }.distinct().size)
            assertEquals(BatchFrozenSettings.checksum(look), lookFiles.first().nameWithoutExtension)
            assertEquals(look.readText(), lookFiles.first().readText())
        } finally { root.deleteRecursively() }
    }

    @Test fun missingOrChangedInputIsMarkedPerPhotoAndFailedFreezeLeavesNoJob() {
        val root = Files.createTempDirectory("collection-missing").toFile()
        try {
            val store = EditStore(File(root, "edits"))
            val input = File(root, "photo.jpg").also { it.writeText("input") }
            val target = BatchTarget(PhotoIdentity("photo"), input, "photo.jpg")
            val exporter = BatchSelectionExport(File(root, "jobs"), store::readState, { null })
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

    @Test fun reviewExpiresWhenThisSessionChangesACommittedTarget() {
        val root = Files.createTempDirectory("collection-generation").toFile()
        try {
            val store = EditStore(File(root, "edits"))
            val input = File(root, "photo.jpg").also { it.writeText("input") }
            val target = BatchTarget(PhotoIdentity("photo"), input, "photo.jpg")
            val generations = mutableMapOf<PhotoIdentity, Long>()
            val exporter = BatchSelectionExport(File(root, "jobs"), store::readState, { null },
                editGeneration = { generations[it] ?: 0L })
            val selection = BatchSelectionState().append(listOf(target))
            val review = exporter.prepare(selection, emptySet(), ExportFormat.JPEG, null, null) {}
            generations[target.identity] = 1L
            val error = assertThrows(AdjustmentOperationExpiredException::class.java) {
                exporter.freeze(selection, review) {}
            }
            assertEquals("This adjustment operation is no longer current.", error.message)
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

    @Test fun prepareCollectionReviewAwaitsInFlightEditBeforeReadingStore() = runBlocking {
        val root = Files.createTempDirectory("collection-flush-race").toFile()
        val releaseWrite = CountDownLatch(1)
        try {
            val store = EditStore(File(root, "edits"))
            val input = File(root, "photo.png").also { it.writeText("input") }
            val photo = BatchTarget(PhotoIdentity("photo"), input, "photo.png", inputKind = PhotoInputKind.RASTER)
            val selection = BatchSelectionState().append(listOf(photo))
            val exporter = BatchSelectionExport(File(root, "jobs"), store::readState, { null })
            val writeEntered = CountDownLatch(1)
            val committing = MutableStateFlow(true)
            val writer = launch(Dispatchers.IO) {
                writeEntered.countDown()
                assertTrue(releaseWrite.await(5, TimeUnit.SECONDS))
                store.save(photo.identity, EditSettings(exposure = .4f))
                committing.value = false
            }
            assertTrue(writeEntered.await(5, TimeUnit.SECONDS))
            val prepared = async(Dispatchers.Default) {
                prepareCollectionReview(
                    awaitPending = { committing.first { !it } },
                    captureActiveValidation = {
                        check(!committing.value) { "Validation captured before pending edit flushed" }
                        val active: (String) -> Unit = {}
                        active
                    },
                ) { validateActive ->
                    exporter.prepare(selection, emptySet(), ExportFormat.JPEG, null, null, validateActive)
                }
            }
            delay(50)
            assertFalse("Prepare must wait for the in-flight edit flush", prepared.isCompleted)
            releaseWrite.countDown()
            val review = withTimeout(5_000) { prepared.await() }
            writer.join()
            assertTrue(review.ready)
            assertEquals(.4f, review.rows.single().settings!!.exposure)
            val job = exporter.freeze(selection, review) {}
            assertEquals(.4f, job.rows.single().target.frozen!!.settings.exposure)
        } finally {
            releaseWrite.countDown()
            root.deleteRecursively()
        }
    }

    @Test fun freezeChecksTotalBatchSpaceBeforeCreatingJobFolder() {
        val root = Files.createTempDirectory("batch-freeze-space").toFile()
        try {
            val batchDir = object : File(root, "batch") {
                override fun getUsableSpace(): Long = 100L
            }.apply { mkdirs() }
            val source1 = File(root, "a.dng").apply { writeBytes(ByteArray(60) { 1 }) }
            val source2 = File(root, "b.dng").apply { writeBytes(ByteArray(60) { 2 }) }
            val t1 = BatchTarget(PhotoIdentity("a"), source1, "a.dng", inputKind = PhotoInputKind.RAW)
            val t2 = BatchTarget(PhotoIdentity("b"), source2, "b.dng", inputKind = PhotoInputKind.RAW)
            val selection = BatchSelectionState().append(listOf(t1, t2))
            val store = EditStore(File(root, "edits"))
            val exporter = BatchSelectionExport(
                directory = batchDir,
                readRecord = store::readState,
                resolveLook = { null },
            )
            val review = exporter.prepare(selection, emptySet(), ExportFormat.JPEG, null, null) {}
            assertTrue(review.ready)

            val result = runCatching { exporter.freeze(selection, review) {} }
            assertTrue(result.exceptionOrNull() is com.rawlab.android.photo.WorkingCopyStorageFull)
            assertEquals("Total space preflight must fail before creating any batch job folder",
                emptyList<String>(), batchDir.list()?.toList().orEmpty())
        } finally { root.deleteRecursively() }
    }

    @Test fun freezeDetectsSourceModificationViaSinglePassChecksum() {
        val root = Files.createTempDirectory("batch-freeze-sha").toFile()
        try {
            val batchDir = File(root, "batch").apply { mkdirs() }
            val source = File(root, "a.dng").apply { writeBytes(ByteArray(64) { 7 }) }
            val target = BatchTarget(PhotoIdentity("a"), source, "a.dng", inputKind = PhotoInputKind.RAW)
            val selection = BatchSelectionState().append(listOf(target))
            val store = EditStore(File(root, "edits"))
            val exporter = BatchSelectionExport(
                directory = batchDir,
                readRecord = store::readState,
                resolveLook = { null },
            )
            val review = exporter.prepare(selection, emptySet(), ExportFormat.JPEG, null, null) {}
            assertTrue(review.ready)

            source.writeBytes(ByteArray(64) { 9 })
            val result = runCatching { exporter.freeze(selection, review) {} }
            val error = result.exceptionOrNull()
            assertTrue(error is IllegalStateException && error.message == "Photo source changed")
            assertEquals("Failed freeze must discard partial job folder",
                emptyList<String>(), batchDir.list()?.toList().orEmpty())
        } finally { root.deleteRecursively() }
    }

}
