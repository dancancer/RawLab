package com.rawlab.android.editor

import android.content.ContentValues
import android.graphics.Bitmap
import android.net.Uri
import android.os.SystemClock
import android.provider.MediaStore
import android.view.accessibility.AccessibilityNodeInfo
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.MainActivity
import com.rawlab.android.R
import com.rawlab.android.adjustments.*
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.testing.ForegroundTestRule
import com.rawlab.android.testing.LanguageTestRule
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File

class AdjustmentTargetPickerUITest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule()).around(ForegroundTestRule()).around(compose)
    private val automation get() = InstrumentationRegistry.getInstrumentation().uiAutomation
    private fun ready() {
        compose.waitUntil(60_000) { compose.activity.model.state.value.let { it.canExport || it.error != null } }
        assertNull(compose.activity.model.state.value.error)
    }
    private fun find(node: AccessibilityNodeInfo?, labels: Set<String>): AccessibilityNodeInfo? {
        if (node == null) return null
        if (node.text?.toString() in labels || node.contentDescription?.toString() in labels) return node
        for (i in 0 until node.childCount) find(node.getChild(i), labels)?.let { return it }
        return null
    }
    private fun clickNative(labels: Set<String>, timeout: Long = 10_000): Boolean {
        val end = SystemClock.uptimeMillis() + timeout
        while (SystemClock.uptimeMillis() < end) {
            var node = find(automation.rootInActiveWindow, labels)
            if (node != null) {
                while (node != null && !node.isClickable) node = node.parent
                if (node?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true) return true
            }
            SystemClock.sleep(50)
        }
        return false
    }
    @Test fun systemFilesTargetSelectionAndWholeTransactionUndoUseTheSameSavedRecords() {
        val activity = compose.activity
        val model = activity.model
        val resolver = activity.contentResolver
        val name = "rawlab-transfer-${System.nanoTime()}.png"
        val image = Bitmap.createBitmap(64, 48, Bitmap.Config.ARGB_8888).apply { eraseColor(0xff6699aa.toInt()) }
        val source = File(activity.cacheDir, "picker-source-${System.nanoTime()}.png")
        source.outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
        val downloaded = requireNotNull(resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name); put(MediaStore.Downloads.MIME_TYPE, "image/png")
            put(MediaStore.Downloads.RELATIVE_PATH, "Download/"); put(MediaStore.Downloads.IS_PENDING, 1)
        }))
        try {
            resolver.openOutputStream(downloaded)!!.use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
            resolver.update(downloaded, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }; ready()
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = .5f)) }; ready()
            compose.runOnUiThread { model.copyAdjustments(AdjustmentScope.Custom(setOf(AdjustmentField.EXPOSURE))); model.edit(model.state.value.edits.copy(exposure = .9f)) }; ready()
            compose.onNode(hasContentDescription(activity.getString(R.string.more)) and !hasAnyAncestor(hasTestTag("adjustment-dock"))).performClick()
            compose.onNodeWithTag("adjustment-menu-paste").performClick()
            compose.waitUntil(30_000) { model.adjustmentTransfer.value.prepared != null && !model.adjustmentTransfer.value.preparing }
            compose.onNodeWithTag("adjustment-paste-files").performScrollTo().assertIsEnabled().performClick()
            if (!clickNative(setOf(name), 1500)) {
                assertTrue("System Files roots open", clickNative(setOf("Show roots", "显示根目录", "显示根目录菜单", "Open navigation drawer")))
                assertTrue("Downloads root exists", clickNative(setOf("Downloads", "下载", "下载内容")))
                assertTrue("Fixture appears in the real document provider", clickNative(setOf(name)))
            }
            clickNative(setOf("Open", "打开"), 500)
            compose.onNodeWithText("目标：2 张照片").assertExists()
            compose.onNodeWithTag("adjustment-paste-preflight").assertDoesNotExist()
            compose.waitUntil(30_000) { model.adjustmentTransfer.value.prepared != null }
            val operation = requireNotNull(model.adjustmentTransfer.value.prepared)
            assertEquals(2, operation.targets.size); assertTrue(operation.targets.all { it.error == null })
            compose.onNodeWithTag("adjustment-paste-apply").performScrollTo().performClick(); ready()
            val store = EditStore(File(activity.filesDir, "edits"))
            operation.targets.forEach { assertEquals(.5f, store.load(PhotoIdentity(it.id))!!.exposure) }
            compose.onNodeWithTag("adjustment-transaction-undo-${operation.id}").performScrollTo().performClick(); ready()
            assertEquals(.9f, model.state.value.edits.exposure)
            val second = operation.targets.single { it.id != model.state.value.photo!!.identity.value }
            assertNull(store.load(PhotoIdentity(second.id)))
            compose.onNodeWithTag("adjustment-transaction-redo-${operation.id}").performScrollTo().performClick(); ready()
            operation.targets.forEach { assertEquals(.5f, store.load(PhotoIdentity(it.id))!!.exposure) }
            compose.onNodeWithTag("adjustment-transfer-close").performClick()
        } finally { image.recycle(); source.delete(); resolver.delete(downloaded, null, null) }
    }
}
