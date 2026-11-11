package com.rawlab.android.camera

import com.rawlab.android.photo.MediaPhoto
import com.rawlab.android.photo.MediaPhotoAccess
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.security.MessageDigest

class CameraImportStoreTest {
    private val raw = byteArrayOf(73, 73, 42, 0, 8, 0, 0, 0) + ByteArray(100) { it.toByte() }
    private fun photo(key: String = "1") = CameraPhoto(key, "DSC00001.ARW", raw.size.toLong(), 42)
    private fun hash(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    private class Fixture(val root: File) {
        val media = FileMedia(File(root, "media").apply { mkdirs() })
        var capture = CameraCaptureDate.parse("2026:10:22 18:28:03", "+08:00")
        fun store() = CameraImportStore(File(root, "jobs"), File(root, "partial"), media) { capture }
    }
    private fun withStore(test: (Fixture, CameraImportStore) -> Unit) {
        val root = Files.createTempDirectory("camera-store-test").toFile()
        try { val fixture = Fixture(root); test(fixture, fixture.store()) }
        finally { root.deleteRecursively() }
    }
    private fun save(store: CameraImportStore, bytes: ByteArray = raw, destination: CameraImportDestination = CameraImportDestination()): CameraImportJob {
        val job = store.create("camera", listOf(photo()), destination)
        val part = store.partial(job.id); part.writeBytes(bytes)
        return store.publish(job, 0, part, hash(bytes), CameraTransferPermit())
    }

    @Test fun interruptedQueueKeepsSavedMediaAndRestartsOnlyUnfinished() = withStore { fixture, store ->
        var job = store.create("camera", listOf(photo(), photo("2")), CameraImportDestination())
        val part = store.partial(job.id); part.writeBytes(raw)
        job = store.publish(job, 0, part, hash(raw), CameraTransferPermit())
        store.partial(job.id).writeText("incomplete")
        val reopened = fixture.store()
        val restored = reopened.load().single()
        assertEquals(CameraJobStatus.PAUSED, restored.status)
        assertEquals(job.items[0].saved, restored.items[0].saved)
        assertNull(restored.items[1].saved)
        assertArrayEquals(raw, fixture.media.open(reopened.savedUris(restored).single()).use { it.readBytes() })
        assertFalse(reopened.partial(job.id).exists())
        assertFalse(File(fixture.root, "originals").exists())
    }

    @Test fun resumeAcrossTransportsRequiresCameraSerialAndUnchangedPendingFiles() = withStore { fixture, store ->
        val camera = CameraHardwareIdentity("ILCE-7CM2", "1234567")
        val destination = CameraImportDestination("RawLab/Resume", CameraDirectoryGrouping.NONE)
        val first = photo("1").copy(resumeIdentity = "legacy:first")
        val pending = photo("2").copy(resumeIdentity = "legacy:second")
        val job = store.create("BLE:camera", listOf(first, pending), destination, hardwareIdentity = camera)
        val part = store.partial(job.id).apply { writeBytes(raw) }
        val saved = store.publish(job, 0, part, hash(raw), CameraTransferPermit()).items[0].saved
        part.writeText("interrupted")
        val reopened = fixture.store()
        val restored = reopened.load().single()

        assertTrue(restored.matchesCamera("SSID:camera", camera))
        assertFalse(restored.matchesCamera("SSID:camera", null))
        assertFalse(restored.matchesCamera("BLE:camera", camera.copy(serial = "7654321")))
        assertFalse(restored.matchesPendingPhotos(emptyMap()))
        assertFalse(restored.matchesPendingPhotos(mapOf(pending.key to pending.copy(resumeIdentity = "legacy:modified"))))
        assertTrue(restored.matchesPendingPhotos(mapOf(pending.key to pending)))

        var downloads = 0
        val resumed = receiveCameraJob(reopened, restored, CameraTransferPermit(), { current, output ->
            assertEquals(pending, current)
            assertEquals(0L, output.channel.position())
            downloads++
            val changedBytes = raw.copyOf().apply { this[lastIndex] = 100 }
            output.write(changedBytes)
            hash(changedBytes)
        })
        assertEquals(1, downloads)
        assertEquals(CameraJobStatus.COMPLETE, resumed.status)
        assertEquals(saved, resumed.items[0].saved)
        assertEquals(destination.relativePath(fixture.capture), resumed.items[1].saved!!.relativePath)
        assertEquals(camera, fixture.store().load().single().hardwareIdentity)
    }

    @Test fun historicalJobWithOnlyConnectionIdentityCanResumeOnThatConnection() = withStore { fixture, store ->
        val pending = photo()
        store.create("BLE:camera", listOf(pending), CameraImportDestination())
        val restored = fixture.store().load().single()
        val camera = CameraHardwareIdentity("ILCE-7CM2", "1234567")
        assertTrue(restored.matchesCamera("BLE:camera", camera))
        assertFalse(restored.matchesCamera("SSID:camera", camera))
        assertTrue(restored.matchesPendingPhotos(mapOf(pending.key to pending.copy(resumeIdentity = "mobile:current"))))
    }

    @Test fun stoppedPermitCannotPublishOrHandOffPartial() = withStore { fixture, store ->
        val job = store.create("camera", listOf(photo()), CameraImportDestination())
        val part = store.partial(job.id); part.writeBytes(raw)
        val permit = CameraTransferPermit(); permit.cancel()
        assertThrows(IOException::class.java) { store.publish(job, 0, part, hash(raw), permit) }
        assertTrue(store.savedUris(store.load().single()).isEmpty())
        assertTrue(fixture.media.rows.isEmpty())
    }

    @Test fun reservedTetherBatchIdReconnectsToPublishedJobAndRejectsDifferentContent() = withStore { _, store ->
        val id = java.util.UUID.randomUUID().toString()
        val original = store.create("camera", listOf(photo()), CameraImportDestination(), id)
        assertEquals(original, store.create("camera", listOf(photo()), CameraImportDestination(), id))
        val part = store.partial(id); part.writeBytes(raw)
        val saved = store.publish(original, 0, part, hash(raw), CameraTransferPermit())
        assertEquals(saved, store.create("camera", listOf(photo()), CameraImportDestination(), id))
        assertThrows(IOException::class.java) {
            store.create("camera", listOf(photo().copy(size = 500)), CameraImportDestination(), id)
        }
        assertEquals(listOf(saved), store.load())
    }

    @Test fun tetherRecoveryUsesReservedBatchAndDownloadsOnlyUnfinishedOriginals() = withStore { fixture, store ->
        val journal = CameraTetherJournal(File(fixture.root, "runs"))
        val baseline = photo("baseline")
        var run = journal.create("camera", "profile", listOf(baseline), CameraImportDestination())
        val photos = listOf(baseline, photo("first"), photo("second"))
        run = journal.reserve(run, photos).first
        val batchId = run.batches.single().id
        val downloads = mutableListOf<String>()
        val queue = CameraTetherQueue(store, journal)
        assertThrows(IOException::class.java) {
            queue.receive(run, photos, CameraTransferPermit(), { current, output ->
                downloads += current.key
                if (current.key == "second") throw IOException("Disconnected")
                output.write(raw); hash(raw)
            })
        }
        val restoredJobs = store.load()
        assertEquals(batchId, restoredJobs.single().id)
        assertEquals(1, restoredJobs.single().savedCount)
        val restoredRun = journal.load().single().copy(status = CameraTetherStatus.ACTIVE)
        val completed = queue.receive(restoredRun, photos, CameraTransferPermit(), { current, output ->
            downloads += current.key; output.write(raw); hash(raw)
        })
        assertEquals(listOf("first", "second", "second"), downloads)
        assertEquals(batchId, completed.batches.single().id)
        assertEquals(2, store.load().single().savedCount)
        assertEquals(1, fixture.media.rows.size)
    }

    @Test fun tetherQueueChangedCardStopsBeforeDownloading() = withStore { fixture, store ->
        val journal = CameraTetherJournal(File(fixture.root, "runs"))
        val run = journal.create("camera", "profile", listOf(photo("baseline")), CameraImportDestination())
        var downloads = 0
        assertThrows(IOException::class.java) {
            CameraTetherQueue(store, journal).receive(run, listOf(photo("new")), CameraTransferPermit(), { _, _ ->
                downloads++; error("Must not download")
            })
        }
        assertEquals(0, downloads)
    }

    @Test fun tetherBacklogMakesBoundedProgressAndResumesTheSameReservations() = withStore { fixture, store ->
        val journal = CameraTetherJournal(File(fixture.root, "runs"))
        val run = journal.create("camera", "profile", emptyList(), CameraImportDestination())
        val observed = (0..64).map { photo("new-$it") }
        val queue = CameraTetherQueue(store, journal)
        val downloaded = mutableListOf<String>()
        val download: (CameraPhoto, java.io.FileOutputStream) -> String = { current, output ->
            downloaded += current.key; output.write(raw); hash(raw)
        }
        assertThrows(CameraTetherBacklogException::class.java) { queue.receive(run, observed, CameraTransferPermit(), download) }
        assertEquals(64, downloaded.size)
        val restored = journal.load().single().copy(status = CameraTetherStatus.ACTIVE)
        val ids = restored.batches.map { it.id }
        store.load()
        val completed = queue.receive(restored, observed, CameraTransferPermit(), download)
        assertEquals(65, downloaded.size)
        assertEquals(65, downloaded.toSet().size)
        assertTrue(completed.batches.map { it.id }.containsAll(ids))
        assertEquals(65, store.load().sumOf { it.savedCount })
    }

    @Test fun duplicateContentReusesPublishedUriDespiteNewDirectoryRule() = withStore { fixture, store ->
        val first = save(store)
        val duplicate = save(store, destination = CameraImportDestination("Other", CameraDirectoryGrouping.NONE))
        assertEquals(first.items.single().saved, duplicate.items.single().saved)
        assertTrue(duplicate.items.single().duplicate)
        assertEquals(1, fixture.media.rows.size)
        assertEquals("Pictures/RawLab/Camera/2026-10-22/", duplicate.items.single().saved!!.relativePath)
    }

    @Test fun sameNameDifferentContentNeverOverwritesExistingMedia() = withStore { fixture, store ->
        val first = save(store)
        val changedBytes = raw.copyOf().also { it[20] = 99 }
        val changed = save(store, changedBytes)
        assertNotEquals(first.items.single().saved!!.uri, changed.items.single().saved!!.uri)
        assertArrayEquals(raw, fixture.media.open(store.savedUris(first).single()).use { it.readBytes() })
        assertArrayEquals(changedBytes, fixture.media.open(store.savedUris(changed).single()).use { it.readBytes() })
    }

    @Test fun changedOrMissingPublishedContentIsRejectedAndNotReused() = withStore { fixture, store ->
        val first = save(store)
        val uri = first.items.single().saved!!.uri
        fixture.media.file(uri).writeText("changed")
        assertThrows(IOException::class.java) { store.savedUris(first) }
        val replacement = save(store)
        assertNotEquals(uri, replacement.items.single().saved!!.uri)
        assertEquals("changed", fixture.media.file(uri).readText())
        fixture.media.file(replacement.items.single().saved!!.uri).delete()
        assertThrows(IOException::class.java) { store.savedUris(replacement) }
    }

    @Test fun wrongLengthDigestOrFormatNeverCreatesMedia() = withStore { fixture, store ->
        val job = store.create("camera", listOf(photo()), CameraImportDestination())
        val part = store.partial(job.id); part.writeBytes(raw)
        assertThrows(IOException::class.java) { store.publish(job, 0, part, "0".repeat(64), CameraTransferPermit()) }
        part.writeText("short")
        assertThrows(IOException::class.java) { store.publish(job, 0, part, hash(part.readBytes()), CameraTransferPermit()) }
        part.writeBytes(ByteArray(raw.size))
        assertThrows(IOException::class.java) { store.publish(job, 0, part, hash(part.readBytes()), CameraTransferPermit()) }
        assertTrue(fixture.media.rows.isEmpty())
    }

    @Test fun completePendingMediaFinishesAfterRestartWithoutAnotherCopy() = withStore { fixture, store ->
        fixture.media.failBeforePublish = true
        assertThrows(IOException::class.java) { save(store) }
        val pending = fixture.media.rows.values.single()
        assertTrue(pending.pending)
        fixture.media.failBeforePublish = false
        val reopened = fixture.store()
        val recovered = reopened.load().single()
        assertEquals(CameraJobStatus.COMPLETE, recovered.status)
        assertEquals(pending.uri, reopened.savedUris(recovered).single())
        assertFalse(fixture.media.rows.getValue(pending.uri).pending)
        assertEquals(1, fixture.media.rows.size)
    }

    @Test fun publishedMediaSurvivesCrashBeforeFinalJournalUpdate() = withStore { fixture, store ->
        fixture.media.failAfterPublish = true
        assertThrows(IOException::class.java) { save(store) }
        val published = fixture.media.rows.values.single()
        assertFalse(published.pending)
        fixture.media.failAfterPublish = false
        val recovered = fixture.store().load().single()
        assertEquals(CameraJobStatus.COMPLETE, recovered.status)
        assertEquals(published.uri, recovered.items.single().saved!!.uri)
        assertEquals(1, fixture.media.rows.size)
    }

    @Test fun damagedPendingMediaIsRemovedOnRecovery() = withStore { fixture, store ->
        fixture.media.failBeforePublish = true
        assertThrows(IOException::class.java) { save(store) }
        val pending = fixture.media.rows.values.single()
        fixture.media.file(pending.uri).writeText("incomplete")
        fixture.media.failBeforePublish = false
        val recovered = fixture.store().load().single()
        assertEquals(CameraJobStatus.PAUSED, recovered.status)
        assertNull(recovered.items.single().saved)
        assertNull(recovered.items.single().prepared)
        assertTrue(fixture.media.rows.isEmpty())
    }

    @Test fun taskRuleSurvivesRestartAndEachPhotoUsesItsOwnCaptureDay() = withStore { fixture, store ->
        val destination = CameraImportDestination("Trips/Sony", CameraDirectoryGrouping.CAPTURE_DAY)
        var job = store.create("camera", listOf(photo(), photo("2")), destination)
        val part = store.partial(job.id); part.writeBytes(raw)
        job = store.publish(job, 0, part, hash(raw), CameraTransferPermit())
        job = fixture.store().load().single()
        assertEquals(destination, job.destination)
        fixture.capture = CameraCaptureDate.parse("2026:10:23 01:02:03", null)
        val second = raw.copyOf().also { it[20] = 88 }; part.writeBytes(second)
        job = store.publish(job, 1, part, hash(second), CameraTransferPermit())
        assertEquals("Pictures/Trips/Sony/2026-10-22/", job.items[0].saved!!.relativePath)
        assertEquals("Pictures/Trips/Sony/2026-10-23/", job.items[1].saved!!.relativePath)
    }

    @Test fun missingCaptureDateDoesNotUseTheRemoteCreatedTime() = withStore { fixture, store ->
        fixture.capture = null
        val job = save(store)
        assertEquals("Pictures/RawLab/Camera/Unknown date/", job.items.single().saved!!.relativePath)
        assertNull(job.items.single().captureDay)
    }

    @Test fun orphanPendingMediaIsCleanedWithoutDeletingPublishedFiles() = withStore { fixture, store ->
        val saved = save(store)
        val orphan = fixture.media.createPending("orphan.ARW", "Pictures/Test/", "image/x-sony-arw", "orphan")
        fixture.store().load()
        assertFalse(fixture.media.rows.containsKey(orphan.uri))
        assertTrue(fixture.media.rows.containsKey(saved.items.single().saved!!.uri))
    }

    @Test fun restartingAfterExternalDeletionDoesNotReportTheOriginalAsSaved() = withStore { fixture, store ->
        val job = save(store)
        fixture.media.file(job.items.single().saved!!.uri).delete()
        val reopened = fixture.store().load().single()
        assertEquals(CameraJobStatus.PAUSED, reopened.status)
        assertEquals(0, reopened.savedCount)
        assertEquals(CameraMediaProblem.MISSING, reopened.items.single().problem)
        assertNotNull(reopened.items.single().unavailable)
        assertTrue(store.savedUris(reopened).isEmpty())
    }

    @Test fun restartingAfterExternalReplacementKeepsTheChangedFileButMarksItUnavailable() = withStore { fixture, store ->
        val job = save(store)
        val uri = job.items.single().saved!!.uri
        fixture.media.file(uri).writeText("external change")
        val reopened = fixture.store().load().single()
        assertEquals(CameraJobStatus.PAUSED, reopened.status)
        assertEquals(0, reopened.savedCount)
        assertEquals(CameraMediaProblem.CHANGED, reopened.items.single().problem)
        assertEquals(uri, reopened.items.single().unavailable!!.uri)
        assertEquals("external change", fixture.media.file(uri).readText())
        val part = store.partial(reopened.id); part.writeBytes(raw)
        val retried = store.publish(reopened, 0, part, hash(raw), CameraTransferPermit())
        assertEquals(CameraJobStatus.COMPLETE, retried.status)
        assertNull(retried.items.single().problem)
        assertNotEquals(uri, retried.items.single().saved!!.uri)
        assertEquals("external change", fixture.media.file(uri).readText())
    }

    private class FileMedia(private val root: File) : MediaPhotoAccess {
        val rows = linkedMapOf<String, MediaPhoto>()
        var failBeforePublish = false
        var failAfterPublish = false
        private var next = 0
        fun file(uri: String) = File(root, uri.substringAfterLast('/'))
        override fun createPending(name: String, relativePath: String, mime: String, token: String): MediaPhoto {
            val uri = "content://media/external_primary/images/media/${++next}"
            val photo = MediaPhoto(uri, name, relativePath, true)
            rows[uri] = photo; file(uri).writeBytes(byteArrayOf())
            return photo
        }
        override fun write(uri: String, source: File) { source.copyTo(file(uri), overwrite = true) }
        override fun publish(uri: String): MediaPhoto {
            if (failBeforePublish) throw IOException("Interrupted before publish")
            val photo = rows.getValue(uri).copy(pending = false); rows[uri] = photo
            if (failAfterPublish) throw IOException("Interrupted after publish")
            return photo
        }
        override fun inspect(uri: String): MediaPhoto? = rows[uri]?.takeIf { file(uri).isFile }
        override fun open(uri: String) = file(uri).inputStream()
        override fun remember(uri: String, size: Long, digest: String) = Unit
        override fun deletePending(uri: String) { if (rows[uri]?.pending == true) { file(uri).delete(); rows.remove(uri) } }
        override fun cleanupOrphans(referenced: Set<String>) {
            rows.values.filter { it.pending && it.uri !in referenced }.map { it.uri }.forEach(::deletePending)
        }
    }
}
