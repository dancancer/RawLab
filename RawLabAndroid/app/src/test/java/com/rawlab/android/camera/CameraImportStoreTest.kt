package com.rawlab.android.camera

import com.rawlab.android.photo.MediaPhoto
import com.rawlab.android.photo.MediaPhotoAccess
import com.rawlab.android.photo.MediaPhotoStat
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import org.json.JSONObject
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID

class CameraImportStoreTest {
    private val raw = byteArrayOf(73, 73, 42, 0, 8, 0, 0, 0) + ByteArray(100) { it.toByte() }
    private val jpeg = byteArrayOf(-1, -40, -1, -32, 0, 16, 74, 70, 73, 70) + ByteArray(100) { it.toByte() }
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

    private fun jpegPhoto(key: String = "jpeg-1") = CameraPhoto(key, "DSC00001.JPG", jpeg.size.toLong(), 42)

    private fun saveAdjusted(store: CameraImportStore, options: CameraJPEGOptions, key: String = "jpeg-1"): CameraImportJob {
        val plan = CameraIncrementalPlan(CameraImportFormat.JPEG, options)
        val job = store.create("camera", listOf(jpegPhoto(key)), CameraImportDestination(), incremental = plan)
        val part = store.partial(job.id); part.writeBytes(jpeg)
        return store.publish(job, 0, part, hash(jpeg), CameraTransferPermit())
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

    @Test fun resumeAcrossTransportsRequiresCameraSerialAndVerifiedSourceBytes() = withStore { fixture, store ->
        val camera = CameraHardwareIdentity("ILCE-7CM2", "1234567")
        val destination = CameraImportDestination("RawLab/Resume", CameraDirectoryGrouping.NONE)
        val first = photo("1").copy(resumeIdentity = "legacy:first")
        val pending = photo("2").copy(name = "DSC00002.ARW", storageToken = "mobile")
        val job = store.create("BLE:camera", listOf(first, pending), destination,
            hardwareIdentity = camera, listingOwner = "old-listing")
        val part = store.partial(job.id).apply { writeBytes(raw) }
        val partialJob = store.publish(job, 0, part, hash(raw), CameraTransferPermit())
        val saved = partialJob.items[0].saved
        part.writeText("interrupted")
        val reopened = fixture.store()
        val restored = reopened.load().single()

        assertTrue(restored.matchesCamera("SSID:camera", camera))
        assertFalse(restored.matchesCamera("SSID:camera", null))
        assertFalse(restored.matchesCamera("BLE:camera", camera.copy(serial = "7654321")))
        assertTrue(resumeLocatorMap(restored, listOf(pending), "new-listing").isEmpty())
        assertEquals(pending, resumeLocatorMap(restored, listOf(pending), "old-listing")[pending.key])
        val knownBytes = raw.copyOf().apply { this[lastIndex] = 100 }
        reopened.save(restored.copy(items = listOf(restored.items[0], restored.items[1].copy(digest = hash(knownBytes)))))
        val verified = reopened.load().single()
        val rebound = pending.copy(key = "reassigned-handle")
        assertEquals(rebound, resumeLocatorMap(verified, listOf(rebound), "new-listing")[pending.key])
        assertThrows(CameraImportSourceChanged::class.java) {
            receiveCameraJob(reopened, verified, CameraTransferPermit(), { _, output ->
                output.write(raw); hash(raw)
            })
        }
        assertNull(reopened.load().single().items[1].saved)

        var downloads = 0
        val resumed = receiveCameraJob(reopened, verified, CameraTransferPermit(), { current, output ->
            assertEquals(pending, current)
            assertEquals(0L, output.channel.position())
            downloads++
            output.write(knownBytes)
            hash(knownBytes)
        })
        assertEquals(1, downloads)
        assertEquals(CameraJobStatus.COMPLETE, resumed.status)
        assertEquals(saved, resumed.items[0].saved)
        assertEquals(destination.relativePath(fixture.capture), resumed.items[1].saved!!.relativePath)
        assertEquals(camera, fixture.store().load().single().hardwareIdentity)
    }

    @Test fun historicalJobKeepsConnectionButNeedsSourceProofAfterReconnect() = withStore { fixture, store ->
        val pending = photo()
        store.create("BLE:camera", listOf(pending), CameraImportDestination())
        val restored = fixture.store().load().single()
        val camera = CameraHardwareIdentity("ILCE-7CM2", "1234567")
        assertTrue(restored.matchesCamera("BLE:camera", camera))
        assertFalse(restored.matchesCamera("SSID:camera", camera))
        assertTrue(resumeLocatorMap(restored, listOf(pending.copy(resumeIdentity = "mobile:current")), "new-listing").isEmpty())
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

    @Test fun tetherRecoveryVerifiesSavedOriginalsAndOnlyPublishesUnfinishedOnes() = withStore { fixture, store ->
        val journal = CameraTetherJournal(File(fixture.root, "runs"))
        val hardware = CameraHardwareIdentity("ILCE-7CM2", "1234567")
        var run = journal.create("camera", "profile", emptyList(), CameraImportDestination(), hardware)
        val photos = listOf(photo("first"), photo("second").copy(name = "DSC00002.ARW"))
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
        val restoredRun = journal.load().single()
        val remapped = photos.map { it.copy(key = "reconnected-${it.key}") }
        assertThrows(CameraTetherSourceException::class.java) {
            queue.resume(restoredRun, remapped, hardware, restoredJobs, CameraTransferPermit(),
                { _, _ -> error("Unverified source must not be downloaded") }, {})
        }
        val restoredJob = restoredJobs.single()
        val verified = restoredJob.copy(items = listOf(restoredJob.items[0], restoredJob.items[1].copy(digest = hash(raw))))
        store.save(verified)
        val changed = raw.copyOf().apply { this[lastIndex]++ }
        assertThrows(CameraTetherSourceException::class.java) {
            queue.resume(restoredRun, remapped, hardware, listOf(verified), CameraTransferPermit(),
                { _, output -> output.write(changed); hash(changed) }, {})
        }
        assertEquals(restoredRun, journal.load().single())
        val completed = queue.resume(restoredRun, remapped, hardware, listOf(verified), CameraTransferPermit(), { current, output ->
            downloads += current.key; output.write(raw); hash(raw)
        }, {})
        assertEquals(listOf("first", "second", "reconnected-first", "reconnected-second"), downloads)
        assertEquals(batchId, completed.batches.single().id)
        assertEquals(2, store.load().single().savedCount)
        assertEquals(1, fixture.media.rows.size)
        assertEquals(remapped, completed.baseline)
        assertNull(journal.reserve(completed, remapped).second)
    }

    @Test fun tetherRecoveryRechecksCompletedOriginalsAfterHandlesHaveAlreadyBeenRebased() = withStore { fixture, store ->
        val journal = CameraTetherJournal(File(fixture.root, "runs"))
        val hardware = CameraHardwareIdentity("ILCE-7CM2", "1234567")
        val queue = CameraTetherQueue(store, journal)
        val original = photo("old")
        val run = journal.create("camera", "profile", emptyList(), CameraImportDestination(), hardware)
        queue.receive(run, listOf(original), CameraTransferPermit(), { _, output -> output.write(raw); hash(raw) })
        val completed = store.load().single()
        assertEquals(CameraJobStatus.COMPLETE, completed.status)
        val rebound = queue.resume(journal.load().single(), listOf(original.copy(key = "first-reconnect")), hardware,
            listOf(completed), CameraTransferPermit(), { _, output -> output.write(raw); hash(raw) }, {})
        assertEquals(rebound.batches.size, rebound.rebasedBatches)
        val paused = journal.load().single()
        val changed = raw.copyOf().apply { this[lastIndex]++ }
        val sameMetadata = original.copy(key = "different-card")
        assertThrows(CameraTetherSourceException::class.java) {
            queue.resume(paused, listOf(sameMetadata), hardware, listOf(completed), CameraTransferPermit(),
                { _, output -> output.write(changed); hash(changed) }, {})
        }
        assertEquals(paused, journal.load().single())
        assertEquals(listOf(completed), store.load())
        assertEquals(1, fixture.media.rows.size)
    }

    @Test fun tetherRebaseVerifiesUnverifiedBaselineByObjectMetadata() = withStore { fixture, store ->
        val journal = CameraTetherJournal(File(fixture.root, "runs"))
        val hardware = CameraHardwareIdentity("ILCE-7CM2", "1234567")
        val original = photo("old")
        journal.create("camera", "profile", listOf(original), CameraImportDestination(), hardware)
        val paused = journal.load().single()
        // 空批次（首拍未登记）不再拒绝续接：由 rebase 逐个核对来源元数据兜底，同名同尺寸的句柄更换视为同一对象。
        val resumed = CameraTetherQueue(store, journal).resume(paused, listOf(original.copy(key = "different-card")), hardware,
            emptyList(), CameraTransferPermit(), { _, _ -> error("There is no original digest to verify") }, {})
        assertEquals(CameraTetherStatus.ACTIVE, resumed.status)
        assertEquals(listOf(original.copy(key = "different-card")), resumed.baseline)
        // 元数据对不上时，未验证基线仍拒绝续接，落盘的仍是续接成功的记录。
        assertThrows(CameraTetherSourceException::class.java) {
            CameraTetherQueue(store, journal).resume(paused, listOf(original.copy(name = "other.ARW")), hardware,
                emptyList(), CameraTransferPermit(), { _, _ -> error("There is no original digest to verify") }, {})
        }
        val persisted = journal.load().single()
        assertEquals(listOf(original.copy(key = "different-card")), persisted.baseline)
        assertEquals(CameraTetherStatus.PAUSED, persisted.status)
    }

    @Test fun tetherRecoveryRejectsOverBudgetProofBeforeDownloading() = withStore { fixture, store ->
        val mib = 1L shl 20
        for ((index, scenario) in listOf(
            List(65) { raw.size.toLong() } to false,
            List(53) { 40 * mib } to false,
            (List(63) { 32 * mib } + (32 * mib + 1)) to true,
        ).withIndex()) {
            val (sizes, lastPending) = scenario
            val journal = CameraTetherJournal(File(fixture.root, "budget-$index"))
            val (run, jobs) = tetherRecoveryFixture(journal, sizes, lastPending)
            var downloads = 0
            assertThrows(CameraTetherSourceException::class.java) {
                CameraTetherQueue(store, journal).resume(run, run.observedPhotos, run.hardwareIdentity, jobs,
                    CameraTransferPermit(), { _, _ -> downloads++; hash(raw) }, {})
            }
            assertEquals("The total proof budget is checked before fetching any file", 0, downloads)
            assertEquals(run, journal.load().single())
        }
    }

    @Test fun tetherRecoveryCanVerifyExactly64FilesAndTwoGiB() = withStore { fixture, store ->
        val journal = CameraTetherJournal(File(fixture.root, "budget-limit"))
        val (run, jobs) = tetherRecoveryFixture(journal, List(64) { 32L shl 20 }, lastPending = false)
        val requested = mutableListOf<CameraPhoto>()
        val resumed = CameraTetherQueue(store, journal).resume(run, run.observedPhotos, run.hardwareIdentity, jobs,
            CameraTransferPermit(), { photo, _ -> requested += photo; hash(raw) }, {})
        assertEquals(run.observedPhotos, requested)
        assertEquals(2L shl 30, requested.sumOf { it.size })
        assertEquals(resumed.batches.size, resumed.rebasedBatches)
    }

    private fun tetherRecoveryFixture(journal: CameraTetherJournal, sizes: List<Long>, lastPending: Boolean):
        Pair<CameraTetherRun, List<CameraImportJob>> {
        val hardware = CameraHardwareIdentity("ILCE-7CM2", "1234567")
        var run = journal.create("camera", "profile", emptyList(), CameraImportDestination(), hardware)
        val photos = sizes.mapIndexed { index, size ->
            photo("id-$index").copy(name = "DSC$index.ARW", size = size)
        }
        while (true) {
            val (next, batch) = journal.reserve(run, photos)
            run = next
            if (batch == null) break
        }
        val digest = hash(raw)
        val jobs = run.batches.map { batch ->
            val items = batch.photos.map { photo ->
                val saved = if (lastPending && photo == photos.last()) null
                    else MediaPhoto("content://test/${photo.key}", photo.name, "Pictures/", false)
                CameraImportItem(photo, saved = saved, digest = digest)
            }
            CameraImportJob(batch.id, run.cameraId, 1, items,
                if (items.all { it.saved != null }) CameraJobStatus.COMPLETE else CameraJobStatus.PAUSED)
        }
        return journal.load().single() to jobs
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

    @Test fun wrongLengthOrFormatNeverCreatesMediaStreamedDigestTrusted() = withStore { fixture, store ->
        val job = store.create("camera", listOf(photo()), CameraImportDestination())
        val part = store.partial(job.id); part.writeBytes(raw)
        // (a) 全新发布直接采信流式摘要，不再整读 .partial 重算来抓“谎报摘要”：长度与文件头仍是拒绝门槛，
        // 谎报摘要由恢复场景 item.digest 交叉校验（见上方 resume CameraImportSourceChanged）与打开路径
        // savedUris 的整文件强校验兜底（load 命中 savedStat 指纹时信任登记摘要，与 A1 语义一致）。
        val trusted = store.publish(job, 0, part, "0".repeat(64), CameraTransferPermit())
        assertNotNull(trusted.items.single().saved)
        assertEquals("0".repeat(64), trusted.items.single().digest)
        assertEquals(1, fixture.media.rows.size)
        part.writeText("short")
        assertThrows(IOException::class.java) { store.publish(job, 0, part, hash(part.readBytes()), CameraTransferPermit()) }
        part.writeBytes(ByteArray(raw.size))
        assertThrows(IOException::class.java) { store.publish(job, 0, part, hash(part.readBytes()), CameraTransferPermit()) }
        assertEquals("长度或文件头不符不得新建媒体", 1, fixture.media.rows.size)
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

    @Test fun perPhotoImportAppendsWalAnchorsAndMergesSnapshotOnlyAtCompletion() = withStore { fixture, store ->
        // 两个已完成的历史任务提供跨任务去重视图；重启后由 load 一次性装入内存账本。
        save(store, raw)
        val otherBytes = byteArrayOf(73, 73, 42, 0, 8, 0, 0, 0) + ByteArray(100) { (it + 1).toByte() }
        save(store, otherBytes)
        val reopened = fixture.store()
        reopened.load()
        val scans = reopened.directoryScans
        val rewrites = reopened.journalRewrites
        val appends = reopened.walAppends
        val job = reopened.create("camera", listOf(photo("1"), photo("2")), CameraImportDestination())
        var current = job
        // 内容避开历史摘要：两张都走非复用路径，计数才反映稳态写路径。
        val bytes = listOf(raw.copyOf().also { it[20] = 11 }, raw.copyOf().also { it[20] = 22 })
        bytes.forEachIndexed { index, content ->
            val part = reopened.partial(job.id); part.writeBytes(content)
            current = reopened.publish(current, index, part, hash(content), CameraTransferPermit())
        }
        assertEquals(CameraJobStatus.COMPLETE, current.status)
        assertEquals("去重与抽样走内存账本，不再逐张全目录重读", scans, reopened.directoryScans)
        assertEquals("稳态每张零全量重写：仅创建与任务完成各 1 次快照", rewrites + 2, reopened.journalRewrites)
        assertEquals("每张只追加行级锚：非完成张 prepared+saved，完成张 prepared", appends + 3, reopened.walAppends)
        assertFalse(File(fixture.root, "jobs/${job.id}.wal").exists()) // 完成点合并快照即截断 WAL
    }

    @Test fun truncatedWalTailIsDroppedAndOrphanWalReapedOnLoad() = withStore { fixture, store ->
        val job = save(store)
        val wal = File(fixture.root, "jobs/${job.id}.wal")
        assertFalse("完成快照后 WAL 已截断", wal.exists())
        wal.writeText("{\"i\":0,\"prepared\":") // 模拟崩溃留下的半行：重放丢弃，快照为准
        val recovered = fixture.store().load().single()
        assertEquals(job.id, recovered.id)
        assertNotNull(recovered.items.single().saved)
        assertFalse("load 折叠后重写快照时截断 WAL", wal.exists())
        val orphan = File(fixture.root, "jobs/00000000-0000-0000-0000-00000000000f.wal")
        orphan.writeText("{}\n")
        fixture.store().load()
        assertFalse("没有快照的孤儿 WAL 由 load 回收", orphan.exists())
    }

    @Test fun staleWalLinesDoNotOverwriteNewerSnapshotAfterCrashBeforeTruncation() = withStore { fixture, store ->
        val bytes = listOf(raw.copyOf().also { it[20] = 5 }, raw.copyOf().also { it[20] = 6 })
        val job = store.create("camera", listOf(photo("1"), photo("2")), CameraImportDestination())
        var current = job
        var staleSavedLine = ""
        bytes.forEachIndexed { index, content ->
            val part = store.partial(job.id); part.writeBytes(content)
            current = store.publish(current, index, part, hash(content), CameraTransferPermit())
            // 第一张的已保存锚行（带当时有效的 savedStat），模拟截断前崩溃的 WAL 残留。
            if (index == 0) staleSavedLine = File(fixture.root, "jobs/${job.id}.wal").readLines().last()
        }
        assertEquals(CameraJobStatus.COMPLETE, current.status)
        // 同尺寸同 mtime 改写：savedUris 的强校验抓到摘要不符，清掉指纹并落盘新快照。
        val firstUri = current.items[0].saved!!.uri
        val file = fixture.media.file(firstUri)
        val stamp = file.lastModified()
        val tampered = file.readBytes().also { it[0] = (it[0] + 1).toByte() }
        file.writeBytes(tampered); file.setLastModified(stamp)
        assertThrows(CameraLocalSourceChanged::class.java) { store.savedUris(current) }
        // 快照落盘与 WAL 截断之间崩溃：旧锚行（含无序号的旧 prepared 行）回到 WAL 上。
        File(fixture.root, "jobs/${job.id}.wal").writeText(staleSavedLine + "\n" +
            JSONObject().put("i", 1).put("digest", hash(bytes[1]))
                .put("prepared", JSONObject().put("uri", current.items[1].saved!!.uri)
                    .put("name", "DSC00001.ARW").put("path", "DSC00001.ARW").put("pending", false)) + "\n")
        val recovered = fixture.store().load().single()
        assertNull("旧 prepared 锚按写序号跳过，不再盖回已保存条目（撤序号必红）", recovered.items[1].prepared)
        assertEquals("旧 savedStat 不能复活放行被篡改的文件：仍翻转为 CHANGED（撤序号必红）",
            CameraMediaProblem.CHANGED, recovered.items[0].problem)
        assertNotNull(recovered.items[1].saved)
        assertEquals(CameraJobStatus.PAUSED, recovered.status)
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

    @Test fun unreadableJournalIsKeptWithoutHidingOtherJobsOrCleaningItsMedia() {
        val damages = listOf<(File) -> Unit>(
            { it.writeText("{broken") },
            { it.writeText(JSONObject(it.readText()).put("version", 3).toString()) },
            { it.writeText(JSONObject(it.readText()).put("status", "ARCHIVED").toString()) },
            { it.appendBytes(ByteArray(8 * 1024 * 1024)) })
        for (damage in damages) withStore { fixture, store ->
            val kept = save(store)
            // 待发布媒体已登记后中断，随后这份日志变得无法读取。
            fixture.media.failBeforePublish = true
            assertThrows(IOException::class.java) { save(store, raw.copyOf().also { it[20] = 7 }) }
            fixture.media.failBeforePublish = false
            val pending = fixture.media.rows.values.single { it.pending }
            val journal = File(fixture.root, "jobs").listFiles()!!.single { it.extension == "json" && it.nameWithoutExtension != kept.id }
            damage(journal)
            val damaged = journal.readBytes()

            val reopened = fixture.store()
            assertEquals(listOf(kept.id), reopened.load().map { it.id })
            assertEquals(setOf(journal.nameWithoutExtension), reopened.unreadableJobIds)
            assertTrue(fixture.media.rows.getValue(pending.uri).pending)
            assertThrows(Exception::class.java) {
                reopened.create("camera", listOf(photo()), CameraImportDestination(), id = journal.nameWithoutExtension)
            }
            assertEquals(CameraJobStatus.COMPLETE, save(reopened, raw.copyOf().also { it[21] = 9 }).status)
            assertTrue(fixture.media.rows.getValue(pending.uri).pending)
            assertArrayEquals(damaged, journal.readBytes())
        }
    }

    @Test fun discardedUnreadableJournalStopsProtectingItsPendingMedia() = withStore { fixture, store ->
        val kept = save(store)
        // 待发布媒体已登记后中断，随后这份日志变得无法读取。
        fixture.media.failBeforePublish = true
        assertThrows(IOException::class.java) { save(store, raw.copyOf().also { it[20] = 7 }) }
        fixture.media.failBeforePublish = false
        val pending = fixture.media.rows.values.single { it.pending }
        val journal = File(fixture.root, "jobs").listFiles()!!.single { it.extension == "json" && it.nameWithoutExtension != kept.id }
        journal.writeText("{broken")
        val damaged = journal.nameWithoutExtension

        val reopened = fixture.store()
        assertEquals(listOf(kept.id), reopened.load().map { it.id })
        assertEquals(setOf(damaged), reopened.unreadableJobIds)
        // 只有隔离集合里的坏记录能被放弃；其它 id 一律拒绝，不碰文件。
        assertFalse(reopened.discardUnreadableJob("not-a-uuid"))
        assertFalse(reopened.discardUnreadableJob(kept.id))
        assertEquals(setOf(damaged), reopened.unreadableJobIds)
        assertTrue(reopened.discardUnreadableJob(damaged))
        assertTrue(reopened.unreadableJobIds.isEmpty())
        assertFalse(journal.exists())
        // 放弃当时不删媒体；坏记录不再阻塞孤儿清理，下一次 load 回收待发布原件并确认其它任务完好。
        assertTrue(fixture.media.rows.getValue(pending.uri).pending)
        fixture.store().load()
        assertFalse(fixture.media.rows.containsKey(pending.uri))
        assertEquals(listOf(kept.id), reopened.load().map { it.id })
        assertFalse(reopened.discardUnreadableJob(damaged))
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

    @Test fun reloadTrustsStatFingerprintAndDigestsNothingUntilStatChanges() = withStore { fixture, store ->
        var job = store.create("camera", listOf(photo("1"), photo("2"), photo("3")), CameraImportDestination())
        val contents = listOf(raw, raw.copyOf().apply { this[5] = 77 }, raw.copyOf().apply { this[7] = -77 })
        for ((index, content) in contents.withIndex()) {
            val part = store.partial(job.id); part.writeBytes(content)
            job = store.publish(job, index, part, hash(content), CameraTransferPermit())
        }
        assertEquals(3, job.savedCount)
        fixture.media.opens = 0
        val reloaded = fixture.store().load().single()
        assertEquals(3, reloaded.savedCount)
        assertEquals("reload must trust the size+mtime fingerprint: zero whole-file digests on a cold start",
            0, fixture.media.opens)
        val changed = fixture.media.file(reloaded.items.first().saved!!.uri)
        assertTrue(changed.setLastModified(changed.lastModified() + 5_000))
        fixture.media.opens = 0
        val touched = fixture.store().load().single()
        assertEquals(3, touched.savedCount)
        assertEquals("only the item whose stat fingerprint changed may be re-digested", 1, fixture.media.opens)
    }

    @Test fun legacyJournalWithoutFingerprintsDigestsEachItemOnceThenTrustsStat() = withStore { fixture, store ->
        val job = save(store)
        val uri = job.items.single().saved!!.uri
        // 模拟旧版本的历史日志：指纹缺失，首次加载回落整文件摘要。
        store.save(job.copy(items = listOf(job.items.single().copy(savedStat = null))))
        fixture.media.opens = 0
        val warmed = fixture.store().load().single()
        assertNotNull(warmed.items.single().saved)
        assertEquals("a fingerprint-less item must be digested exactly once on the first load", 1, fixture.media.opens)
        fixture.media.opens = 0
        val steady = fixture.store().load().single()
        assertEquals(uri, steady.items.single().saved!!.uri)
        assertEquals("the recorded fingerprint must keep later loads free of whole-file digests", 0, fixture.media.opens)
    }

    @Test fun strongVerificationFailureClearsFingerprintSoNextLoadFlipsToChanged() = withStore { fixture, store ->
        val job = save(store)
        val file = fixture.media.file(job.items.single().saved!!.uri)
        val mtime = file.lastModified()
        // 同 stat 改写：内容变化但 size 与 mtime 复原，stat 指纹抓不到（评审 finding 3 场景）。
        file.writeBytes(ByteArray(raw.size) { ((it * 7 + 3) % 251).toByte() })
        assertTrue(file.setLastModified(mtime))
        val trusted = fixture.store().load().single()
        assertNotNull("load keeps trusting the unchanged fingerprint", trusted.items.single().saved)
        // 用户点打开：savedUris 整文件强校验拦截，同时必须清掉该条指纹并落盘（自愈前提）。
        assertThrows(CameraLocalSourceChanged::class.java) { store.savedUris(trusted) }
        val healed = fixture.store().load().single()
        assertNull("after strong verification failed the entry must self-heal away from saved", healed.items.single().saved)
        assertEquals(CameraMediaProblem.CHANGED, healed.items.single().problem)
    }

    @Test fun statTrustRequiresFingerprintSizeToMatchExpectedSize() = withStore { fixture, store ->
        val job = save(store)
        val item = job.items.single()
        val recorded = checkNotNull(item.savedStat)
        // 篡改场景：指纹与当前 stat 一致，但预期校验 size 不同（输出尺寸记录漂移）。
        store.save(job.copy(items = listOf(item.copy(outputSize = recorded.substringBefore(':').toLong() - 1))))
        fixture.media.opens = 0
        val reloaded = fixture.store().load().single()
        assertEquals("a fingerprint whose size differs from the expected size must not be trusted",
            CameraMediaProblem.CHANGED, reloaded.items.single().problem)
        assertEquals(1, fixture.media.opens)
    }

    @Test fun publishReusesStreamedDigestWithoutRehashingPartOrPending() = withStore { fixture, store ->
        val job = store.create("camera", listOf(photo()), CameraImportDestination())
        val part = store.partial(job.id); part.writeBytes(raw)
        fixture.media.opens = 0
        val before = store.contentDigestCount
        val published = store.publish(job, 0, part, hash(raw), CameraTransferPermit())
        assertNotNull(published.items.single().saved)
        assertEquals("publish 必须直接采信下载路径的流式摘要：.partial 与 pending 写入零整文件摘要",
            0, store.contentDigestCount - before)
        assertEquals("publish 不应整读媒体文件", 0, fixture.media.opens)
    }

    @Test fun pendingSizeFingerprintMismatchRejectsPublication() = withStore { fixture, store ->
        val job = store.create("camera", listOf(photo()), CameraImportDestination())
        val part = store.partial(job.id); part.writeBytes(raw)
        // 机型差异：个别 MediaProvider 在 pending 期间就回填 SIZE；指纹 size 与预期校验大小不符必须拒绝发布。
        fixture.media.pendingStatOverride = MediaPhotoStat(raw.size - 1L, System.currentTimeMillis())
        val error = assertThrows(IOException::class.java) { store.publish(job, 0, part, hash(raw), CameraTransferPermit()) }
        assertEquals("Stored camera photo differs", error.message)
    }

    @Test fun sampledReuseValidatesCandidateByFingerprintWithoutDigest() = withStore { fixture, store ->
        val big = ByteArray(200_000) { ((it * 31 + 7) % 251).toByte() }
        big[0] = 73; big[1] = 73; big[2] = 42; big[3] = 0
        val bigPhoto = CameraPhoto("1", "DSC00001.ARW", big.size.toLong(), 1_764_000_000_000L)
        val first = store.create("camera", listOf(bigPhoto), CameraImportDestination())
        val part = store.partial(first.id); part.writeBytes(big)
        store.publish(first, 0, part, hash(big), CameraTransferPermit())
        val second = store.create("camera", listOf(bigPhoto), CameraImportDestination())
        val output = File(fixture.root, "reuse.out")
        val before = store.contentDigestCount
        val scans = store.directoryScans
        val digest = store.copySampledOriginal(second, bigPhoto, FileOutputStream(output), CameraTransferPermit()) { offset, length ->
            big.copyOfRange(offset.toInt(), offset.toInt() + length)
        }
        assertEquals(hash(big), digest)
        assertEquals("候选指纹命中即复用：候选校验零整文件摘要", 0, store.contentDigestCount - before)
        assertEquals("候选复用视野走内存账本，不重读全目录", scans, store.directoryScans)
        assertArrayEquals(big, output.readBytes())
    }

    @Test fun adjustedJpegReuseRequiresTheSameSourceAndFrozenOptions() = withStore { fixture, _ ->
        val processor: (File, File, CameraJPEGOptions) -> CameraProcessedFile = { _, destination, options ->
            val bytes = ("adjusted-${options.longEdge}-${options.quality}").toByteArray()
            destination.writeBytes(bytes)
            CameraProcessedFile(bytes.size.toLong(), hash(bytes))
        }
        val store = CameraImportStore(File(fixture.root, "jobs"), File(fixture.root, "partial"), fixture.media,
            { fixture.capture }, processor)
        val first = saveAdjusted(store, CameraJPEGOptions(true, 2048, 90))
        val same = saveAdjusted(store, CameraJPEGOptions(true, 2048, 90), "jpeg-2")
        val changed = saveAdjusted(store, CameraJPEGOptions(true, 3000, 90), "jpeg-3")
        assertEquals(first.items.single().saved, same.items.single().saved)
        assertTrue(same.items.single().duplicate)
        assertNotEquals(first.items.single().saved!!.uri, changed.items.single().saved!!.uri)
        assertEquals(2, fixture.media.rows.size)
        assertEquals(16L, first.items.single().outputSize)
        assertEquals(hash("adjusted-2048-90".toByteArray()), first.items.single().outputDigest)
    }

    @Test fun onlyACompletedIncrementalTaskPublishesItsBoundary() = withStore { _, store ->
        val boundary = CameraImportBoundary(2_000, setOf("card"), setOf("key"), setOf("key"), "camera")
        val plan = CameraIncrementalPlan(CameraImportFormat.RAW, checkpoints = mapOf(CameraImportFormat.RAW to boundary))
        val job = store.create("camera", listOf(photo()), CameraImportDestination(), incremental = plan)
        assertTrue(committedIncrementalCheckpoints(store.load()).isEmpty())
        val part = store.partial(job.id); part.writeBytes(raw)
        val complete = store.publish(job, 0, part, hash(raw), CameraTransferPermit())
        assertEquals(boundary, committedIncrementalCheckpoints(listOf(complete))[CameraImportFormat.RAW])
    }

    @Test fun adjustmentChecksForGainMapBeforeReusingAnOlderDerivative() = withStore { fixture, _ ->
        val store = CameraImportStore(File(fixture.root, "jobs"), File(fixture.root, "partial"), fixture.media,
            { fixture.capture }, processJpeg = { _, destination, _ ->
                destination.writeBytes(jpeg)
                CameraProcessedFile(jpeg.size.toLong(), hash(jpeg))
            }, verifyJpeg = { throw CameraJPEGGainMapAdjustmentException() })
        val options = CameraJPEGOptions(adjust = true, longEdge = 2048)
        saveAdjusted(store, options)
        val job = store.create("camera", listOf(jpegPhoto("again")), CameraImportDestination(),
            incremental = CameraIncrementalPlan(CameraImportFormat.JPEG, options))
        val blocked = receiveCameraJob(store, job, CameraTransferPermit(), { _, output ->
            output.write(jpeg)
            hash(jpeg)
        })
        assertEquals(CameraJobStatus.PAUSED, blocked.status)
        assertEquals(CameraMediaProblem.HDR_GAIN_MAP, blocked.items.single().problem)
        assertFalse(blocked.committed)
        assertEquals(1, fixture.media.rows.size)
    }

    @Test fun jpegMemoryLimitPausesAndCanKeepTheVerifiedOriginal() = withStore { fixture, _ ->
        val store = CameraImportStore(File(fixture.root, "jobs"), File(fixture.root, "partial"), fixture.media,
            { fixture.capture }, processJpeg = { _, _, _ -> throw CameraJPEGMemoryException() })
        val job = store.create("camera", listOf(jpegPhoto()), CameraImportDestination(),
            incremental = CameraIncrementalPlan(CameraImportFormat.JPEG, CameraJPEGOptions(adjust = true)))
        val download: (CameraPhoto, java.io.FileOutputStream) -> String = { _, output ->
            output.write(jpeg)
            hash(jpeg)
        }
        val paused = receiveCameraJob(store, job, CameraTransferPermit(), download)
        assertEquals(CameraJobStatus.PAUSED, paused.status)
        assertEquals(CameraMediaProblem.JPEG_MEMORY, paused.items.single().problem)
        assertTrue(fixture.media.rows.isEmpty())
        val recovered = checkNotNull(store.recover(job.id))
        assertEquals(hash(jpeg), recovered.items.single().digest)
        val complete = receiveCameraJob(store, recovered.keepingPendingJpegOriginals(), CameraTransferPermit(), download)
        assertEquals(CameraJobStatus.COMPLETE, complete.status)
        val uri = checkNotNull(complete.items.single().saved).uri
        assertArrayEquals(jpeg, fixture.media.file(uri).readBytes())
    }

    @Test fun keepOriginalSurvivesRecoveryAndDoesNotReuseAnAdjustedJpeg() = withStore { fixture, _ ->
        val adjusted = "adjusted JPEG".toByteArray()
        val store = CameraImportStore(File(fixture.root, "jobs"), File(fixture.root, "partial"), fixture.media,
            { fixture.capture }, processJpeg = { _, destination, _ ->
                destination.writeBytes(adjusted)
                CameraProcessedFile(adjusted.size.toLong(), hash(adjusted))
            })
        val options = CameraJPEGOptions(adjust = true, longEdge = 2048)
        val plan = CameraIncrementalPlan(CameraImportFormat.JPEG, options)
        val job = store.create("camera", listOf(jpegPhoto(), jpegPhoto("jpeg-2")), CameraImportDestination(), incremental = plan)
        val part = store.partial(job.id).apply { writeBytes(jpeg) }
        val partial = store.publish(job, 0, part, hash(jpeg), CameraTransferPermit())
        val adjustedUri = checkNotNull(partial.items.first().saved).uri
        store.save(partial.keepingPendingJpegOriginals())

        val recovered = checkNotNull(store.recover(job.id))
        val complete = receiveCameraJob(store, recovered, CameraTransferPermit(), { photo, output ->
            assertEquals("jpeg-2", photo.key)
            output.write(jpeg)
            hash(jpeg)
        })
        assertTrue(complete.committed)
        assertEquals(adjustedUri, complete.items.first().saved?.uri)
        val originalUri = checkNotNull(complete.items.last().saved).uri
        assertNotEquals(adjustedUri, originalUri)
        assertArrayEquals(jpeg, fixture.media.file(originalUri).readBytes())

        val repeated = saveAdjusted(store, options, "jpeg-3")
        assertEquals(adjustedUri, repeated.items.single().saved?.uri)
        assertArrayEquals(adjusted, fixture.media.file(adjustedUri).readBytes())
    }

    @Test fun committedBoundarySurvivesACompletedMediaRowBecomingUnavailable() = withStore { fixture, store ->
        val boundary = CameraImportBoundary(2_000, setOf("card"), setOf("key"), setOf("key"), "session")
        val plan = CameraIncrementalPlan(CameraImportFormat.RAW, checkpoints = mapOf(CameraImportFormat.RAW to boundary))
        val job = store.create("camera", listOf(photo()), CameraImportDestination(), incremental = plan)
        val part = store.partial(job.id); part.writeBytes(raw)
        val complete = store.publish(job, 0, part, hash(raw), CameraTransferPermit())
        assertTrue(complete.committed)
        fixture.media.file(complete.items.single().saved!!.uri).writeText("external change")
        val reopened = fixture.store()
        val recovered = reopened.load().single()
        assertEquals(CameraJobStatus.PAUSED, recovered.status)
        assertEquals(boundary, committedIncrementalCheckpoints(listOf(recovered))[CameraImportFormat.RAW])
    }

    @Test fun reconnectKeepsAMissingRemoteObjectAsFailedWithoutDownloadingIt() = withStore { fixture, store ->
        val job = store.create("camera", listOf(photo()), CameraImportDestination())
        val marked = job.copy(items = listOf(job.items.single().copy(problem = CameraMediaProblem.REMOTE_MISSING)),
            status = CameraJobStatus.PAUSED)
        var downloads = 0
        val result = receiveCameraJob(store, marked, CameraTransferPermit(), { _, _ -> downloads++; error("must not download") })
        assertEquals(CameraJobStatus.PAUSED, result.status)
        assertEquals("PAUSED", JSONObject(File(fixture.root, "jobs/${job.id}.json").readText()).getString("status"))
        assertEquals(0, downloads)
    }

    @Test fun legacyUnifiedBoundaryMigratesFromSavedKindsInsteadOfItsGlobalDateOrKeys() = withStore { fixture, store ->
        val time = 1_700_000_000_000L
        val rawPhoto = CameraPhoto("raw-locator", "RAW.ARW", raw.size.toLong(), time, storageToken = "card")
        val jpegPhoto = CameraPhoto("jpeg-locator", "JPEG.JPG", jpeg.size.toLong(), time + 1_000, storageToken = "card")
        val rawMedia = fixture.media.createPending(rawPhoto.name, "Pictures/", "image/x-sony-arw", "raw")
        fixture.media.write(rawMedia.uri, File(fixture.root, "raw").apply { writeBytes(raw) })
        val rawSaved = fixture.media.publish(rawMedia.uri)
        val legacy = CameraImportBoundary(time + 1_000, setOf("card"), setOf(jpegPhoto.key), setOf(jpegPhoto.anchorKey), "old")
        val plan = CameraIncrementalPlan(CameraImportFormat.RAW, boundary = legacy)
        val job = CameraImportJob(UUID.randomUUID().toString(), "camera", 1_000,
            listOf(CameraImportItem(rawPhoto, saved = rawSaved, digest = hash(raw))),
            CameraJobStatus.COMPLETE, CameraImportDestination(), plan, committed = true)
        store.save(job)
        val reopened = fixture.store()
        val migrated = reopened.load().single().incremental!!
        assertEquals(time, migrated.checkpoints[CameraImportFormat.RAW]?.dateMillis)
        assertEquals(setOf(rawPhoto.key), migrated.checkpoints[CameraImportFormat.RAW]?.keys)
        assertFalse(CameraImportFormat.JPEG in migrated.checkpoints)
    }

    @Test fun resumeCannotCommitWhenASavedFileChangedAndTheCameraOriginalIsMissing() = withStore { fixture, store ->
        val plan = CameraIncrementalPlan(CameraImportFormat.RAW)
        val job = store.create("camera", listOf(photo(), photo("2")), CameraImportDestination(), incremental = plan)
        val part = store.partial(job.id); part.writeBytes(raw)
        val paused = store.publish(job, 0, part, hash(raw), CameraTransferPermit()).copy(status = CameraJobStatus.PAUSED)
        store.save(paused)
        fixture.media.file(checkNotNull(paused.items.first().saved).uri).writeText("external change")
        val recovered = checkNotNull(store.recover(job.id))
        assertEquals(CameraMediaProblem.CHANGED, recovered.items.first().problem)
        assertNull(recovered.items.first().saved)
        val missing = recovered.copy(items = recovered.items.map { it.copy(problem = CameraMediaProblem.REMOTE_MISSING) })
        val resumed = receiveCameraJob(store, missing, CameraTransferPermit(), { _, _ -> error("No remote original") })
        assertEquals(CameraJobStatus.PAUSED, resumed.status)
        assertFalse(resumed.committed)
    }

    @Test fun manualImportAppliesJpegOptionsPersistsAcrossLoadAndSkipsRawSampling() = withStore { fixture, _ ->
        val resizedBytes = "resized-manual-jpeg".toByteArray()
        var processedCalls = 0
        val store = CameraImportStore(File(fixture.root, "jobs"), File(fixture.root, "partial"), fixture.media,
            { fixture.capture }, processJpeg = { _, destination, options ->
                processedCalls++
                assertEquals(CameraJPEGOptions(true, 2048, 85), options)
                destination.writeBytes(resizedBytes)
                CameraProcessedFile(resizedBytes.size.toLong(), hash(resizedBytes))
            })
        val bigJpeg = jpeg.copyOf(256 * 1024)
        val unadjustedPhoto = CameraPhoto("big-jpeg-1", "DSC02.JPG", bigJpeg.size.toLong(), 1_700_000_000_000L, storageToken = "card")
        val plainJob = store.create("camera", listOf(unadjustedPhoto), CameraImportDestination())
        val plainPart = store.partial(plainJob.id).apply { writeBytes(bigJpeg) }
        val plainComplete = store.publish(plainJob, 0, plainPart, hash(bigJpeg), CameraTransferPermit())
        val plainUri = checkNotNull(plainComplete.items.single().saved).uri

        val rawPhoto = CameraPhoto("raw-1", "DSC01.ARW", raw.size.toLong(), 1_700_000_000_000L, storageToken = "card")
        val jpegOptions = CameraJPEGOptions(adjust = true, longEdge = 2048, quality = 85)
        val manualJob = store.create("camera", listOf(rawPhoto, unadjustedPhoto), CameraImportDestination(), jpeg = jpegOptions)
        assertEquals(jpegOptions, manualJob.effectiveJpeg)
        assertNull(manualJob.jpegOptions(manualJob.items[0]))
        assertEquals(jpegOptions, manualJob.jpegOptions(manualJob.items[1]))

        val samplingOutput = File(fixture.root, "sampling-unused.jpg")
        assertNull(java.io.FileOutputStream(samplingOutput).use { out ->
            store.copySampledOriginal(manualJob, unadjustedPhoto, out, CameraTransferPermit()) { offset, length ->
                bigJpeg.copyOfRange(offset.toInt(), offset.toInt() + length)
            }
        })

        val completed = receiveCameraJob(store, manualJob, CameraTransferPermit(), { photo, output ->
            val bytes = if (photo.raw) raw else bigJpeg
            output.write(bytes)
            hash(bytes)
        })
        assertEquals(CameraJobStatus.COMPLETE, completed.status)
        assertEquals(1, processedCalls)
        val rawUri = checkNotNull(completed.items[0].saved).uri
        val adjustedUri = checkNotNull(completed.items[1].saved).uri
        assertNotEquals(plainUri, adjustedUri)
        assertEquals(resizedBytes.size.toLong(), completed.items[1].outputSize)
        assertArrayEquals(raw, fixture.media.file(rawUri).readBytes())
        assertArrayEquals(resizedBytes, fixture.media.file(adjustedUri).readBytes())

        val reloaded = CameraImportStore(File(fixture.root, "jobs"), File(fixture.root, "partial"), fixture.media,
            { fixture.capture }).load().first { it.id == manualJob.id }
        assertEquals(jpegOptions, reloaded.jpeg)
        assertEquals(jpegOptions, reloaded.effectiveJpeg)
        val keptOriginals = manualJob.keepingPendingJpegOriginals()
        assertNull(keptOriginals.jpegOptions(keptOriginals.items[1]))
    }

    private class FileMedia(private val root: File) : MediaPhotoAccess {
        val rows = linkedMapOf<String, MediaPhoto>()
        var failBeforePublish = false
        var failAfterPublish = false
        // 计数探针：JVM 里 load 路径的整文件 digest 恰好等于一次 open+全量读，用它数 digest 次数。
        var opens = 0
        // 模拟个别 MediaProvider 在 IS_PENDING 期间就提前回填元数据的机型行为。
        var pendingStatOverride: MediaPhotoStat? = null
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
        override fun open(uri: String): InputStream { opens++; return file(uri).inputStream() }
        // 模拟真机 MediaProvider：IS_PENDING=1 期间 SIZE/DATE_MODIFIED 未定稿，publish（IS_PENDING=0）后才可 stat。
        override fun stat(uri: String): MediaPhotoStat? {
            val row = rows[uri] ?: return null
            if (!row.pending) return file(uri).takeIf { it.isFile }?.let { MediaPhotoStat(it.length(), it.lastModified()) }
            return pendingStatOverride
        }
        override fun remember(uri: String, size: Long, digest: String) = Unit
        override fun deletePending(uri: String) { if (rows[uri]?.pending == true) { file(uri).delete(); rows.remove(uri) } }
        override fun cleanupOrphans(referenced: Set<String>) {
            rows.values.filter { it.pending && it.uri !in referenced }.map { it.uri }.forEach(::deletePending)
        }
    }
}
