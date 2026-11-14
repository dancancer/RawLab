package com.rawlab.android.camera

import com.rawlab.android.R
import com.rawlab.android.camera.protocol.CameraMediaSession
import com.rawlab.android.camera.protocol.SonyMobileSession
import com.rawlab.android.photo.MediaPhoto
import com.rawlab.android.photo.MediaPhotoAccess
import com.rawlab.android.photo.MediaPhotoStat
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.net.SocketException
import java.nio.file.Files
import java.security.MessageDigest

class CameraImportAuditTest {
    private val rawBytes = byteArrayOf(73, 73, 42, 0, 8, 0, 0, 0) + ByteArray(96) { it.toByte() }
    private val jpegBytes = byteArrayOf(-1, -40, -1, -32, 0, 16, 74, 70, 73, 70) + ByteArray(96) { it.toByte() }
    private val previewBytes = byteArrayOf(-1, -40, -1, -39)
    private val baseCaptureMillis = 1_730_000_000_000L

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun mobileDevice(): SonyMobileSession.Device = SonyMobileSession.Device(
        "Sony Corporation",
        "ILCE-7CM2",
        "2.00",
        "7654321",
        setOf(0x1001, 0x1002, 0x1003, 0x923c, 0x923d, 0x923e),
    )

    private class FakeImportSession(
        val device: SonyMobileSession.Device,
        private val onDownload: (Int, SonyMobileSession.Asset, OutputStream, SonyMobileSession.Progress?) -> String,
    ) : CameraMediaSession {
        private val indexByAsset = java.util.IdentityHashMap<SonyMobileSession.Asset, Int>()
        var listed: List<SonyMobileSession.Asset> = emptyList()
        var openCalls = 0
        var closeCalls = 0
        var closed = false
        val downloadedNames = mutableListOf<String>()

        fun asset(
            index: Int,
            name: String = "DSC%05d.ARW".format(index),
            size: Long = 104L,
            created: Long = 1_730_000_000_000L + index * 1_000L,
        ): SonyMobileSession.Asset = SonyMobileSession.Asset(this, index, index, name, size, created).also {
            indexByAsset[it] = index
        }

        override fun isOpen(): Boolean = !closed
        override fun deviceInfo(): SonyMobileSession.Device = device
        override fun openSession() {
            if (closed) throw IOException("Session closed")
            openCalls++
        }
        override fun listPhotos(device: SonyMobileSession.Device): List<SonyMobileSession.Asset> {
            if (closed) throw IOException("Session closed")
            return listed
        }
        override fun preview(asset: SonyMobileSession.Asset, large: Boolean): ByteArray {
            if (closed || !indexByAsset.containsKey(asset)) throw IOException("Preview unavailable")
            return byteArrayOf(-1, -40, -1, -39)
        }
        override fun download(
            device: SonyMobileSession.Device,
            asset: SonyMobileSession.Asset,
            destination: OutputStream,
            progress: SonyMobileSession.Progress?,
        ): String {
            if (closed) throw IOException("Session closed")
            val index = indexByAsset[asset] ?: throw IOException("Asset outside session")
            downloadedNames += asset.name
            return onDownload(index, asset, destination, progress)
        }
        override fun close() {
            closed = true
            closeCalls++
        }
    }

    private class TestMedia(private val root: File) : MediaPhotoAccess {
        val rows = linkedMapOf<String, MediaPhoto>()
        private var next = 0
        fun file(uri: String) = File(root, uri.substringAfterLast('/'))
        override fun createPending(name: String, relativePath: String, mime: String, token: String): MediaPhoto {
            val uri = "content://media/external_primary/images/media/${++next}"
            return MediaPhoto(uri, name, relativePath, true).also {
                rows[uri] = it
                file(uri).writeBytes(byteArrayOf())
            }
        }
        override fun write(uri: String, source: File) { source.copyTo(file(uri), overwrite = true) }
        override fun publish(uri: String): MediaPhoto =
            rows.getValue(uri).copy(pending = false).also { rows[uri] = it }
        override fun inspect(uri: String): MediaPhoto? = rows[uri]?.takeIf { file(uri).isFile }
        override fun open(uri: String) = file(uri).inputStream()
        // 真机语义：publish（IS_PENDING=0）前 MediaStore 元数据未定稿，stat 不可用。
        override fun stat(uri: String): MediaPhotoStat? =
            rows[uri]?.takeIf { !it.pending }?.let { file(uri) }?.takeIf { it.isFile }
                ?.let { MediaPhotoStat(it.length(), it.lastModified()) }
        override fun remember(uri: String, size: Long, digest: String) = Unit
        override fun deletePending(uri: String) {
            if (rows[uri]?.pending == true) {
                file(uri).delete()
                rows.remove(uri)
            }
        }
        override fun cleanupOrphans(referenced: Set<String>) {
            rows.values.filter { it.pending && it.uri !in referenced }.map { it.uri }.forEach(::deletePending)
        }
    }

