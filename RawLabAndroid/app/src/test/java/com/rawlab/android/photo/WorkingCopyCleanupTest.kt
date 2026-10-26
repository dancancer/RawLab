package com.rawlab.android.photo

import com.rawlab.android.batch.*
import com.rawlab.android.batch.journal.BatchJournal
import com.rawlab.android.settings.*
import java.io.File
import java.nio.file.Files
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

class WorkingCopyCleanupTest {
    @Test fun onlyUnreferencedSessionDirectoriesAreRemovedAndJournalsStayUntouched() {
        val root = Files.createTempDirectory("rawlab-cleanup").toFile()
        try {
            val cache = File(root, "cache").apply { mkdirs() }; val jobs = File(root, "jobs")
            fun working() = File(cache, "rawlab-${UUID.randomUUID()}").apply { mkdirs(); resolve("source.raw").writeText("raw") }
            val orphan = working(); val source = working(); val target = working(); val look = working()
            val unrelated = File(cache, "other-cache").apply { mkdirs() }
            val journal = BatchJournal(jobs)
            val job = BatchJob(BatchSourceSnapshot(PhotoIdentity("source"), source.resolve("source.raw"), EditSettings(), lookFile = look.resolve("source.raw")),
                listOf(BatchTarget(PhotoIdentity("target"), target.resolve("source.raw"), "photo.raw")))
            journal.save(job.withRows(job.rows.map { it.copy(status = BatchRowStatus.SUCCESS) }))
            val before = jobs.listFiles()!!.associate { it.name to it.readBytes().toList() }
            WorkingCopyCleanup.atProcessStart(cache, jobs)
            assertFalse(orphan.exists()); assertTrue(source.exists()); assertTrue(target.exists()); assertTrue(look.exists()); assertTrue(unrelated.exists())
            assertEquals(before, jobs.listFiles()!!.associate { it.name to it.readBytes().toList() })
            val retained = working()
            jobs.resolve("broken.properties").writeText("bad snapshot")
            WorkingCopyCleanup.atProcessStart(cache, jobs)
            assertTrue(retained.exists())
        } finally { root.deleteRecursively() }
    }
}
