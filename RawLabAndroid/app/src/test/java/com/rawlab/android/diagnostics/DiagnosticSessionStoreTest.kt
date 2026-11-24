package com.rawlab.android.diagnostics

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
    fun defaultOffRecordsZeroBreadcrumbsAndLeaseExpiresAutomatically() {
        var nowMs = 1_795_000_000_000L
        val dir = tempFolder.newFolder("diag-lease")

        val store1 = DiagnosticSessionStore(dir, env, leaseDurationMs = 1_800_000L, clockMs = { nowMs })
        assertFalse(store1.isRecording)
        store1.recordBreadcrumb(category = "import", stage = "ignored", message = "Off")
        assertEquals(0, store1.stateSnapshot().breadcrumbCount)

        val enabled = store1.setRecordingEnabled(true)
        assertTrue(enabled.isRecording)
        store1.recordBreadcrumb(category = "import", stage = "open", message = "Opened RAW", context = mapOf("extension" to "arw"))
        assertTrue(store1.stateSnapshot().breadcrumbCount >= 2)

        // First relaunch within 30 minutes stays active
        nowMs += 60_000L
        val store2 = DiagnosticSessionStore(dir, env, leaseDurationMs = 1_800_000L, clockMs = { nowMs })
        val relaunch1 = store2.resumeOnLaunch()
        assertTrue(relaunch1.isRecording)

        // Second relaunch auto-resets switch to off while keeping logs exportable
        nowMs += 60_000L
        val store3 = DiagnosticSessionStore(dir, env, leaseDurationMs = 1_800_000L, clockMs = { nowMs })
        val relaunch2 = store3.resumeOnLaunch()
        assertFalse(relaunch2.isRecording)
        assertTrue(relaunch2.recoveredPreviousSession)
        assertTrue(relaunch2.hasExportableLogs)
    }

    @Test
    fun redactionZipIntegrityAndSlsPayloadContract() {
        val dir = tempFolder.newFolder("diag-zip")
        val store = DiagnosticSessionStore(
            directory = dir,
            environment = env,
            extraRedactedPaths = listOf("/custom/app/files" to "<files>"),
        )
        store.setRecordingEnabled(true)
        store.recordBreadcrumb(
            level = "warn",
            category = "preview",
            stage = "openUri",
            message = "Failed reading content://media/external/images/media/9999 and /storage/emulated/0/DCIM/Camera/DSC0001.ARW",
            context = mapOf(
                "extension" to "privateext",
                "localFile" to "/custom/app/files/retained/secret.arw",
            ),
        )
        store.recordError(
            operation = "export",
            stage = "writeFile",
            error = IllegalStateException("Failed writing /data/user/0/com.rawlab.android/cache/photo.jpg"),
            context = mapOf("extension" to "jpg"),
        )

        val pkg = store.buildReportPackage(
            userNote = "导出 /storage/emulated/0/Pictures/secret.jpg 失败",
            stopActiveRecording = true,
        )
        assertFalse(store.isRecording)
        assertTrue(DiagnosticReportIds.isValid(pkg.reportID))

        val allText = pkg.manifestJSON + "\n" + pkg.breadcrumbsJSONL + "\n" + pkg.recentErrorsJSON
        assertFalse(allText.contains("DSC0001"))
        assertFalse(allText.contains("content://media"))
        assertFalse(allText.contains("/storage/emulated"))
        assertFalse(allText.contains("/data/user/0"))
        assertFalse(allText.contains("privateext"))
        assertTrue(allText.contains("\"extension\": \"unknown\"") || allText.contains("\"extension\":\"unknown\""))

        // Verify ZIP entries
        val zipEntries = linkedMapOf<String, String>()
        ZipInputStream(ByteArrayInputStream(pkg.toZipBytes())).use { zis ->
            var entry = zis.nextEntry
            while (entry != null) {
                zipEntries[entry.name] = zis.readBytes().toString(StandardCharsets.UTF_8)
                entry = zis.nextEntry
            }
        }
        assertEquals(setOf("manifest.json", "breadcrumbs.jsonl", "recent-errors.json", "README.txt"), zipEntries.keys)

        // Verify SLS WebTracking endpoint guard & payload
        SLSDiagnosticWebTracking.validateEndpoint(SLSDiagnosticWebTracking.PRODUCTION_URL)
        assertThrows(DiagnosticUploadException::class.java) {
            SLSDiagnosticWebTracking.validateEndpoint("http://proj-x.cn-shanghai.log.aliyuncs.com/logstores/diag/track")
        }
        assertThrows(DiagnosticUploadException::class.java) {
            SLSDiagnosticWebTracking.validateEndpoint("https://attacker.invalid/logstores/diag/track")
        }

        val payloadBytes = SLSDiagnosticWebTracking.buildPayload(pkg, env)
        val envelope = JSONObject(payloadBytes.toString(StandardCharsets.UTF_8))
        assertEquals("rawlab-diagnostic-v1", envelope.getString("__topic__"))
        assertEquals("android", envelope.getString("__source__"))
        val logs = envelope.getJSONArray("__logs__")
        assertEquals(1, logs.length())
        assertEquals(pkg.reportID, logs.getJSONObject(0).getString("report_id"))
    }
}
