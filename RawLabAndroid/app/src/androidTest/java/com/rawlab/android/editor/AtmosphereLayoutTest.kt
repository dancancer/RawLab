package com.rawlab.android.editor

import android.content.res.Configuration
import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.R
import com.rawlab.android.RawLabTheme
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.editor.ui.EditorScreen
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.testing.LanguageTestRule
import com.rawlab.android.testing.workbenchTool
import com.rawlab.android.testing.localizedTestContext
import com.rawlab.android.testing.localizedTestConfiguration
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.runner.RunWith
import org.junit.runners.Parameterized
import java.io.File
import java.util.Locale

@RunWith(Parameterized::class)
class AtmosphereLayoutTest(private val language: String) {
    companion object {
        @JvmStatic @Parameterized.Parameters(name = "{0}")
        fun languages() = listOf("zh-Hans", "en", "de", "fr", "ja", "es")
    }
    private val compose = createComposeRule()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule(language)).around(compose)

    @Test fun atmosphereToolsAndNumbersFitInEveryLanguage() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888)
        val config = localizedTestConfiguration(context.resources.configuration, language)
        val localized = localizedTestContext(context, language, config.fontScale)
        assertEquals("The fixture must use the requested language", Locale.forLanguageTag(language).language,
            localized.resources.configuration.locales[0].language)
        compose.setContent {
            CompositionLocalProvider(LocalContext provides localized, LocalConfiguration provides config) {
                RawLabTheme { EditorScreen(state = EditorState(
                    photo = ImportedPhoto(Uri.parse("content://rawlab.test/atmosphere-layout"), "fixture", File("fixture")),
                    edits = EditSettings(clarity = 37.251234f, dehaze = -42.5f),
                    preview = PreviewPair(bitmap, bitmap, temperature = 6500f, tint = 0f), exact = true),
                    onAlbum = {}, onFile = {}, onEdit = { _, _ -> }, onRetry = {}, onExport = {},
                    onMessageDismiss = {}, onLicenses = {}, onGpuChange = {}) }
            }
        }
        for ((id, resource, number) in listOf(Triple(22, R.string.clarity, "37.25"), Triple(23, R.string.dehaze, "-42.5"))) {
            val tool = compose.workbenchTool(id)
            compose.onNodeWithTag("editor-group-effects").assertIsSelected()
            val layouts = mutableListOf<TextLayoutResult>()
            compose.onNodeWithTag("editor-tool-label-$id", useUnmergedTree = true).assertTextEquals(localized.getString(resource))
                .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
            File(context.cacheDir, "atmosphere-layout-$language.png").outputStream().use {
                compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it)
            }
            val visible = compose.onNodeWithTag("editor-tool-label-$id", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
            assertTrue("The complete translated tool label must fit: visible=$visible " + layouts.map { "size=${it.size} right=${it.getLineRight(0)} lines=${it.lineCount} text=${it.layoutInput.text}" },
                layouts.isNotEmpty() && layouts.all { !it.didOverflowHeight &&
                    (0 until it.lineCount).all { line -> !it.isLineEllipsized(line) &&
                        it.getLineRight(line) - it.getLineLeft(line) <= visible.width + 1f } &&
                    it.size.height <= visible.height + 1f })
            tool.performClick()
            compose.onNodeWithTag("editor-parameters").assertIsDisplayed()
            val formatted = if (language in listOf("de", "fr", "es")) number.replace('.', ',') else number
            compose.onNodeWithTag("adjustment-value-$resource").assertIsDisplayed().assertTextContains(formatted)
        }
        File(context.cacheDir, "atmosphere-layout-$language.png").outputStream().use {
            assertTrue(compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it))
        }
    }
}
