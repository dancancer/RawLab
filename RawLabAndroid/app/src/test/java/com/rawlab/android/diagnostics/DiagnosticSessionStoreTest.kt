package com.rawlab.android.diagnostics

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.nio.charset.StandardCharsets
import java.util.zip.ZipInputStream

class DiagnosticSessionStoreTest {
    @get:Rule
    val tempFolder = TemporaryFolder()

    private val env = DiagnosticEnvironmentInfo(
        platform = "android",
        appVersion = "0.12.1",
        build = "24",
        osVersion = "15",
        deviceModel = "Pixel_9",
    )

    @Test
    fun defaultOffActivityRecreateIdempotenceAndLeaseAutoExpiry() {
        var nowMs = 1_795_000_000_000L
        val dir = tempFolder.newFolder("diag-lease")

        val store1 = DiagnosticSessionStore(dir, env, leaseDurationMs = 1_800_000L, clockMs = { nowMs })
        assertFalse(store1.isRecording)
        store1.recordBreadcrumb(category = "import", stage = "ignored", message = "Off")
        assertEquals(0, store1.stateSnapshot().breadcrumbCount)

        val enabled = store1.setRecordingEnabled(true)
        assertTrue(enabled.isRecording)
        // Simulate multiple MainActivity recreations (rotation / language change) in the same process
        repeat(5) {
            assertTrue("Activity recreation in same process must keep recording on", store1.resumeOnLaunch().isRecording)
        }
        store1.recordBreadcrumb(category = "import", stage = "open", message = "Opened RAW", context = mapOf("extension" to "arw"))
        assertTrue(store1.stateSnapshot().breadcrumbCount >= 2)

        // True process relaunch #1 within 30 minutes stays active even across repeated Activity recreations
        nowMs += 60_000L
        val store2 = DiagnosticSessionStore(dir, env, leaseDurationMs = 1_800_000L, clockMs = { nowMs })
        repeat(4) {
            assertTrue(store2.resumeOnLaunch().isRecording)
        }

        // True process relaunch #2 auto-resets switch to off while keeping logs exportable
        nowMs += 60_000L
        val store3 = DiagnosticSessionStore(dir, env, leaseDurationMs = 1_800_000L, clockMs = { nowMs })
        val relaunch2 = store3.resumeOnLaunch()
        assertFalse(relaunch2.isRecording)
        assertTrue(relaunch2.recoveredPreviousSession)
        assertTrue(relaunch2.hasExportableLogs)
    }

    @Test
    fun redactionSpacedPathsSdCardRealHomeZipIntegrityAndFreshReportIds() {
        val dir = tempFolder.newFolder("diag-zip")
        val appFilesRoot = tempFolder.newFolder("app-files").absolutePath
        val realHome = System.getProperty("user.home").orEmpty()
        val winPath = listOf("D:", "My Photos", "Wedding 2026", "IMG_01.CR3").joinToString("\\")
        val sdCardPath = "/storage/1234-5678/DCIM/Trip Paris/DSC 0002.ARW"
        val homePhotoPath = "$realHome/Pictures/SecretVacation/DSC0001.ARW"

        val store = DiagnosticSessionStore(
            directory = dir,
            environment = env,
            extraRedactedPaths = listOf(appFilesRoot to "<files>"),
        )
        store.setRecordingEnabled(true)
        store.recordBreadcrumb(
            level = "warn",
            category = "preview",
            stage = "openUri",
            message = "Failed reading content://media/external/images/media/9999 and $sdCardPath and $homePhotoPath and $winPath; bare_shot.dng",
            context = mapOf(
                "extension" to "privateext",
                "localFile" to "$appFilesRoot/retained/My Folder/secret_copy.arw",
            ),
        )
        store.recordError(
            operation = "export",
            stage = "writeFile",
            error = IllegalStateException("Failed writing /data/user/0/com.rawlab.android/cache/export_out.jpg"),
            context = mapOf("extension" to "jpg"),
        )

        val pkg1 = store.buildReportPackage(
            userNote = "导出 $sdCardPath 失败",
            stopActiveRecording = true,
            consumeReportID = true,
        )
        assertFalse(store.isRecording)
        assertTrue(DiagnosticReportIds.isValid(pkg1.reportID))

        val allText = pkg1.manifestJSON + "\n" + pkg1.breadcrumbsJSONL + "\n" + pkg1.recentErrorsJSON
        for (forbidden in listOf(
            "DSC0001",
            "SecretVacation",
            "1234-5678",
            "Trip Paris",
            "DSC 0002",
            "My Photos",
            "Wedding 2026",
            "IMG_01",
            "My Folder",
            "secret_copy",
            "export_out",
            "bare_shot",
            "content://media",
            "/data/user/0",
            "privateext",
        )) {
            assertFalse("Leaked '$forbidden' in:\n$allText", allText.contains(forbidden))
        }
        assertTrue(allText.contains("<files>"))
        assertTrue(allText.contains("<file>.dng"))
        assertTrue(allText.contains("\"extension\": \"unknown\"") || allText.contains("\"extension\":\"unknown\""))

        // Subsequent report after consuming reportID gets a brand-new reportID
        val pkg2 = store.buildReportPackage(stopActiveRecording = false, consumeReportID = true)
        assertNotEquals(pkg1.reportID, pkg2.reportID)

        val zipEntries = linkedMapOf<String, String>()
        ZipInputStream(ByteArrayInputStream(pkg1.toZipBytes())).use { zis ->
            var entry = zis.nextEntry
            while (entry != null) {
                zipEntries[entry.name] = zis.readBytes().toString(StandardCharsets.UTF_8)
                entry = zis.nextEntry
            }
        }
        assertEquals(setOf("manifest.json", "breadcrumbs.jsonl", "recent-errors.json", "README.txt"), zipEntries.keys)

        SLSDiagnosticWebTracking.validateEndpoint(SLSDiagnosticWebTracking.PRODUCTION_URL)
        assertThrows(DiagnosticUploadException::class.java) {
            SLSDiagnosticWebTracking.validateEndpoint("http://proj-x.cn-shanghai.log.aliyuncs.com/logstores/diag/track")
        }
        assertThrows(DiagnosticUploadException::class.java) {
            SLSDiagnosticWebTracking.validateEndpoint("https://attacker.invalid/logstores/diag/track")
        }

        val payloadBytes = SLSDiagnosticWebTracking.buildPayload(pkg1, env)
        val envelope = JSONObject(payloadBytes.toString(StandardCharsets.UTF_8))
        assertEquals("rawlab-diagnostic-v1", envelope.getString("__topic__"))
        assertEquals("android", envelope.getString("__source__"))
        val logs = envelope.getJSONArray("__logs__")
        assertEquals(1, logs.length())
        assertEquals(pkg1.reportID, logs.getJSONObject(0).getString("report_id"))
    }
}
