package com.rawlab.android.batch.journal

import com.rawlab.android.batch.BatchJob
import com.rawlab.android.batch.BatchRunner
import com.rawlab.android.batch.BatchSourceSnapshot
import com.rawlab.android.batch.BatchTarget
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.PhotoIdentity
import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class BatchJournalScalingTest {
    @Test fun freshRunWritesLinearBytesWithoutDroppingCheckpoints() {
        val small = writtenBytes(100)
        val large = writtenBytes(300)
        assertTrue("100 rows=$small bytes, 300 rows=$large bytes", large < small * 4)
    }

    private fun writtenBytes(count: Int): Long {
        val root = Files.createTempDirectory("batch-scaling").toFile()
        try {
            val source = BatchSourceSnapshot(PhotoIdentity("source"), File("/input/source.raw"), EditSettings())
            val job = BatchJob(source, (1..count).map {
                BatchTarget(PhotoIdentity("target-$it"), File("/input/$it.raw"), "$it.raw")
            }, id = "scaling")
            var checkpoints = 0
            var bytes = 0L
            var previousLog = 0L
            BatchRunner.run(job, { _, _ -> Unit }, { _, _, _ -> }, journal = BatchJournal(root),
                publish = { _, _, target, checkpoint -> checkpoint("content://output/${target.id}") },
                didUpdate = {
                    val log = File(root, "${job.id}.rows")
                    val length = log.length()
                    bytes += if (!log.exists() || checkpoints == 0) File(root, "${job.id}.properties").length() + length
                        else length - previousLog
                    previousLog = length
                    checkpoints++
                })
            assertEquals(5 * count + 1, checkpoints)
            return bytes
        } finally { root.deleteRecursively() }
    }
}
