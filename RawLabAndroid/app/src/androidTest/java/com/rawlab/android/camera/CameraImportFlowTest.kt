package com.rawlab.android.camera

import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.MainActivity
import com.rawlab.android.editor.AdjustmentGroup
import com.rawlab.android.testing.LanguageTestRule
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File

class CameraImportFlowTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val languageAndCompose: RuleChain = RuleChain.outerRule(LanguageTestRule()).around(compose)

    @Test fun cameraBrowserPreservesDraftUntilSavedPhotoHandoff() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val fixture = java.util.UUID.randomUUID().toString()
        val source = File(context.cacheDir, "camera-flow-source-$fixture.png")
        val incoming = File(context.cacheDir, "camera-flow-incoming-$fixture.png")
        fun raster(file: File, color: Int) {
            val bitmap = Bitmap.createBitmap(320, 240, Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(color)
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
        }
        raster(source, android.graphics.Color.BLUE)
        raster(incoming, android.graphics.Color.GREEN)
        try {
            compose.runOnUiThread { compose.activity.model.setGpuEnabled(false); compose.activity.model.importPhoto(Uri.fromFile(source)) }
            ready()
            assertEquals(Uri.fromFile(source), compose.activity.model.state.value.photo!!.uri)
            compose.onNodeWithTag("editor-camera").performClick()
            compose.runOnUiThread { compose.activity.model.beginDraft(AdjustmentGroup.GEOMETRY) }
            draftReady()
            compose.runOnUiThread {
                val model = compose.activity.model
                model.changeDraft(model.state.value.visibleEdits.copy(geometry = model.state.value.visibleEdits.geometry.copy(cropWidth = .8f)), false)
            }
            draftReady()
            val draft = compose.activity.model.state.value.draft
            val original = compose.activity.model.state.value.photo!!.identity
            assertTrue(draft!!.changed)
            compose.onNodeWithTag("camera-home").assertIsDisplayed()
            capture("camera-connect.png")
            assertEquals(draft, compose.activity.model.state.value.draft)
            compose.onNodeWithTag("camera-menu").performClick()
            compose.onNodeWithTag("camera-history").performClick()
            compose.onNodeWithText("导入记录").assertIsDisplayed()
            repeat(3) { compose.onNodeWithTag("camera-back").performClick() }
            assertEquals(draft, compose.activity.model.state.value.draft)
            assertEquals(original, compose.activity.model.state.value.photo!!.identity)
            // 与相机结果页相同的交接入口：到这一步才显示既有草稿门禁。
            compose.runOnUiThread { compose.activity.model.receiveSystemPhotos(listOf(Uri.fromFile(incoming))) }
            compose.waitUntil(20_000) { compose.activity.model.systemPhotoRequests.value.isNotEmpty() }
            compose.waitForIdle()
            assertNotEquals(compose.activity.model.state.value.photo!!.uri, compose.activity.model.systemPhotoRequests.value.first().uris.first())
            assertEquals(original, compose.activity.model.state.value.photo!!.identity)
            assertEquals(draft, compose.activity.model.state.value.draft)
            compose.onNodeWithText("继续编辑").assertIsDisplayed()
            capture("camera-draft-gate.png")
            compose.onNodeWithText("继续编辑").performClick()
            assertEquals(original, compose.activity.model.state.value.photo!!.identity)
        } finally { source.delete(); incoming.delete() }
    }

    @Test fun cameraHistoryIsAvailableWithoutPermissionOrConnection() {
        compose.onNodeWithTag("editor-camera").performClick()
        compose.onNodeWithTag("camera-menu").performClick()
        compose.onNodeWithTag("camera-history").performClick()
        compose.onNodeWithText("导入记录").assertIsDisplayed()
        assertFalse(compose.activity.camera.state.value.connected)
        assertNull(compose.activity.camera.state.value.stage)
        repeat(3) { compose.onNodeWithTag("camera-back").performClick() }
        compose.onNodeWithTag("editor-camera").assertIsDisplayed()
    }

    @Test fun unfinishedTaskEntryOpensProgressDirectly() {
        val model = compose.activity.camera
        compose.waitUntil(10_000) { !model.state.value.preparing }
        val previous = model.state.value.job
        val pending = CameraImportJob(java.util.UUID.randomUUID().toString(), "fixture", System.currentTimeMillis(),
            listOf(CameraImportItem(CameraPhoto("fixture-key", "camera-resume-fixture.ARW", 1024, 0))), CameraJobStatus.PAUSED)
        try {
            compose.runOnUiThread { model.selectJob(pending) }
            compose.onNodeWithTag("camera-open-task").performClick()
            compose.onNodeWithText("导入进度").assertIsDisplayed()
            compose.onNodeWithText("camera-resume-fixture.ARW").assertIsDisplayed()
            compose.onNodeWithText("上次导入未完成").assertIsDisplayed()
        } finally { if (previous != null) compose.runOnUiThread { model.selectJob(previous) } }
    }

    @Test fun pausedTetherCannotHijackFreshCameraEntryOrHideImport() {
        compose.waitUntil(10_000) { !compose.activity.camera.state.value.preparing }
        compose.runOnUiThread { compose.activity.camera.setMode(CameraMode.TETHER) }
        compose.waitUntil(10_000) { !compose.activity.camera.state.value.closing }
        compose.onNodeWithTag("editor-camera").performClick()
        compose.onNodeWithTag("camera-home").assertIsDisplayed()
        compose.onNodeWithTag("camera-mode-TETHER").performClick()
        compose.onNodeWithTag("camera-connect-screen").assertIsDisplayed()
        compose.onNodeWithTag("camera-back").performClick()
        compose.onNodeWithTag("camera-home").assertIsDisplayed()
        compose.onNodeWithTag("camera-mode-IMPORT").performClick()
        compose.onNodeWithTag("camera-connect-screen").assertIsDisplayed()
        compose.onNodeWithTag("camera-back").performClick()
        compose.onNodeWithTag("camera-back").performClick()
        compose.onNodeWithTag("editor-camera").performClick()
        compose.onNodeWithTag("camera-home").assertIsDisplayed()
    }

    @Test fun tetherEntryAndReturnToImportKeepConnectionGuidanceReachable() {
        compose.waitUntil(10_000) { !compose.activity.camera.state.value.preparing }
        compose.onNodeWithTag("editor-camera").performClick()
        compose.onNodeWithTag("camera-mode-TETHER").performClick()
        compose.onNodeWithTag("camera-connect-screen").assertIsDisplayed()
        compose.runOnUiThread {
            val camera = compose.activity.camera
            camera.tether.restore(emptyList(), camera.state.value.jobs)
            val field = CameraImportViewModel::class.java.getDeclaredField("mutable").apply { isAccessible = true }
            @Suppress("UNCHECKED_CAST")
            val state = field.get(camera) as kotlinx.coroutines.flow.MutableStateFlow<CameraImportState>
            state.value = state.value.copy(connected = true, preparing = false, closing = false)
        }
        compose.onNodeWithTag("tether-menu").performClick()
        compose.onNodeWithTag("tether-switch-import").performClick()
        compose.onNodeWithTag("camera-connect-screen").assertIsDisplayed()
        compose.onNodeWithTag("camera-connection-help").assertIsDisplayed()
        assertEquals(CameraMode.IMPORT, compose.activity.camera.state.value.mode)
        assertFalse(compose.activity.camera.state.value.connected)
    }

    @Test fun connectionHelpUsesASecondPageAndReturnsToTheSameTask() {
        compose.onNodeWithTag("editor-camera").performClick()
        compose.onNodeWithTag("camera-mode-IMPORT").performClick()
        compose.onNodeWithTag("camera-connection-help").performClick()
        compose.onNodeWithTag("camera-connect-help").assertIsDisplayed()
        compose.onNodeWithTag("camera-back").performClick()
        compose.onNodeWithTag("camera-connect-screen").assertIsDisplayed()
    }

    private fun capture(name: String) {
        val file = File(compose.activity.getExternalFilesDir(null), name)
        val bitmap = checkNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot())
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }

    private fun ready() {
        compose.waitUntil(60_000) { compose.activity.model.state.value.let { it.canExport || it.error != null } }
        assertNull(compose.activity.model.state.value.error)
        assertTrue(compose.activity.model.state.value.canExport)
    }
    private fun draftReady() {
        compose.waitUntil(60_000) { compose.activity.model.state.value.let { it.draftReady || it.error != null } }
        assertNull(compose.activity.model.state.value.error)
    }
}
