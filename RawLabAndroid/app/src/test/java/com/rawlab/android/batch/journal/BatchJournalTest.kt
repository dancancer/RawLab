package com.rawlab.android.batch.journal

import com.rawlab.android.batch.*
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.PhotoIdentity
import java.io.File
import java.io.IOException
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class BatchJournalTest {
    @get:Rule val temporary = TemporaryFolder()
    private val root get() = temporary.root
    private fun job(count: Int = 2) = BatchJob(
        BatchSourceSnapshot(PhotoIdentity("source"), File("/source.jpg"), EditSettings(exposure = .75f),
            lookFile = File("/look.cube"), inputKind = PhotoInputKind.RASTER),
        (0 until count).map { BatchTarget(PhotoIdentity("target-$it"), File("/$it.raw"), "$it.raw", "content://input/$it") },
        id = "fixture", outputFormat = ExportFormat.DNG, outputLongEdge = 3000, destination = "content://tree/output")
    private fun log() = File(root, "fixture.rows")

    @Test fun snapshotAndRowLogRoundTripMetadataAndLastRowChange() {
        val journal = BatchJournal(root)
        val original = job()
        journal.save(original)
        val snapshot = File(root, "fixture.properties").readBytes()
        val first = original.withRows(original.rows.mapIndexed { i, row ->
            if (i == 1) row.copy(status = BatchRowStatus.PUBLISHING, outputName = "custom.dng", outputUri = "content://output/1") else row
        })
        journal.recordRow(first, 1)
        val latest = first.withRows(first.rows.mapIndexed { i, row -> if (i == 1) row.copy(outputReady = true) else row })
        journal.recordRow(latest, 1)
        assertArrayEquals(snapshot, File(root, "fixture.properties").readBytes())
        val recovered = BatchJournal(root).load(original.id)!!
        assertEquals(latest.copy(rows = latest.rows.map { if (it.status == BatchRowStatus.PUBLISHING) it.copy(status = BatchRowStatus.NEEDS_CONFIRMATION) else it }), recovered)
        val compactedLength = log().length()
        assertEquals(recovered, BatchJournal(root).load(original.id))
        assertEquals(compactedLength, log().length())
    }

    @Test fun everyTornTrailingRecordKeepsEarlierDurableRow() {
        val journal = BatchJournal(root)
        val original = job()
        journal.save(original)
        val durable = original.withRows(original.rows.mapIndexed { i, row -> if (i == 0) row.copy(status = BatchRowStatus.SUCCESS) else row })
        journal.recordRow(durable, 0)
        val boundary = log().length().toInt()
        val last = durable.withRows(durable.rows.mapIndexed { i, row -> if (i == 1) row.copy(status = BatchRowStatus.SUCCESS) else row })
        journal.recordRow(last, 1)
        val complete = log().readBytes()
        val snapshot = File(root, "fixture.properties").readBytes()
        for (end in boundary until complete.size) {
            File(root, "fixture.properties").writeBytes(snapshot)
            log().writeBytes(complete.copyOf(end))
            assertEquals("truncated at $end", durable, BatchJournal(root).load(original.id))
        }
    }

    @Test fun garbageOrCorruptRecordStopsReplayBeforeLaterRecords() {
        val journal = BatchJournal(root)
        val original = job()
        journal.save(original)
        val snapshot = File(root, "fixture.properties").readBytes()
        val header = log().readBytes()
        val updated = original.withRows(original.rows.map { it.copy(status = BatchRowStatus.SUCCESS) })
        journal.recordRow(updated, 0)
        val valid = log().readBytes().drop(header.size).toByteArray()
        for (garbage in listOf(byteArrayOf(1, 2, 3), byteArrayOf(127, -1, -1, -1), valid.copyOf().also { it[it.lastIndex] = (it.last() + 1).toByte() })) {
            File(root, "fixture.properties").writeBytes(snapshot)
            log().writeBytes(header + garbage + valid)
            assertEquals(original, BatchJournal(root).load(original.id))
        }
    }

    @Test fun newerSnapshotNeverReplaysOldGenerationEvenIfLogResetWasInterrupted() {
        val journal = BatchJournal(root)
        val original = job()
        journal.save(original)
        journal.recordRow(original.withRows(original.rows.map { it.copy(status = BatchRowStatus.SUCCESS) }), 0)
        val staleLog = log().readBytes()
        val newer = original.withRows(original.rows.map { it.copy(status = BatchRowStatus.CANCELLED) }, "cancelled")
        journal.save(newer)
        log().writeBytes(staleLog)
        assertEquals(newer, BatchJournal(root).load(original.id))
        log().delete()
        assertEquals(newer, BatchJournal(root).load(original.id))
    }

    @Test fun v2EncoderFixtureKeepsFormatsSettingsAndRecoveryMapping() {
        for (format in ExportFormat.entries) {
            val original = job(7).copy(outputFormat = format).let { base -> base.withRows(base.rows.mapIndexed { i, row ->
                row.copy(status = BatchRowStatus.entries[i], error = "error-$i", outputUri = "content://output/$i", outputReady = i % 2 == 0)
            }, "global failure") }
            writeV2Fixture(root, original)
            val recovered = BatchJournal(root).load(original.id)!!
            assertEquals(original.copy(rows = original.rows.map {
                it.copy(status = when (it.status) {
                    BatchRowStatus.PROCESSING -> BatchRowStatus.PENDING
                    BatchRowStatus.PUBLISHING -> BatchRowStatus.NEEDS_CONFIRMATION
                    else -> it.status
                })
            }), recovered)
            assertEquals(recovered, BatchJournal(root).load(original.id))
        }
    }

    @Test fun rowReplayAppliesRecoveryOnlyAfterAllRecords() {
        val journal = BatchJournal(root)
        val original = job(7)
        journal.save(original)
        var current = original
        BatchRowStatus.entries.forEachIndexed { i, status ->
            current = current.withRows(current.rows.mapIndexed { j, row -> if (i == j) row.copy(status = status) else row })
            journal.recordRow(current, i)
        }
        assertEquals(listOf(BatchRowStatus.PENDING, BatchRowStatus.PENDING, BatchRowStatus.NEEDS_CONFIRMATION,
            BatchRowStatus.NEEDS_CONFIRMATION, BatchRowStatus.SUCCESS, BatchRowStatus.FAILED, BatchRowStatus.CANCELLED),
            BatchJournal(root).load(original.id)!!.rows.map { it.status })
    }

    @Test fun discardRemovesSnapshotLogAndFrozenInputs() {
        val journal = BatchJournal(root)
        journal.save(job())
        File(root, "fixture/inputs").mkdirs()
        journal.discard("fixture")
        assertFalse(journal.contains("fixture"))
        assertTrue(root.listFiles()!!.isEmpty())
    }

    @Test fun readableRecoveryRemainsDiscoverableWhenCompactionCannotResetLog() {
        val journal = BatchJournal(root)
        val original = job()
        journal.save(original)
        log().delete()
        log().mkdir()
        File(log(), "block").writeText("Prevent log replacement")
        assertEquals(original, journal.load(original.id))
        assertEquals(listOf(original.id), journal.pending())
    }

    @Test fun failedCompactionInvalidatesWriterBeforeTheNextRowCheckpoint() {
        val journal = BatchJournal(root)
        val original = job()
        journal.save(original)
        val staleLog = log().readBytes()
        log().delete()
        log().mkdir()
        File(log(), "block").writeText("Prevent log replacement")
        val newer = original.withRows(original.rows.map { it.copy(status = BatchRowStatus.CANCELLED) })
        assertThrows(IOException::class.java) { journal.save(newer) }
        log().deleteRecursively()
        log().writeBytes(staleLog)
        val latest = newer.withRows(newer.rows.mapIndexed { i, row -> if (i == 0) row.copy(status = BatchRowStatus.SUCCESS) else row })
        journal.recordRow(latest, 0)
        assertEquals(latest, BatchJournal(root).load(original.id))
    }

    @Test fun runnerPersistsUriBeforePublishingAndKeepsCancelAndGlobalFailureSnapshots() {
        val original = job()
        val journal = BatchJournal(root)
        var published = 0
        val cancelled = BatchRunner.run(original, { _, _ -> Unit }, { _, _, _ -> }, journal = journal,
            shouldCancel = { published == 1 },
            publish = { _, _, _, checkpoint ->
                checkpoint("content://output/first")
                val persisted = BatchJournal(root).load(original.id)!!.rows.first()
                assertEquals(BatchRowStatus.NEEDS_CONFIRMATION, persisted.status)
                assertEquals("content://output/first", persisted.outputUri)
                assertFalse(persisted.outputReady)
                published++
            })
        assertEquals(listOf(BatchRowStatus.SUCCESS, BatchRowStatus.CANCELLED), cancelled.rows.map { it.status })
        assertEquals(cancelled, BatchJournal(root).load(original.id))
        val failed = BatchRunner.run(original, { target, _ ->
            if (target.id == "target-1") throw com.rawlab.android.photo.BatchGlobalFailure("disk full")
            Unit
        }, { _, _, _ -> }, journal = journal)
        assertEquals("disk full", failed.globalError)
        assertEquals(listOf(BatchRowStatus.SUCCESS, BatchRowStatus.FAILED), failed.rows.map { it.status })
        assertEquals(failed, BatchJournal(root).load(original.id))
    }
}