    private fun withTempRoot(block: (File) -> Unit) {
        val root = Files.createTempDirectory("camera-audit-test").toFile()
        try { block(root) } finally { root.deleteRecursively() }
    }

    @Test
    fun middlePhotoPerItemErrorsContinueImportKeepSessionOpenAndRecordError() = withTempRoot { root ->
        data class Case(
            val label: String,
            val middleName: String = "DSC00002.ARW",
            val adjustJpeg: Boolean = false,
            val expectedErrorSubstring: String,
            val middleDownload: (OutputStream) -> String,
        )

        val firstRaw = rawBytes.copyOf().also { it[10] = 1 }
        val thirdRaw = rawBytes.copyOf().also { it[10] = 3 }
        val firstJpeg = jpegBytes.copyOf().also { it[20] = 1 }
        val thirdJpeg = jpegBytes.copyOf().also { it[20] = 3 }

        val cases = listOf(
            Case(
                label = "camera_error_code",
                expectedErrorSubstring = "0x2002",
                middleDownload = { throw SonyMobileSession.ResponseException(0x923d, 0x2002) },
            ),
            Case(
                label = "header_mismatch",
                expectedErrorSubstring = "Incomplete camera photo",
                middleDownload = { out ->
                    out.write(jpegBytes)
                    sha256(jpegBytes)
                },
            ),
            Case(
                label = "invalid_filename",
                middleName = "DSC:00002.ARW",
                expectedErrorSubstring = "Invalid camera filename",
                middleDownload = { out ->
                    out.write(rawBytes)
                    sha256(rawBytes)
                },
            ),
            Case(
                label = "jpeg_decode_failed",
                middleName = "DSC00002.JPG",
                adjustJpeg = true,
                expectedErrorSubstring = "Cannot decode camera JPEG",
                middleDownload = { out ->
                    out.write(jpegBytes)
                    sha256(jpegBytes)
                },
            ),
        )

        for (case in cases) {
            val caseDir = File(root, case.label).apply { mkdirs() }
            val media = TestMedia(File(caseDir, "media").apply { mkdirs() })
            val capture = CameraCaptureDate.parse("2026:11:13 10:00:00", "+08:00")
            val store = CameraImportStore(
                File(caseDir, "jobs"),
                File(caseDir, "partial"),
                media,
                { capture },
                processJpeg = { source, destination, _ ->
                    if (source.readBytes().contentEquals(jpegBytes)) {
                        throw CameraPhotoImportException("Cannot decode camera JPEG")
                    }
                    source.copyTo(destination, overwrite = true)
                    val bytes = destination.readBytes()
                    CameraProcessedFile(bytes.size.toLong(), sha256(bytes))
                },
            )
            val device = mobileDevice()
            val session = FakeImportSession(device) { index, _, output, progress ->
                when (index) {
                    1 -> {
                        val payload = if (case.adjustJpeg) firstJpeg else firstRaw
                        output.write(payload)
                        progress?.transferred(payload.size.toLong(), payload.size.toLong())
                        sha256(payload)
                    }
                    2 -> case.middleDownload(output)
                    3 -> {
                        val payload = if (case.adjustJpeg) thirdJpeg else thirdRaw
                        output.write(payload)
                        progress?.transferred(payload.size.toLong(), payload.size.toLong())
                        sha256(payload)
                    }
                    else -> error("Unexpected file $index")
                }
            }
            val extension = if (case.adjustJpeg) "JPG" else "ARW"
            val payloadSize = (if (case.adjustJpeg) firstJpeg else firstRaw).size.toLong()
            val assets = listOf(
                session.asset(1, "DSC00001.$extension", payloadSize, baseCaptureMillis + 1_000L),
                session.asset(2, case.middleName, payloadSize, baseCaptureMillis + 2_000L),
                session.asset(3, "DSC00003.$extension", payloadSize, baseCaptureMillis + 3_000L),
            )
            session.listed = assets
            session.openSession()

            val owner = "owner-${case.label}"
            val incremental = if (case.adjustJpeg) {
                CameraIncrementalPlan(
                    CameraImportFormat.JPEG,
                    CameraJPEGOptions(adjust = true, longEdge = 2048, quality = 85),
                    sessionOwner = owner,
                )
            } else null
            val job = store.create(
                cameraId = "BLE:sony",
                photos = assets.map { it.photo() },
                destination = CameraImportDestination(),
                incremental = incremental,
                hardwareIdentity = CameraHardwareIdentity.read(device),
                listingOwner = owner,
            )

            val result = runBlocking {
                executeCameraSessionQueue(
                    store = store,
                    opened = session,
                    info = device,
                    initialJob = job,
                    listedAssets = assets.associateBy { it.key() },
                    incrementalOwner = owner,
                    allowed = CameraTransferPermit(),
                )
            }

            assertNull(case.label, result.failure)
            assertFalse(case.label, result.shouldDisconnect)
            assertTrue(case.label, session.isOpen)
            assertEquals(case.label, 0, session.closeCalls)
            assertEquals(case.label, listOf(assets[0].name, assets[1].name, assets[2].name), session.downloadedNames)
            assertEquals(case.label, CameraJobStatus.PAUSED, result.job.status)
            assertFalse(case.label, result.job.committed)
            assertEquals(case.label, 2, result.job.savedCount)
            assertEquals(case.label, 1, result.job.failedCount)
            assertNotNull(case.label, result.job.items[0].saved)
            assertNull(case.label, result.job.items[1].saved)
            assertNotNull(case.label, result.job.items[2].saved)
            val recordedError = result.job.items[1].error
            assertNotNull(case.label, recordedError)
            assertTrue("${case.label}: $recordedError", recordedError!!.contains(case.expectedErrorSubstring))
            assertEquals(case.label, 2, store.savedUris(result.job).size)
        }
    }

