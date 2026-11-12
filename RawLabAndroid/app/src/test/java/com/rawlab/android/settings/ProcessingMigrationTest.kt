package com.rawlab.android.settings

import com.rawlab.android.adjustments.AdjustmentStatus
import com.rawlab.android.adjustments.AdjustmentTransferSession
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.nio.file.Files

class ProcessingMigrationTest {
    private fun original() = EditSettings(processing = ProcessingIdentity.C5, film = "saved-look", exposure = .5f,
        highlights = -.2f, clarity = 14f, denoise = DenoiseSettings(true, 10f, 70f, 90f))
    private fun result(disposition: Float = 1f) = floatArrayOf(1f, 80f, 2f, 3f, disposition, 20f,
        .75f, 1.1f, .1f, .2f, 1.15f, -.1f, .2f, .05f, .1f, -.05f, .001f, .003f, .002f, .001f)

    @Test fun canonicalMappingPreservesAllOtherEdits() {
        val before = original()
        val after = requireNotNull(ProcessingMigrationOutcome.decode(before, result()).candidate(before))
        assertEquals(.75f, after.exposure, 1e-6f)
        assertEquals(.1f, after.contrast, 1e-6f)
        assertEquals(-.1f, after.highlights, 1e-6f)
        assertEquals(.15f, after.saturation, 1e-6f)
        assertEquals(-10f, after.blackPoint, 1e-6f)
        assertEquals(5f, after.vibrance, 1e-6f)
        assertEquals(before.denoise, after.denoise)
        assertEquals(before.film, after.film)
        assertEquals(before.geometry, after.geometry)
        assertEquals(before.temperature, after.temperature, 0f)
        assertEquals(before.tint, after.tint, 0f)
        assertThrows(IllegalArgumentException::class.java) {
            ProcessingMigrationOutcome.decode(before, result().also { it[5] = 0f })
        }
        assertEquals(ProcessingIdentity.CURRENT, after.processing)
        assertNull(ProcessingMigrationOutcome.decode(before, result(2f)).candidate(before))
        assertThrows(IllegalArgumentException::class.java) {
            ProcessingMigrationOutcome.decode(before, result().also { it[16] = .2f })
        }
        assertThrows(IllegalArgumentException::class.java) {
            ProcessingMigrationOutcome.decode(before, result().also { it[3] = 4f })
        }
    }

    @Test fun atomicCASAndRestartRollbackRetainOriginalSettings() {
        val directory = Files.createTempDirectory("rawlab-migration").toFile()
        try {
            val identity = PhotoIdentity("content:original")
            val before = original()
            val store = EditStore(directory)
            store.save(identity, before)
            val expected = store.readState(identity)
            val fit = ProcessingMigrationOutcome.decode(before, result())
            val candidate = requireNotNull(fit.candidate(before))
            val originalBytes = File(directory, "edits.properties").readBytes()
            val failing = EditStore(directory) { _, _ -> throw IOException("injected write failure") }
            assertThrows(IOException::class.java) { failing.commitProcessingMigration(expected, candidate, fit.quality) }
            assertArrayEquals(originalBytes, File(directory, "edits.properties").readBytes())
            store.commitProcessingMigration(expected, candidate, fit.quality)
            val reopened = EditStore(directory)
            assertEquals(before, reopened.processingMigration(identity)?.original)
            reopened.save(identity, candidate.copy(exposure = 2f))
            assertThrows(AdjustmentOperationExpiredException::class.java) {
                store.rollbackProcessingMigration(PhotoEditState(identity, candidate))
            }
            assertEquals(before, reopened.rollbackProcessingMigration(reopened.readState(identity)).settings)
            val receipt = EditStore(directory).processingMigration(identity)!!
            assertEquals(ProcessingMigrationStatus.ROLLED_BACK, receipt.status)
            assertFalse(receipt.shouldAttempt(before, 2))
            assertThrows(AdjustmentOperationExpiredException::class.java) {
                store.commitProcessingMigration(store.readState(identity), candidate, fit.quality)
            }
        } finally { directory.deleteRecursively() }
    }

