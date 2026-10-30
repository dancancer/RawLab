package com.rawlab.android.editor

import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.MainActivity
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.settings.X3fMode
import com.rawlab.android.testing.ForegroundTestRule
import com.rawlab.android.testing.LanguageTestRule
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

class X3fEditorTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule()).around(ForegroundTestRule()).around(compose)

    @Test fun modePickerChangesPixelsAndKeepsSavedMode() {
        val source = fixture(false)
        val model = compose.activity.model
        try {
            import(model, source); ready(model)
            assertEquals(X3fMode.NORMAL, model.state.value.edits.x3fMode)
            // 对比参考固定为 1600px；结果预览会随面板布局调整大小。
            val normal = model.state.value.preview!!.neutral
            selectMode(X3fMode.LEGACY); ready(model)
            assertFalse(normal.sameAs(model.state.value.preview!!.neutral))
            capture("legacy")
            selectMode(X3fMode.NORMAL); ready(model)
            val restored = model.state.value.preview!!.neutral
            assertTrue("Normal pixels differ: ${normal.width}x${normal.height} -> ${restored.width}x${restored.height}; ${model.state.value.edits}", normal.sameAs(restored))
            capture("normal")
            savedMode(source, X3fMode.NORMAL)
            val saved = EditStore(File(compose.activity.filesDir, "edits")).load(PhotoIdentity(Uri.fromFile(source).toString()))
            assertEquals(X3fMode.NORMAL, saved!!.x3fMode)
            import(model, source); ready(model)
            assertEquals(X3fMode.NORMAL, model.state.value.edits.x3fMode)
        } finally { source.delete() }
    }

    @Test fun failedFirstAndSavedNormalImportsAllowExplicitLegacyRetry() {
        val source = fixture(true)
        val model = compose.activity.model
        try {
            import(model, source)
            compose.waitUntil(180_000) { model.state.value.retryLegacyX3f }
            compose.onNodeWithTag("x3f.retryLegacy").assertIsDisplayed()
            capture("first-import-failure")
            compose.onNodeWithTag("x3f.retryLegacy").performClick(); ready(model)
            assertEquals(X3fMode.LEGACY, model.state.value.edits.x3fMode)
            selectMode(X3fMode.NORMAL)
            compose.waitUntil(180_000) { !model.state.value.rendering && model.state.value.error != null }
            savedMode(source, X3fMode.NORMAL)
            import(model, source)
            compose.waitUntil(180_000) { model.state.value.retryLegacyX3f }
            compose.onNodeWithTag("x3f.retryLegacy").performClick(); ready(model)
            assertEquals(X3fMode.LEGACY, model.state.value.edits.x3fMode)
            capture("saved-import-recovered")
        } finally { source.delete() }
    }

    @Test fun removingCollectionEntryDoesNotReleasePendingLegacyRecovery() {
        val source = fixture(true)
        val model = compose.activity.model
        val uri = Uri.fromFile(source)
        try {
            compose.runOnUiThread { model.addCollectionPhotos(listOf(uri)) }
            compose.waitUntil(30_000) { model.collection.value.photos.any { it.id == uri.toString() } }
            import(model, source)
            compose.waitUntil(180_000) { model.state.value.retryLegacyX3f }
            compose.runOnUiThread { model.removeCollectionPhoto(uri.toString()) }
            compose.onNodeWithTag("x3f.retryLegacy").performClick(); ready(model)
            assertEquals(X3fMode.LEGACY, model.state.value.edits.x3fMode)
            savedMode(source, X3fMode.LEGACY)
        } finally { source.delete() }
    }

    private fun savedMode(source: File, mode: X3fMode) {
        val store = EditStore(File(compose.activity.filesDir, "edits"))
        compose.waitUntil(30_000) { store.load(PhotoIdentity(Uri.fromFile(source).toString()))?.x3fMode == mode }
    }

    private fun fixture(unsupported: Boolean): File {
        val bytes = InstrumentationRegistry.getInstrumentation().context.assets.open("sample.X3F").use { it.readBytes() }
        if (unsupported) {
            check(ByteBuffer.wrap(bytes, 4, 4).order(ByteOrder.LITTLE_ENDIAN).int == 0x20002)
            val slot = (0 until 32).first { bytes[72 + it].toInt() == 6 }
            ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).putFloat(104 + 4 * slot, 1f)
        }
        return File(compose.activity.cacheDir, "x3f-ui-${System.nanoTime()}.X3F").apply { writeBytes(bytes) }
    }
    private fun import(model: EditorViewModel, file: File) {
        compose.waitUntil(30_000) { !model.state.value.committingAdjustments && model.state.value.operation == Operation.NONE }
        compose.runOnUiThread {
            if (model.state.value.photo == null) model.setGpuEnabled(false)
            model.importPhoto(Uri.fromFile(file))
        }
    }
    private fun ready(model: EditorViewModel) {
        compose.waitUntil(180_000) { model.state.value.canExport || model.state.value.error != null }
        assertNull(model.state.value.error); assertTrue(model.state.value.canExport)
    }
    private fun selectMode(mode: X3fMode) {
        compose.onAllNodesWithContentDescription("更多").onFirst().performClick()
        compose.onNodeWithText("照片处理设置").performClick()
        compose.onNodeWithTag("x3f.mode.${mode.id}").assertIsDisplayed().performClick()
        compose.onNodeWithText("确定").performClick()
    }
    private fun capture(name: String) {
        val output = File(compose.activity.getExternalFilesDir(null), "x3f-verification/$name.png")
        output.parentFile!!.mkdirs()
        output.outputStream().use { compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
}
