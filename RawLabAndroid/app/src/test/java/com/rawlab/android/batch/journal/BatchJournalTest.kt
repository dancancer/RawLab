package com.rawlab.android.batch.journal

import com.rawlab.android.batch.*
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.PhotoIdentity
import java.io.File
import java.util.Properties
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
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
        val logBytes = log().readBytes()
        assertEquals(recovered, BatchJournal(root).load(original.id))
        assertArrayEquals(logBytes, log().readBytes())
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
        val snapshot = File(root, "fixture.properties").readBytes()
        log().writeBytes(staleLog)
        repeat(2) {
            assertEquals(newer, BatchJournal(root).load(original.id))
            assertArrayEquals(snapshot, File(root, "fixture.properties").readBytes())
            assertArrayEquals(staleLog, log().readBytes())
        }
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

    @Test fun loadAndPendingLeaveSnapshotAndLogBytesUntouched() {
        val writer = BatchJournal(root)
        val original = job()
        writer.save(original)
        val current = original.withRows(listOf(
            original.rows[0].copy(status = BatchRowStatus.PROCESSING),
            original.rows[1].copy(status = BatchRowStatus.PUBLISHING, outputUri = "content://output/1", outputReady = true)))
        writer.recordRow(current, 0)
        writer.recordRow(current, 1)
        log().appendBytes(byteArrayOf(1, 2, 3))
        val snapshot = File(root, "fixture.properties").readBytes()
        val logBytes = log().readBytes()
        val reader = BatchJournal(root)
        repeat(2) {
            val recovered = reader.load(original.id)!!
            assertEquals(listOf(BatchRowStatus.PENDING, BatchRowStatus.NEEDS_CONFIRMATION), recovered.rows.map { it.status })
            assertEquals("content://output/1", recovered.rows[1].outputUri)
            assertTrue(recovered.rows[1].outputReady)
            assertArrayEquals(snapshot, File(root, "fixture.properties").readBytes())
            assertArrayEquals(logBytes, log().readBytes())
            assertEquals(listOf(original.id), reader.pending())
            assertArrayEquals(snapshot, File(root, "fixture.properties").readBytes())
            assertArrayEquals(logBytes, log().readBytes())
        }
    }

    @Test fun anotherReaderDoesNotInterruptWritersPublicationCheckpoints() {
        val writer = BatchJournal(root)
        val original = job(3)
        writer.save(original)
        val snapshot = File(root, "fixture.properties").readBytes()
        val reader = BatchJournal(root)
        var current = original
        repeat(2) { index ->
            current = current.withRows(current.rows.mapIndexed { i, row ->
                if (i == index) row.copy(status = BatchRowStatus.PUBLISHING, outputUri = "content://output/$index") else row
            })
            writer.recordRow(current, index)
            val durablePrefix = log().readBytes()
            assertEquals(BatchRowStatus.NEEDS_CONFIRMATION, reader.load(original.id)!!.rows[index].status)
            current = current.withRows(current.rows.mapIndexed { i, row -> if (i == index) row.copy(outputReady = true) else row })
            writer.recordRow(current, index)
            current = current.withRows(current.rows.mapIndexed { i, row -> if (i == index) row.copy(status = BatchRowStatus.SUCCESS) else row })
            writer.recordRow(current, index)
            assertArrayEquals("Reading must not force the writer to replace its snapshot", snapshot, File(root, "fixture.properties").readBytes())
            val appended = log().readBytes()
            assertTrue(appended.size > durablePrefix.size)
            assertArrayEquals(durablePrefix, appended.copyOf(durablePrefix.size))
        }
        val recovered = BatchJournal(root).load(original.id)!!
        assertEquals(current, recovered)
        assertEquals(listOf(BatchRowStatus.SUCCESS, BatchRowStatus.SUCCESS, BatchRowStatus.PENDING), recovered.rows.map { it.status })
        assertEquals(listOf("content://output/0", "content://output/1", null), recovered.rows.map { it.outputUri })
        assertEquals(listOf(true, true, false), recovered.rows.map { it.outputReady })
    }

    @Test fun resumingV2JournalCompactsAtRunStartBeforeRendering() {
        val original = job().let { base -> base.withRows(listOf(
            base.rows[0].copy(status = BatchRowStatus.SUCCESS, outputUri = "content://output/0", outputReady = true),
            base.rows[1].copy(status = BatchRowStatus.CANCELLED))) }
        writeV2Fixture(root, original)
        val snapshotFile = File(root, "fixture.properties")
        val v2Snapshot = snapshotFile.readBytes()
        val loaded = BatchJournal(root).load(original.id)!!
        assertArrayEquals(v2Snapshot, snapshotFile.readBytes())
        assertFalse(log().exists())
        var initialSnapshot: ByteArray? = null
        var initialLogLength = 0L
        val resumed = BatchRunner.run(loaded, { target, _ ->
            assertEquals("target-1", target.id)
            assertNotNull("Run-start checkpoint must precede rendering", initialSnapshot)
            Unit
        }, { _, _, _ -> }, journal = BatchJournal(root), didUpdate = {
            if (initialSnapshot == null) {
                val properties = Properties().also { values -> snapshotFile.inputStream().use(values::load) }
                assertEquals("4", properties.getProperty("journal.version"))
                assertFalse(properties.getProperty("journal.generation").isNullOrEmpty())
                assertEquals("CANCELLED", properties.getProperty("row.1.status"))
                initialSnapshot = snapshotFile.readBytes()
                initialLogLength = log().length()
                assertTrue(initialLogLength > 0)
            }
        })
        assertEquals(listOf(BatchRowStatus.SUCCESS, BatchRowStatus.SUCCESS), resumed.rows.map { it.status })
        assertArrayEquals(initialSnapshot, snapshotFile.readBytes())
        assertTrue(log().length() > initialLogLength)
        assertEquals(resumed, BatchJournal(root).load(original.id))
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

    @Test fun corruptEntryIsIsolatedAndDoesNotBlockPendingOrSubsequentSave() {
        val journal = BatchJournal(root)
        val validJob = job().copy(id = "valid-job")
        journal.save(validJob)

        val corruptFile = File(root, "corrupt-job.properties")
        corruptFile.writeText("journal.version=bad\nincomplete-data")
        val corruptRows = File(root, "corrupt-job.rows")
        corruptRows.writeBytes(byteArrayOf(0, 1, 2, 3))

        val pendingJobs = journal.pending()
        assertEquals(listOf("valid-job"), pendingJobs)
        assertFalse("Corrupt properties file must be quarantined from its active path", corruptFile.exists())
        assertFalse("Corrupt rows log must be quarantined from its active path", corruptRows.exists())
        val quarantined = root.listFiles()?.filter { it.name.startsWith("corrupt-job.properties.corrupt-") }.orEmpty()
        assertEquals("Quarantined corrupt properties file must exist", 1, quarantined.size)
        val quarantinedRows = root.listFiles()?.filter { it.name.startsWith("corrupt-job.rows.corrupt-") }.orEmpty()
        assertEquals("Quarantined corrupt rows log must exist", 1, quarantinedRows.size)
        assertTrue("Quarantine must expose the moved names for callers and diagnostics",
            journal.lastQuarantinedPaths.any { it.startsWith("corrupt-job.properties.corrupt-") } &&
                journal.lastQuarantinedPaths.any { it.startsWith("corrupt-job.rows.corrupt-") })

        val anotherJob = job().copy(id = "another-job")
        journal.save(anotherJob)
        assertEquals(setOf("valid-job", "another-job"), journal.pending().toSet())
    }

    @Test fun saveWithSameIdQuarantinesCorruptJournalAndRowsWithoutPendingScan() {
        val journal = BatchJournal(root)
        val corruptID = "same-id-job"
        val corruptFile = File(root, "$corruptID.properties")
        corruptFile.writeText("journal.version=bad\nrow.count=x{")
        val corruptRows = File(root, "$corruptID.rows")
        corruptRows.writeBytes(byteArrayOf(9, 8, 7))

        // No pending() scan first: save() must isolate the corrupt same-ID journal via load(id:).
        val job = job().copy(id = corruptID)
        journal.save(job)

        // save() rewrites the same paths with valid data; the old corrupt bytes must live on only in the isolates.
        val movedProperties = root.listFiles()?.filter { it.name.startsWith("$corruptID.properties.corrupt-") }.orEmpty()
        val movedRows = root.listFiles()?.filter { it.name.startsWith("$corruptID.rows.corrupt-") }.orEmpty()
        assertEquals("save must isolate the corrupt properties file", 1, movedProperties.size)
        assertEquals("save must isolate the corrupt rows log", 1, movedRows.size)
        assertTrue("Isolated properties must keep the corrupt bytes", movedProperties[0].readText().contains("row.count=x{"))
        assertTrue("save must expose isolated names through lastQuarantinedPaths",
            journal.lastQuarantinedPaths.any { it.startsWith("$corruptID.properties.corrupt-") } &&
                journal.lastQuarantinedPaths.any { it.startsWith("$corruptID.rows.corrupt-") })
        assertEquals(listOf(corruptID), journal.pending())
        assertEquals(job, journal.load(corruptID))
    }

    @Test fun futureTopJournalVersionRefusesQuarantineAndOverwrite() {
        val journal = BatchJournal(root)
        val id = "future-top"
        val record = File(root, "$id.properties")
        record.writeText("journal.version=${JournalCodec.VERSION + 5}\nrow.count=0\n")

        var thrown = false
        try { journal.pending() } catch (error: Exception) {
            assertTrue("Future-version load must fail as a hard error", error is java.io.IOException)
            thrown = true
        }
        assertTrue("pending must refuse to quarantine a future-version journal", thrown)
        assertTrue("Future-version journal must stay on its active path", record.exists())
        assertTrue(root.listFiles()?.none { it.name.contains(".corrupt-") } ?: true)

        var saveThrown = false
        try { journal.save(job().copy(id = id)) } catch (_: Exception) { saveThrown = true }
        assertTrue("save must refuse to overwrite a future-version journal", saveThrown)
        assertTrue("Rejected save must leave the future journal untouched", record.exists())
    }

    @Test fun futureFrozenVersionRefusesQuarantine() {
        val frozenRoot = temporary.newFolder("frozen-case")
        val journal = BatchJournal(frozenRoot)
        val id = "future-frozen"
        val frozenJob = BatchJob(
            BatchSourceSnapshot(PhotoIdentity("source"), File("/source.jpg"), EditSettings(exposure = .75f),
                lookFile = File("/look.cube"), inputKind = PhotoInputKind.RASTER),
            (0 until 2).map { BatchTarget(PhotoIdentity("target-$it"), File("/$it.raw"), "$it.raw", "content://input/$it",
                frozen = BatchFrozenSettings(ordinal = it, settings = EditSettings(), inputSHA256 = "a".repeat(64),
                    outputFormat = ExportFormat.DNG, longEdge = 3000)) },
            id = id, outputFormat = ExportFormat.DNG, outputLongEdge = 3000,
            destination = "content://tree/output", settingsMode = BatchSettingsMode.PER_TARGET_FROZEN)
        journal.save(frozenJob)

        // A future frozen entry version is a recognizable-but-newer record, not corruption.
        val record = File(frozenRoot, "$id.properties")
        val properties = Properties().also { record.inputStream().use(it::load) }
        properties.setProperty("row.0.frozen.version", "2")
        record.outputStream().use { properties.store(it, null) }

        var thrown = false
        try { journal.pending() } catch (_: Exception) { thrown = true }
        assertTrue("pending must refuse to quarantine a future frozen entry version", thrown)
        assertTrue("Future frozen journal must stay on its active path", record.exists())
        assertTrue(frozenRoot.listFiles()?.none { it.name.contains(".corrupt-") } ?: true)

        var saveThrown = false
        try { journal.save(frozenJob) } catch (_: Exception) { saveThrown = true }
        assertTrue("save must refuse to overwrite a future frozen version record", saveThrown)
    }

    @Test fun futureProcessingVersionInSettingsRefusesQuarantine() {
        val settingsRoot = temporary.newFolder("processing-case")
        val journal = BatchJournal(settingsRoot)
        val id = "future-processing"
        val validJob = job().copy(id = id)
        journal.save(validJob)

        // Bump only the processed-image version inside source.settings to a future value.
        val record = File(settingsRoot, "$id.properties")
        val properties = Properties().also { record.inputStream().use(it::load) }
        val settings = properties.getProperty("source.settings")
        assertTrue("Fixture must carry a processing identity version", settings.contains("\"version\":3"))
        properties.setProperty("source.settings", settings.replace("\"version\":3", "\"version\":9"))
        record.outputStream().use { properties.store(it, null) }

        var thrown = false
        try { journal.pending() } catch (_: Exception) { thrown = true }
        assertTrue("pending must refuse to quarantine a future processing version", thrown)
        assertTrue("Journal with a future processing version must stay on its active path", record.exists())
        assertTrue(settingsRoot.listFiles()?.none { it.name.contains(".corrupt-") } ?: true)
    }

    @Test fun quarantineRenameFailurePropagatesInsteadOfSilentOverwrite() {
        val journal = BatchJournal(root)
        val id = "locked-corrupt"
        val record = File(root, "$id.properties")
        record.writeText("journal.version=bad\n{broken")
        File(root, "write-probe").writeText("probe")
        root.setWritable(false)
        try {
            assumeTrue("filesystem must enforce directory write permission for this anchor",
                !File(root, "write-probe").renameTo(File(root, "write-probe-moved")))
            var thrown = false
            try { journal.pending() } catch (error: Exception) {
                thrown = error is java.io.IOException
            }
            assertTrue("pending must report a failed quarantine rename instead of swallowing it", thrown)
            assertTrue("Un-renameable corrupt record must remain for manual recovery", record.exists())
        } finally {
            root.setWritable(true)
        }
    }
}
