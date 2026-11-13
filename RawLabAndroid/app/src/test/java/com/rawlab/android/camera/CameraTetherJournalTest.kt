package com.rawlab.android.camera

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.nio.file.Files

class CameraTetherJournalTest {
    private fun photo(id: Int, suffix: String = "ARW") = CameraPhoto("key-$id-$suffix", "DSC%05d.%s".format(id, suffix), 100, 42)
    private fun withJournal(block: (File, CameraTetherJournal) -> Unit) {
        val root = Files.createTempDirectory("camera-tether-journal").toFile()
        try { block(root, CameraTetherJournal(root)) } finally { root.deleteRecursively() }
    }

    @Test fun emptyBaselineAllowsFirstPhotoAndRawJpegAreSeparate() = withJournal { _, journal ->
        val initial = journal.create("camera", "sony-test", emptyList(), CameraImportDestination())
        val (reserved, batch) = journal.reserve(initial, listOf(photo(1), photo(1, "JPG"), photo(1)))
        assertEquals(reserved.batches.single(), batch)
        assertEquals(listOf(photo(1), photo(1, "JPG")), reserved.batches.single().photos)
        assertEquals(reserved to null, journal.reserve(reserved, listOf(photo(1, "JPG"), photo(1))))
    }

    @Test fun discoveryIsDurableBeforeJobCreationAndFreezesDestination() = withJournal { root, journal ->
        val destination = CameraImportDestination("RawLab/Shoot", CameraDirectoryGrouping.CAPTURE_MONTH)
        val initial = journal.create("camera", "sony-test", listOf(photo(1)), destination)
        val reserved = journal.reserve(initial, listOf(photo(1), photo(2))).first
        val recovered = CameraTetherJournal(root).load().single()
        assertEquals(CameraTetherStatus.PAUSED, recovered.status)
        assertEquals(reserved.id, recovered.id)
        assertEquals(reserved.batches, recovered.batches)
        assertEquals(destination, recovered.destination)
        assertEquals("sony-test", recovered.profileId)
        assertEquals(listOf(photo(1)), recovered.baseline)
        assertEquals(recovered, CameraTetherJournal(root).load().single())
    }

    @Test fun boundedBatchesDoNotLoseFurtherDiscoveries() = withJournal { _, journal ->
        var run = journal.create("camera", "sony-test", listOf(photo(0)), CameraImportDestination())
        val current = (0..20).map(::photo)
        run = journal.reserve(run, current).first
        assertEquals(16, run.batches.single().photos.size)
        run = journal.reserve(run, current.reversed()).first
        assertEquals(20, run.batches.sumOf { it.photos.size })
        assertEquals(2, run.batches.map { it.id }.distinct().size)
        assertEquals(20, run.batches.flatMap { it.photos }.map { it.key }.distinct().size)
    }

    @Test fun conflictingMetadataAfterBatchLimitFailsWithoutWritingPartialDiscovery() = withJournal { root, journal ->
        val run = journal.create("camera", "sony-test", listOf(photo(0)), CameraImportDestination())
        val current = (1..20).map(::photo) + photo(0).copy(size = 200)
        assertThrows(IOException::class.java) { journal.reserve(run, current) }
        assertTrue(CameraTetherJournal(root).load().single().batches.isEmpty())
        assertThrows(IOException::class.java) { journal.reserve(run, listOf(photo(1), photo(1).copy(name = "other.ARW"))) }
    }

    @Test fun sameTimestampDoesNotHideNewObjectsAndEndedRunCannotResumeDiscovery() = withJournal { _, journal ->
        val initial = journal.create("camera", "sony-test", listOf(photo(1)), CameraImportDestination())
        val run = journal.reserve(initial, listOf(photo(1), photo(2))).first
        assertEquals(photo(2), run.batches.single().photos.single())
        val ended = run.copy(status = CameraTetherStatus.ENDED).also(journal::save)
        assertThrows(IOException::class.java) { journal.reserve(ended, listOf(photo(3))) }
    }

    @Test fun resumeOnlyKeepsRegisteredBatchesAndRebasesOfflinePhotos() = withJournal { _, journal ->
        val initial = journal.create("camera", "sony-test", listOf(photo(1)), CameraImportDestination())
        val registered = journal.reserve(initial, listOf(photo(1), photo(2))).first.copy(shutterRequestedAt = 42)
        val resumed = journal.rebase(registered, listOf(photo(1), photo(2), photo(3)))
        assertEquals(registered.batches, resumed.batches)
        assertNull(resumed.shutterRequestedAt)
        assertEquals(listOf(photo(1), photo(2), photo(3)), resumed.baseline)
        assertNull(journal.reserve(resumed, listOf(photo(1), photo(2), photo(3))).second)
        assertEquals(listOf(photo(4)), journal.reserve(resumed, listOf(photo(1), photo(2), photo(3), photo(4))).second!!.photos)
        assertThrows(IOException::class.java) { journal.rebase(registered, listOf(photo(2), photo(3))) }
    }

    @Test fun malformedOrUnknownVersionIsNotSilentlyDiscarded() = withJournal { root, journal ->
        val kept = journal.create("camera", "sony-test", emptyList(), CameraImportDestination())
        val run = journal.create("camera", "sony-test", emptyList(), CameraImportDestination())
        val file = File(root, "${run.id}.json")
        for (damaged in listOf("{broken", "{\"version\":99}")) {
            file.writeText(damaged)
            assertEquals(kept.id, CameraTetherJournal(root).load().single().id)
            assertEquals(damaged, file.readText())
        }
    }

    @Test fun missingBaselineOrReusedHandleCannotTurnAChangedCardIntoNewPhotos() = withJournal { root, journal ->
        val run = journal.create("camera", "sony-test", listOf(photo(1)), CameraImportDestination())
        assertThrows(IOException::class.java) { journal.reserve(run, listOf(photo(2))) }
        assertThrows(IOException::class.java) { journal.reserve(run, listOf(photo(1).copy(key = "reused-handle", size = 200))) }
        assertTrue(CameraTetherJournal(root).load().single().batches.isEmpty())
    }

    @Test fun invalidPhotoMetadataAndDuplicateBatchIdsAreRejected() = withJournal { _, journal ->
        val run = journal.create("camera", "sony-test", emptyList(), CameraImportDestination())
        for (invalid in listOf(photo(1).copy(size = 0), photo(1).copy(name = "../raw.ARW"), photo(1).copy(key = ""))) {
            assertThrows(IOException::class.java) { journal.reserve(run, listOf(invalid)) }
        }
        val reserved = journal.reserve(run, listOf(photo(1))).first
        assertThrows(IOException::class.java) { journal.save(reserved.copy(batches = reserved.batches + reserved.batches)) }
    }

    @Test fun cardExceeding10000ObjectsThrowsPhotoLimitExceededException() = withJournal { _, journal ->
        val run = journal.create("camera", "sony-test", emptyList(), CameraImportDestination())
        val oversized = (1..10_001).map(::photo)
        assertThrows(com.rawlab.android.camera.protocol.CameraMediaSession.PhotoLimitExceededException::class.java) {
            journal.reserve(run, oversized)
        }
        assertThrows(com.rawlab.android.camera.protocol.CameraMediaSession.PhotoLimitExceededException::class.java) {
            journal.rebase(run, oversized)
        }
    }
}
