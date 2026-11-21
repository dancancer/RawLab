package com.rawlab.android.camera

import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.Lifecycle
import com.rawlab.android.MainActivity
import com.rawlab.android.R
import com.rawlab.android.camera.protocol.CameraResumeFixture
import com.rawlab.android.camera.protocol.CameraSessionFixture
import com.rawlab.android.testing.LanguageTestRule
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.Job
import kotlinx.coroutines.sync.Mutex
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File
import java.io.ByteArrayOutputStream
import java.util.UUID

class CameraImportInterruptionTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val languageAndCompose: RuleChain = RuleChain.outerRule(LanguageTestRule()).around(compose)

    @Test fun backgroundDuringPreparationDoesNotStartDownload() = backgroundDuringPreparation(false)
    @Test fun foregroundReturnDoesNotReviveInvalidatedPreparation() = backgroundDuringPreparation(true)

    @Test fun backgroundDuringConnectionInvalidatesAndWaitsForTheOldOwner() {
        compose.waitUntil(10_000) { !compose.activity.camera.state.value.preparing }
        val model = compose.activity.camera
        val pending = Job()
        CameraSessionFixture().use { fixture ->
            connectFixture(fixture)
            try {
            compose.runOnUiThread {
                setField(model, "connectionWork", pending)
                val state = field<MutableStateFlow<CameraImportState>>(model, "mutable")
                state.value = state.value.copy(connected = false, stage = SonyCameraConnection.Stage.NETWORK)
                model.onBackground()
            }
            assertTrue(model.state.value.closing)
            assertNull(field<Any?>(model, "session"))
            assertNull(model.state.value.stage)
            compose.runOnUiThread { model.onForeground() }
            assertTrue("New owner must wait for the old connection work", model.state.value.closing)
            pending.complete()
            compose.waitUntil(10_000) { !model.state.value.closing }
            assertFalse(model.state.value.connected)
            } finally {
                pending.complete()
                compose.runOnUiThread { model.onForeground() }
            }
        }
    }

    private fun backgroundDuringPreparation(returnToForeground: Boolean) {
        compose.waitUntil(10_000) { !compose.activity.camera.state.value.preparing }
        val model = compose.activity.camera
        val before = model.state.value.jobs.map { it.id }.toSet()
        // 阻塞已有存储锁来固定异步创建窗口，不给产品增加测试专用暂停逻辑。
        val lock = field<Mutex>(model, "storeLock")
        var held = false
        CameraSessionFixture().use { fixture ->
            connectFixture(fixture)
            try {
                runBlocking { lock.lock() }; held = true
                compose.runOnUiThread { model.startImport() }
                assertTrue(model.state.value.preparing)
                compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
                if (returnToForeground) compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
                lock.unlock(); held = false
                compose.waitUntil(10_000) { model.state.value.let { !it.preparing && !it.transferring } }
                assertEquals("Background preparation emitted a download request", 0, fixture.downloads.get())
                val job = checkNotNull(model.state.value.job)
                assertFalse(job.id in before)
                assertEquals(CameraJobStatus.PAUSED, job.status)
                assertEquals("PAUSED", JSONObject(File(compose.activity.filesDir, "camera-media-imports/${job.id}.json").readText()).getString("status"))
                compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
                compose.onNodeWithTag("camera-open-task").performClick()
                compose.onNodeWithText("上次导入未完成").assertIsDisplayed()
                capture("camera-review-preparation-paused.png")
            } finally {
                if (held) lock.unlock()
                compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
                compose.runOnUiThread { model.disconnect() }
                model.state.value.jobs.filter { it.id !in before }.forEach {
                    File(compose.activity.filesDir, "camera-media-imports/${it.id}.json").delete()
                }
            }
        }
    }

    @Test fun malformedPreviewDisconnectsAndShowsReconnectEntry() {
        compose.waitUntil(10_000) { !compose.activity.camera.state.value.preparing }
        CameraSessionFixture(malformedPreview = true).use { fixture ->
            connectFixture(fixture)
            compose.onNodeWithTag("editor-camera").performClick()
            compose.onNodeWithTag("camera-mode-IMPORT").performClick()
            compose.waitUntil(10_000) {
                compose.activity.camera.state.value.let { !it.connected && !it.closing }
            }
            compose.onNodeWithTag("camera-connect").assertIsDisplayed()
            compose.onNodeWithText(compose.activity.getString(R.string.camera_disconnected)).assertIsDisplayed()
            capture("camera-review-preview-disconnected.png")
        }
    }

    @Test fun unavailablePreviewKeepsConnectionForOtherPhotos() {
        compose.waitUntil(10_000) { !compose.activity.camera.state.value.preparing }
        CameraSessionFixture().use { fixture ->
            val photo = connectFixture(fixture)
            assertNull(runBlocking { compose.activity.camera.preview(photo, false) })
            assertTrue(compose.activity.camera.state.value.connected)
            assertNull(compose.activity.camera.state.value.message)
            compose.runOnUiThread { compose.activity.camera.disconnect() }
        }
    }

    @Test fun resumeOnManualWifiMarksTheMatchingPhotoInTheGrid() {
        compose.waitUntil(10_000) { !compose.activity.camera.state.value.preparing }
        val model = compose.activity.camera
        val bytes = ByteArrayOutputStream().also { stream ->
            val bitmap = Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(0xff5f829a.toInt())
            check(bitmap.compress(Bitmap.CompressFormat.JPEG, 90, stream))
            bitmap.recycle()
        }.toByteArray()
        val fixture = CameraResumeFixture("RESUME-${UUID.randomUUID()}.JPG", bytes)
        val asset = fixture.asset
        val photo = asset.photo()
        val identity = checkNotNull(CameraHardwareIdentity.read(fixture.device))
        val store = field<CameraImportStore>(model, "store")
        val reserved = store.create("ble:old", listOf(photo.copy(key = "previous-handle")), CameraImportDestination("RawLabTests",
            CameraDirectoryGrouping.NONE), hardwareIdentity = identity, listingOwner = "old-listing")
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        val job = reserved.copy(status = CameraJobStatus.PAUSED, items = listOf(reserved.items.single().copy(digest = digest))).also(store::save)
        val state = field<MutableStateFlow<CameraImportState>>(model, "mutable")
        try {
            compose.runOnUiThread { model.selectJob(job) }
            compose.onNodeWithTag("camera-open-task").performClick()
            compose.onNodeWithTag("camera-resume").performClick()
            compose.onNodeWithTag("camera-legacy-connect").performClick()
            compose.onNodeWithTag("camera-use-wifi").assertIsDisplayed()
            compose.runOnUiThread {
                setField(model, "session", fixture)
                setField(model, "device", fixture.device)
                setField(model, "assets", mapOf(photo.key to asset))
                setField(model, "cameraId", "wifi:current")
                state.value = state.value.copy(stage = null, connected = true, cameraId = "wifi:current",
                    hardwareIdentity = identity, photos = listOf(photo), incrementalOwner = "manual-listing")
            }
            compose.onNodeWithTag("camera-resume").performClick()
            compose.waitUntil(15_000) {
                model.state.value.let { !it.transferring && it.job?.status == CameraJobStatus.COMPLETE }
            }
            assertEquals("ble:old", model.state.value.job!!.cameraId)
            assertEquals(1, fixture.listings.get())
            assertEquals(1, fixture.downloads.get())
            compose.onNodeWithTag("camera-back").performClick()
            compose.onNodeWithTag("camera-grid").assertIsDisplayed()
            val saved = hasContentDescription(compose.activity.getString(R.string.camera_saved)) and
                hasAnyAncestor(hasTestTag("camera-item-${photo.key}"))
            compose.onNode(saved, useUnmergedTree = true).assertIsDisplayed()
            capture("camera-resume-manual-wifi-grid.png")
            compose.runOnUiThread { state.value = state.value.copy(photos = listOf(photo.copy(resumeIdentity = "reused-handle"))) }
            compose.onNode(saved, useUnmergedTree = true).assertDoesNotExist()
        } finally {
            compose.runOnUiThread { model.disconnect() }
            compose.waitUntil(10_000) { !model.state.value.closing }
            model.state.value.job?.takeIf { it.id == job.id }?.items?.mapNotNull { it.saved }?.forEach {
                compose.activity.contentResolver.delete(Uri.parse(it.uri), null, null)
            }
            File(compose.activity.filesDir, "camera-media-imports/${job.id}.json").delete()
        }
    }

    private fun connectFixture(fixture: CameraSessionFixture): CameraPhoto {
        val asset = fixture.asset
        val photo = CameraPhoto(asset.key(), asset.name, asset.size, asset.created)
        compose.runOnUiThread {
            val model = compose.activity.camera
            setField(model, "session", fixture.session)
            setField(model, "device", fixture.device)
            setField(model, "assets", mapOf(photo.key to asset))
            setField(model, "cameraId", "fixture")
            val state = field<MutableStateFlow<CameraImportState>>(model, "mutable")
            state.value = state.value.copy(connected = true, cameraId = "fixture", photos = listOf(photo),
                selected = setOf(photo.key), message = null)
        }
        return photo
    }

    @Suppress("UNCHECKED_CAST")
    private fun <T> field(model: CameraImportViewModel, name: String): T =
        CameraImportViewModel::class.java.getDeclaredField(name).apply { isAccessible = true }.get(model) as T
    private fun setField(model: CameraImportViewModel, name: String, value: Any) =
        CameraImportViewModel::class.java.getDeclaredField(name).apply { isAccessible = true }.set(model, value)
    private fun capture(name: String) {
        val bitmap = checkNotNull(androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot())
        File(compose.activity.getExternalFilesDir(null), name).outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }
}
