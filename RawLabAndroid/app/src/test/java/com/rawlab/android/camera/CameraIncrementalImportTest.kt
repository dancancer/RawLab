package com.rawlab.android.camera

import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneOffset

class CameraIncrementalImportTest {
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
            assets = listOf(old, sameMomentNew, later), boundary = boundary,
            cutoff = boundaryTime - 86_400_000, customCutoff = null,
            format = CameraImportFormat.RAW_AND_JPEG, includeUndated = false,
            sessionOwner = "camera", storage = setOf("card-a"),
        )
        assertFalse(result.needsCutoffConfirmation)
        assertEquals(listOf("new-at-boundary", "later"), result.assets.map { it.key })
        assertEquals(boundaryTime + 1_000, result.nextBoundary?.dateMillis)
    }

    @Test fun changedCardRequiresExplicitCutoffBeforeCreatingAPlan() {
        val boundary = CameraImportBoundary(1_000, setOf("old-card"), setOf("old"), setOf("old"), "camera")
        val result = CameraIncrementalScan(
            assets = listOf(photo("new", 2_000)), boundary = boundary,
            cutoff = 0, customCutoff = null,
            format = CameraImportFormat.RAW, includeUndated = false,
            sessionOwner = "camera", storage = setOf("new-card"),
        )
        assertTrue(result.needsCutoffConfirmation)
        assertTrue(result.assets.isEmpty())
        assertNull(result.nextBoundary)
    }

    @Test fun reconnectChecksBoundaryObjectsWithoutAssumingTheOldSessionLocatorIsPermanent() {
        val time = 1_761_128_883_000L
        val old = CameraPhoto("17:1:DSC001.JPG:10:$time", "DSC001.JPG", 10, time, "mobile")
        val current = old.copy(key = "42:1:DSC001.JPG:10:$time")
        val boundary = CameraImportBoundary(time, setOf("mobile"), setOf(old.key), setOf(old.anchorKey), "old-session")
        val result = CameraIncrementalScan(listOf(current), boundary, time - 1, null,
            CameraImportFormat.JPEG, false, emptySet(), "new-session", setOf("mobile"))
        assertFalse(result.needsCutoffConfirmation)
        assertEquals(listOf(current), result.assets)
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

    private fun photo(key: String, created: Long) = CameraPhoto(key, "$key.ARW", 10, created)

    private fun legacyClock(value: String): Long =
        java.time.LocalDateTime.parse(value, java.time.format.DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss"))
            .toInstant(ZoneOffset.UTC).toEpochMilli()
}