    @Test
    fun connectionLevelErrorStillAbortsQueueAndDisconnectsSession() = withTempRoot { root ->
        val firstRaw = rawBytes.copyOf().also { it[10] = 11 }
        val thirdRaw = rawBytes.copyOf().also { it[10] = 33 }

        for (mode in listOf("socket_disconnect", "session_not_open")) {
            val subDir = File(root, mode).apply { mkdirs() }
            val media = TestMedia(File(subDir, "media").apply { mkdirs() })
            val store = CameraImportStore(File(subDir, "jobs"), File(subDir, "partial"), media) { null }
            val device = mobileDevice()
            lateinit var session: FakeImportSession
            session = FakeImportSession(device) { index, _, output, _ ->
                when (index) {
                    1 -> {
                        output.write(firstRaw)
                        sha256(firstRaw)
                    }
                    2 -> {
                        if (mode == "socket_disconnect") {
                            session.closed = true
                            throw SocketException("Connection reset")
                        } else {
                            throw SonyMobileSession.ResponseException(0x923d, 0x2003)
                        }
                    }
                    3 -> {
                        output.write(thirdRaw)
                        sha256(thirdRaw)
                    }
                    else -> error("Unexpected file $index")
                }
            }
            val assets = (1..3).map { session.asset(it, size = firstRaw.size.toLong()) }
            session.listed = assets
            session.openSession()

            val owner = "owner-$mode"
            val job = store.create(
                cameraId = "BLE:sony",
                photos = assets.map { it.photo() },
                destination = CameraImportDestination(),
                hardwareIdentity = CameraHardwareIdentity.read(device),
                listingOwner = owner,
            )

            val result = runBlocking {
                executeCameraSessionQueue(
                    store = store,
                    opened = session,
                    info = device,
                    initialJob = job,
                    listedAssets = assets.associateBy { it.key() },
                    incrementalOwner = owner,
                    allowed = CameraTransferPermit(),
                )
            }

            assertNotNull(mode, result.failure)
            assertTrue(mode, result.shouldDisconnect)
            assertEquals(mode, listOf("DSC00001.ARW", "DSC00002.ARW"), session.downloadedNames)
            assertEquals(mode, CameraJobStatus.PAUSED, result.job.status)
            assertEquals(mode, 1, result.job.savedCount)
            assertNull(mode, result.job.items[1].error)
            assertNull(mode, result.job.items[2].saved)
        }
    }

