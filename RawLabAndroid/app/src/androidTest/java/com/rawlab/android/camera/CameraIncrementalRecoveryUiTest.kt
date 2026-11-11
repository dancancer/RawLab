package com.rawlab.android.camera

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.MainActivity
import com.rawlab.android.camera.protocol.CameraIncrementalSessionFixture
import com.rawlab.android.testing.LanguageTestRule
import java.io.File
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain

class CameraIncrementalRecoveryUiTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val languageAndCompose: RuleChain = RuleChain.outerRule(LanguageTestRule()).around(compose)

    @Test fun keepingOriginalAfterGainMapWarningPublishesTheCameraBytes() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val source = instrumentation.context.assets.open("apple-legacy-macos26.jpg").use { it.readBytes() }
        val model = compose.activity.camera
        compose.waitUntil(10_000) { !model.state.value.preparing }

        CameraIncrementalSessionFixture(context.cacheDir, jpegSource = source, interruptJpeg = false).use { fixture ->
            try {
                connect(model, fixture)
                openIncrementalImport()
                compose.onNodeWithTag("camera-incremental-format-JPEG").performClick()
                compose.onNodeWithTag("camera-jpeg-adjust").performClick()
                compose.onNodeWithTag("camera-import").performClick()
                compose.waitUntil(15_000) {
                    val state = model.state.value
                    !state.transferring && state.job?.items?.singleOrNull()?.problem == CameraMediaProblem.HDR_GAIN_MAP
                }
                val blocked = checkNotNull(model.state.value.job)
                assertNull(blocked.items.single().saved)
                compose.onNodeWithText("此 JPEG 含 HDR 增益图。请选择原样保存以保留 HDR。").assertIsDisplayed()
                val screenshot = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
                try {
                    File(context.getExternalFilesDir(null), "camera-hdr-gain-map-warning.png").outputStream().use {
                        screenshot.compress(Bitmap.CompressFormat.PNG, 100, it)
                    }
                } finally { screenshot.recycle() }

                compose.onNodeWithTag("camera-jpeg-keep-original").performClick()
                compose.onNodeWithTag("camera-import").performClick()
                compose.waitUntil(15_000) {
                    val job = model.state.value.job
                    job != null && job.id != blocked.id && job.status == CameraJobStatus.COMPLETE
                }
                val saved = checkNotNull(model.state.value.job?.items?.single()?.saved)
                val output = checkNotNull(context.contentResolver.openInputStream(Uri.parse(saved.uri))).use { it.readBytes() }
                assertArrayEquals(source, output)
                assertEquals(listOf(2, 2), fixture.downloadRequests.map { it.file })
            } finally { cleanUp(context, model, fixture) }
        }
    }

    @Test fun resumeRestoresADeletedMediaStoreOriginalBeforeCommitting() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val model = compose.activity.camera
        compose.waitUntil(10_000) { !model.state.value.preparing }

        CameraIncrementalSessionFixture(context.cacheDir).use { fixture ->
            try {
                connect(model, fixture)
                openIncrementalImport()
                compose.onNodeWithTag("camera-import").performClick()
                compose.waitUntil(15_000) {
                    val state = model.state.value
                    !state.transferring && !state.closing && !state.connected && state.job?.savedCount == 1
                }
                val paused = checkNotNull(model.state.value.job)
                assertFalse(paused.committed)
                val oldUri = checkNotNull(paused.items.single { it.photo.raw }.saved).uri

                connect(model, fixture)
                assertEquals(1, context.contentResolver.delete(Uri.parse(oldUri), null, null))
                context.getSharedPreferences("camera-media-sources", 0).edit().remove(oldUri).commit()
                compose.onNodeWithTag("camera-resume").performClick()
                compose.waitUntil(15_000) {
                    val state = model.state.value
                    !state.transferring && state.job?.status == CameraJobStatus.COMPLETE
                }
                val completed = checkNotNull(model.state.value.job)
                assertEquals(paused.id, completed.id)
                assertTrue(completed.committed)
                assertEquals(2, completed.savedCount)
                val restored = checkNotNull(completed.items.single { it.photo.raw }.saved).uri
                assertNotEquals(oldUri, restored)
                val raw = checkNotNull(context.contentResolver.openInputStream(Uri.parse(restored))).use { it.readBytes() }
                assertArrayEquals(fixture.rawBytes, raw)
                assertEquals(listOf(1, 1, 2, 2), fixture.downloadRequests.map { it.connection })
                assertEquals(listOf(1, 2, 11, 12), fixture.downloadRequests.map { it.file })
            } finally { cleanUp(context, model, fixture) }
        }
    }

    private fun connect(model: CameraImportViewModel, fixture: CameraIncrementalSessionFixture) {
        compose.runOnUiThread { model.connectImport(fixture.factory, fixture.address, fixture.cameraId) }
        compose.waitUntil(15_000) { model.state.value.connected && model.state.value.photos.size == 2 }
    }

    private fun openIncrementalImport() {
        compose.onNodeWithTag("editor-camera").performClick()
        compose.onNodeWithTag("camera-mode-IMPORT").performClick()
        compose.onNodeWithTag("camera-import-mode-INCREMENTAL").performClick()
    }

    private fun cleanUp(context: Context, model: CameraImportViewModel, fixture: CameraIncrementalSessionFixture) {
        compose.runOnUiThread { model.disconnect() }
        compose.waitUntil(10_000) { !model.state.value.closing }
        val sources = context.getSharedPreferences("camera-media-sources", 0).edit()
        model.state.value.jobs.filter { it.cameraId == fixture.cameraId }.forEach { job ->
            job.items.mapNotNull { it.saved?.uri }.distinct().forEach { uri ->
                context.contentResolver.delete(Uri.parse(uri), null, null)
                sources.remove(uri)
            }
            File(context.filesDir, "camera-media-imports/${job.id}.json").delete()
        }
        sources.commit()
        val preferences = context.getSharedPreferences("camera-import", 0)
        val edit = preferences.edit()
        preferences.all.keys.filter { it.startsWith("camera:${fixture.cameraId}:") }.forEach(edit::remove)
        edit.commit()
    }
}
