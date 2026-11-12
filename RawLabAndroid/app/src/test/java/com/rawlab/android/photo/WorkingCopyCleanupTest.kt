package com.rawlab.android.photo

import com.rawlab.android.batch.*
import com.rawlab.android.batch.journal.BatchJournal
import com.rawlab.android.engine.exportStagingFile
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

    @Test fun transientExportCleanupRemovesRenderAndPartFilesAcrossRootsWithoutTouchingUserOrAppFiles() {
        val root = Files.createTempDirectory("rawlab-export-cleanup").toFile()
        try {
            val cache = File(root, "cache").apply { mkdirs() }
            val files = File(root, "files").apply { mkdirs() }
            val jobs = File(files, "RawLab/BatchJobs").apply { mkdirs() }
            val external = File(root, "external").apply { mkdirs() }

            val shouldDelete = setOf(
                File.createTempFile("render-", ".jpg", files).apply { writeText("half-jpg") },
                File(files, "render-abandoned-${UUID.randomUUID()}.png").apply { writeText("half-png") },
                File(files, "render-987654.dng").apply { writeText("half-dng") },
                exportStagingFile(files, "render-12345.jpg", ".jpg").apply { writeText("part-jpg") },
                exportStagingFile(files, "render-987654.dng", ".dng").apply { writeText("part-dng") },
                exportStagingFile(files, "custom-target", "").apply { writeText("part-no-ext") },
                exportStagingFile(cache, "export-444.png", ".png").apply { writeText("cache-part") },
                File(cache, "render-cache-111.jpg").apply { writeText("cache-render") },
            )

            val outsideUserPhoto = File(external, "user-original.jpg").apply { writeText("original-photo") }
            val symlinkInFiles = File(files, "render-symlink.jpg").also {
                Files.createSymbolicLink(it.toPath(), outsideUserPhoto.toPath())
            }
            val directoryNamedLikeRender = File(files, "render-dir.jpg").apply {
                mkdirs()
                resolve("keep.txt").writeText("keep-dir")
            }
            val nestedSystemPhoto = File(files, "system-photos/render-imported.jpg").apply {
                parentFile!!.mkdirs()
                writeText("managed-user-photo")
            }
            val shouldKeep = listOf(
                File(files, "DSC00001.ARW").apply { writeText("raw") },
                File(files, "family.jpg").apply { writeText("jpg") },
                File(files, "render.jpg").apply { writeText("not-prefix") },
                File(files, "render-notes.txt").apply { writeText("not-image-ext") },
                File(files, "vacation.part.jpg").apply { writeText("user-part-name") },
                File(files, ".hidden.part").apply { writeText("hidden-no-uuid") },
                File(files, ".hidden.part.jpg").apply { writeText("hidden-no-uuid-jpg") },
                File(files, "batch-gpu-test-cleanup.properties").apply { writeText("pid=1") },
                File(files, ".import-${UUID.randomUUID()}.pending").apply { writeText("look-marker") },
                File(files, ".${UUID.randomUUID()}.stage.rlook").apply { writeText("look-stage") },
                nestedSystemPhoto,
                outsideUserPhoto,
            )

            val discovered = WorkingCopyCleanup.transientExportFiles(listOf(cache, files, files))
            assertEquals(
                shouldDelete.map { it.canonicalFile }.toSet(),
                discovered.map { it.canonicalFile }.toSet(),
            )

            WorkingCopyCleanup.atProcessStart(cache, jobs, listOf(cache, files))

            for (deleted in shouldDelete) {
                assertFalse("Expected transient file to be deleted: ${deleted.name}", deleted.exists())
            }
            for (kept in shouldKeep) {
                assertTrue("Expected non-transient file to be preserved: ${kept.path}", kept.isFile)
            }
            assertTrue(directoryNamedLikeRender.isDirectory)
            assertTrue(Files.isSymbolicLink(symlinkInFiles.toPath()))
            assertEquals("original-photo", outsideUserPhoto.readText())
        } finally { root.deleteRecursively() }
    }
}
