package com.rawlab.android.editor

import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import com.rawlab.android.MainActivity
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.testing.LanguageTestRule
import com.rawlab.android.testing.openWorkbenchTool
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File

class RasterRecipeSwitchTest {
    val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val languageAndCompose = RuleChain.outerRule(LanguageTestRule()).around(compose)

    @Test fun jpegRecipeCanBeReplacedWithNeutralAndBuiltInFilm() = verifySwitches(Bitmap.CompressFormat.JPEG, "jpg")

    @Test fun pngRecipeCanBeReplacedWithNeutralAndBuiltInFilm() = verifySwitches(Bitmap.CompressFormat.PNG, "png")

    private fun verifySwitches(format: Bitmap.CompressFormat, extension: String) {
        val source = File(compose.activity.cacheDir, "recipe-switch-${System.nanoTime()}.$extension")
        val unseen = File(compose.activity.cacheDir, "recipe-unseen-${System.nanoTime()}.$extension")
        val bitmap = Bitmap.createBitmap(96, 64, Bitmap.Config.ARGB_8888)
        try {
            bitmap.eraseColor(0xFF336699.toInt())
            source.outputStream().use { assertTrue(bitmap.compress(format, 95, it)) }
        } finally { bitmap.recycle() }
        val model = compose.activity.model
        fun awaitPreview() {
            compose.waitUntil(30_000) { model.state.value.canExport || model.state.value.error != null }
            assertNull(model.state.value.error)
            assertTrue(model.state.value.canExport)
        }
        fun tool(index: Int) = compose.openWorkbenchTool(index)
        fun applyDraft() {
            compose.waitUntil(60_000) { model.state.value.draftReady || model.state.value.error != null }
            assertNull(model.state.value.error)
            compose.onNodeWithTag("draft.apply").assertIsEnabled().performClick()
            awaitPreview()
        }
        try {
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
            awaitPreview()
            assertEquals(PhotoInputKind.RASTER, model.state.value.photo!!.inputKind)
            assertEquals(EditSettings().effectiveFor(PhotoInputKind.RASTER), model.state.value.edits)
            for ((label, film) in listOf("中性" to "neutral", "PROVIA" to "provia", "无配方" to "neutral")) {
                tool(15)
                compose.onNodeWithText("保井崇志").performScrollTo().performClick()
                applyDraft()
                assertEquals("takashi_yasui_zen", model.state.value.edits.recipeID)
                // 配方选中态同时把配方的渲染基准写进独立值；换胶片应原样承接该 tint（independentForReset 保值契约）。
                val recipeTint = model.state.value.edits.tint
                assertNotEquals("recipe must carry a non-zero tint baseline, else the keep-check below is vacuous", 0f, recipeTint)
                // draft.apply 关闭工具面板；换胶片回 looks(0)，清除配方回配方面板(15) 点“无配方”磁贴。
                tool(if (label == "无配方") 15 else 0)
                compose.onNodeWithText(label).performScrollTo().performClick()
                applyDraft()
                assertNull(model.state.value.edits.recipeID)
                assertEquals(film, model.state.value.edits.film)
                assertEquals("film switch must keep the recipe's converted tint (preview tint=${model.state.value.preview?.tint})",
                    recipeTint, model.state.value.edits.tint, 0f)
                assertFalse(model.state.value.edits.customWb)
            }
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(film = "velvia", exposure = .5f)) }
            awaitPreview()
            source.copyTo(unseen)
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(unseen)) }
            awaitPreview()
            assertEquals(EditSettings().effectiveFor(PhotoInputKind.RASTER), model.state.value.edits)
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
            awaitPreview()
            assertEquals("velvia", model.state.value.edits.film)
            assertEquals(.5f, model.state.value.edits.exposure)
        } finally { source.delete(); unseen.delete() }
    }
}
