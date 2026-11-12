package com.rawlab.android.camera

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.MainActivity
import com.rawlab.android.camera.protocol.CameraIncrementalSessionFixture
import com.rawlab.android.testing.LanguageTestRule
import java.io.File
import java.util.concurrent.TimeUnit
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
    private val compose = createEmptyComposeRule()
    @get:Rule val languageAndCompose: RuleChain = RuleChain.outerRule(LanguageTestRule()).around(compose)

    @Test fun keepingOriginalFromHistoryResumesAnOlderBatchAfterRelaunch() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val source = instrumentation.context.assets.open("apple-legacy-macos26.jpg").use { it.readBytes() }
        val captured = System.currentTimeMillis() - TimeUnit.DAYS.toMillis(3)
        val cutoff = captured - 1_000

        CameraIncrementalSessionFixture(context.cacheDir, jpegSource = source, interruptJpeg = false, created = captured).use { fixture ->
            val blocked = ActivityScenario.launch(MainActivity::class.java).use { activity ->
                val model = camera(activity)
                connect(model, fixture)
                openIncrementalImport()
                compose.runOnUiThread { model.setIncrementalCutoff(cutoff) }
                compose.onNodeWithTag("camera-incremental-format-RAW_AND_JPEG").performClick()
                compose.onNodeWithTag("camera-jpeg-adjust").performClick()
                compose.onNodeWithTag("camera-import").performClick()
                compose.waitUntil(15_000) {
                    val state = model.state.value
                    !state.transferring && state.job?.items?.any { it.problem == CameraMediaProblem.HDR_GAIN_MAP } == true
                }
                val job = checkNotNull(model.state.value.job)
                assertEquals(cutoff, job.incremental?.customCutoffMillis)
                assertEquals(1, job.savedCount)
                assertFalse(job.committed)
                compose.onNodeWithText("此 JPEG 含 HDR 增益图。请选择原样保存以保留 HDR。").assertIsDisplayed()
                val screenshot = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
                try {
                    File(context.getExternalFilesDir(null), "camera-hdr-gain-map-warning.png").outputStream().use {
                        screenshot.compress(Bitmap.CompressFormat.PNG, 100, it)
                    }
                } finally { screenshot.recycle() }
                disconnect(model)
                job
            }

            ActivityScenario.launch(MainActivity::class.java).use { activity ->
                val model = camera(activity)
                try {
                    connect(model, fixture)
                    assertNull(model.state.value.incrementalCutoffMillis)
                    assertTrue(checkNotNull(model.state.value.incrementalScan).assets.isEmpty())
                    compose.onNodeWithTag("editor-camera").performClick()
                    compose.onNodeWithTag("camera-menu").performClick()
                    compose.onNodeWithTag("camera-history").performClick()
                    compose.onNodeWithText("已保存 1 / 2 张").performClick()
                    compose.onNodeWithTag("camera-jpeg-keep-original")
                        .assertTextEquals("剩余 JPEG 原样保存")
                        .assertIsDisplayed()
                        .performClick()
                    compose.waitUntil(15_000) {
                        val state = model.state.value
                        !state.transferring && state.job?.status == CameraJobStatus.COMPLETE
                    }

                    val completed = checkNotNull(model.state.value.job)
                    assertEquals(blocked.id, completed.id)
                    assertEquals(blocked.incremental?.customCutoffMillis, completed.incremental?.customCutoffMillis)
                    assertEquals(blocked.items.first().saved, completed.items.first().saved)
                    assertTrue(completed.committed)
                    assertTrue(model.state.value.incrementalJpeg.adjust)
                    assertTrue(checkNotNull(model.state.value.incrementalScan).needsCutoffConfirmation)
                    compose.runOnUiThread { model.setIncrementalCutoff(cutoff) }
                    // Choosing the old time includes both candidates. The original JPEG saved above
                    // does not satisfy the current preference to save a JPEG with adjustments.
                    assertEquals(listOf(false, true), checkNotNull(model.state.value.incrementalScan).assets.map { it.raw }.sorted())
                    val saved = checkNotNull(completed.items.single { !it.photo.raw }.saved)
                    val output = checkNotNull(context.contentResolver.openInputStream(Uri.parse(saved.uri))).use { it.readBytes() }
                    assertArrayEquals(source, output)
                    assertEquals(listOf(1, 2, 12), fixture.downloadRequests.map { it.file })
                    compose.onNodeWithText("已保存 2 / 2 张").assertIsDisplayed()
                } finally { cleanUp(context, model, fixture) }
            }
        }
    }

    @Test fun resumeRestoresADeletedMediaStoreOriginalBeforeCommitting() {
        ActivityScenario.launch(MainActivity::class.java).use { activity ->
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val model = camera(activity)

            val source = InstrumentationRegistry.getInstrumentation().context.assets.open("apple-legacy-macos26.jpg").use { it.readBytes() }
            CameraIncrementalSessionFixture(context.cacheDir, jpegSource = source, interruptJpeg = false).use { fixture ->
                try {
                    connect(model, fixture)
                    openIncrementalImport()
                    compose.onNodeWithTag("camera-jpeg-adjust").performClick()
                    compose.onNodeWithTag("camera-import").performClick()
                    compose.waitUntil(15_000) {
                        val state = model.state.value
                        !state.transferring && state.job?.items?.any { it.problem == CameraMediaProblem.HDR_GAIN_MAP } == true
                    }
                    val paused = checkNotNull(model.state.value.job)
                    assertFalse(paused.committed)
                    val oldUri = checkNotNull(paused.items.single { it.photo.raw }.saved).uri

                    disconnect(model)
                    connect(model, fixture)
                    assertEquals(1, context.contentResolver.delete(Uri.parse(oldUri), null, null))
                    context.getSharedPreferences("camera-media-sources", 0).edit().remove(oldUri).commit()
                    compose.onNodeWithTag("camera-jpeg-keep-original").performClick()
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
    }

    private fun camera(activity: ActivityScenario<MainActivity>): CameraImportViewModel {
        lateinit var model: CameraImportViewModel
        activity.onActivity { model = it.camera }
        compose.waitUntil(10_000) { !model.state.value.preparing }
        return model
    }

    private fun disconnect(model: CameraImportViewModel) {
        compose.runOnUiThread { model.disconnect() }
        compose.waitUntil(10_000) { !model.state.value.closing }
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
        disconnect(model)
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
