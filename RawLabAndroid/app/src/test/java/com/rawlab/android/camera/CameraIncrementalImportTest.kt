package com.rawlab.android.camera

import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneOffset

class CameraIncrementalImportTest {
    private val digest = "a".repeat(64)
    @Test fun modernMillisecondsAndLegacyClockUseTheSupportedCaptureWindow() {
        val modern = CameraPhoto("12:1:DSC00001.ARW:10:1761128883000", "DSC00001.ARW", 10, 1761128883000)
        val legacy = CameraPhoto("3:42:1:10:DSC00001.ARW:20261022T182803:20261022T182804", "DSC00001.ARW", 10,
            legacyClock("20261022T182803"))
        assertEquals(1761128883000, modern.captureDateMillis)
        assertEquals("2026-10-22", CameraIncrementalScan.day(legacy.captureDateMillis!!))
        assertNull(CameraPhoto("unknown", "DSC00001.ARW", 10, 42).captureDateMillis)
        assertNull(CameraPhoto("future", "DSC00001.ARW", 10, 4102444800000).captureDateMillis)
    }

    @Test fun scanIncludesNewObjectsAtTheSuccessfulBoundaryButSkipsKnownKeys() {
        val boundaryTime = LocalDate.of(2026, 10, 22).atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli()
        val old = photo("old", boundaryTime)
        val boundary = CameraImportBoundary(boundaryTime, setOf("card-a"), setOf(old.key), setOf(old.anchorKey), "camera")
        val sameMomentNew = photo("new-at-boundary", boundaryTime)
        val later = photo("later", boundaryTime + 1_000)
        val result = CameraIncrementalScan(
            listing = listOf(old, sameMomentNew, later), checkpoints = mapOf(CameraImportFormat.RAW to boundary),
            cutoff = boundaryTime - 86_400_000, customCutoff = null,
            format = CameraImportFormat.RAW_AND_JPEG, includeUndated = false,
            sessionOwner = "camera",
        )
        assertFalse(result.needsCutoffConfirmation)
        assertEquals(listOf("new-at-boundary", "later"), result.assets.map { it.key })
        assertEquals(boundaryTime + 1_000, result.nextCheckpoints[CameraImportFormat.RAW]?.dateMillis)
    }

    @Test fun changedCardRequiresExplicitCutoffBeforeCreatingAPlan() {
        val boundary = CameraImportBoundary(1_000, setOf("old-card"), setOf("old"), setOf("old"), "camera")
        val result = CameraIncrementalScan(
            listing = listOf(photo("new", 2_000).copy(storageToken = "new-card")),
            checkpoints = mapOf(CameraImportFormat.RAW to boundary),
            cutoff = 0, customCutoff = null,
            format = CameraImportFormat.RAW, includeUndated = false,
            sessionOwner = "camera",
        )
        assertTrue(result.needsCutoffConfirmation)
        assertTrue(result.assets.isEmpty())
        assertTrue(result.nextCheckpoints.isEmpty())
    }

    @Test fun reconnectRequiresCutoffEvenWhenMetadataMatchesAndRetainsEarlierPhotos() {
        val time = 1_761_128_883_000L
        val old = CameraPhoto("17:1:DSC001.JPG:10:$time", "DSC001.JPG", 10, time, storageToken = "mobile")
        val current = old.copy(key = "42:1:DSC001.JPG:10:$time")
        val earlier = current.copy(key = "earlier", name = "EARLIER.JPG", created = time - 1_000,
            captureTimestamp = time - 1_000)
        val boundary = CameraImportBoundary(time, setOf("mobile"), setOf(old.key), setOf(old.anchorKey), "old-session")
        val listing = listOf(current, earlier)
        val previous = mapOf(CameraImportFormat.JPEG to boundary)
        val result = CameraIncrementalScan(listing, previous, time - 1, null,
            CameraImportFormat.JPEG, false, sessionOwner = "new-session")
        assertTrue(result.needsCutoffConfirmation)
        assertTrue(result.assets.isEmpty())
        assertTrue(result.nextCheckpoints.isEmpty())

        val confirmed = CameraIncrementalScan(listing, previous, time - 1, time - 1_000,
            CameraImportFormat.JPEG, false, sessionOwner = "new-session")
        assertEquals(listOf(earlier, current), confirmed.assets)
        val next = confirmed.nextCheckpoints
        assertEquals("new-session", next[CameraImportFormat.JPEG]?.owner)
        val repeat = CameraIncrementalScan(listing, next, time - 1, null,
            CameraImportFormat.JPEG, false, sessionOwner = "new-session")
        assertFalse(repeat.needsCutoffConfirmation)
        assertTrue(repeat.assets.isEmpty())
    }