    @Test fun rejectedFitAndConcurrentSaveNeverReplaceOldRecords() {
        val directory = Files.createTempDirectory("rawlab-migration-kept").toFile()
        try {
            val identity = PhotoIdentity("photo:kept")
            val before = original(); val store = EditStore(directory)
            store.save(identity, before)
            val expected = store.readState(identity)
            val fit = ProcessingMigrationOutcome.decode(before, result(2f))
            assertEquals(expected, store.commitProcessingMigration(expected, null, fit.quality))
            val kept = store.processingMigration(identity)!!
            assertFalse(kept.shouldAttempt(before, 2))
            val changed = before.copy(shadows = .4f)
            assertTrue(kept.shouldAttempt(changed, 2))
            EditStore(directory).save(identity, changed)
            assertThrows(AdjustmentOperationExpiredException::class.java) {
                store.commitProcessingMigration(expected, null, fit.quality)
            }
            assertEquals(changed, store.readState(identity).settings)
        } finally { directory.deleteRecursively() }
    }

    @Test fun resetCommitClearsMigrationReceiptAndPreventsRollbackAcrossReopen() {
        val directory = Files.createTempDirectory("rawlab-migration-reset").toFile()
        try {
            val identity = PhotoIdentity("content://test/migrated-photo")
            val before = original()
            val store = EditStore(directory)
            val session = AdjustmentTransferSession(store)
            store.save(identity, before)
            val fit = ProcessingMigrationOutcome.decode(before, result())
            val candidate = requireNotNull(fit.candidate(before))
            val accepted = store.commitProcessingMigration(store.readState(identity), candidate, fit.quality)
            session.adoptProcessingMigration(accepted)
            assertEquals(ProcessingMigrationStatus.MIGRATED, store.processingMigration(identity)?.status)

            val ordinaryEdit = session.commitEdit(accepted, candidate.copy(exposure = 1.25f))
            assertEquals(AdjustmentStatus.APPLIED, ordinaryEdit.status)
            assertEquals(ProcessingMigrationStatus.MIGRATED, store.processingMigration(identity)?.status)

            val neutralV3 = EditSettings(processing = ProcessingIdentity.CURRENT)
            val resetOutcome = session.commitEdit(
                store.readState(identity),
                neutralV3,
                clearProcessingMigration = true,
            )
            assertEquals(AdjustmentStatus.APPLIED, resetOutcome.status)
            assertEquals(neutralV3, store.load(identity))
            assertNull(store.processingMigration(identity))
            assertThrows(AdjustmentOperationExpiredException::class.java) {
                store.rollbackProcessingMigration(store.readState(identity))
            }

            val reopened = EditStore(directory)
            assertNull(reopened.processingMigration(identity))
            assertThrows(AdjustmentOperationExpiredException::class.java) {
                reopened.rollbackProcessingMigration(reopened.readState(identity))
            }

            val undone = session.undoPhoto(identity)
            assertEquals(AdjustmentStatus.APPLIED, undone.single().status)
            assertEquals(1.25f, store.load(identity)?.exposure ?: 0f, 0f)
            assertNull(store.processingMigration(identity))
            assertThrows(AdjustmentOperationExpiredException::class.java) {
                store.rollbackProcessingMigration(store.readState(identity))
            }

            // Also verify KEPT and ROLLED_BACK receipts are cleared by explicit reset intent.
            val keptIdentity = PhotoIdentity("content://test/kept-photo")
            store.save(keptIdentity, before)
            val keptFit = ProcessingMigrationOutcome.decode(before, result(2f))
            val keptState = store.commitProcessingMigration(store.readState(keptIdentity), null, keptFit.quality)
            session.adoptProcessingMigration(keptState)
            assertEquals(ProcessingMigrationStatus.KEPT, store.processingMigration(keptIdentity)?.status)
            session.commitEdit(
                keptState,
                EditSettings(processing = ProcessingIdentity.C5),
                clearProcessingMigration = true,
            )
            assertNull(EditStore(directory).processingMigration(keptIdentity))

            val rolledIdentity = PhotoIdentity("content://test/rolled-photo")
            store.save(rolledIdentity, before)
            val rolledMigrated = store.commitProcessingMigration(store.readState(rolledIdentity), candidate, fit.quality)
            val rolledBack = store.rollbackProcessingMigration(rolledMigrated)
            session.adoptProcessingMigration(rolledBack)
            assertEquals(ProcessingMigrationStatus.ROLLED_BACK, store.processingMigration(rolledIdentity)?.status)
            store.reset(rolledIdentity)
            assertNull(EditStore(directory).processingMigration(rolledIdentity))
        } finally { directory.deleteRecursively() }
    }
}
