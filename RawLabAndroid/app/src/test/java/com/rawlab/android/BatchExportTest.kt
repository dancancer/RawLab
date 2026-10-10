package com.rawlab.android

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class BatchExportTest {
    @Test fun olderSnapshotsDefaultToDisabledDenoise() {
        val settings = SettingsCodec.decode("neutral|1.0|0.0|0.0|0.0|0.0|0.0|0.0|false|6500.0|0.0|0.0")
        assertEquals(DenoiseSettings(), settings.denoise)
    }

    @Test fun pngResumeAndPublishingCheckpointAreDurable() {
        val root = Files.createTempDirectory("rawlab-recovery").toFile()
        try {
            val source = BatchSourceSnapshot(PhotoIdentity("source"), File(root, "s.raw"),
                EditSettings(denoise = DenoiseSettings(true, 10f, 72f, 100f)))
            val job = BatchJob(source, (1..2).map { BatchTarget(PhotoIdentity("$it"), File(root, "$it.raw"), "$it.raw") }, outputPng = true)
            assertTrue(job.rows.all { it.outputName.endsWith(".png") })
            val journal = BatchJournal(root)
            var writes = 0
            val updates = mutableListOf<BatchJob>()
            val stopped = BatchRunner.run(job, { _, _ -> byteArrayOf(1) }, { _, _, _ -> },
                shouldCancel = { writes == 1 }, journal = journal, didUpdate = { updates += it },
                publish = { _, _, _, checkpoint -> writes++; checkpoint("content://output/$writes") })
            assertEquals(1, stopped.rows.count { it.status == BatchRowStatus.SUCCESS })
            assertTrue(updates.any { it.rows[0].status == BatchRowStatus.PUBLISHING && it.rows[0].outputUri != null })
            assertEquals(listOf(job.id), journal.pending())
            assertEquals(source.settings, journal.load(job.id)!!.source.settings)
            val resumed = BatchRunner.run(journal.load(job.id)!!, { _, _ -> byteArrayOf(1) }, { _, _, _ -> writes++ })
            assertEquals(2, writes)
            assertTrue(resumed.rows.all { it.status == BatchRowStatus.SUCCESS })
            val uncertain = job.withRows(job.rows.map { it.copy(status = BatchRowStatus.PUBLISHING) })
            journal.save(uncertain)
            val recovered = journal.load(job.id)!!
            assertTrue(recovered.rows.all { it.status == BatchRowStatus.NEEDS_CONFIRMATION })
            BatchRunner.run(recovered, { _, _ -> error("must not rerender unknown publication") }, { _, _, _ -> error("must not publish") })
        } finally { root.deleteRecursively() }
    }
    @Test fun sourceSnapshotIsImmutableAndTargetsHaveIndependentRows() {
        val root = Files.createTempDirectory("rawlab-batch").toFile()
        try {
            val source = BatchSourceSnapshot(PhotoIdentity("source"), File(root, "source.raw"),
                EditSettings(exposure = .75f, denoise = DenoiseSettings(true, 10f, 72f, 100f)))
            val targets = (1..6).map { BatchTarget(PhotoIdentity("target-$it"), File(root, "same.raw"), "same.raw") }
            var job = BatchJob(source, targets)
            var settingsSeen = EditSettings()
            job = BatchRunner.run(job, render = { _, settings -> settingsSeen = settings; ByteArray(1) }, write = { _, _, _ -> })
            assertEquals(.75f, settingsSeen.exposure)
            assertEquals(source.settings.denoise, settingsSeen.denoise)
            assertEquals(6, job.rows.count { it.status == BatchRowStatus.SUCCESS })
            assertEquals(6, job.rows.map { it.outputName }.toSet().size)
        } finally { root.deleteRecursively() }
    }

    @Test fun failuresContinueCancellationPreservesSuccessAndRetrySkipsSuccesses() {
        val root = Files.createTempDirectory("rawlab-batch").toFile()
        try {
            val source = BatchSourceSnapshot(PhotoIdentity("source"), File(root, "source.raw"), EditSettings())
            val targets = (1..6).map { BatchTarget(PhotoIdentity("target-$it"), File(root, "$it.raw"), "$it.raw") }
            var job = BatchJob(source, targets)
            var failed = true
            job = BatchRunner.run(job, render = { target, _ ->
                if (target.id == "target-3" && failed) throw IllegalStateException("fixture")
                ByteArray(1)
            }, write = { _, _, _ -> })
            assertEquals(5, job.rows.count { it.status == BatchRowStatus.SUCCESS })
            assertEquals(1, job.rows.count { it.status == BatchRowStatus.FAILED })
            val successCount = job.rows.count { it.status == BatchRowStatus.SUCCESS }
            failed = false
            job = BatchRunner.retryFailed(job, render = { _, _ -> ByteArray(1) }, write = { _, _, _ -> })
            assertEquals(6, job.rows.count { it.status == BatchRowStatus.SUCCESS })
            assertEquals(successCount, 5)

            var cancelled = BatchJob(source, targets)
            var writes = 0
            cancelled = BatchRunner.run(cancelled, render = { _, _ -> ByteArray(1) }, write = { _, _, _ -> writes++ }, shouldCancel = { writes >= 2 })
            assertEquals(2, cancelled.rows.count { it.status == BatchRowStatus.SUCCESS })
            assertTrue(cancelled.rows.drop(2).all { it.status == BatchRowStatus.CANCELLED })
        } finally { root.deleteRecursively() }
    }

    @Test fun journalRoundTripsPendingRowsAndDropsCompletedJobs() {
        val root = Files.createTempDirectory("rawlab-journal").toFile()
        try {
            val source = BatchSourceSnapshot(PhotoIdentity("source"), File(root, "source.raw"), EditSettings())
            val job = BatchJob(source, listOf(BatchTarget(PhotoIdentity("target"), File(root, "target.raw"), "target.raw")))
            val journal = BatchJournal(root)
            journal.save(job)
            assertEquals(job.id, journal.load(job.id)?.id)
            assertEquals(listOf(job.id), journal.pending())
            val done = BatchRunner.run(job, render = { _, _ -> byteArrayOf(1) }, write = { _, _, _ -> }, journal = journal)
            assertEquals(BatchRowStatus.SUCCESS, done.rows.single().status)
            assertTrue(journal.pending().isEmpty())
        } finally { root.deleteRecursively() }
    }

    @Test fun journalRoundTripsRequestedOutputLongEdge() {
        val root = Files.createTempDirectory("rawlab-size").toFile()
        try {
            val source = BatchSourceSnapshot(PhotoIdentity("source"), File(root, "source.raw"), EditSettings())
            val job = BatchJob(source, listOf(BatchTarget(PhotoIdentity("target"), File(root, "target.raw"), "target.raw")),
                outputLongEdge = 3000)
            val journal = BatchJournal(root)
            journal.save(job)
            assertEquals(3000, journal.load(job.id)?.outputLongEdge)
        } finally { root.deleteRecursively() }
    }
}
