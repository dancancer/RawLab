package com.rawlab.android.settings

import com.rawlab.android.adjustments.AdjustmentStatus
import com.rawlab.android.adjustments.AdjustmentTransferSession
import com.rawlab.android.engine.NativeMigrationResult
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.nio.file.Files

class ProcessingMigrationTest {
    private fun original() = EditSettings(processing = ProcessingIdentity.C5, film = "saved-look", exposure = .5f,
        highlights = .2f, clarity = 14f, denoise = DenoiseSettings(true, 10f, 70f, 90f))
    private fun result(disposition: Int = 1) = NativeMigrationResult(
        sourceVersion = 2,
        targetVersion = 3,
        disposition = disposition,
        evaluationCount = 20,
        exposureEv = .75f,
        contrast = 1.1f,
        highlights = .1f,
        shadows = .2f,
        saturation = 1.15f,
        blackPoint = -.1f,
        whitePoint = .2f,
        vibrance = .05f,
        clarity = .1f,
        dehaze = -.05f,
        rgbRmse = .001f,
        p99Error = .003f,
        worstTileRmse = .002f,
        detailRmse = .001f,
    )

    @Test fun canonicalMappingPreservesAllOtherEdits() {
        val before = original()
        val after = requireNotNull(ProcessingMigrationOutcome.fromNative(before, result()).candidate(before))
        assertEquals(.75f, after.exposure, 1e-6f)
        assertEquals(1.1f, after.contrast, 1e-6f)
        assertEquals(.1f, after.highlights, 1e-6f)
        assertEquals(1.15f, after.saturation, 1e-6f)
        assertEquals(-10f, after.blackPoint, 1e-6f)
        assertEquals(5f, after.vibrance, 1e-6f)
        assertEquals(before.denoise, after.denoise)
        assertEquals(before.film, after.film)
        assertEquals(before.geometry, after.geometry)
        assertEquals(before.temperature, after.temperature, 0f)
        assertEquals(before.tint, after.tint, 0f)
        assertThrows(IllegalArgumentException::class.java) {
            ProcessingMigrationOutcome.fromNative(before, result().copy(evaluationCount = 0))
        }
        assertEquals(ProcessingIdentity.CURRENT, after.processing)
        assertNull(ProcessingMigrationOutcome.fromNative(before, result(2)).candidate(before))
        assertThrows(IllegalArgumentException::class.java) {
            ProcessingMigrationOutcome.fromNative(before, result().copy(rgbRmse = .2f))
        }
        assertThrows(IllegalArgumentException::class.java) {
            ProcessingMigrationOutcome.fromNative(before, result().copy(targetVersion = 4))
        }
    }