    @Test
    fun retryImportsRecoveredPhotoWhileSkipStopsIncrementalCheckpointBeforeSkippedFile() = withTempRoot { root ->
        val media = TestMedia(File(root, "media").apply { mkdirs() })
        val store = CameraImportStore(File(root, "jobs"), File(root, "partial"), media) { null }
        val device = mobileDevice()
        val payloads = mapOf(
            1 to rawBytes.copyOf().also { it[5] = 1 },
            2 to rawBytes.copyOf().also { it[5] = 2 },
            3 to rawBytes.copyOf().also { it[5] = 3 },
        )
        var failSecond = true
        val session = FakeImportSession(device) { index, _, output, _ ->
            if (index == 2 && failSecond) throw SonyMobileSession.ResponseException(0x923d, 0x2002)
            val bytes = payloads.getValue(index)
            output.write(bytes)
            sha256(bytes)
        }
        val assets = (1..3).map { index ->
            session.asset(index, size = rawBytes.size.toLong(), created = baseCaptureMillis + index * 10_000L)
        }
        session.listed = assets
        session.openSession()

        val owner = "incremental-owner"
        val photos = assets.map { it.photo() }
        val initialScan = CameraIncrementalScan(
            listing = photos,
            checkpoints = emptyMap(),
            cutoff = baseCaptureMillis,
            customCutoff = null,
            format = CameraImportFormat.RAW,
            includeUndated = false,
            sessionOwner = owner,
        )
        val plan = CameraIncrementalPlan(
            format = CameraImportFormat.RAW,
            sessionOwner = owner,
            checkpoints = initialScan.nextCheckpoints,
        )
        val job = store.create(
            cameraId = "BLE:sony",
            photos = initialScan.assets,
            destination = CameraImportDestination(),
            incremental = plan,
            hardwareIdentity = CameraHardwareIdentity.read(device),
            listingOwner = owner,
        )

        val partial = runBlocking {
            executeCameraSessionQueue(
                store = store,
                opened = session,
                info = device,
                initialJob = job,
                listedAssets = assets.associateBy { it.key() },
                incrementalOwner = owner,
                allowed = CameraTransferPermit(),
            )
        }
        assertEquals(CameraJobStatus.PAUSED, partial.job.status)
        assertFalse(partial.job.committed)
        assertTrue(committedIncrementalCheckpoints(listOf(partial.job)).isEmpty())

        // Verify Retry path: fixing photo 2 and resuming downloads only photo 2 and completes checkpoint at photo 3.
        val retryRoot = File(root, "retry-copy").apply { mkdirs() }
        val retryMedia = TestMedia(File(retryRoot, "media").apply { mkdirs() })
        val retryStore = CameraImportStore(File(retryRoot, "jobs"), File(retryRoot, "partial"), retryMedia) { null }
        val retryJob = retryStore.create(
            cameraId = "BLE:sony",
            photos = initialScan.assets,
            destination = CameraImportDestination(),
            incremental = plan,
            hardwareIdentity = CameraHardwareIdentity.read(device),
            listingOwner = owner,
        )
        failSecond = true
        val retryInitial = runBlocking {
            executeCameraSessionQueue(
                store = retryStore,
                opened = session,
                info = device,
                initialJob = retryJob,
                listedAssets = assets.associateBy { it.key() },
                incrementalOwner = owner,
                allowed = CameraTransferPermit(),
            )
        }
        assertEquals(1, retryInitial.job.failedCount)
        session.downloadedNames.clear()
        failSecond = false
        val retried = runBlocking {
            executeCameraSessionQueue(
                store = retryStore,
                opened = session,
                info = device,
                initialJob = retryInitial.job,
                listedAssets = assets.associateBy { it.key() },
                incrementalOwner = owner,
                allowed = CameraTransferPermit(),
                resuming = true,
            )
        }
        assertEquals(listOf("DSC00002.ARW"), session.downloadedNames)
        assertEquals(CameraJobStatus.COMPLETE, retried.job.status)
        assertTrue(retried.job.committed)
        assertEquals(
            photos[2].captureDateMillis,
            committedIncrementalCheckpoints(listOf(retried.job))[CameraImportFormat.RAW]?.dateMillis,
        )

        // Verify Skip path: skipping failed photo 2 commits checkpoint strictly at photo 1 (before photo 2).
        val skipped = skipFailedCameraItems(store, partial.job)
        assertTrue(skipped.items[1].skipped)
        assertEquals(CameraJobStatus.PAUSED, skipped.status)
        assertTrue(skipped.committed)
        val safeCheckpoint = committedIncrementalCheckpoints(listOf(skipped))[CameraImportFormat.RAW]
        assertNotNull(safeCheckpoint)
        assertEquals(photos[0].captureDateMillis, safeCheckpoint!!.dateMillis)
        assertEquals(setOf(photos[0].key), safeCheckpoint.keys)

        val scanAfterSkip = CameraIncrementalScan(
            listing = photos,
            checkpoints = committedIncrementalCheckpoints(listOf(skipped)),
            cutoff = baseCaptureMillis,
            customCutoff = null,
            format = CameraImportFormat.RAW,
            includeUndated = false,
            savedKeys = setOf(photos[0].key, photos[2].key),
            sessionOwner = owner,
        )
        // Photo 1 is before checkpoint, photo 3 is already saved, and photo 2 was NOT silently crossed by checkpoint.
        assertEquals(listOf(photos[1]), scanAfterSkip.assets)
    }

