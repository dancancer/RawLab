package com.rawlab.android.camera

import org.junit.Assert.*
import org.junit.Test
import java.util.TimeZone

class CameraImportDestinationTest {
    @Test fun usesEachOriginalCaptureDayInsteadOfImportDay() {
        val destination = CameraImportDestination()
        assertEquals("Pictures/RawLab/Camera/2026-10-22/",
            destination.relativePath(CameraCaptureDate.parse("2026:10:22 23:59:58", "+08:00")))
        assertEquals("Pictures/RawLab/Camera/2026-10-23/",
            destination.relativePath(CameraCaptureDate.parse("2026:10:23 00:00:01", "+08:00")))
    }

    @Test fun phoneTimezoneDoesNotChangeTheOriginalLocalDate() {
        val previous = TimeZone.getDefault()
        try {
            for (zone in listOf("Pacific/Honolulu", "Asia/Tokyo")) {
                TimeZone.setDefault(TimeZone.getTimeZone(zone))
                assertEquals("Pictures/RawLab/Camera/2024-02-29/", CameraImportDestination().relativePath(
                    CameraCaptureDate.parse("2024:02:29 00:10:00", "+14:00")))
            }
        } finally { TimeZone.setDefault(previous) }
    }

    @Test fun invalidOrMissingOriginalDateUsesUnknownWithoutInventingADate() {
        for (original in listOf(null, "", "2023:02:29 12:00:00", "2026:13:01 12:00:00", "0000:00:00 00:00:00", "2026:10:22")) {
            assertNull(CameraCaptureDate.parse(original, null))
            assertEquals("Pictures/RawLab/Camera/Unknown date/", CameraImportDestination().relativePath(
                CameraCaptureDate.parse(original, null)))
        }
    }

    @Test fun monthAndSingleDirectoryRulesKeepTheConfiguredDirectory() {
        val date = CameraCaptureDate.parse("2026:10:22 18:28:03", null)
        assertEquals("Pictures/摄影/索尼/2026-10/", CameraImportDestination("摄影/索尼", CameraDirectoryGrouping.CAPTURE_MONTH).relativePath(date))
        assertEquals("Pictures/摄影/索尼/", CameraImportDestination("摄影/索尼", CameraDirectoryGrouping.NONE).relativePath(date))
        assertEquals("Pictures/摄影/索尼/", CameraImportDestination("摄影/索尼", CameraDirectoryGrouping.NONE).relativePath(null))
    }

    @Test fun unsafeOrHiddenPathsCannotEscapeOrHideTheMediaDirectory() {
        for (directory in listOf("", "/Camera", "../Camera", "RawLab/../Camera", "RawLab//Camera", "RawLab/.private", "RawLab\\Camera", "RawLab/Camera:", "RawLab/Camera ", "RawLab\nCamera")) {
            assertThrows(directory, IllegalArgumentException::class.java) { CameraImportDestination(directory) }
        }
    }
}
