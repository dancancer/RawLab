package com.rawlab.android.editor

import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.hasTestTag
import com.rawlab.android.MainActivity
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.testing.LanguageTestRule
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
        fun tool(index: Int) {
            compose.onNodeWithTag("editor-tools").performScrollToNode(hasTestTag("editor-tool-$index"))
            compose.onNodeWithTag("editor-tool-$index").performClick()
        }
        try {
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
            awaitPreview()
            assertEquals(PhotoInputKind.RASTER, model.state.value.photo!!.inputKind)
            assertEquals(EditSettings(), model.state.value.edits)
            for ((label, film) in listOf("中性" to "neutral", "PROVIA" to "provia", "无配方" to "neutral")) {
                tool(15)
                compose.onNodeWithText("保井崇志").performClick()
                awaitPreview()
                assertEquals("takashi_yasui_zen", model.state.value.edits.recipeID)
                if (label != "无配方") tool(0)
                compose.onNodeWithText(label).performClick()
                awaitPreview()
                assertNull(model.state.value.edits.recipeID)
                assertEquals(film, model.state.value.edits.film)
                assertEquals(0f, model.state.value.edits.tint)
                assertFalse(model.state.value.edits.customWb)
            }
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(film = "velvia", exposure = .5f)) }
            awaitPreview()
            source.copyTo(unseen)
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(unseen)) }
            awaitPreview()
            assertEquals(EditSettings(), model.state.value.edits)
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
            awaitPreview()
            assertEquals("velvia", model.state.value.edits.film)
            assertEquals(.5f, model.state.value.edits.exposure)
        } finally { source.delete(); unseen.delete() }
    }
}