    @Test
    fun cardExceeding10000FilesReportsPhotoLimitWithoutDisconnectingAndSessionStaysUsable() = withTempRoot { root ->
        val device = mobileDevice()
        val payload = rawBytes.copyOf()
        val session = FakeImportSession(device) { _, _, output, progress ->
            output.write(payload)
            progress?.transferred(payload.size.toLong(), payload.size.toLong())
            sha256(payload)
        }
        session.listed = (1..10_001).map { index ->
            session.asset(
                index = index,
                name = "DSC%05d.ARW".format(index),
                size = payload.size.toLong(),
                created = baseCaptureMillis + index * 1_000L,
            )
        }

        val connected = runBlocking {
            openCameraImportSession(
                createMobile = { session },
                createLegacy = { error("Should not fall back to legacy") },
            )
        }
        assertTrue(connected.listing.limitExceeded)
        assertEquals(CameraMediaSession.MAX_LISTED_PHOTOS, connected.listing.assets.size)
        assertTrue(session.isOpen)
        assertEquals(0, session.closeCalls)

        for (mode in listOf(CameraImportMode.MANUAL, CameraImportMode.INCREMENTAL)) {
            val state = CameraImportState(preparing = false).withConnectedListing(
                cameraId = "BLE:sony",
                opened = connected.session,
                info = connected.device,
                listing = connected.listing,
                owner = "limit-owner",
                mode = mode,
            )
            assertTrue(mode.name, state.connected)
            assertEquals(mode.name, CameraImportFailure.PHOTO_LIMIT_EXCEEDED, state.failure)
            assertNotEquals(mode.name, R.string.camera_disconnected, state.message)
            assertEquals(mode.name, R.string.camera_incremental_oversized, state.message)
            assertEquals(mode.name, 10_000, state.photos.size)
            assertEquals(mode.name, "DSC10001.ARW", state.photos.first().name)
            assertEquals(mode.name, "DSC00002.ARW", state.photos.last().name)
        }

        // Session remains open and usable for both preview and importing from the retained recent photos.
        val newestAsset = connected.listing.assets.first()
        assertArrayEquals(previewBytes, session.preview(newestAsset, false))

        val media = TestMedia(File(root, "media").apply { mkdirs() })
        val store = CameraImportStore(File(root, "jobs"), File(root, "partial"), media) { null }
        val job = store.create(
            cameraId = "BLE:sony",
            photos = listOf(newestAsset.photo()),
            destination = CameraImportDestination(),
            hardwareIdentity = CameraHardwareIdentity.read(device),
            listingOwner = "limit-owner",
        )
        val imported = runBlocking {
            executeCameraSessionQueue(
                store = store,
                opened = session,
                info = device,
                initialJob = job,
                listedAssets = connected.listing.assets.associateBy { it.key() },
                incrementalOwner = "limit-owner",
                allowed = CameraTransferPermit(),
            )
        }
        assertNull(imported.failure)
        assertFalse(imported.shouldDisconnect)
        assertEquals(CameraJobStatus.COMPLETE, imported.job.status)
        assertEquals(1, imported.job.savedCount)
        assertTrue(session.isOpen)
        assertEquals(0, session.closeCalls)
    }
}
