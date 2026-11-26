package com.rawlab.android.ui

import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import com.rawlab.android.MainActivity
import com.rawlab.android.R
import com.rawlab.android.adjustments.AdjustmentField
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.testing.*
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File
import java.util.UUID

/** 旋转、深色模式等配置变化会重建 Activity；用户在面板里做到一半的选择必须跟着回来。 */
class SessionStateRestorationUiTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule("zh-Hans")).around(ForegroundTestRule()).around(compose)

    private fun rasterFixture(name: String): File = File(compose.activity.cacheDir, "$name-${UUID.randomUUID()}.png").also { file ->
        Bitmap.createBitmap(64, 48, Bitmap.Config.ARGB_8888).let { bitmap ->
            bitmap.eraseColor(0xFF446688.toInt())
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
        }
    }

    private fun recreate() {
        compose.activityRule.scenario.recreate()
        compose.waitForIdle()
    }

    @Test fun copySheetKeepsCustomFieldsAndPasteSheetClosesAcrossRecreation() {
        val source = rasterFixture("restore-copy")
        val model = compose.activity.model
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            compose.waitUntilEditorReady(model)

            compose.openWorkbenchMenuItem("adjustment-menu-copy")
            compose.onNodeWithTag("adjustment-copy-clear").performScrollTo().performClick()
            compose.onNodeWithTag("adjustment-group-light").performScrollTo().performClick()
            compose.onNodeWithTag("adjustment-field-light.exposure").performScrollTo().performClick()

            recreate()

            compose.onNodeWithTag("adjustment-transfer-root").assertExists()
            // 分组展开只是查看状态，重建后重新展开再核对勾选。
            compose.onNodeWithTag("adjustment-group-light").performScrollTo().performClick()
            compose.onNodeWithTag("adjustment-field-light.exposure").performScrollTo().assertIsOn()
            compose.onNodeWithTag("adjustment-field-light.contrast").performScrollTo().assertIsOff()
            compose.onNodeWithTag("adjustment-copy-confirm").performScrollTo().performClick()
            compose.runOnIdle { assertEquals(setOf(AdjustmentField.EXPOSURE), model.adjustmentClipboard!!.fields) }

            // 粘贴面板的预检随重建作废，刻意不恢复。
            compose.openWorkbenchMenuItem("adjustment-menu-paste")
            compose.onNodeWithTag("adjustment-transfer-root").assertExists()
            recreate()
            compose.onNodeWithTag("adjustment-transfer-root").assertDoesNotExist()
        } finally {
            EditStore(File(compose.activity.filesDir, "edits")).reset(PhotoIdentity(Uri.fromFile(source).toString()))
            source.delete()
        }
    }

    @Test fun presetSaveSheetKeepsTypedNameAcrossRecreation() {
        val source = rasterFixture("restore-preset")
        val model = compose.activity.model
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            compose.waitUntilEditorReady(model)
            compose.openWorkbenchMenuItem("preset-menu")
            compose.onNodeWithTag("preset.quick.manage").performClick()
            compose.onNodeWithTag("preset-create").performClick()
            compose.onNodeWithTag("preset-name").performTextReplacement("Half Typed")

            recreate()

            compose.onNodeWithTag("preset-name").assert(hasText("Half Typed"))
            compose.onNodeWithTag("preset-save").assertExists()
            compose.onNodeWithTag("preset-close").performClick()
            compose.onNodeWithTag("preset-root").assertDoesNotExist()
        } finally {
            EditStore(File(compose.activity.filesDir, "edits")).reset(PhotoIdentity(Uri.fromFile(source).toString()))
            source.delete()
        }
    }

    @Test fun collectionExportSheetKeepsOptionsAcrossRecreation() {
        val source = rasterFixture("restore-export")
        val model = compose.activity.model
        try {
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(source)) }
            compose.waitUntilEditorReady(model)
            val batch = BatchRobot(compose)
            batch.openCollectionAndAssertDisplayed(model)
            batch.openBatchExportConfig()

            compose.onNodeWithTag("export-format-PNG").performScrollTo().performClick()
            compose.onNodeWithTag("export-size").performScrollTo().performClick()
            compose.onNodeWithTag("export-size-custom").performClick()
            compose.onNodeWithTag("export-size-custom-value").performScrollTo().performTextReplacement("1234")
            compose.onNodeWithTag("export-sharpening").performScrollTo().performClick()
            compose.onNodeWithTag("export-sharpening-high").performClick()
            val skip = isToggleable() and hasAnyAncestor(hasTestTag("collection-export-review"))
            compose.onNode(skip).performScrollTo().performClick()
            compose.onNode(skip).assertIsOn()

            recreate()

            compose.onNodeWithTag("collection-export-review").assertExists()
            compose.onNodeWithTag("export-format-PNG").performScrollTo().assertIsSelected()
            compose.onNodeWithTag("export-size-custom-value").performScrollTo().assert(hasText("1234"))
            compose.onNodeWithTag("export-sharpening").performScrollTo()
                .assert(hasText(AppStrings.text(R.string.output_sharpening_high)))
            compose.onNode(skip).performScrollTo().assertIsOn()
            compose.onNodeWithTag("collection-export-start").assertIsNotEnabled()
            compose.onNodeWithTag("collection-export-cancel").performClick()
            compose.onNodeWithTag("collection-export-review").assertDoesNotExist()
        } finally {
            EditStore(File(compose.activity.filesDir, "edits")).reset(PhotoIdentity(Uri.fromFile(source).toString()))
            source.delete()
        }
    }
}