    @Test fun atomicCASAndRestartRollbackRetainOriginalSettings() {
        val directory = Files.createTempDirectory("rawlab-migration").toFile()
        try {
            val identity = PhotoIdentity("content:original")
            val before = original()
            val store = EditStore(directory)
            store.save(identity, before)
            val expected = store.readState(identity, isX3f = false)
            val fit = ProcessingMigrationOutcome.fromNative(before, result())
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
                store.rollbackProcessingMigration(PhotoEditState(identity, candidate), isX3f = false)
            }
            assertEquals(before, reopened.rollbackProcessingMigration(reopened.readState(identity, isX3f = false), isX3f = false).settings)
            val receipt = EditStore(directory).processingMigration(identity)!!
            assertEquals(ProcessingMigrationStatus.ROLLED_BACK, receipt.status)
            assertFalse(receipt.shouldAttempt(before, 2))
            assertThrows(AdjustmentOperationExpiredException::class.java) {
                store.commitProcessingMigration(store.readState(identity, isX3f = false), candidate, fit.quality)
            }
        } finally { directory.deleteRecursively() }
    }

    @Test fun rejectedFitAndConcurrentSaveNeverReplaceOldRecords() {
        val directory = Files.createTempDirectory("rawlab-migration-kept").toFile()
        try {
            val identity = PhotoIdentity("photo:kept")
            val before = original(); val store = EditStore(directory)
            store.save(identity, before)
            val expected = store.readState(identity, isX3f = false)
            val fit = ProcessingMigrationOutcome.fromNative(before, result(2))
            assertEquals(expected, store.commitProcessingMigration(expected, null, fit.quality))
            val kept = store.processingMigration(identity)!!
            assertFalse(kept.shouldAttempt(before, 2))
            val changed = before.copy(shadows = .4f)
            assertTrue(kept.shouldAttempt(changed, 2))
            EditStore(directory).save(identity, changed)
            assertThrows(AdjustmentOperationExpiredException::class.java) {
                store.commitProcessingMigration(expected, null, fit.quality)
            }
            assertEquals(changed, store.readState(identity, isX3f = false).settings)
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
            val fit = ProcessingMigrationOutcome.fromNative(before, result())
            val candidate = requireNotNull(fit.candidate(before))
            val accepted = store.commitProcessingMigration(store.readState(identity, isX3f = false), candidate, fit.quality)
            session.adoptProcessingMigration(accepted)
            assertEquals(ProcessingMigrationStatus.MIGRATED, store.processingMigration(identity)?.status)

            val ordinaryEdit = session.commitEdit(accepted, candidate.copy(exposure = 1.25f))
            assertEquals(AdjustmentStatus.APPLIED, ordinaryEdit.status)
            assertEquals(ProcessingMigrationStatus.MIGRATED, store.processingMigration(identity)?.status)

            val neutralV3 = EditSettings(processing = ProcessingIdentity.CURRENT)
            val resetOutcome = session.commitEdit(
                store.readState(identity, isX3f = false),
                neutralV3,
                clearProcessingMigration = true,
            )
            assertEquals(AdjustmentStatus.APPLIED, resetOutcome.status)
            assertEquals(neutralV3, store.load(identity))
            assertNull(store.processingMigration(identity))
            assertThrows(AdjustmentOperationExpiredException::class.java) {
                store.rollbackProcessingMigration(store.readState(identity, isX3f = false), isX3f = false)
            }

            val reopened = EditStore(directory)
            assertNull(reopened.processingMigration(identity))
            assertThrows(AdjustmentOperationExpiredException::class.java) {
                reopened.rollbackProcessingMigration(reopened.readState(identity, isX3f = false), isX3f = false)
            }

            val undone = session.undoPhoto(identity)
            assertEquals(AdjustmentStatus.APPLIED, undone.single().status)
            assertEquals(1.25f, store.load(identity)?.exposure ?: 0f, 0f)
            assertNull(store.processingMigration(identity))
            assertThrows(AdjustmentOperationExpiredException::class.java) {
                store.rollbackProcessingMigration(store.readState(identity, isX3f = false), isX3f = false)
            }

            // Also verify KEPT and ROLLED_BACK receipts are cleared by explicit reset intent.
            val keptIdentity = PhotoIdentity("content://test/kept-photo")
            store.save(keptIdentity, before)
            val keptFit = ProcessingMigrationOutcome.fromNative(before, result(2))
            val keptState = store.commitProcessingMigration(store.readState(keptIdentity, isX3f = false), null, keptFit.quality)
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
            val rolledMigrated = store.commitProcessingMigration(store.readState(rolledIdentity, isX3f = false), candidate, fit.quality)
            val rolledBack = store.rollbackProcessingMigration(rolledMigrated, isX3f = false)
            session.adoptProcessingMigration(rolledBack)
            assertEquals(ProcessingMigrationStatus.ROLLED_BACK, store.processingMigration(rolledIdentity)?.status)
            store.reset(rolledIdentity)
            assertNull(EditStore(directory).processingMigration(rolledIdentity))
        } finally { directory.deleteRecursively() }
    }
}