    @Test fun legacyDefaultCutoffUsesTodayOnTheLocalCalendar() {
        val shanghai = java.time.ZoneId.of("Asia/Shanghai")
        val day = LocalDate.of(2026, 10, 22)
        val now = day.atTime(1, 0).atZone(shanghai).toInstant().toEpochMilli()
        assertEquals(day.atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli(),
            CameraIncrementalScan.defaultCutoffMillis(now, shanghai, ZoneOffset.UTC))
    }

    @Test fun jpegOptionsUseTheStableDefaultsAndRejectOutOfRangeValues() {
        assertEquals(CameraJPEGOptions(false, null, 90), CameraJPEGOptions())
        assertTrue(CameraJPEGOptions(true, 2048, 1).isValid)
        assertTrue(CameraJPEGOptions(true, 65535, 100).isValid)
        assertFalse(CameraJPEGOptions(true, 0, 90).isValid)
        assertFalse(CameraJPEGOptions(true, 65536, 90).isValid)
        assertFalse(CameraJPEGOptions(true, 2048, 0).isValid)
        assertFalse(CameraJPEGOptions(true, 2048, 101).isValid)
    }

    @Test fun combinedScanUsesIndependentRawAndJpegCheckpoints() {
        val rawTime = 1_700_000_000_000L
        val jpegTime = rawTime + 10_000
        val assets = listOf(
            CameraPhoto("raw-old", "old.ARW", 10, rawTime, storageToken = "card"),
            CameraPhoto("raw-new", "new.ARW", 10, rawTime + 1_000, storageToken = "card"),
            CameraPhoto("jpeg-old", "old.JPG", 10, jpegTime, storageToken = "card"),
            CameraPhoto("jpeg-new", "new.JPG", 10, jpegTime + 1_000, storageToken = "card"),
        )
        val rawCheckpoint = CameraImportBoundary(rawTime, setOf("card"), setOf("raw-old"), setOf(assets[0].anchorKey), "session")
        val jpegCheckpoint = CameraImportBoundary(jpegTime, setOf("card"), setOf("jpeg-old"), setOf(assets[2].anchorKey), "session")
        val scan = CameraIncrementalScan(assets,
            mapOf(CameraImportFormat.RAW to rawCheckpoint, CameraImportFormat.JPEG to jpegCheckpoint), rawTime - 1, null,
            CameraImportFormat.RAW_AND_JPEG, false, sessionOwner = "session")
        assertEquals(listOf("raw-new", "jpeg-new"), scan.assets.map { it.key })
        assertEquals(rawTime + 1_000, scan.nextCheckpoints[CameraImportFormat.RAW]?.dateMillis)
        assertEquals(jpegTime + 1_000, scan.nextCheckpoints[CameraImportFormat.JPEG]?.dateMillis)
    }

    @Test fun stableRemapPreservesItemIdentityAndSavedUrisAcrossLocatorChanges() {
        val old = CameraPhoto("old-locator", "DSC.JPG", 10, 1_700_000_000_000L, storageToken = "mobile")
        val savedOld = old.copy(key = "saved-old", name = "SAVED.JPG")
        val current = old.copy(key = "new-locator")
        val savedCurrent = savedOld.copy(key = "saved-new")
        val saved = com.rawlab.android.photo.MediaPhoto("content://media/external_primary/images/media/7", "DSC.JPG", "Pictures/", false)
        val job = CameraImportJob("00000000-0000-0000-0000-000000000007", "camera", 1,
            listOf(CameraImportItem(savedOld, saved = saved, digest = digest), CameraImportItem(old, digest = digest)), CameraJobStatus.PAUSED,
            incremental = CameraIncrementalPlan(CameraImportFormat.JPEG))
        val remapped = resumeLocatorMap(job, listOf(savedCurrent, current), "reconnected")
        assertEquals(current.key, remapped[old.key]?.key)
        assertEquals(savedCurrent.key, remapped[savedOld.key]?.key)
        assertEquals(saved, job.items.first().saved)
    }

    @Test fun stableRemapRejectsAmbiguousCurrentLocators() {
        val old = CameraPhoto("old-locator", "DSC.JPG", 10, 1_700_000_000_000L, storageToken = "mobile")
        val current = listOf(old.copy(key = "new-1"), old.copy(key = "new-2"))
        val job = CameraImportJob("00000000-0000-0000-0000-000000000008", "camera", 1,
            listOf(CameraImportItem(old, digest = digest)), CameraJobStatus.PAUSED,
            incremental = CameraIncrementalPlan(CameraImportFormat.JPEG))
        assertTrue(resumeLocatorMap(job, current, "reconnected").isEmpty())
        assertTrue(resumeLocatorMap(job, listOf(old.copy(storageToken = "legacy:2")), "reconnected").isEmpty())
    }

