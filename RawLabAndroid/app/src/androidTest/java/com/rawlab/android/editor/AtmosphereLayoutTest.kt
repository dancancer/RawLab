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

    @Test fun atmosphereToolsAndNumbersFitLargeTextInEveryLanguage() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888)
        val config = Configuration(context.resources.configuration).apply { setLocale(Locale.forLanguageTag(language)); fontScale = 1.6f }
        val localized = context.createConfigurationContext(config)
        compose.setContent {
            val density = LocalDensity.current.density
            CompositionLocalProvider(LocalContext provides localized, LocalConfiguration provides config,
                LocalDensity provides Density(density, 1.6f)) {
                RawLabTheme { EditorScreen(state = EditorState(
                    photo = ImportedPhoto(Uri.parse("content://rawlab.test/atmosphere-layout"), "fixture", File("fixture")),
                    edits = EditSettings(clarity = 37.251234f, dehaze = -42.5f),
                    preview = PreviewPair(bitmap, bitmap, temperature = 6500f, tint = 0f), exact = true),
                    onAlbum = {}, onFile = {}, onEdit = { _, _ -> }, onRetry = {}, onExport = {},
                    onMessageDismiss = {}, onLicenses = {}, onGpuChange = {}) }
            }
        }
        compose.onNodeWithTag("editor-groups").performScrollToNode(hasTestTag("editor-group-effects"))
        compose.onNodeWithTag("editor-group-effects").performClick()
        for ((id, resource, number) in listOf(Triple(22, R.string.clarity, "37.25"), Triple(23, R.string.dehaze, "-42.5"))) {
            compose.onNodeWithTag("editor-tools").performScrollToNode(hasTestTag("editor-tool-$id"))
            compose.onNodeWithTag("editor-tool-$id").performClick().assertIsSelected().assertIsDisplayed()
            val layouts = mutableListOf<TextLayoutResult>()
            compose.onNodeWithTag("editor-tool-label-$id", useUnmergedTree = true).assertTextEquals(localized.getString(resource))
                .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
            File(context.cacheDir, "atmosphere-layout-$language.png").outputStream().use {
                compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it)
            }
            val visible = compose.onNodeWithTag("editor-tool-label-$id", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
            assertTrue("The complete translated tool label must fit: visible=$visible " + layouts.map { "size=${it.size} right=${it.getLineRight(0)} lines=${it.lineCount} text=${it.layoutInput.text}" },
                layouts.isNotEmpty() && layouts.all { !it.didOverflowHeight && it.lineCount == 1 &&
                    it.getLineRight(0) <= it.size.width + 1f && it.size.width <= visible.width + 1f })
            val formatted = if (language in listOf("de", "fr", "es")) number.replace('.', ',') else number
            compose.onNodeWithTag("adjustment-value-$resource").assertIsDisplayed().assertTextContains(formatted)
        }
        File(context.cacheDir, "atmosphere-layout-$language.png").outputStream().use {
            assertTrue(compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it))
        }
    }
}