    @Test fun legacyReconnectOnlyIgnoresTheObjectHandle() {
        val old = CameraPhoto("old-locator", "DSC.JPG", 10, 1_700_000_000_000L,
            resumeIdentity = "legacy:65537:7:14337:10:DSC.JPG:20231114T221320:20231114T221400",
            storageToken = "legacy:65537")
        val item = CameraImportItem(old, digest = digest)
        val job = CameraImportJob("00000000-0000-0000-0000-000000000010", "camera", 1, listOf(item),
            CameraJobStatus.PAUSED, incremental = CameraIncrementalPlan(CameraImportFormat.JPEG, sessionOwner = "old"))
        val current = old.copy(key = "new-locator", resumeIdentity = old.resumeIdentity!!.replace(":7:", ":29:"))
        assertEquals(current, resumeLocatorMap(job, listOf(current), "reconnected")[old.key])

        val replaced = current.copy(resumeIdentity = current.resumeIdentity!!.replace("20231114T221400", "20231114T221500"))
        assertTrue(resumeLocatorMap(job, listOf(replaced), "reconnected").isEmpty())
        val differentFormat = current.copy(resumeIdentity = current.resumeIdentity.replace(":14337:", ":14338:"))
        assertTrue(resumeLocatorMap(job, listOf(differentFormat), "reconnected").isEmpty())

        val oldJournal = job.copy(items = listOf(item.copy(photo = old.copy(resumeIdentity = null))))
        assertEquals(current, resumeLocatorMap(oldJournal, listOf(current), "reconnected")[old.key])
    }

    @Test fun autoResumeExcludesCommittedHistoryAndGainMapFailures() {
        val old = CameraPhoto("old-locator", "DSC.JPG", 10, 1_700_000_000_000L, storageToken = "mobile")
        val job = CameraImportJob("00000000-0000-0000-0000-000000000009", "camera", 1,
            listOf(CameraImportItem(old)), CameraJobStatus.PAUSED,
            incremental = CameraIncrementalPlan(CameraImportFormat.JPEG))
        val history = job.copy(committed = true)
        val blocked = job.copy(items = listOf(job.items.single().copy(problem = CameraMediaProblem.HDR_GAIN_MAP)))
        val connected = CameraImportState(photos = listOf(old.copy(key = "new-locator")), connected = true,
            cameraId = "camera", importMode = CameraImportMode.INCREMENTAL, incrementalOwner = "reconnected")
        assertNull(connected.copy(jobs = listOf(history, blocked)).resumableIncrementalJob)
        assertEquals(job, connected.copy(jobs = listOf(job)).resumableIncrementalJob)
        val verified = job.copy(items = listOf(job.items.single().copy(digest = digest)))
        assertEquals(verified, connected.copy(jobs = listOf(verified)).resumableIncrementalJob)
    }

    @Test fun explicitCutoffSeedsOnlyTheKindWithoutAnExistingCheckpoint() {
        val rawTime = 1_700_000_000_000L
        val jpegTime = rawTime + 10_000
        val raw = CameraPhoto("raw", "RAW.ARW", 10, rawTime, storageToken = "card")
        val jpeg = CameraPhoto("jpeg", "JPEG.JPG", 10, jpegTime, storageToken = "card")
        val rawCheckpoint = CameraImportBoundary(rawTime, setOf("card"), setOf(raw.key), setOf(raw.anchorKey), "session")
        val scan = CameraIncrementalScan(listOf(raw, jpeg), mapOf(CameraImportFormat.RAW to rawCheckpoint), 0, 0,
            CameraImportFormat.RAW_AND_JPEG, false, sessionOwner = "session")
        assertFalse(CameraImportFormat.RAW in scan.nextCheckpoints)
        assertEquals(jpegTime, scan.nextCheckpoints[CameraImportFormat.JPEG]?.dateMillis)
    }

    @Test fun rawOnlyCheckpointLeavesBothUnimportedJpegsEligible() {
        val time = 1_700_000_000_000L
        val raw = photo("raw", time)
        val paired = CameraPhoto("paired", "RAW.JPG", 10, time, storageToken = "card-a")
        val later = CameraPhoto("later-jpeg", "LATER.JPG", 10, time + 3_600_000, storageToken = "card-a")
        val card = listOf(raw, paired, later)
        val rawScan = CameraIncrementalScan(card, emptyMap(), time - 1, null,
            CameraImportFormat.RAW, false, sessionOwner = "session")
        assertEquals(setOf(CameraImportFormat.RAW), rawScan.nextCheckpoints.keys)
        assertEquals(time, rawScan.nextCheckpoints[CameraImportFormat.RAW]?.dateMillis)
        val jpegScan = CameraIncrementalScan(card, rawScan.nextCheckpoints, time - 1, null,
            CameraImportFormat.JPEG, false, sessionOwner = "session")
        assertEquals(listOf(paired, later), jpegScan.assets)
    }

    private fun photo(key: String, created: Long) = CameraPhoto(key, "$key.ARW", 10, created, storageToken = "card-a")

    private fun legacyClock(value: String): Long =
        java.time.LocalDateTime.parse(value, java.time.format.DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss"))
            .toInstant(ZoneOffset.UTC).toEpochMilli()
}
